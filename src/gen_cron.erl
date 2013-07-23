%% @doc Provides a gen_server-like interface to periodic execution.
%% The {@link handle_tick/2} callback is executed in a seperate
%% process periodically or in response to a {@link force_run/1} command.
%% Only one instance of a spawned handle_tick/2 is allowed at any time.
%% @end

-module(gen_cron).
-export([force_run/1,
         start/4,
         start/5,
         start_link/4,
         start_link/5]).

-behaviour(gen_server).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).
-export([handle_tick/2]).

-include_lib("eunit/include/eunit.hrl").

-record(gencron, {module,
                  interval,
                  mref = undefined,
                  pid = undefined,
                  state}).

-define(is_interval(X),(((X) =:= infinity)
                        orelse (is_integer(X) andalso(X) > 0)
                        orelse (is_tuple(X)
                                andalso element(1, X) =:= cluster
                                andalso is_integer(element(2, X))
                                andalso element(2, X) > 0))).

%% @doc One can specify a cluster-scaled interval, in which case the
%% 2nd element of the tuple is(dynamically) multiplied by the number
%% of nodes length([node() | nodes()]).
%% @end
-type interval() :: integer() | {cluster, integer()}.

-callback init(term()) -> {ok, term()} | {ok, term(), integer()}.
-callback handle_call(term(), term(), term()) -> term().
-callback handle_cast(term(), term()) -> term().
-callback handle_info(term(), term()) -> term().
-callback terminate(term(), term()) -> none().
-callback code_change(term(), term(), term()) -> term().
-callback handle_tick(tick | force, term()) -> none().

%% @doc Schedule an immediate execution.  If the process is already
%% executing then {underway, Pid} is returned.
%% @end
-spec force_run(pid()) -> {ok, pid()} | {underway, pid()}.
force_run(ServerRef) ->
    gen_server:call(ServerRef, {?MODULE, force_run}).

%% @doc The analog to gen_server:start/3.  Takes an extra argument
%% Interval which is the periodic execution interval in milliseconds.
%% @end
-spec start(atom(), interval(), list(), proplists:proplist()) -> term().
start(Module, Interval, Args, Options) when ?is_interval(Interval) ->
    gen_server:start(?MODULE, [Module, Interval | Args], Options).

%% @doc The analog to gen_server:start/4.  Takes an extra argument
%% Interval which is the periodic execution interval in milliseconds.
%% @end
-spec start(term(), atom(), interval(), list(), proplists:proplist()) -> term().
start(ServerName, Module, Interval, Args, Options) when ?is_interval(Interval) ->
    gen_server:start(ServerName, ?MODULE, [Module, Interval | Args], Options).

%% @doc The analog to gen_server:start_link/3.  Takes an extra argument
%% Interval which is the periodic execution interval in milliseconds.
%% @end
-spec start_link(atom(), interval(), list(), proplists:proplist()) -> term().
start_link(Module, Interval, Args, Options) when ?is_interval(Interval) ->
    gen_server:start_link(?MODULE, [Module, Interval | Args], Options).

%% @doc The analog to gen_server:start_link/4.  Takes an extra argument
%% Interval which is the periodic execution interval in milliseconds.
%% @end
-spec start_link(term(), atom(), interval(), list(), proplists:proplist()) -> term().
start_link(ServerName, Module, Interval, Args, Options) when ?is_interval(Interval) ->
    gen_server:start_link(ServerName, ?MODULE, [Module, Interval | Args], Options).

%% @doc Just like the gen_server version.
%% @end
init([Module, Interval | Args]) ->
    case Module:init(Args) of
        {ok, State} ->
            reset_timer(Interval),
            {ok, #gencron{interval = Interval, module = Module, state = State}};
        {ok, State, Timeout} ->
            reset_timer(Interval),
            {ok,
             #gencron{interval = Interval, module = Module, state = State},
             Timeout};
        R ->
            R
    end.

%% @doc Just like the gen_server version, except that
%% the force_run call is intercepted and handled.
%% @end
handle_call({?MODULE, force_run}, _From,
            State = #gencron{pid = undefined, module = M, state=S}) ->
    {Pid, MRef} = erlang:spawn_monitor(M, handle_tick,[force, S]),
    {reply, {ok, Pid}, State#gencron{pid = Pid, mref = MRef}};
handle_call({?MODULE, force_run}, _From, State=#gencron{pid = Pid}) ->
    {reply, {underway, Pid}, State};
handle_call(Request, From, State=#gencron{module=M, state=S}) ->
    wrap(M:handle_call(Request, From, S), State).

%% @doc Just like the gen_server version.
%% @end
handle_cast(Request, State=#gencron{module=M, state=S}) ->
    wrap(M:handle_cast(Request, S), State).

%% @doc Just like the gen_server version, except that
%% messages related to spawned process monitor are intercepted and
%% handled(and forwarded to the callback module in a {tick_monitor, Msg}
%% tuple), and messages related to the periodic timer are handled
%%(and not forwarded to the callback module).
%% @end
handle_info(Msg = {'DOWN', MRef, _, _, _}, State = #gencron{mref = MRef}) ->
    handle_info({tick_monitor, Msg}, State#gencron{pid = undefined, mref = undefined});
handle_info({?MODULE, tick}, State = #gencron{mref = undefined,
                                              interval=I,
                                              module=M,
                                              state=S}) ->
    reset_timer(I),
    {Pid, MRef} = erlang:spawn_monitor(M, handle_tick, [tick, S]),
    {noreply, State#gencron{pid = Pid, mref = MRef}};
handle_info({?MODULE, tick}, State=#gencron{interval=I}) ->
    reset_timer(I),
    {noreply, State};
handle_info(Msg, State=#gencron{module=M, state=S}) ->
    wrap(M:handle_info(Msg, S), State).

%% @doc Just like the gen_server version, except that
%% if a process is running, we wait for it to terminate
%%(prior to calling the module's terminate).
%% @end
terminate(Reason, _State=#gencron{mref=MRef, pid=Pid, module=M, state=S}) ->
    NewS =
        case MRef of
            undefined ->
                S;
            _ ->
                exit(Pid, Reason),
                receive Msg = {'DOWN', MRef, _, _, _} ->
                        case M:handle_info({tick_monitor, Msg}, S) of
                            {noreply, NS} -> NS;
                            {noreply, NS, _} -> NS;
                            {stop, _, NS} -> NS
                        end
                end
        end,
    M:terminate(Reason, NewS).

%% @doc Just like the gen_server version.
%% @end
code_change(OldVsn, State=#gencron{module=M, state=S}, Extra) ->
    {ok, NewS} =
        M:code_change(OldVsn, S, Extra),
    {ok, State#gencron{state = NewS}}.

%% @doc This is called as a seperate process, either periodically or in
%% response to a force.  The State argument is the server state at
%% the time of the spawn.
handle_tick(_Reason, _State) ->
    ok.

%%% private
reset_timer(Interval) ->
    %% infinity may seem unnecessary, but we can get here via code_change/3
    case Interval of
        infinity -> ok;
        _ -> {ok, _} = timer:send_after(tick_interval(Interval), {?MODULE, tick})
    end.

tick_interval(Interval) when is_integer(Interval) ->
    Interval;
tick_interval({cluster, Interval}) when is_integer(Interval) ->
    NodeCount = length([node() | nodes()]),
    Spread = random:uniform(NodeCount),
    (tick_interval(Interval) * 2 *(1 + Spread)) div (3 + NodeCount).

wrap({reply, Reply, NewState}, State) ->
    {reply, Reply, State#gencron{state = NewState}};
wrap({reply, Reply, NewState, Timeout}, State) ->
    {reply, Reply, State#gencron{state = NewState}, Timeout};
wrap({noreply, NewState}, State) ->
    {noreply, State#gencron{state = NewState}};
wrap({noreply, NewState, Timeout}, State) ->
    {noreply, State#gencron{state = NewState}, Timeout};
wrap({stop, Reason, Reply, NewState}, State) ->
    {stop, Reason, Reply, State#gencron{state = NewState}};
wrap({stop, Reason, NewState}, State) ->
    {stop, Reason, State#gencron{state = NewState}}.

-ifdef(EUNIT).

infinity_test_() ->
    F =
        fun(Tab) ->
                fun() ->
                        {ok, Pid} = gen_cron:start(gen_cron_test,
                                                   infinity,
                                                   [Tab],
                                                   []),

                        MRef = erlang:monitor(process, Pid),

                        {ok, RunPid} = gen_cron:force_run(Pid),
                        {underway, RunPid} = gen_cron:force_run(Pid),

                        receive after 6500 -> ok end,

                        exit(Pid, shutdown),

                        receive
                            {'DOWN', MRef, _, _, _} -> ok
                        end,

                        [?_assertEqual(ets:lookup(Tab, count),[{count, 0}]),
                         ?_assertEqual(ets:lookup(Tab, force),[{force, 1}]),
                         ?_assertEqual(ets:lookup(Tab, mega),[]),
                         ?_assertEqual(ets:lookup(Tab, turg),[])]
                end
        end,

    {setup,
     fun() -> application:start(lager),
              ets:new(?MODULE, [public, set, named_table])
     end,
     fun(Tab) -> ets:delete(Tab) end,
     fun(Tab) -> {timeout, 60, {generator, F(Tab)}} end
    }.

cluster_tick_test_() ->
    F =
        fun(Tab) ->
                fun() ->
                        {ok, Pid} = gen_cron:start(gen_cron_test,
                                                   {cluster, 1000},
                                                   [Tab],
                                                   []),

                        MRef = erlang:monitor(process, Pid),

                        {ok, RunPid} = gen_cron:force_run(Pid),
                        {underway, RunPid} = gen_cron:force_run(Pid),

                        receive after 6500 -> ok end,

                        exit(Pid, shutdown),

                        DownRet = receive
                                      {'DOWN', MRef, _, _, Info} -> Info
                                  end,

                        [?_assertEqual(DownRet , shutdown),
                         ?_assertEqual(ets:lookup(Tab, count) , [{count, 3}]),
                         ?_assertEqual(ets:lookup(Tab, force) , [{force, 1}]),
                         ?_assertEqual(ets:lookup(Tab, tick_monitor) , [{tick_monitor, 3}]),
                         ?_assertEqual(ets:lookup(Tab, mega) , []),
                         ?_assertEqual(ets:lookup(Tab, turg) , [])]
                end
        end,

    {setup,
     fun() -> ets:new(?MODULE, [public, set, named_table]) end,
     fun(Tab) -> ets:delete(Tab) end,
     fun(Tab) -> {timeout, 60, {generator, F(Tab)}} end
    }.


tick_test_() ->
    F =
        fun(Tab) ->
                fun() ->
                        {ok, Pid} = gen_cron:start(gen_cron_test, 1000, [Tab], []),

                        MRef = erlang:monitor(process, Pid),

                        {ok, RunPid} = gen_cron:force_run(Pid),
                        {underway, RunPid} = gen_cron:force_run(Pid),

                        receive after 6500 -> ok end,

                        exit(Pid, shutdown),

                        DownRet = receive
                                      {'DOWN', MRef, _, _, Info} -> Info
                                  end,

                        [?_assertEqual(DownRet , shutdown),
                         ?_assertEqual(ets:lookup(Tab, count) , [{count, 3}]),
                         ?_assertEqual(ets:lookup(Tab, force) , [{force, 1}]),
                         ?_assertEqual(ets:lookup(Tab, tick_monitor) , [{tick_monitor, 3}]),
                         ?_assertEqual(ets:lookup(Tab, mega) , []),
                         ?_assertEqual(ets:lookup(Tab, turg) , [])]
                end
        end,

    {setup,
     fun() -> ets:new(?MODULE, [public, set, named_table]) end,
     fun(Tab) -> ets:delete(Tab) end,
     fun(Tab) -> {timeout, 60, {generator, F(Tab)}} end
    }.

call_test_() ->
    F =
        fun(Tab) ->
                fun() ->
                        {ok, Pid} = gen_cron:start(gen_cron_test,
                                                   infinity,
                                                   [Tab],
                                                   []),

                        MRef = erlang:monitor(process, Pid),

                        flass = gen_server:call(Pid, turg),
                        flass = gen_server:call(Pid, turg),

                        exit(Pid, shutdown),

                        DownRet = receive
                            {'DOWN', MRef, _, _, Info} -> Info
                        end,

                        [?_assertEqual(DownRet , shutdown),
                         ?_assertEqual(ets:lookup(Tab, count) , [{count, 0}]),
                         ?_assertEqual(ets:lookup(Tab, force) , [{force, 0}]),
                         ?_assertEqual(ets:lookup(Tab, tick_monitor) , [{tick_monitor, 0}]),
                         ?_assertEqual(ets:lookup(Tab, mega) , []),
                         ?_assertEqual(ets:lookup(Tab, turg) , [{turg, baitin}])]
                end
        end,

    {setup,
     fun() -> ets:new(?MODULE, [public, set, named_table]) end,
     fun(Tab) -> ets:delete(Tab) end,
     fun(Tab) -> {timeout, 60, {generator, F(Tab)}} end
    }.

info_test_() ->
    F =
        fun(Tab) ->
                fun() ->
                        {ok, Pid} = gen_cron:start(gen_cron_test,
                                                   infinity,
                                                   [Tab],
                                                   []),

                        MRef = erlang:monitor(process, Pid),

                        Pid ! {mega, sweet},
                        Pid ! {mega, sweet},

                        receive after 6500 -> ok end,

                        exit(Pid, shutdown),

                        DownRet = receive
                                      {'DOWN', MRef, _, _, Info} -> Info
                                  end,

                        [?_assertEqual(DownRet , shutdown),
                         ?_assertEqual(ets:lookup(Tab, count) , [{count, 0}]),
                         ?_assertEqual(ets:lookup(Tab, force) , [{force, 0}]),
                         ?_assertEqual(ets:lookup(Tab, tick_monitor) , [{tick_monitor, 0}]),
                         ?_assertEqual(ets:lookup(Tab, mega) , [{mega, sweet}]),
                         ?_assertEqual(ets:lookup(Tab, turg) , [])]
                end
        end,

    {setup,
     fun() -> ets:new(?MODULE, [public, set, named_table]) end,
     fun(Tab) -> ets:delete(Tab) end,
     fun(Tab) -> {timeout, 60, {generator, F(Tab)}} end
    }.

-endif.
