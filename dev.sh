#!/usr/bin/env bash
# Start the whole local stack and wait until each tier is actually serving.
#
# Why this exists: the three processes (Memurai, the Python worker, the Node
# API) were being started ad hoc as detached background jobs, and each has
# silently died at least once between working sessions -- a dead Redis surfaced
# as every LinkedIn call reporting `ambiguous`, a dead worker as every API call
# returning `503 provider_unavailable`, and a half-started API as a health
# check that raced its own boot. One script that starts everything in order
# and REFUSES to report success until the health endpoints answer removes that
# whole class of confusion.
#
# Usage:  ./dev.sh            start everything (idempotent: skips tiers already up)
#         ./dev.sh stop       stop the worker and API (leaves Memurai running)
#         ./dev.sh status     just print what is up
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

API_PORT=3001
WORKER_PORT=8001      # must match worker/.env INTERNAL_PORT and api/.env LINKEDIN_SVC_URL
REDIS_PORT=6379
LOG_DIR="${TMPDIR:-/tmp}"

up() { curl -s -m 3 -o /dev/null "$1" ; }
listening() { netstat -ano 2>/dev/null | grep -q ":$1 .*LISTENING"; }
pid_on() { netstat -ano 2>/dev/null | grep ":$1 " | grep LISTENING | awk '{print $5}' | head -1; }

# The action worker (python -m app.worker) binds nothing, so find it by command line.
drainer_pid() {
  # `Where-Object CommandLine -like` (comparison syntax) rather than a script
  # block: it avoids $_ entirely, which does not survive bash -> PowerShell
  # quoting and silently reported the drainer as DOWN while it was running.
  # tr uses [:space:] so this line carries no backslash escapes to mangle.
  powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | Where-Object CommandLine -like '*app.worker*' | Select-Object -First 1 -ExpandProperty ProcessId" 2>/dev/null | tr -d '[:space:]' | grep -E '^[0-9]+$'
}


status() {
  printf "  %-8s " redis;  python -c "
import redis,sys
try: redis.Redis.from_url('redis://127.0.0.1:$REDIS_PORT/0',socket_connect_timeout=1).ping(); print('UP')
except Exception: print('DOWN')" 2>/dev/null || echo DOWN
  printf "  %-8s " worker; up "http://127.0.0.1:$WORKER_PORT/internal/health" && echo UP || echo DOWN
  printf "  %-8s " api;    up "http://127.0.0.1:$API_PORT/health" && echo UP || echo DOWN
  # The queue drainer has no port to probe, so it is identified by its command
  # line. Without it every queued write sits at "queued" forever and the API
  # looks healthy -- which is exactly how it was missed before it was added here.
  printf "  %-8s " drainer; if drainer_pid >/dev/null; then echo UP; else echo DOWN; fi
}

stop() {
  dpid="$(drainer_pid || true)"
  if [ -n "$dpid" ]; then
    taskkill //F //T //PID "$dpid" >/dev/null 2>&1 && echo "  stopped drainer (pid $dpid)" || true
  fi
  for port in $WORKER_PORT $API_PORT; do
    pid="$(pid_on "$port")"
    if [ -n "$pid" ]; then
      # //T kills the process TREE. Killing only the parent (e.g. uvicorn's
      # reloader, or npm) leaves the child holding the port, and the next start
      # then fails to bind while the old code keeps serving -- observed live.
      taskkill //F //T //PID "$pid" >/dev/null 2>&1 && echo "  stopped :$port (pid $pid)" || true
    fi
  done
}

wait_for() {  # wait_for <label> <url> <seconds>
  local label="$1" url="$2" secs="$3" i=0
  until up "$url"; do
    i=$((i+1))
    if [ "$i" -ge "$secs" ]; then echo "  $label: did not come up in ${secs}s -- see $LOG_DIR/$label.log" >&2; return 1; fi
    sleep 1
  done
  echo "  $label: up (${i}s)"
}

case "${1:-start}" in
  status) status ;;
  stop)   stop ;;
  start)
    echo "starting stack..."
    if ! listening $REDIS_PORT; then
      ( ./memurai/tools/memurai.exe --port $REDIS_PORT --save "" > "$LOG_DIR/redis.log" 2>&1 & )
      sleep 2
    fi
    if ! up "http://127.0.0.1:$WORKER_PORT/internal/health"; then
      ( cd worker && python -m uvicorn app.main:app --host 127.0.0.1 --port $WORKER_PORT > "$LOG_DIR/worker.log" 2>&1 & )
    fi
    if ! up "http://127.0.0.1:$API_PORT/health"; then
      ( cd api && npm run dev > "$LOG_DIR/api.log" 2>&1 & )
    fi
    # The queue drainer. Every queued reaction, invitation and comment waits on
    # this process; starting the two servers without it produces a stack that
    # answers 202 to every write and then never performs any of them.
    if ! drainer_pid >/dev/null; then
      ( cd worker && python -m app.worker > "$LOG_DIR/drainer.log" 2>&1 & )
    fi
    wait_for worker "http://127.0.0.1:$WORKER_PORT/internal/health" 30
    wait_for api    "http://127.0.0.1:$API_PORT/health" 45
    echo; status
    ;;
  *) echo "usage: $0 [start|stop|status]" >&2; exit 2 ;;
esac
