%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2013, Vladimir G. Sekissov
%%% @doc
%%% Simply run function periodically.
%%% @end
%%% Created : 23 Jul 2013 by Vladimir G. Sekissov <eryx67@gmail.com>

-module(gencron_periodic).

-behaviour(gen_cron).

-compile([{parse_transform, lager_transform}]).

-export([start_link/3]).

%% gen_server API
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% gen_cron API
-export([handle_tick/2]).

-record(state, {name, hlr}).

-spec start_link(term(), integer(), fun(('force' | 'tick') -> any()))
                -> {ok, pid()} | {error, term()}.
start_link(Name, Interval, Handler) ->
    gen_cron:start_link(?MODULE, Interval, [Name, Handler], []).

%% gen_server callbacks
init([Name, Handler]) ->
    {ok, #state{name=Name, hlr=Handler}}.

-spec handle_tick('force' | 'tick', #state{}) -> term().
handle_tick(Event, #state{name=Name, hlr=Handler}) ->
    lager:debug("~w start handler with ~w", [Name, Event]),
    Handler(Event).

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({tick_monitor, {'DOWN', _, _, _, normal}}, S=#state{name=Name}) ->
    lager:debug("~w handler finished", [Name]),
    {noreply, S};
handle_info({tick_monitor, {'DOWN', _, _, _, Reason}}, S=#state{name=Name}) ->
    lager:error("~w handler finished, reason ~w", [Name, Reason]),
    {noreply, S};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
