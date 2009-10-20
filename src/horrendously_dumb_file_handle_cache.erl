%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2009 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2009 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2009 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(horrendously_dumb_file_handle_cache).

-export([init/0, open/4, close/2, release/2, read/4, write/4, sync/2,
         position/3, truncate/2, with_file_handle_at/4, sync_to_offset/3]).

-record(hcstate,
        { ref_entry, path_mode_ref }).

-record(entry,
        { hdl,
          current_offset,
          last_sync_offset,
          is_dirty,
          is_append,
          at_eof,
          path_mode_key }).

init() ->
    #hcstate { ref_entry = dict:new(),
               path_mode_ref = dict:new() }.

open(Path, Mode, [] = _ExtraOptions,
     State = #hcstate { ref_entry = RefEntry, path_mode_ref = PathModeRef }) ->
    Mode1 = lists:usort(Mode),
    Path1 = filename:absname(Path),
    Key = {Path1, Mode1},
    case dict:find(Key, PathModeRef) of
        {ok, Ref} -> {{ok, Ref}, State};
        error ->
            case file:open(Path1, Mode1) of
                {ok, Hdl} ->
                    Ref = make_ref(),
                    PathModeRef1 = dict:store(Key, Ref, PathModeRef),
                    Entry = #entry { hdl = Hdl, current_offset = 0,
                                     last_sync_offset = 0, is_dirty = false,
                                     is_append = lists:member(append, Mode1),
                                     at_eof = false, path_mode_key = Key },
                    RefEntry1 = dict:store(Ref, Entry, RefEntry),
                    {{ok, Ref}, State #hcstate { ref_entry = RefEntry1,
                                                 path_mode_ref = PathModeRef1 }};
                {error, Error} ->
                    {{error, Error}, State}
            end
    end.

close(Ref, State = #hcstate { ref_entry = RefEntry,
                              path_mode_ref = PathModeRef }) ->
    {ok,
     case dict:find(Ref, RefEntry) of
         {ok, #entry { hdl = Hdl, is_dirty = IsDirty, path_mode_key = Key }} ->
             ok = case IsDirty of
                      true -> file:sync(Hdl);
                      false -> ok
                  end,
             ok = file:close(Hdl),
             State #hcstate { ref_entry = dict:erase(Ref, RefEntry),
                              path_mode_ref = dict:erase(Key, PathModeRef) };
         error -> State
     end}.

release(_Ref, State) -> %% noop for the time being
    {ok, State}.

read(Ref, Offset, Count, State = #hcstate { ref_entry = RefEntry }) ->
    case dict:find(Ref, RefEntry) of
        {ok, Entry = #entry { hdl = Hdl, current_offset = OldOffset }} ->
            NewOffset = Count +
                case Offset of
                    cur -> OldOffset;
                    _ -> {ok, RealOff} = file:position(Hdl, Offset),
                         RealOff
                end,
            Entry1 = Entry #entry { current_offset = NewOffset,
                                    at_eof = Offset =:= eof },
            State1 = State #hcstate { ref_entry = dict:store(Ref, Entry1,
                                                             RefEntry) },
            {file:read(Hdl, Count), State1};
        error -> {{error, not_open}, State}
    end.

%% if the file was opened in append mode, then Offset is ignored, as
%% it would only affect the read head for this file.
write(Ref, Offset, Data, State = #hcstate { ref_entry = RefEntry }) ->
    case dict:find(Ref, RefEntry) of
        {ok, Entry = #entry { hdl = Hdl, current_offset = OldOffset,
                              is_append = IsAppend, at_eof = AtEoF }} ->
            NewOffset =
                case IsAppend of
                    true ->
                        OldOffset;
                    false ->
                        size_of_write_data(Data) +
                            case Offset of
                                cur -> OldOffset;
                                eof when AtEoF -> OldOffset;
                                _ -> {ok, RealOff} = file:position(Hdl, Offset),
                                     RealOff
                            end
                end,
            Entry1 = Entry #entry { current_offset = NewOffset,
                                    is_dirty = true, at_eof = Offset =:= eof },
            State1 = State #hcstate { ref_entry = dict:store(Ref, Entry1,
                                                             RefEntry) },
            {file:write(Hdl, Data), State1};
        error -> {{error, not_open}, State}
    end.

sync(Ref, State = #hcstate { ref_entry = RefEntry }) ->
    case dict:find(Ref, RefEntry) of
        {ok, Entry = #entry { hdl = Hdl, current_offset = Offset,
                              last_sync_offset = LastSyncOffset,
                              is_dirty = true }} ->
            SyncOffset = lists:max([Offset, LastSyncOffset]),
            ok = file:sync(Hdl),
            Entry1 = Entry #entry { last_sync_offset = SyncOffset,
                                    is_dirty = false },
            {ok, State #hcstate { ref_entry = dict:store(Ref, Entry1,
                                                         RefEntry) }};
        {ok, _Entry_not_dirty} ->
            {ok, State};
        error -> {{error, not_open}, State}
    end.

position(Ref, NewOffset, State = #hcstate { ref_entry = RefEntry }) ->
    case dict:find(Ref, RefEntry) of
        {ok, #entry { current_offset = NewOffset }} ->
            {ok, State};
        {ok, #entry { at_eof = true }} when NewOffset =:= eof ->
            {ok, State};
        {ok, Entry = #entry { hdl = Hdl }} ->
            {ok, RealOff} = file:position(Hdl, NewOffset),
            Entry1 = Entry #entry { current_offset = RealOff,
                                    at_eof = NewOffset =:= eof },
            {ok, State #hcstate { ref_entry = dict:store(Ref, Entry1,
                                                         RefEntry) }};
        error ->
            {{error, not_open}, State}
    end.

truncate(Ref, State = #hcstate { ref_entry = RefEntry }) ->
    case dict:find(Ref, RefEntry) of
        {ok, Entry = #entry { hdl = Hdl, current_offset = Offset,
                              last_sync_offset = LastSyncOffset,
                              is_dirty = IsDirty }} ->
            ok = case IsDirty of
                     true -> file:sync(Hdl);
                     false -> ok
                 end,
            LastSyncOffset1 = lists:min([Offset, LastSyncOffset]),
            ok = file:truncate(Hdl),
            Entry1 = Entry #entry { last_sync_offset = LastSyncOffset1,
                                    is_dirty = false, at_eof = true },
            {ok, State #hcstate { ref_entry = dict:store(Ref, Entry1,
                                                         RefEntry) }};
        error -> {{error, not_open}, State}
    end.

with_file_handle_at(Ref, Offset, Fun,
                    State = #hcstate { ref_entry = RefEntry }) ->
    case dict:find(Ref, RefEntry) of
        {ok, Entry = #entry { hdl = Hdl, current_offset = OldOffset,
                              last_sync_offset = LastSyncOffset,
                              is_dirty = IsDirty, at_eof = AtEoF }} ->
            Offset1 =
                case Offset of
                    eof when AtEoF -> OldOffset;
                    cur       -> OldOffset;
                    OldOffset -> OldOffset;
                    _         -> {ok, RealOff} = file:position(Hdl, Offset),
                                 RealOff
                end,
            LastSyncOffset1 =
                case IsDirty of
                    true -> ok = file:sync(Hdl),
                            lists:max([Offset1, OldOffset]);
                    false -> LastSyncOffset
                end,
            {Offset2, Result} = Fun(Hdl),
            Entry1 = Entry #entry { current_offset = Offset2,
                                    last_sync_offset = LastSyncOffset1,
                                    is_dirty = true, at_eof = false },
            State1 = State #hcstate { ref_entry = dict:store(Ref, Entry1,
                                                             RefEntry) },
            {Result, State1};
        error -> {{error, not_open}, State}
    end.

sync_to_offset(Ref, Offset, State = #hcstate { ref_entry = RefEntry }) ->
    case dict:find(Ref, RefEntry) of
        {ok, Entry = #entry { hdl = Hdl, last_sync_offset = LastSyncOffset,
                              current_offset = CurOffset, is_dirty = true }}
        when (Offset =:= cur andalso CurOffset > LastSyncOffset)
        orelse (Offset > LastSyncOffset) ->
            ok = file:sync(Hdl),
            LastSyncOffset1 =
                case Offset of
                    cur -> lists:max([LastSyncOffset, CurOffset]);
                    _ -> lists:max([LastSyncOffset, CurOffset, Offset])
                end,
            Entry1 = Entry #entry { last_sync_offset = LastSyncOffset1,
                                    is_dirty = false },
            {ok, State #hcstate { ref_entry = dict:store(Ref, Entry1,
                                                         RefEntry) }};
        {ok, _Entry} -> {ok, State};
        error -> {{error, not_open}, State}
    end.

size_of_write_data(Data) ->
    size_of_write_data(Data, 0).

size_of_write_data([], Acc) ->
    Acc;
size_of_write_data([A|B], Acc) ->
    size_of_write_data(B, size_of_write_data(A, Acc));
size_of_write_data(Bin, Acc) when is_binary(Bin) ->
    size(Bin) + Acc.
