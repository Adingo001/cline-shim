#!/usr/bin/env bash
# Control the Cline gateway shim that fronts https://api.cline.bot/api/v1.
#
#   ctl.sh start | stop | restart | status
#
# The shim repairs four things a plain client cannot handle on its own: the
# {"data": {...}} response envelope, the `reasoning` field name, bare model
# ids, and transient HTTP 500 routing misses.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${CLINE_SHIM_PORT:-8788}"
PIDFILE="$DIR/shim.pid"
LOGFILE="$DIR/shim.log"

# Gateway channel pin mode. Measured 2026-09-17 against the live gateway with
# cline-pass/deepseek-v4.1-flash, 8 streaming rounds per mode (tests/_probe10.py):
#
#   off        8/8 ok   mean 2.5s   spread across fireworks/alibaba/novita
#   preferred  7/8 ok   mean 2.6s   all togetherai; one empty response
#   strict     8/8 ok   mean 1.4s   all togetherai
#
# `off` is not broken -- an earlier note claiming it failed 8/8 came from
# minimal one-message payloads and does not reproduce. What pinning buys is
# latency and a known channel: `strict` is twice as fast and always the same
# server, `preferred` still lets the router fall through to channels that have
# not been vetted. `strict` is the default for the dsh use case, where a turn
# is long and a slow first token is the expensive failure.
PIN_MODE="${CLINE_SHIM_PIN_MODE:-strict}"

is_up() {
    ss -lntH "sport = :$PORT" 2>/dev/null | grep -q .
}

port_pid() {
    ss -lptnH "sport = :$PORT" 2>/dev/null \
        | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -1
}

stop_quiet() {
    if [ -f "$PIDFILE" ]; then
        kill -9 "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
    fi
    local pid
    pid="$(port_pid)"
    if [ -n "$pid" ]; then
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi
}

start() {
    if is_up; then
        echo "shim   : already listening on $PORT"
        return 0
    fi
    stop_quiet
    cd "$DIR" || exit 1
    CLINE_SHIM_PIN_MODE="$PIN_MODE" nohup /usr/bin/python3 shim.py >> "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 2
    if is_up; then
        echo "shim   : started on $PORT (pin=$PIN_MODE)"
    else
        echo "shim   : FAILED to bind $PORT"
        tail -n 5 "$LOGFILE" 2>/dev/null
        return 1
    fi
}

case "${1:-status}" in
    start)
        start
        ;;
    stop)
        stop_quiet
        echo "shim   : stopped"
        ;;
    restart)
        stop_quiet
        sleep 1
        start
        ;;
    status)
        if is_up; then
            curl -sS -m 15 "http://127.0.0.1:$PORT/health" 2>/dev/null \
                || echo '(health check failed)'
            echo ''
            live="$(tr '\0' '\n' < "/proc/$(port_pid)/environ" 2>/dev/null \
                | sed -n 's/^CLINE_SHIM_PIN_MODE=//p')"
            echo "pin    : ${live:-<unset>} (ctl default: $PIN_MODE)"
        else
            echo 'not listening'
        fi
        ;;
    *)
        echo "usage: ctl.sh {start|stop|restart|status}" >&2
        exit 2
        ;;
esac
