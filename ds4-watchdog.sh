#!/bin/sh
set -u

parent_pid=${1:-}
managed_by="pi-sd4-provider"
ds4_dir=${DS4_DIR:?}
client_dir=${DS4_CLIENT_DIR:?}
state_file=${DS4_STATE_FILE:?}
log_file=${DS4_LOG_FILE:?}
base_url=${DS4_BASE_URL:?}
lease_ttl_s=${DS4_LEASE_TTL_S:-45}
poll_s=${DS4_WATCHDOG_POLL_S:-2}
shutdown_grace_s=${DS4_SHUTDOWN_GRACE_S:-60}
own_lease="$client_dir/$parent_pid.json"

log() {
  mkdir -p "$ds4_dir" 2>/dev/null || true
  printf '[%s] ds4-watchdog(%s): %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$parent_pid" "$*" >> "$log_file" 2>/dev/null || true
}

pid_alive() {
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null
}

mtime_sec() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

process_args() {
  ps -p "$1" -o args= 2>/dev/null || true
}

process_start() {
  ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

json_string_field() {
  key=$1
  file=$2
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" 2>/dev/null | head -1
}

looks_like_ds4_server() {
  process_args "$1" | grep -Eq '(^|[/[:space:]])ds4-server([[:space:]]|$)'
}

find_ds4_server_pid() {
  if command -v lsof >/dev/null 2>&1; then
    for pid in $(lsof -nP -tiTCP:8000 -sTCP:LISTEN 2>/dev/null); do
      if pid_alive "$pid" && looks_like_ds4_server "$pid"; then
        echo "$pid"
        return 0
      fi
    done
  fi
  return 1
}

state_pid() {
  sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$state_file" 2>/dev/null | head -1
}

active_lease_count() {
  mkdir -p "$client_dir" 2>/dev/null || true
  count=0
  now=$(date +%s)

  for file in "$client_dir"/*.json; do
    [ -e "$file" ] || continue
    name=${file##*/}
    pid=${name%.json}
    stale=0

    grep -q '"managedBy"[[:space:]]*:[[:space:]]*"pi-sd4-provider"' "$file" 2>/dev/null || stale=1
    grep -q '"usesDs4"[[:space:]]*:[[:space:]]*true' "$file" 2>/dev/null || stale=1
    pid_alive "$pid" || stale=1

    lease_start=$(json_string_field processStart "$file")
    proc_start=$(process_start "$pid")
    [ -n "$lease_start" ] || stale=1
    [ -n "$proc_start" ] || stale=1
    [ "$lease_start" = "$proc_start" ] || stale=1

    mt=$(mtime_sec "$file")
    if [ $((now - mt)) -gt "$lease_ttl_s" ]; then
      stale=1
    fi

    if [ "$stale" -eq 1 ]; then
      rm -f "$file" 2>/dev/null || true
    else
      count=$((count + 1))
    fi
  done

  echo "$count"
}

mark_stopping() {
  pid=$1
  mkdir -p "$ds4_dir" 2>/dev/null || true
  cat > "$state_file" <<EOF
{
  "managedBy": "$managed_by",
  "pid": $pid,
  "baseUrl": "$base_url",
  "stopping": true,
  "stoppingAt": $(date +%s)000,
  "stoppingAtIso": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF
}

clear_state_if_dead() {
  pid=$1
  if ! pid_alive "$pid"; then
    rm -f "$state_file" 2>/dev/null || true
  fi
}

stop_server() {
  pid=$(state_pid)
  if [ -z "$pid" ] || ! pid_alive "$pid" || ! looks_like_ds4_server "$pid"; then
    pid=$(find_ds4_server_pid || true)
  fi

  if [ -z "$pid" ]; then
    log "no active ds4-server; exiting"
    exit 0
  fi

  mark_stopping "$pid"
  if kill -TERM "$pid" 2>/dev/null; then
    log "sent SIGTERM to ds4-server pid=$pid"
  else
    log "SIGTERM failed for ds4-server pid=$pid"
    clear_state_if_dead "$pid"
    exit 0
  fi

  waited=0
  while pid_alive "$pid" && [ "$waited" -lt "$shutdown_grace_s" ]; do
    sleep 1
    waited=$((waited + 1))
  done

  if pid_alive "$pid"; then
    log "ds4-server pid=$pid still alive after ${shutdown_grace_s}s; sending SIGKILL"
    kill -KILL "$pid" 2>/dev/null || true
    sleep 1
  fi

  clear_state_if_dead "$pid"
  log "ds4-server pid=$pid stopped"
}

if [ -z "$parent_pid" ]; then
  log "missing parent pid; exiting"
  exit 0
fi

log "started for parent pid=$parent_pid"
while pid_alive "$parent_pid"; do
  sleep "$poll_s"
done

rm -f "$own_lease" 2>/dev/null || true
if [ "$(active_lease_count)" -eq 0 ]; then
  stop_server
else
  log "parent exited; other ds4 leases still active"
fi
