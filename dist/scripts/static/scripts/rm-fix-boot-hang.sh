#!/bin/sh
set -eu

LOG=/home/root/.cache/rm-custom/fix-boot-hang.log
mkdir -p /home/root/.cache/rm-custom
: > "$LOG"
log(){ echo "[fix] $*" | tee -a "$LOG"; }

mount -o remount,rw / 2>/dev/null || true

log "1) Make xochitl drop-in ENV-ONLY (no Wants/After/Before)"
mkdir -p /etc/systemd/system/xochitl.service.d 2>/dev/null || true
cat > /etc/systemd/system/xochitl.service.d/99-rm-custom.conf <<'D'
[Service]
Environment=HOME=/home/root
Environment=XDG_CONFIG_HOME=/home/root/.config
Environment=XDG_CACHE_HOME=/home/root/.cache
Environment=XDG_DATA_HOME=/home/root/.local/share
Environment=QT_QPA_FONTDIR=/usr/share/fonts/rm-custom:/home/root/.local/share/fonts:/usr/share/fonts
D

log "2) Make rm-customizations run AFTER xochitl (never part of xochitl start ordering)"
cat > /etc/systemd/system/rm-customizations.service <<'S'
[Unit]
Description=rm-customizations (font cache + keyboard patch)
After=local-fs.target xochitl.service
Wants=local-fs.target

[Service]
Type=oneshot
TimeoutStartSec=180
ExecStart=/home/root/bin/rm-customizations.sh

[Install]
WantedBy=multi-user.target
S

log "3) Reload systemd and restart xochitl cleanly"
systemctl daemon-reload 2>/dev/null || true

# Make sure xochitl is enabled (belt + suspenders)
systemctl enable xochitl.service 2>/dev/null || true

# Restart xochitl now
systemctl restart xochitl.service 2>/dev/null || {
  systemctl stop xochitl.service 2>/dev/null || true
  systemctl start xochitl.service 2>/dev/null || true
}

mount -o remount,ro / 2>/dev/null || true

log "done. Check: journalctl -b | grep -i 'ordering cycle' (should be empty)."
