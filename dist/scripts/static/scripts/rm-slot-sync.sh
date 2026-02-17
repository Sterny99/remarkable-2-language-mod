#!/bin/sh
set +e

LOG=/home/root/.cache/rm-custom/slot-sync.log
mkdir -p /home/root/.cache/rm-custom
echo "[slot] start $(date 2>/dev/null || true)" >> "$LOG"

LOCK=/home/root/.cache/rm-custom/.slot-sync.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "[slot] already running; exit" >> "$LOG"
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
      echo "[slot] timeout running: $*" >> "$LOG"
      return 124
    fi
    sleep 1
    t=$((t+1))
  done
  wait "$pid" 2>/dev/null
  return $?
}

canon() { readlink -f "$1" 2>/dev/null || echo "$1"; }

# Determine current root source from cmdline or mounts
ROOTSRC="$(tr ' ' '\n' </proc/cmdline 2>/dev/null | awk -F= '$1=="root"{print $2; exit}')"
[ -z "$ROOTSRC" ] && ROOTSRC="$(awk '$2=="/"{print $1; exit}' /proc/mounts 2>/dev/null || true)"

resolve_rootdev() {
  src="$1"
  case "$src" in
    /dev/*) echo "$(canon "$src")"; return 0 ;;
    PARTUUID=*)
      id="${src#PARTUUID=}"
      [ -e "/dev/disk/by-partuuid/$id" ] && echo "$(canon "/dev/disk/by-partuuid/$id")" && return 0
      have blkid && blkid -t "PARTUUID=$id" -o device 2>/dev/null | head -n 1 && return 0
      ;;
    UUID=*)
      id="${src#UUID=}"
      [ -e "/dev/disk/by-uuid/$id" ] && echo "$(canon "/dev/disk/by-uuid/$id")" && return 0
      have blkid && blkid -t "UUID=$id" -o device 2>/dev/null | head -n 1 && return 0
      ;;
  esac
  echo ""
  return 0
}

ROOTDEV="$(resolve_rootdev "$ROOTSRC")"
[ -z "$ROOTDEV" ] && ROOTDEV="$(canon "$(awk '$2=="/"{print $1; exit}' /proc/mounts 2>/dev/null || true)")"

echo "[slot] rootsrc=$ROOTSRC rootdev=$ROOTDEV" >> "$LOG"

OTHER=""
case "$ROOTDEV" in
  /dev/mmcblk*p2) OTHER="${ROOTDEV%p2}p3" ;;
  /dev/mmcblk*p3) OTHER="${ROOTDEV%p3}p2" ;;
esac

if [ -z "$OTHER" ]; then
  echo "[slot] ERROR: cannot derive OTHER from rootdev=$ROOTDEV" >> "$LOG"
  exit 0
fi

OTHERC="$(canon "$OTHER")"
echo "[slot] other=$OTHER (canon=$OTHERC)" >> "$LOG"

# Find existing mountpoint for OTHER by canonical source match
MNT=""
while read src tgt rest; do
  srcc="$(canon "$src")"
  if [ "$srcc" = "$OTHERC" ]; then
    MNT="$tgt"
    break
  fi
done </proc/mounts 2>/dev/null || true

UMOUNT=0
if [ -n "$MNT" ]; then
  echo "[slot] other already mounted at $MNT; try remount rw" >> "$LOG"
  run_tmo 3 mount -o remount,rw "$MNT" || true
else
  MNT=/mnt/rm-inactive
  mkdir -p "$MNT"
  echo "[slot] mounting $OTHER at $MNT" >> "$LOG"
  run_tmo 4 mount -o rw "$OTHER" "$MNT" || { echo "[slot] ERROR: mount failed" >> "$LOG"; exit 0; }
  UMOUNT=1
fi

# Writability check
touch "$MNT/.rm-slot-sync.$$" 2>>"$LOG" || {
  echo "[slot] ERROR: $MNT not writable" >> "$LOG"
  [ "$UMOUNT" = "1" ] && run_tmo 3 umount "$MNT" || true
  exit 0
}
rm -f "$MNT/.rm-slot-sync.$$" 2>>"$LOG" || true

# Copy artifacts (small files, no full sync)
mkdir -p "$MNT/etc/systemd/system" \
         "$MNT/etc/systemd/system/multi-user.target.wants" \
         "$MNT/etc/systemd/system/shutdown.target.wants" \
         "$MNT/etc/systemd/system/reboot.target.wants" \
         "$MNT/etc/systemd/system/halt.target.wants" \
         "$MNT/etc/systemd/system/poweroff.target.wants" \
         "$MNT/etc/systemd/system/xochitl.service.d" \
         "$MNT/usr/share/fonts/rm-custom" 2>>"$LOG" || true

copy_if_present() {
  src="$1"; dst="$2"
  if [ -f "$src" ]; then
    cp -f "$src" "$dst" 2>>"$LOG" || echo "[slot] ERROR copying $src" >> "$LOG"
  else
    echo "[slot] missing $src" >> "$LOG"
  fi
}

# Unit files
for f in rm-customizations.service rm-slot-sync.service rm-ssh-ensure.service rm-update-watch.service; do
  copy_if_present "/etc/systemd/system/$f" "$MNT/etc/systemd/system/$f"
done

# Xochitl drop-in
copy_if_present "/etc/systemd/system/xochitl.service.d/99-rm-custom.conf" "$MNT/etc/systemd/system/xochitl.service.d/99-rm-custom.conf"

# System font copy
copy_if_present "/usr/share/fonts/rm-custom/hebrew.ttf" "$MNT/usr/share/fonts/rm-custom/hebrew.ttf"

# Enable services on OTHER slot
ln -sf ../rm-customizations.service "$MNT/etc/systemd/system/multi-user.target.wants/rm-customizations.service" 2>>"$LOG" || true
ln -sf ../rm-ssh-ensure.service     "$MNT/etc/systemd/system/multi-user.target.wants/rm-ssh-ensure.service"     2>>"$LOG" || true
ln -sf ../rm-update-watch.service   "$MNT/etc/systemd/system/multi-user.target.wants/rm-update-watch.service"   2>>"$LOG" || true

for t in shutdown reboot halt poweroff; do
  ln -sf ../rm-slot-sync.service "$MNT/etc/systemd/system/$t.target.wants/rm-slot-sync.service" 2>>"$LOG" || true
done

# Unmount only if we mounted it
if [ "$UMOUNT" = "1" ]; then
  run_tmo 3 umount "$MNT" || true
fi

echo "[slot] done" >> "$LOG"
exit 0
