#!/usr/bin/env bash
# Overlay-Update-Apply — läuft EINMALIG beim Boot, wenn ein Update ansteht.
#
# Kontext: Bei aktivem Overlay-FS ist Root read-only, ein git pull würde bei
# Reboot verpuffen. Der eigentliche Update-Flow ist daher zweistufig:
#
#   1. kiosk-update.sh (nachts): erkennt Update → Marker auf /boot/firmware,
#      deaktiviert Overlay, reboot.
#   2. DIESES Skript (kiosk-update-apply.service, oneshot beim Boot): läuft im
#      jetzt beschreibbaren Root → git pull + Assets → Overlay wieder an → reboot.
#
# FAIL-SAFE-Prinzip: Egal ob der Pull klappt oder nicht — am Ende wird IMMER
# das Overlay reaktiviert und rebootet, damit das FS nie dauerhaft im
# verwundbaren rw-Zustand verbleibt.

set -uo pipefail

KIOSK_DIR=/opt/kiosk
KIOSK_ENV=/etc/kiosk/kiosk.env
MARKER=/boot/firmware/kiosk-update.pending
OVERLAY_CTL="$KIOSK_DIR/scripts/overlay-ctl.sh"
LOG_TAG=kiosk-update-apply

log()  { logger -t "$LOG_TAG" "$*"; echo "[apply] $*" >&2; }
warn() { logger -t "$LOG_TAG" -p user.warning "$*"; echo "[apply] WARN: $*" >&2; }

# ── Marker vorhanden? ─────────────────────────────────────────────────────────
if [ ! -f "$MARKER" ]; then
    exit 0   # kein Update angefordert — nichts zu tun
fi

log "Update-Marker gefunden — beginne Apply."

# ── Sicherheit: Overlay MUSS aus sein, sonst ist Root read-only ──────────────
if "$OVERLAY_CTL" is-on; then
    warn "Overlay ist noch aktiv — Root wäre read-only. Apply nicht möglich."
    warn "Entferne Marker (Root bleibt geschützt, kein Reboot nötig)."
    "$OVERLAY_CTL" boot-rw && rm -f "$MARKER" && sync
    exit 1
fi

# ── Fail-safe-Trap: bei JEDEM Exit Overlay wieder an + reboot ────────────────
finish() {
    local rc=$?
    log "Apply beendet (rc=$rc) — reaktiviere Overlay + reboot."
    # /boot rw lassen: raspi-config enable_overlayfs braucht die Boot-Partition
    # beschreibbar. Marker entfernen, damit der Apply nicht erneut triggert.
    "$OVERLAY_CTL" boot-rw 2>/dev/null || true
    rm -f "$MARKER" 2>/dev/null || true
    sync
    "$OVERLAY_CTL" enable  || warn "Overlay-Reaktivierung fehlgeschlagen!"
    sync
    systemctl reboot
}
trap finish EXIT

# ── git pull ──────────────────────────────────────────────────────────────────
KIOSK_BRANCH=main
if [ -f "$KIOSK_ENV" ]; then
    KIOSK_BRANCH=$(grep '^KIOSK_BRANCH=' "$KIOSK_ENV" | cut -d= -f2 | tr -d '"' 2>/dev/null || echo main)
fi
KIOSK_BRANCH=${KIOSK_BRANCH:-main}

if [ ! -d "$KIOSK_DIR/.git" ]; then
    warn "Kein Git-Repo in $KIOSK_DIR — Apply abgebrochen"
    exit 1
fi

cd "$KIOSK_DIR" || exit 1
LOCAL=$(git rev-parse HEAD 2>/dev/null)

log "git pull (Branch $KIOSK_BRANCH)…"
if ! git pull --ff-only origin "$KIOSK_BRANCH" 2>&1 | logger -t "$LOG_TAG"; then
    warn "git pull fehlgeschlagen — behalte aktuelle Version (${LOCAL:0:8})"
    exit 0   # Trap räumt auf: Overlay an + reboot mit altem Code
fi
NEW_HEAD=$(git rev-parse HEAD)
log "Aktualisiert: ${LOCAL:0:8} → ${NEW_HEAD:0:8}"

# ── Executable-Bits + Assets ins System übernehmen ───────────────────────────
chmod +x "$KIOSK_DIR/scripts/"*.sh "$KIOSK_DIR/scanner-trigger.py" "$KIOSK_DIR/install.sh" 2>/dev/null || true

CHANGED=$(git diff --name-only "$LOCAL" "$NEW_HEAD" 2>/dev/null)

# Systemd-Units
if echo "$CHANGED" | grep -q '^systemd/'; then
    log "Systemd-Units aktualisiert"
    cp "$KIOSK_DIR/systemd/"*.service /etc/systemd/system/ 2>/dev/null || true
    cp "$KIOSK_DIR/systemd/"*.timer   /etc/systemd/system/ 2>/dev/null || true
    systemctl daemon-reload
fi

# Wallpaper
if echo "$CHANGED" | grep -q 'kniger-wallpaper.png'; then
    cp "$KIOSK_DIR/kniger-wallpaper.png" /usr/share/rpd-wallpaper/kniger-kiosk.png 2>/dev/null \
        && log "Wallpaper aktualisiert"
fi

# Plymouth-Theme
if echo "$CHANGED" | grep -q '^plymouth/'; then
    cp "$KIOSK_DIR/plymouth/kniger.plymouth" /usr/share/plymouth/themes/kniger/ 2>/dev/null || true
    cp "$KIOSK_DIR/plymouth/kniger.script"   /usr/share/plymouth/themes/kniger/ 2>/dev/null || true
    [ -f "$KIOSK_DIR/plymouth/logo.png" ] && cp "$KIOSK_DIR/plymouth/logo.png" /usr/share/plymouth/themes/kniger/ 2>/dev/null || true
    update-initramfs -u 2>/dev/null && log "Plymouth-Theme + initramfs aktualisiert"
fi

log "Apply erfolgreich — Trap reaktiviert Overlay und rebootet."
# EXIT-Trap (finish) übernimmt Overlay-Reaktivierung + Reboot
