#!/bin/sh
set +e

LOG=/home/root/.cache/rm-custom/customizations.log
mkdir -p /home/root/.cache/rm-custom
echo "[cus] start $(date 2>/dev/null || true)" >> "$LOG"

LOCK=/home/root/.cache/rm-custom/.customizations.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "[cus] already running; exit" >> "$LOG"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT INT TERM

have(){ command -v "$1" >/dev/null 2>&1; }

run_tmo() {
  secs="$1"; shift
  if have timeout; then
    timeout -k 1 "$secs" "$@" >>"$LOG" 2>&1
    return $?
  fi
  "$@" >>"$LOG" 2>&1 &
  pid=$!
  t=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$t" -ge "$secs" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      echo "[cus] timeout running: $*" >> "$LOG"
      return 124
    fi
    sleep 1
    t=$((t+1))
  done
  wait "$pid" 2>/dev/null
  return $?
}

ROOT_OPTS="$(awk '$2=="/"{print $4; exit}' /proc/mounts 2>/dev/null || true)"
ROOT_WAS_RW=0
echo "$ROOT_OPTS" | grep -q 'rw' && ROOT_WAS_RW=1

remount_rw(){ [ "$ROOT_WAS_RW" = "1" ] && return 0; mount -o remount,rw / >>"$LOG" 2>&1 || true; }
remount_back(){ [ "$ROOT_WAS_RW" = "1" ] && return 0; mount -o remount,ro / >>"$LOG" 2>&1 || true; }

LOCALE="__LOCALE__"
BIN="/home/root/bin/rm-xochitl-kbdpatch"
JSON="__RJSON__"

FONT_HOME_DIR="__RFONTHOMEDIR__"
FONT_HOME="__RFONTHOME__"
FONT_SYS_DIR="__RFONTSYSDIR__"
FONT_SYS="__RFONTSYS__"

# Safe fallbacks if deploy-time placeholder substitution didn't happen.
[ "$LOCALE" = "__LOCALE__" ] && LOCALE="de_DE"
[ "$JSON" = "__RJSON__" ] && JSON="/home/root/.local/share/rm-custom/keyboards/$LOCALE/keyboard_layout.json"

[ "$FONT_HOME_DIR" = "__RFONTHOMEDIR__" ] && FONT_HOME_DIR="/home/root/.local/share/fonts"
[ "$FONT_HOME" = "__RFONTHOME__" ] && FONT_HOME="$FONT_HOME_DIR/hebrew.ttf"
[ "$FONT_SYS_DIR" = "__RFONTSYSDIR__" ] && FONT_SYS_DIR="/usr/share/fonts/rm-custom"
[ "$FONT_SYS" = "__RFONTSYS__" ] && FONT_SYS="$FONT_SYS_DIR/hebrew.ttf"

STATE=/home/root/.cache/rm-custom/state.env
XO=/usr/bin/xochitl

# Ensure fontconfig config exists in /home
mkdir -p /home/root/.config/fontconfig /home/root/.cache/fontconfig "$FONT_HOME_DIR" 2>/dev/null || true
cat > /home/root/.config/fontconfig/fonts.conf <<'CONF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>/home/root/.local/share/fonts</dir>
  <cachedir>/home/root/.cache/fontconfig</cachedir>
</fontconfig>
CONF
cp -f /home/root/.config/fontconfig/fonts.conf /home/root/.fonts.conf 2>/dev/null || true

# Install system-font copy (helps on cold boots if xochitl ignores HOME fontconfig)
if [ -f "$FONT_HOME" ]; then
  remount_rw
  mkdir -p "$FONT_SYS_DIR" 2>/dev/null || true
  cp -f "$FONT_HOME" "$FONT_SYS" 2>/dev/null || true
  chmod 0644 "$FONT_SYS" 2>/dev/null || true
  remount_back
fi

# Rebuild caches (helps after hard power-off)
if have fc-cache; then
  run_tmo 8 fc-cache -f "$FONT_HOME_DIR" >/dev/null 2>&1 || true
  remount_rw
  run_tmo 8 fc-cache -f "$FONT_SYS_DIR" >/dev/null 2>&1 || true
  remount_back
fi

sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

CUR_SHA="$(sha "$XO")"
JSON_SHA="$(sha "$JSON")"
echo "[cus] xochitl cur=$CUR_SHA json_sha=$JSON_SHA locale=$LOCALE" >> "$LOG"

kill_xochitl() {
  systemctl stop xochitl >>"$LOG" 2>&1 || true

  # BusyBox often has killall/pidof; pkill usually missing.
  if have pidof; then
    PIDS="$(pidof xochitl 2>/dev/null || true)"
    for p in $PIDS; do
      kill -TERM "$p" >>"$LOG" 2>&1 || true
    done
    sleep 1
    for p in $PIDS; do
      kill -KILL "$p" >>"$LOG" 2>&1 || true
    done
  elif have killall; then
    killall -TERM xochitl >>"$LOG" 2>&1 || true
    sleep 1
    killall -KILL xochitl >>"$LOG" 2>&1 || true
  fi
}

restart_xochitl() {
  kill_xochitl
  systemctl start xochitl >>"$LOG" 2>&1 || true
}

NEED_PATCH=0
if [ -x "$BIN" ] && [ -f "$JSON" ]; then
  echo "[cus] check if patch needed..." >> "$LOG"
  RC=0
  run_tmo 8 "$BIN" --locale "$LOCALE" --json "$JSON" --check >>"$LOG" 2>&1 || RC=$?
  echo "[cus] check rc=$RC (0=ok/unchanged,2=needs patch)" >> "$LOG"
  [ "$RC" = "2" ] && NEED_PATCH=1
else
  echo "[cus] WARNING: missing BIN or JSON (BIN=$BIN JSON=$JSON)" >> "$LOG"
fi

if [ "$NEED_PATCH" = "1" ]; then
  echo "[cus] patching xochitl (JSON changed or xochitl updated)..." >> "$LOG"

  # Stop UI to avoid "Text file busy"
  kill_xochitl

  remount_rw

  # Keep a safety backup of the current xochitl (even if patcher also does this)
  BK=/home/root/.cache/rm-custom/xochitl."$CUR_SHA".orig
  if [ -n "$CUR_SHA" ] && [ ! -f "$BK" ]; then
    cp -f "$XO" "$BK" 2>>"$LOG" || true
  fi

  RC2=0
  run_tmo 25 "$BIN" --locale "$LOCALE" --json "$JSON" --verbose >>"$LOG" 2>&1 || RC2=$?
  echo "[cus] patch rc=$RC2" >> "$LOG"

  # Validate ELF header (brick-aware)
  if have hexdump; then
    MAGIC="$(dd if="$XO" bs=1 count=4 2>/dev/null | hexdump -v -e '/1 "%02x"' 2>/dev/null)"
  else
    MAGIC="$(head -c 4 "$XO" 2>/dev/null | od -An -t x1 2>/dev/null | tr -d ' \n')"
  fi
  if [ "$MAGIC" != "7f454c46" ]; then
    echo "[cus] ERROR: xochitl ELF magic invalid ($MAGIC) -> restoring backup" >> "$LOG"
    [ -f "$BK" ] && cp -f "$BK" "$XO" 2>>"$LOG" || true
    chmod 755 "$XO" 2>/dev/null || true
  fi

  remount_back
else
  echo "[cus] no patch needed" >> "$LOG"
fi

# Restart xochitl so patched resources/fonts take effect
restart_xochitl
sleep 1

# If xochitl didn't come up, try restore latest backup and retry
if ! systemctl is-active --quiet xochitl; then
  echo "[cus] WARNING: xochitl not active after restart; attempting restore" >> "$LOG"
  remount_rw
  LATEST="$(ls -1t /home/root/.cache/rm-custom/xochitl.*.orig 2>/dev/null | head -n 1 || true)"
  if [ -n "$LATEST" ] && [ -f "$LATEST" ]; then
    cp -f "$LATEST" "$XO" 2>>"$LOG" || true
    chmod 755 "$XO" 2>/dev/null || true
  fi
  remount_back
  systemctl start xochitl >>"$LOG" 2>&1 || true
fi

# Update a simple env state for quick human inspection
NEW_SHA="$(sha "$XO")"
echo "patched_sha=$NEW_SHA" > "$STATE" 2>/dev/null || true
echo "json_sha=$JSON_SHA" >> "$STATE" 2>/dev/null || true
echo "locale=$LOCALE" >> "$STATE" 2>/dev/null || true

echo "[cus] done new_sha=$NEW_SHA" >> "$LOG"
exit 0
