#!/usr/bin/env bash
# Run the shim in gateway mode in front of the remote New API gateway.
#
#   _gwctl.sh start | stop | status
#
# Why: Claude Code talks to the remote gateway directly, which leaves
# nothing on the path between it and the model. Pointing it here gives a place
# to observe request size -- the variable that actually governs throughput on
# this route -- and to terminate the Anthropic wire locally.
#
# Measured on this route (tests/_probe36.py, cline_dsflash, max_tokens 400):
#   input  3k -> 79.9 tps, ttfb  2.27s
#   input 34k -> 68.2 tps, ttfb  5.25s
#   input 68k -> 28.7 tps, ttfb  7.93s
#   input 170k -> 13.9 tps, ttfb 18.80s
set -u

DIR="${GW_DIR:-$HOME/openai4s-shim}"
PORT="${GW_PORT:-8789}"
PIDFILE="$DIR/shim-gw.pid"
LOGFILE="$DIR/shim-gw.log"
UPSTREAM="${GW_UPSTREAM:-https://GATEWAY_HOST/v1}"

is_up() {
    ss -lntH "sport = :$PORT" 2>/dev/null | grep -q .
}

# The listening pid is the authoritative one. A pidfile records the shell that
# was backgrounded, which is not the process holding the socket here -- on this
# host the pidfile went empty while the shim kept serving, so a stop that only
# trusted it reported success and left the port bound.
know_pid() {
    local pid
    pid=$(ss -lptnH "sport = :$PORT" 2>/dev/null \
        | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
    if [ -n "$pid" ]; then
        printf '%s' "$pid"
        return
    fi
    if [ -s "$PIDFILE" ]; then
        cat "$PIDFILE"
    fi
}

port_pid() {
    ss -lptnH "sport = :$PORT" 2>/dev/null \
        | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -1
}

stop_quiet() {
    local pid
    pid="$(know_pid)"
    if [ -n "$pid" ]; then
        kill -9 "$pid" 2>/dev/null || true
        # wait for the socket to actually drop before declaring victory
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            is_up || break
            sleep 0.3
        done
    fi
    rm -f "$PIDFILE"
    if is_up; then
        echo "gw-shim: could not free port $PORT (still bound by $(know_pid))" >&2
        return 1
    fi
}

start() {
    if is_up; then
        echo "gw-shim: already listening on $PORT"
        return 0
    fi
    stop_quiet
    cd "$DIR" || exit 1
    # The gateway answers empties intermittently and each roll can take a
    # minute, so two in-place tries inside a 60s wall is the whole retry
    # budget: enough to absorb one bad roll, short enough that a dead stretch
    # hands control back to the caller instead of looking like a hang.
    CLINE_UPSTREAM="$UPSTREAM" \
    CLINE_SHIM_PORT="$PORT" \
    CLINE_MODEL_MODE=gateway \
    CLINE_SHIM_PIN_MODE=off \
    CLINE_SHIM_RETRIES=2 \
    CLINE_SHIM_BUDGET=60 \
        nohup /usr/bin/python3 shim.py >> "$LOGFILE" 2>&1 &
    local real
    real=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.3
        real="$(know_pid)"
        [ -n "$real" ] && is_up && break
    done
    if is_up && [ -n "$real" ]; then
        printf '%s' "$real" > "$PIDFILE"
        echo "gw-shim: started on $PORT (pid $real) -> $UPSTREAM"
    else
        echo "gw-shim: FAILED to bind $PORT"
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
        echo "gw-shim: stopped"
        ;;
    restart)
        stop_quiet
        sleep 1
        start
        ;;
    status)
        if is_up; then
            curl -sS -m 20 "http://127.0.0.1:$PORT/health" 2>/dev/null
            echo ''
        else
            echo 'not listening'
        fi
        ;;
    *)
        echo "usage: _gwctl.sh {start|stop|restart|status}" >&2
        exit 2
        ;;
esac
