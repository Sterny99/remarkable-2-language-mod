#!/bin/sh
set +e

LOG=/home/root/.cache/rm-custom/ssh-ensure.log
mkdir -p /home/root/.cache/rm-custom
echo "[ssh] start $(date 2>/dev/null || true)" >> "$LOG"

have(){ command -v "$1" >/dev/null 2>&1; }

ensure_usb0() {
  if have ip; then
    ip link show usb0 >/dev/null 2>&1 || return 1
    ip link set usb0 up >/dev/null 2>&1 || true
    ip addr show dev usb0 2>/dev/null | grep -q "10\.11\.99\.1" || ip addr add 10.11.99.1/24 dev usb0 >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

ensure_dropbear() {
  # dropbear is commonly socket-activated on reMarkable
  systemctl start dropbear.socket >/dev/null 2>&1 || true
  systemctl start dropbear.service >/dev/null 2>&1 || true
  systemctl start sshd.service >/dev/null 2>&1 || true
  systemctl start ssh.service  >/dev/null 2>&1 || true

  systemctl is-active --quiet dropbear.socket && return 0
  systemctl is-active --quiet dropbear.service && return 0
  pgrep dropbear >/dev/null 2>&1 && return 0
  return 1
}

ok=0
i=0
while [ "$i" -lt 24 ]; do
  ensure_usb0
  ensure_dropbear
  # Success heuristic: usb0 has expected IP AND a dropbear socket/service exists
  if (have ip && ip addr show dev usb0 2>/dev/null | grep -q "10\.11\.99\.1") && ensure_dropbear; then
    ok=1
    break
  fi
  sleep 5
  i=$((i+1))
done

if [ "$ok" = "1" ]; then
  echo "[ssh] ok" >> "$LOG"
else
  echo "[ssh] WARNING: could not confirm ssh over usb0 within retry window" >> "$LOG"
fi
exit 0
