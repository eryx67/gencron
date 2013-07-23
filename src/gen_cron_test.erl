-module (gen_cron_test).
-behaviour (gen_cron).
-export ([ init/1,
           handle_call/3,
           handle_cast/2,
           handle_info/2,
           handle_tick/2,
           terminate/2,
           code_change/3 ]).

%-=====================================================================-
%-                          gen_cron callbacks                         -
%-=====================================================================-

init ([ Tab ]) ->
  ets:insert (Tab, { count, 0 }),
  ets:insert (Tab, { force, 0 }),
  ets:insert (Tab, { tick_monitor, 0 }),
  { ok, Tab }.

handle_tick (force, Tab) ->
  process_flag (trap_exit, true),
  receive after 2000 -> ok end,
  ets:update_counter (Tab, force, 1);
handle_tick (tick, Tab) ->
  process_flag (trap_exit, true),
  receive after 2000 -> ok end,
  ets:update_counter (Tab, count, 1).

handle_call (turg, _From, Tab) -> 
  ets:insert (Tab, { turg, baitin }),
  { reply, flass, Tab };
handle_call (_Msg, _From, State) -> { noreply, State }.
handle_cast (_Msg, State) -> { noreply, State }.
handle_info ({ tick_monitor, _ }, Tab) ->
  ets:update_counter (Tab, tick_monitor, 1),
  { noreply, Tab };
handle_info ({ Key, Val }, Tab) -> 
  ets:insert (Tab, { Key, Val }),
  { noreply, Tab };
handle_info (_Msg, State) -> { noreply, State }.
terminate (_Reason, Tab) -> 
  [ { count, _ } ] = ets:lookup (Tab, count),
  ok.
code_change (_OldVsn, State, _Extra) -> { ok, State }.
