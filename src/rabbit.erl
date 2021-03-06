%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%

-module(rabbit).

-behaviour(application).

-export([prepare/0, start/0, stop/0, stop_and_halt/0, status/0,
         is_running/0 , is_running/1, environment/0,
         rotate_logs/1, force_event_refresh/0]).

-export([start/2, stop/1]).

-export([log_location/1]). %% for testing

%%---------------------------------------------------------------------------
%% Boot steps.
-export([maybe_insert_default_data/0, boot_delegate/0, recover/0]).

-rabbit_boot_step({pre_boot, [{description, "rabbit boot start"}]}).

-rabbit_boot_step({codec_correctness_check,
                   [{description, "codec correctness check"},
                    {mfa,         {rabbit_binary_generator,
                                   check_empty_content_body_frame_size,
                                   []}},
                    {requires,    pre_boot},
                    {enables,     external_infrastructure}]}).

-rabbit_boot_step({database,
                   [{mfa,         {rabbit_mnesia, init, []}},
                    {requires,    file_handle_cache},
                    {enables,     external_infrastructure}]}).

-rabbit_boot_step({file_handle_cache,
                   [{description, "file handle cache server"},
                    {mfa,         {rabbit_sup, start_restartable_child,
                                   [file_handle_cache]}},
                    {requires,    pre_boot},
                    {enables,     worker_pool}]}).

-rabbit_boot_step({worker_pool,
                   [{description, "worker pool"},
                    {mfa,         {rabbit_sup, start_child, [worker_pool_sup]}},
                    {requires,    pre_boot},
                    {enables,     external_infrastructure}]}).

-rabbit_boot_step({external_infrastructure,
                   [{description, "external infrastructure ready"}]}).

-rabbit_boot_step({rabbit_registry,
                   [{description, "plugin registry"},
                    {mfa,         {rabbit_sup, start_child,
                                   [rabbit_registry]}},
                    {requires,    external_infrastructure},
                    {enables,     kernel_ready}]}).

-rabbit_boot_step({rabbit_log,
                   [{description, "logging server"},
                    {mfa,         {rabbit_sup, start_restartable_child,
                                   [rabbit_log]}},
                    {requires,    external_infrastructure},
                    {enables,     kernel_ready}]}).

-rabbit_boot_step({rabbit_event,
                   [{description, "statistics event manager"},
                    {mfa,         {rabbit_sup, start_restartable_child,
                                   [rabbit_event]}},
                    {requires,    external_infrastructure},
                    {enables,     kernel_ready}]}).

-rabbit_boot_step({kernel_ready,
                   [{description, "kernel ready"},
                    {requires,    external_infrastructure}]}).

-rabbit_boot_step({rabbit_alarm,
                   [{description, "alarm handler"},
                    {mfa,         {rabbit_alarm, start, []}},
                    {requires,    kernel_ready},
                    {enables,     core_initialized}]}).

-rabbit_boot_step({rabbit_memory_monitor,
                   [{description, "memory monitor"},
                    {mfa,         {rabbit_sup, start_restartable_child,
                                   [rabbit_memory_monitor]}},
                    {requires,    rabbit_alarm},
                    {enables,     core_initialized}]}).

-rabbit_boot_step({guid_generator,
                   [{description, "guid generator"},
                    {mfa,         {rabbit_sup, start_restartable_child,
                                   [rabbit_guid]}},
                    {requires,    kernel_ready},
                    {enables,     core_initialized}]}).

-rabbit_boot_step({delegate_sup,
                   [{description, "cluster delegate"},
                    {mfa,         {rabbit, boot_delegate, []}},
                    {requires,    kernel_ready},
                    {enables,     core_initialized}]}).

-rabbit_boot_step({rabbit_node_monitor,
                   [{description, "node monitor"},
                    {mfa,         {rabbit_sup, start_restartable_child,
                                   [rabbit_node_monitor]}},
                    {requires,    kernel_ready},
                    {enables,     core_initialized}]}).

-rabbit_boot_step({core_initialized,
                   [{description, "core initialized"},
                    {requires,    kernel_ready}]}).

-rabbit_boot_step({empty_db_check,
                   [{description, "empty DB check"},
                    {mfa,         {?MODULE, maybe_insert_default_data, []}},
                    {requires,    core_initialized},
                    {enables,     routing_ready}]}).

-rabbit_boot_step({recovery,
                   [{description, "exchange, queue and binding recovery"},
                    {mfa,         {rabbit, recover, []}},
                    {requires,    empty_db_check},
                    {enables,     routing_ready}]}).

-rabbit_boot_step({mirror_queue_slave_sup,
                   [{description, "mirror queue slave sup"},
                    {mfa,         {rabbit_mirror_queue_slave_sup, start, []}},
                    {requires,    recovery},
                    {enables,     routing_ready}]}).

-rabbit_boot_step({mirrored_queues,
                   [{description, "adding mirrors to queues"},
                    {mfa,         {rabbit_mirror_queue_misc, on_node_up, []}},
                    {requires,    mirror_queue_slave_sup},
                    {enables,     routing_ready}]}).

-rabbit_boot_step({routing_ready,
                   [{description, "message delivery logic ready"},
                    {requires,    core_initialized}]}).

-rabbit_boot_step({log_relay,
                   [{description, "error log relay"},
                    {mfa,         {rabbit_error_logger, boot, []}},
                    {requires,    routing_ready},
                    {enables,     networking}]}).

-rabbit_boot_step({direct_client,
                   [{mfa,        {rabbit_direct, boot, []}},
                    {requires,   log_relay}]}).

-rabbit_boot_step({networking,
                   [{mfa,         {rabbit_networking, boot, []}},
                    {requires,    log_relay}]}).

-rabbit_boot_step({notify_cluster,
                   [{description, "notify cluster nodes"},
                    {mfa,         {rabbit_node_monitor, notify_cluster, []}},
                    {requires,    networking}]}).

%%---------------------------------------------------------------------------

-include("rabbit_framing.hrl").
-include("rabbit.hrl").

-define(APPS, [os_mon, mnesia, rabbit]).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(file_suffix() :: binary()).
%% this really should be an abstract type
-type(log_location() :: 'tty' | 'undefined' | file:filename()).

-spec(prepare/0 :: () -> 'ok').
-spec(start/0 :: () -> 'ok').
-spec(stop/0 :: () -> 'ok').
-spec(stop_and_halt/0 :: () -> no_return()).
-spec(rotate_logs/1 :: (file_suffix()) -> rabbit_types:ok_or_error(any())).
-spec(force_event_refresh/0 :: () -> 'ok').
-spec(status/0 ::
        () -> [{pid, integer()} |
               {running_applications, [{atom(), string(), string()}]} |
               {os, {atom(), atom()}} |
               {erlang_version, string()} |
               {memory, any()}]).
-spec(is_running/0 :: () -> boolean()).
-spec(is_running/1 :: (node()) -> boolean()).
-spec(environment/0 :: () -> [{atom() | term()}]).
-spec(log_location/1 :: ('sasl' | 'kernel') -> log_location()).

-spec(maybe_insert_default_data/0 :: () -> 'ok').
-spec(boot_delegate/0 :: () -> 'ok').
-spec(recover/0 :: () -> 'ok').

-endif.

%%----------------------------------------------------------------------------

prepare() ->
    ok = ensure_working_log_handlers(),
    ok = rabbit_upgrade:maybe_upgrade_mnesia().

start() ->
    try
        ok = prepare(),
        ok = rabbit_misc:start_applications(application_load_order())
    after
        %%give the error loggers some time to catch up
        timer:sleep(100)
    end.

stop() ->
    ok = rabbit_misc:stop_applications(application_load_order()).

stop_and_halt() ->
    try
        stop()
    after
        init:stop()
    end,
    ok.

status() ->
    [{pid, list_to_integer(os:getpid())},
     {running_applications, application:which_applications(infinity)},
     {os, os:type()},
     {erlang_version, erlang:system_info(system_version)},
     {memory, erlang:memory()}].

is_running() -> is_running(node()).

is_running(Node) ->
    case rpc:call(Node, application, which_applications, [infinity]) of
        {badrpc, _} -> false;
        Apps        -> proplists:is_defined(rabbit, Apps)
    end.

environment() ->
    lists:keysort(
      1, [P || P = {K, _} <- application:get_all_env(rabbit),
               K =/= default_pass]).

rotate_logs(BinarySuffix) ->
    Suffix = binary_to_list(BinarySuffix),
    log_rotation_result(rotate_logs(log_location(kernel),
                                    Suffix,
                                    rabbit_error_logger_file_h),
                        rotate_logs(log_location(sasl),
                                    Suffix,
                                    rabbit_sasl_report_file_h)).

%%--------------------------------------------------------------------

start(normal, []) ->
    case erts_version_check() of
        ok ->
            ok = rabbit_mnesia:delete_previously_running_nodes(),
            {ok, SupPid} = rabbit_sup:start_link(),
            true = register(rabbit, self()),

            print_banner(),
            [ok = run_boot_step(Step) || Step <- boot_steps()],
            io:format("~nbroker running~n"),
            {ok, SupPid};
        Error ->
            Error
    end.

stop(_State) ->
    ok = rabbit_mnesia:record_running_nodes(),
    terminated_ok = error_logger:delete_report_handler(rabbit_error_logger),
    ok = rabbit_alarm:stop(),
    ok = case rabbit_mnesia:is_clustered() of
             true  -> rabbit_amqqueue:on_node_down(node());
             false -> rabbit_mnesia:empty_ram_only_tables()
         end,
    ok.

%%---------------------------------------------------------------------------
%% application life cycle

application_load_order() ->
    ok = load_applications(),
    {ok, G} = rabbit_misc:build_acyclic_graph(
                fun (App, _Deps) -> [{App, App}] end,
                fun (App,  Deps) -> [{Dep, App} || Dep <- Deps] end,
                [{App, app_dependencies(App)} ||
                    {App, _Desc, _Vsn} <- application:loaded_applications()]),
    true = digraph:del_vertices(
             G, digraph:vertices(G) -- digraph_utils:reachable(?APPS, G)),
    Result = digraph_utils:topsort(G),
    true = digraph:delete(G),
    Result.

load_applications() ->
    load_applications(queue:from_list(?APPS), sets:new()).

load_applications(Worklist, Loaded) ->
    case queue:out(Worklist) of
        {empty, _WorkList} ->
            ok;
        {{value, App}, Worklist1} ->
            case sets:is_element(App, Loaded) of
                true  -> load_applications(Worklist1, Loaded);
                false -> case application:load(App) of
                             ok                             -> ok;
                             {error, {already_loaded, App}} -> ok;
                             Error                          -> throw(Error)
                         end,
                         load_applications(
                           queue:join(Worklist1,
                                      queue:from_list(app_dependencies(App))),
                           sets:add_element(App, Loaded))
            end
    end.

app_dependencies(App) ->
    case application:get_key(App, applications) of
        undefined -> [];
        {ok, Lst} -> Lst
    end.

%%---------------------------------------------------------------------------
%% boot step logic

run_boot_step({StepName, Attributes}) ->
    Description = case lists:keysearch(description, 1, Attributes) of
                      {value, {_, D}} -> D;
                      false           -> StepName
                  end,
    case [MFA || {mfa, MFA} <- Attributes] of
        [] ->
            io:format("-- ~s~n", [Description]);
        MFAs ->
            io:format("starting ~-60s ...", [Description]),
            [try
                 apply(M,F,A)
             catch
                 _:Reason -> boot_error("FAILED~nReason: ~p~nStacktrace: ~p~n",
                                        [Reason, erlang:get_stacktrace()])
             end || {M,F,A} <- MFAs],
            io:format("done~n"),
            ok
    end.

boot_steps() ->
    sort_boot_steps(rabbit_misc:all_module_attributes(rabbit_boot_step)).

vertices(_Module, Steps) ->
    [{StepName, {StepName, Atts}} || {StepName, Atts} <- Steps].

edges(_Module, Steps) ->
    [case Key of
         requires -> {StepName, OtherStep};
         enables  -> {OtherStep, StepName}
     end || {StepName, Atts} <- Steps,
            {Key, OtherStep} <- Atts,
            Key =:= requires orelse Key =:= enables].

sort_boot_steps(UnsortedSteps) ->
    case rabbit_misc:build_acyclic_graph(fun vertices/2, fun edges/2,
                                         UnsortedSteps) of
        {ok, G} ->
            %% Use topological sort to find a consistent ordering (if
            %% there is one, otherwise fail).
            SortedSteps = lists:reverse(
                            [begin
                                 {StepName, Step} = digraph:vertex(G, StepName),
                                 Step
                             end || StepName <- digraph_utils:topsort(G)]),
            digraph:delete(G),
            %% Check that all mentioned {M,F,A} triples are exported.
            case [{StepName, {M,F,A}} ||
                     {StepName, Attributes} <- SortedSteps,
                     {mfa, {M,F,A}}         <- Attributes,
                     not erlang:function_exported(M, F, length(A))] of
                []               -> SortedSteps;
                MissingFunctions -> boot_error(
                                      "Boot step functions not exported: ~p~n",
                                      [MissingFunctions])
            end;
        {error, {vertex, duplicate, StepName}} ->
            boot_error("Duplicate boot step name: ~w~n", [StepName]);
        {error, {edge, Reason, From, To}} ->
            boot_error(
              "Could not add boot step dependency of ~w on ~w:~n~s",
              [To, From,
               case Reason of
                   {bad_vertex, V} ->
                       io_lib:format("Boot step not registered: ~w~n", [V]);
                   {bad_edge, [First | Rest]} ->
                       [io_lib:format("Cyclic dependency: ~w", [First]),
                        [io_lib:format(" depends on ~w", [Next]) ||
                            Next <- Rest],
                        io_lib:format(" depends on ~w~n", [First])]
               end])
    end.

boot_error(Format, Args) ->
    io:format("BOOT ERROR: " ++ Format, Args),
    error_logger:error_msg(Format, Args),
    timer:sleep(1000),
    exit({?MODULE, failure_during_boot}).

%%---------------------------------------------------------------------------
%% boot step functions

boot_delegate() ->
    {ok, Count} = application:get_env(rabbit, delegate_count),
    rabbit_sup:start_child(delegate_sup, [Count]).

recover() ->
    rabbit_binding:recover(rabbit_exchange:recover(), rabbit_amqqueue:start()).

maybe_insert_default_data() ->
    case rabbit_mnesia:is_db_empty() of
        true -> insert_default_data();
        false -> ok
    end.

insert_default_data() ->
    {ok, DefaultUser} = application:get_env(default_user),
    {ok, DefaultPass} = application:get_env(default_pass),
    {ok, DefaultTags} = application:get_env(default_user_tags),
    {ok, DefaultVHost} = application:get_env(default_vhost),
    {ok, [DefaultConfigurePerm, DefaultWritePerm, DefaultReadPerm]} =
        application:get_env(default_permissions),
    ok = rabbit_vhost:add(DefaultVHost),
    ok = rabbit_auth_backend_internal:add_user(DefaultUser, DefaultPass),
    ok = rabbit_auth_backend_internal:set_tags(DefaultUser, DefaultTags),
    ok = rabbit_auth_backend_internal:set_permissions(DefaultUser, DefaultVHost,
                                                      DefaultConfigurePerm,
                                                      DefaultWritePerm,
                                                      DefaultReadPerm),
    ok.

%%---------------------------------------------------------------------------
%% logging

ensure_working_log_handlers() ->
    Handlers = gen_event:which_handlers(error_logger),
    ok = ensure_working_log_handler(error_logger_file_h,
                                    rabbit_error_logger_file_h,
                                    error_logger_tty_h,
                                    log_location(kernel),
                                    Handlers),

    ok = ensure_working_log_handler(sasl_report_file_h,
                                    rabbit_sasl_report_file_h,
                                    sasl_report_tty_h,
                                    log_location(sasl),
                                    Handlers),
    ok.

ensure_working_log_handler(OldFHandler, NewFHandler, TTYHandler,
                           LogLocation, Handlers) ->
    case LogLocation of
        undefined -> ok;
        tty       -> case lists:member(TTYHandler, Handlers) of
                         true  -> ok;
                         false ->
                             throw({error, {cannot_log_to_tty,
                                            TTYHandler, not_installed}})
                     end;
        _         -> case lists:member(NewFHandler, Handlers) of
                         true  -> ok;
                         false -> case rotate_logs(LogLocation, "",
                                                   OldFHandler, NewFHandler) of
                                      ok -> ok;
                                      {error, Reason} ->
                                          throw({error, {cannot_log_to_file,
                                                         LogLocation, Reason}})
                                  end
                     end
    end.

log_location(Type) ->
    case application:get_env(Type, case Type of
                                       kernel -> error_logger;
                                       sasl   -> sasl_error_logger
                                   end) of
        {ok, {file, File}} -> File;
        {ok, false}        -> undefined;
        {ok, tty}          -> tty;
        {ok, silent}       -> undefined;
        {ok, Bad}          -> throw({error, {cannot_log_to_file, Bad}});
        _                  -> undefined
    end.

rotate_logs(File, Suffix, Handler) ->
    rotate_logs(File, Suffix, Handler, Handler).

rotate_logs(File, Suffix, OldHandler, NewHandler) ->
    case File of
        undefined -> ok;
        tty       -> ok;
        _         -> gen_event:swap_handler(
                       error_logger,
                       {OldHandler, swap},
                       {NewHandler, {File, Suffix}})
    end.

log_rotation_result({error, MainLogError}, {error, SaslLogError}) ->
    {error, {{cannot_rotate_main_logs, MainLogError},
             {cannot_rotate_sasl_logs, SaslLogError}}};
log_rotation_result({error, MainLogError}, ok) ->
    {error, {cannot_rotate_main_logs, MainLogError}};
log_rotation_result(ok, {error, SaslLogError}) ->
    {error, {cannot_rotate_sasl_logs, SaslLogError}};
log_rotation_result(ok, ok) ->
    ok.

force_event_refresh() ->
    rabbit_direct:force_event_refresh(),
    rabbit_networking:force_connection_event_refresh(),
    rabbit_channel:force_event_refresh(),
    rabbit_amqqueue:force_event_refresh().

%%---------------------------------------------------------------------------
%% misc

erts_version_check() ->
    FoundVer = erlang:system_info(version),
    case rabbit_misc:version_compare(?ERTS_MINIMUM, FoundVer, lte) of
        true  -> ok;
        false -> {error, {erlang_version_too_old,
                          {found, FoundVer}, {required, ?ERTS_MINIMUM}}}
    end.

print_banner() ->
    {ok, Product} = application:get_key(id),
    {ok, Version} = application:get_key(vsn),
    ProductLen = string:len(Product),
    io:format("~n"
              "+---+   +---+~n"
              "|   |   |   |~n"
              "|   |   |   |~n"
              "|   |   |   |~n"
              "|   +---+   +-------+~n"
              "|                   |~n"
              "| ~s  +---+   |~n"
              "|           |   |   |~n"
              "| ~s  +---+   |~n"
              "|                   |~n"
              "+-------------------+~n"
              "~s~n~s~n~s~n~n",
              [Product, string:right([$v|Version], ProductLen),
               ?PROTOCOL_VERSION,
               ?COPYRIGHT_MESSAGE, ?INFORMATION_MESSAGE]),
    Settings = [{"node",           node()},
                {"app descriptor", app_location()},
                {"home dir",       home_dir()},
                {"config file(s)", config_files()},
                {"cookie hash",    rabbit_misc:cookie_hash()},
                {"log",            log_location(kernel)},
                {"sasl log",       log_location(sasl)},
                {"database dir",   rabbit_mnesia:dir()},
                {"erlang version", erlang:system_info(version)}],
    DescrLen = 1 + lists:max([length(K) || {K, _V} <- Settings]),
    Format = fun (K, V) ->
                     io:format("~-" ++ integer_to_list(DescrLen) ++ "s: ~s~n",
                               [K, V])
             end,
    lists:foreach(fun ({"config file(s)" = K, []}) ->
                          Format(K, "(none)");
                      ({"config file(s)" = K, [V0 | Vs]}) ->
                          Format(K, V0), [Format("", V) || V <- Vs];
                      ({K, V}) ->
                          Format(K, V)
                  end, Settings),
    io:nl().

app_location() ->
    {ok, Application} = application:get_application(),
    filename:absname(code:where_is_file(atom_to_list(Application) ++ ".app")).

home_dir() ->
    case init:get_argument(home) of
        {ok, [[Home]]} -> Home;
        Other          -> Other
    end.

config_files() ->
    case init:get_argument(config) of
        {ok, Files} -> [filename:absname(
                          filename:rootname(File, ".config") ++ ".config") ||
                           File <- Files];
        error       -> []
    end.
