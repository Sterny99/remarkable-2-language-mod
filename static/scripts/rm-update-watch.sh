#!/bin/sh
set +e

LOG=/home/root/.cache/rm-custom/update-watch.log
mkdir -p /home/root/.cache/rm-custom
echo "[upd] start $(date 2>/dev/null || true)" >> "$LOG"

have(){ command -v "$1" >/dev/null 2>&1; }

if ! have update_engine_client; then
  echo "[upd] update_engine_client not found; exiting" >> "$LOG"
  exit 0
fi

# throttle to avoid repeated sync spam
STAMP=/home/root/.cache/rm-custom/.update-watch.lastsync

maybe_sync() {
  now="$(date +%s 2>/dev/null || echo 0)"
  last=0
  [ -f "$STAMP" ] && last="$(cat "$STAMP" 2>/dev/null || echo 0)"
  # at most once per 120 seconds
  if [ "$now" -gt 0 ] && [ $((now-last)) -lt 120 ]; then
    return 0
  fi
  echo "$now" > "$STAMP" 2>/dev/null || true
  echo "[upd] triggering slot-sync" >> "$LOG"
  /home/root/bin/rm-slot-sync.sh >> "$LOG" 2>&1 || true
}

# Prefer watch_for_updates if available; otherwise poll status.
if update_engine_client -help 2>&1 | grep -q "watch_for_updates"; then
  update_engine_client -watch_for_updates 2>&1 | while IFS= read -r line; do
    echo "[upd] $line" >> "$LOG"
    echo "$line" | grep -Eq "UPDATED_NEED_REBOOT|NEED_REBOOT" && maybe_sync
  done
else
  while true; do
    st="$(update_engine_client -status 2>/dev/null || true)"
    echo "$st" | grep -Eq "UPDATED_NEED_REBOOT|NEED_REBOOT" && maybe_sync
    sleep 10
  done
fi

exit 0
