 %% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at https://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2020 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_maintenance).

 -include("rabbit.hrl").
 
 -export([
     drain/0,
     revive/0,
     mark_as_being_drained/0,
     unmark_as_being_drained/0,
     is_being_drained_local_read/1,
     is_being_drained_consistent_read/1,
     filter_out_drained_nodes_local_read/1,
     filter_out_drained_nodes_consistent_read/1,
     suspend_all_client_listeners/0,
     resume_all_client_listeners/0,
     close_all_client_connections/0,
     primary_replica_transfer_candidate_nodes/0,
     random_primary_replica_transfer_candidate_node/1,
     transfer_leadership_of_quorum_queues/1,
     transfer_leadership_of_classic_mirrored_queues/1]).

 -define(TABLE, rabbit_node_maintenance_states).
 -define(DEFAULT_STATUS,  regular).
 -define(DRAINING_STATUS, draining).
 
%%
%% API
%%

drain() ->
    rabbit_log:alert("This node is being put into maintenance (drain) mode"),
    mark_as_being_drained(),
    rabbit_log:info("Marked this node as undergoing maintenance"),
    suspend_all_client_listeners(),
    rabbit_log:alert("Suspended all listeners and will no longer accept client connections"),
    {ok, NConnections} = close_all_client_connections(),
    rabbit_log:alert("Closed ~b local client connections", [NConnections]),

    TransferCandidates = primary_replica_transfer_candidate_nodes(),
    ReadableCandidates = string:join(lists:map(fun rabbit_data_coercion:to_list/1, TransferCandidates), ","),
    rabbit_log:info("Node will transfer primary replicas of its queues to ~b peers: ~s",
                    [length(TransferCandidates), ReadableCandidates]),
    transfer_leadership_of_classic_mirrored_queues(TransferCandidates),
    %% TODO: shut all Ra instances on this node down
    transfer_leadership_of_quorum_queues(TransferCandidates),
    rabbit_log:alert("Node is ready to be shut down for maintenance or upgrade"),

    ok.

revive() ->
    resume_all_client_listeners(),
    unmark_as_being_drained(),

    ok.

-spec mark_as_being_drained() -> boolean().
mark_as_being_drained() ->
    set_maintenance_state_status(?DRAINING_STATUS).
 
-spec unmark_as_being_drained() -> boolean().
unmark_as_being_drained() ->
    set_maintenance_state_status(?DEFAULT_STATUS).

set_maintenance_state_status(Status) ->
    Res = mnesia:transaction(fun () ->
        case mnesia:wread({?TABLE, node()}) of
           [] ->
                Row = #node_maintenance_state{
                        node   = node(),
                        status = Status
                     },
                mnesia:write(?TABLE, Row, write);
            [Row0] ->
                Row = Row0#node_maintenance_state{
                        node   = node(),
                        status = Status
                      },
                mnesia:write(?TABLE, Row, write)
        end
    end),
    case Res of
        {atomic, ok} -> true;
        _            -> false
    end.
 
 
-spec is_being_drained_local_read(node()) -> boolean().
is_being_drained_local_read(Node) ->
    case mnesia:dirty_read(?TABLE, Node) of
        []  -> false;
        [#node_maintenance_state{node = Node, status = Status}] ->
            Status =:= ?DRAINING_STATUS;
        _   -> false
    end.

-spec is_being_drained_consistent_read(node()) -> boolean().
is_being_drained_consistent_read(Node) ->
    case mnesia:transaction(fun() -> mnesia:read(?TABLE, Node) end) of
        {atomic, []} -> false;
        {atomic, [#node_maintenance_state{node = Node, status = Status}]} ->
            Status =:= ?DRAINING_STATUS;
        {atomic, _}  -> false;
        {aborted, _Reason} -> false
    end.

 -spec filter_out_drained_nodes_local_read([node()]) -> [node()].
filter_out_drained_nodes_local_read(Nodes) ->
    lists:filter(fun(N) -> not is_being_drained_local_read(N) end, Nodes).
 
-spec filter_out_drained_nodes_consistent_read([node()]) -> [node()].
filter_out_drained_nodes_consistent_read(Nodes) ->
    lists:filter(fun(N) -> not is_being_drained_consistent_read(N) end, Nodes).
 
-spec suspend_all_client_listeners() -> rabbit_types:ok_or_error(any()).
 %% Pauses all listeners on the current node except for
 %% Erlang distribution (clustering and CLI tools).
 %% A respausedumed listener will not accept any new client connections
 %% but previously established connections won't be interrupted.
suspend_all_client_listeners() ->
    Listeners = rabbit_networking:node_client_listeners(node()),
    rabbit_log:info("Asked to suspend ~b client connection listeners. "
                    "No new client connections will be accepted until these listeners are resumed!", [length(Listeners)]),
    Results = lists:foldl(local_listener_fold_fun(fun ranch:suspend_listener/1), [], Listeners),
    lists:foldl(fun ok_or_first_error/2, ok, Results).

 -spec resume_all_client_listeners() -> rabbit_types:ok_or_error(any()).
 %% Resumes all listeners on the current node except for
 %% Erlang distribution (clustering and CLI tools).
 %% A resumed listener will accept new client connections.
resume_all_client_listeners() ->
    Listeners = rabbit_networking:node_client_listeners(node()),
    rabbit_log:info("Asked to resume ~b client connection listeners. "
                    "New client connections will be accepted from now on", [length(Listeners)]),
    Results = lists:foldl(local_listener_fold_fun(fun ranch:resume_listener/1), [], Listeners),
    lists:foldl(fun ok_or_first_error/2, ok, Results).

 -spec close_all_client_connections() -> {'ok', non_neg_integer()}.
close_all_client_connections() ->
    Pids = rabbit_networking:local_connections(),
    rabbit_networking:close_connections(Pids, "Node was put into maintenance mode"),
    {ok, length(Pids)}.

-spec transfer_leadership_of_quorum_queues([node()]) -> ok.
transfer_leadership_of_quorum_queues([]) ->
    rabbit_log:warning("Skipping leadership transfer of quorum queues: no candidate "
                       "(online, not under maintenance) nodes to transfer to!");
transfer_leadership_of_quorum_queues(TransferCandidates) ->
    TransferCandidates.

-spec transfer_leadership_of_classic_mirrored_queues([node()]) -> ok.
 transfer_leadership_of_classic_mirrored_queues([]) ->
    rabbit_log:warning("Skipping leadership transfer of classic mirrored queues: no candidate "
                       "(online, not under maintenance) nodes to transfer to!");
transfer_leadership_of_classic_mirrored_queues(TransferCandidates) ->
    Queues = rabbit_amqqueue:list_local_mirrored_classic_queues(),
    ReadableCandidates = string:join(lists:map(fun rabbit_data_coercion:to_list/1, TransferCandidates), ", "),
    rabbit_log:info("Will transfer leadership of ~b classic mirrored queues to these nodes: ~s",
                    [length(Queues), ReadableCandidates]),
    
    [begin
         Name = amqqueue:get_name(Q),
         case random_primary_replica_transfer_candidate_node(TransferCandidates) of
             {ok, Pick} ->
                 rabbit_log:debug("Will transfer leadership of local queue ~s to node ~s",
                          [rabbit_misc:rs(Name), Pick]),
                 case rabbit_mirror_queue_misc:transfer_leadership(Q, Pick) of
                     {migrated, _} ->
                         rabbit_log:debug("Successfully transferred leadership of queue ~s to node ~s",
                                          [rabbit_misc:rs(Name), Pick]);
                     Other ->
                         rabbit_log:warning("Could not transfer leadership of queue ~s to node ~s: ~p",
                                            [rabbit_misc:rs(Name), Pick, Other])
                 end;
             undefined ->
                 rabbit_log:warning("Could not transfer leadership of queue ~s: no suitable candidates?",
                                    [Name])
         end
     end || Q <- Queues],
    rabbit_log:info("Leadership transfer for local classic mirrored queues is complete").

-spec primary_replica_transfer_candidate_nodes() -> [node()].
primary_replica_transfer_candidate_nodes() ->
    filter_out_drained_nodes_consistent_read(rabbit_nodes:all_running() -- [node()]).

-spec random_primary_replica_transfer_candidate_node([node()]) -> {ok, node()} | undefined.
random_primary_replica_transfer_candidate_node([]) ->
    undefined;
random_primary_replica_transfer_candidate_node(Candidates) ->
    Nth = erlang:phash2(erlang:monotonic_time(), length(Candidates)),
    Candidate = lists:nth(Nth + 1, Candidates),
    {ok, Candidate}.
    
 
%%
%% Implementation
%%

local_listener_fold_fun(Fun) ->
    fun(#listener{node = Node, ip_address = Addr, port = Port}, Acc) when Node =:= node() ->
            RanchRef = rabbit_networking:ranch_ref(Addr, Port),
            [Fun(RanchRef) | Acc];
        (_, Acc) ->
            Acc
    end.
 
ok_or_first_error(ok, Acc) ->
    Acc;
ok_or_first_error({error, _} = Err, _Acc) ->
    Err.
