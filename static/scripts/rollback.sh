set -e
LOG=/home/root/.cache/rm-custom/rollback.log
mkdir -p /home/root/.cache/rm-custom
: > "$LOG"

log(){ echo "$1" | tee -a "$LOG"; }

log "[rb] stop xochitl"
systemctl stop xochitl 2>/dev/null || true

# Remount rw for cleanup/restore
mount -o remount,rw / 2>/dev/null || true

BKDIR=/home/root/.cache/rm-custom
BK="$(ls -1t $BKDIR/xochitl.*.orig 2>/dev/null | head -n 1 || true)"
if [ -n "$BK" ] && [ -f "$BK" ]; then
  log "[rb] restore $BK -> /usr/bin/xochitl"
  cp -f "$BK" /usr/bin/xochitl 2>/dev/null || dd if="$BK" of=/usr/bin/xochitl bs=1M conv=fsync 2>/dev/null || true
  chmod 755 /usr/bin/xochitl 2>/dev/null || true
else
  log "[rb] no xochitl backup found; leaving /usr/bin/xochitl as-is"
fi

log "[rb] disable/remove services + drop-ins"
systemctl disable rm-customizations.service 2>/dev/null || true
systemctl disable rm-slot-sync.service 2>/dev/null || true
systemctl disable rm-ssh-ensure.service 2>/dev/null || true
systemctl disable rm-update-watch.service 2>/dev/null || true

rm -f /etc/systemd/system/rm-customizations.service \
      /etc/systemd/system/rm-slot-sync.service \
      /etc/systemd/system/rm-ssh-ensure.service \
      /etc/systemd/system/rm-update-watch.service 2>/dev/null || true

rm -f /etc/systemd/system/xochitl.service.d/99-rm-custom.conf 2>/dev/null || true
rmdir /etc/systemd/system/xochitl.service.d 2>/dev/null || true

rm -f /usr/share/fonts/rm-custom/hebrew.ttf 2>/dev/null || true
rmdir /usr/share/fonts/rm-custom 2>/dev/null || true

rm -f /home/root/bin/rm-fix-boot-hang.sh 2>/dev/null || true

systemctl daemon-reload 2>/dev/null || true

log "[rb] remove state"
rm -f /home/root/.cache/rm-custom/state.env 2>/dev/null || true

# Back to ro (best-effort)
mount -o remount,ro / 2>/dev/null || true

log "[rb] start xochitl"
systemctl start xochitl 2>/dev/null || true

log "[rb] done"
tail -n 220 "$LOG" 2>/dev/null || true
