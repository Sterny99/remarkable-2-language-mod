set -e

PERSIST="true"
LOCALE="de_DE"

STAGE="/home/root/.cache/rm-custom/stage"
BIN_DST="/home/root/bin/rm-xochitl-kbdpatch"
JSON_DIR="/home/root/.local/share/rm-custom/keyboards/de_DE"
JSON_DST="/home/root/.local/share/rm-custom/keyboards/de_DE/keyboard_layout.json"

FONT_STAGE="$STAGE/hebrew.ttf"
FONT_HOME_DIR="/home/root/.local/share/fonts"
FONT_HOME="/home/root/.local/share/fonts/hebrew.ttf"

FONT_SYS_DIR="/usr/share/fonts/rm-custom"
FONT_SYS="/usr/share/fonts/rm-custom/hebrew.ttf"

CUS_SH="/home/root/bin/rm-customizations.sh"
SLOT_SH="/home/root/bin/rm-slot-sync.sh"
SSH_SH="/home/root/bin/rm-ssh-ensure.sh"
UPD_SH="/home/root/bin/rm-update-watch.sh"
FIX_BOOT_HANG_SH="/home/root/bin/rm-fix-boot-hang.sh"

XO_DROPIN="/etc/systemd/system/xochitl.service.d/99-rm-custom.conf"

UNIT_CUS="/etc/systemd/system/rm-customizations.service"
UNIT_SLT="/etc/systemd/system/rm-slot-sync.service"
UNIT_SSH="/etc/systemd/system/rm-ssh-ensure.service"
UNIT_UPD="/etc/systemd/system/rm-update-watch.service"

LOG=/home/root/.cache/rm-custom/deploy.log
mkdir -p /home/root/.cache/rm-custom
: > "$LOG"
log(){ echo "$1" | tee -a "$LOG"; }

log "[deploy] begin (installer-rev=live+permfix+rw-before-customizations)"
log "[deploy] locale=$LOCALE persist=$PERSIST"

export PATH="/home/root/bin:$PATH"

log "[deploy] validating staged payload..."
req() { [ -f "$1" ] || { log "[deploy] ERROR missing: $1"; exit 2; }; }
req "$STAGE/rm-xochitl-kbdpatch"
req "$STAGE/keyboard_layout.json"
req "$STAGE/fonts.conf"
req "$STAGE/99-rm-custom.conf"
req "$STAGE/rm-ssh-ensure.sh"
req "$STAGE/rm-slot-sync.sh"
req "$STAGE/rm-update-watch.sh"
req "$STAGE/rm-customizations.sh"
req "$STAGE/rm-fix-boot-hang.sh"
req "$STAGE/rm-ssh-ensure.service"
req "$STAGE/rm-customizations.service"
req "$STAGE/rm-slot-sync.service"
req "$STAGE/rm-update-watch.service"

log "[deploy] ensuring directories..."
mkdir -p /home/root/bin "$JSON_DIR" /home/root/.cache/rm-custom "$FONT_HOME_DIR" \
  /home/root/.config/fontconfig /home/root/.cache/fontconfig

log "[deploy] remounting rootfs RW (best-effort)..."
mount -o remount,rw / 2>/dev/null || true

log "[deploy] installing patch binary + keyboard json..."
cp -f "$STAGE/rm-xochitl-kbdpatch" "$BIN_DST"
cp -f "$STAGE/keyboard_layout.json" "$JSON_DST"

log "[deploy] installing font + fontconfig..."
if [ -f "$FONT_STAGE" ]; then
  cp -f "$FONT_STAGE" "$FONT_HOME"
  chmod 0644 "$FONT_HOME" 2>/dev/null || true
  log "[deploy] font installed to $FONT_HOME"
else
  log "[deploy] font stage missing (SkipFontInstall?)"
fi

cp -f "$STAGE/fonts.conf" /home/root/.config/fontconfig/fonts.conf
cp -f /home/root/.config/fontconfig/fonts.conf /home/root/.fonts.conf 2>/dev/null || true

mkdir -p "$FONT_SYS_DIR" 2>/dev/null || true
if [ -f "$FONT_HOME" ]; then
  cp -f "$FONT_HOME" "$FONT_SYS" 2>/dev/null || true
  chmod 0644 "$FONT_SYS" 2>/dev/null || true
  log "[deploy] font mirrored to $FONT_SYS"
fi

log "[deploy] installing xochitl drop-in + scripts + units..."
mkdir -p "$(dirname "$XO_DROPIN")" 2>/dev/null || true
cp -f "$STAGE/99-rm-custom.conf" "$XO_DROPIN"

cp -f "$STAGE/rm-ssh-ensure.sh" "$SSH_SH"
cp -f "$STAGE/rm-slot-sync.sh" "$SLOT_SH"
cp -f "$STAGE/rm-update-watch.sh" "$UPD_SH"
cp -f "$STAGE/rm-customizations.sh" "$CUS_SH"
cp -f "$STAGE/rm-fix-boot-hang.sh" "$FIX_BOOT_HANG_SH"

cp -f "$STAGE/rm-ssh-ensure.service" "$UNIT_SSH"
cp -f "$STAGE/rm-customizations.service" "$UNIT_CUS"
cp -f "$STAGE/rm-slot-sync.service" "$UNIT_SLT"
cp -f "$STAGE/rm-update-watch.service" "$UNIT_UPD"

log "[deploy] normalizing CRLF (may reset exec bits; we fix perms after)..."
norm_lf() {
  f="$1"
  [ -f "$f" ] || return 0
  tmp="$f.$$"
  tr -d '\015' < "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f" 2>/dev/null || true
}
norm_lf /home/root/.config/fontconfig/fonts.conf
norm_lf /home/root/.fonts.conf
norm_lf "$XO_DROPIN"
norm_lf "$SSH_SH"
norm_lf "$SLOT_SH"
norm_lf "$UPD_SH"
norm_lf "$CUS_SH"
norm_lf "$FIX_BOOT_HANG_SH"
norm_lf "$UNIT_SSH"
norm_lf "$UNIT_CUS"
norm_lf "$UNIT_SLT"
norm_lf "$UNIT_UPD"

log "[deploy] ensuring PATH export exists inside scripts (systemd-safe)..."
ensure_path() {
  f="$1"
  [ -f "$f" ] || return 0
  grep -q 'export PATH="/home/root/bin:\$PATH"' "$f" 2>/dev/null && return 0
  if head -n 1 "$f" | grep -q '^#!'; then
    sed -i '1a export PATH="/home/root/bin:$PATH"' "$f" 2>/dev/null || true
  else
    sed -i '1i export PATH="/home/root/bin:$PATH"' "$f" 2>/dev/null || true
  fi
}
ensure_path "$SSH_SH"
ensure_path "$SLOT_SH"
ensure_path "$UPD_SH"
ensure_path "$CUS_SH"
ensure_path "$FIX_BOOT_HANG_SH"

log "[deploy] substituting tokens in customizations..."
sed -i "s#de_DE#$LOCALE#g" "$CUS_SH" 2>/dev/null || true
sed -i "s#/home/root/.local/share/rm-custom/keyboards/de_DE/keyboard_layout.json#$JSON_DST#g" "$CUS_SH" 2>/dev/null || true
sed -i "s#/home/root/.local/share/fonts#$FONT_HOME_DIR#g" "$CUS_SH" 2>/dev/null || true
sed -i "s#/home/root/.local/share/fonts/hebrew.ttf#$FONT_HOME#g" "$CUS_SH" 2>/dev/null || true
sed -i "s#/usr/share/fonts/rm-custom#$FONT_SYS_DIR#g" "$CUS_SH" 2>/dev/null || true
sed -i "s#/usr/share/fonts/rm-custom/hebrew.ttf#$FONT_SYS#g" "$CUS_SH" 2>/dev/null || true

log "[deploy] enforcing permissions AFTER edits..."
chmod 0755 "$BIN_DST" 2>/dev/null || true
chmod 0755 "$SSH_SH" "$SLOT_SH" "$UPD_SH" "$CUS_SH" "$FIX_BOOT_HANG_SH" 2>/dev/null || true
chmod 0644 "$XO_DROPIN" "$UNIT_SSH" "$UNIT_CUS" "$UNIT_SLT" "$UNIT_UPD" 2>/dev/null || true

log "[deploy] enabling services..."
systemctl daemon-reload 2>/dev/null || true
systemctl enable rm-ssh-ensure.service 2>/dev/null || true
systemctl enable rm-customizations.service 2>/dev/null || true
systemctl enable rm-update-watch.service 2>/dev/null || true

if [ "$PERSIST" = "true" ]; then
  systemctl enable rm-slot-sync.service 2>/dev/null || true
  log "[deploy] persistence enabled"
else
  systemctl disable rm-slot-sync.service 2>/dev/null || true
  log "[deploy] persistence disabled (per flag)"
fi

log "[deploy] running ssh-ensure now..."
( systemctl start rm-ssh-ensure.service 2>/dev/null || sh /home/root/bin/rm-ssh-ensure.sh ) 2>&1 | tee -a "$LOG" || true

log "[deploy] applying boot-hang ordering fix..."
sh /home/root/bin/rm-fix-boot-hang.sh 2>&1 | tee -a "$LOG" || true

log "[deploy] running customizations now (OSK patch + xochitl restart)..."
mount -o remount,rw / 2>/dev/null || true
sh /home/root/bin/rm-customizations.sh 2>&1 | tee -a "$LOG"

if [ "$PERSIST" = "true" ]; then
  log "[deploy] seeding inactive slot now..."
  sh /home/root/bin/rm-slot-sync.sh 2>&1 | tee -a "$LOG" || true
fi

log "[deploy] refreshing font cache + restarting xochitl..."
fc-cache -f "$FONT_HOME_DIR" 2>&1 | tee -a "$LOG" || true
systemctl stop xochitl 2>&1 | tee -a "$LOG" || true
systemctl start xochitl 2>&1 | tee -a "$LOG" || true

log "[deploy] remounting rootfs RO..."
mount -o remount,ro / 2>/dev/null || true

log "[deploy] DONE"
echo "---- tail deploy.log ----"
tail -n 200 "$LOG" 2>/dev/null || true