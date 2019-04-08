-ifndef(__GENCRON_HRL__).
-define(__GENCRON_HRL__, true).

-ifdef(OTP_RELEASE).

-include_lib("kernel/include/logger.hrl").

-else.

-define(LOG_DEBUG(Fmt, Args), io:format(Fmt, Args)).
-define(LOG_INFO(Fmt, Args), error_logger:info_msg(Fmt, Args)).
-define(LOG_ERROR(Fmt, Args), error_logger:error_msg(Fmt, Args)).

-endif.

-endif.
