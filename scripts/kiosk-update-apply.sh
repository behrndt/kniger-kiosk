#!/usr/bin/env bash
# Overlay-Update-Apply — läuft EINMALIG beim Boot, wenn ein Update ansteht.
#
# Kontext: Bei aktivem Overlay-FS ist Root read-only, ein git pull würde bei
# Reboot verpuffen. Der Update-Flow ist daher zweistufig:
#
#   1. kiosk-update.sh (bewusst ausgelöst): erkennt Update → Marker auf
#      /boot/firmware, deaktiviert Overlay, reboot.
#   2. DIESES Skript (kiosk-update-apply.service, oneshot beim Boot): läuft im
#      jetzt beschreibbaren Root → git pull + Assets → Overlay wieder an → reboot.
#
# FAIL-SAFE: Egal ob der Pull klappt oder nicht — am Ende wird IMMER das Overlay
# reaktiviert und rebootet, damit das FS nie dauerhaft im rw-Zustand verbleibt.
#
# ROBUSTHEIT: git pull mit Netz-Warten + Timeout + Retry (die häufigste
# Fehlerquelle war ein zu früher Pull, bevor Netz/DNS bereit waren).
# Persistentes Log auf /boot/firmware (überlebt Reboot trotz volatile journald).

set -uo pipefail

KIOSK_DIR=/opt/kiosk
KIOSK_ENV=/etc/kiosk/kiosk.env
MARKER=/boot/firmware/kiosk-update.pending
PERSIST_LOG=/boot/firmware/kiosk-update.log
OVERLAY_CTL="$KIOSK_DIR/scripts/overlay-ctl.sh"
LOG_TAG=kiosk-update-apply

# ── Logging: journald (flüchtig) + persistent auf /boot (überlebt Reboot) ────
plog() {
    logger -t "$LOG_TAG" "$*"
    echo "[apply] $*" >&2
    # Persistent auf Boot-Partition — nur wenn beschreibbar
    echo "$(date '+%Y-%m-%dT%H:%M:%S') $*" >> "$PERSIST_LOG" 2>/dev/null || true
}
warn() { plog "WARN: $*"; }

# ── Marker vorhanden? ─────────────────────────────────────────────────────────
[ -f "$MARKER" ] || exit 0   # kein Update angefordert

# /boot rw für Log + Marker-Handling
"$OVERLAY_CTL" boot-rw 2>/dev/null || true
plog "===== Update-Apply gestartet ====="

# ── Sicherheit: Overlay MUSS aus sein, sonst ist Root read-only ──────────────
if "$OVERLAY_CTL" is-on; then
    warn "Overlay noch aktiv — Root read-only, Apply nicht möglich. Marker entfernt."
    rm -f "$MARKER"; sync
    exit 1
fi

# ── Fail-safe-Trap: bei JEDEM Exit Overlay wieder an + reboot ────────────────
finish() {
    local rc=$?
    plog "Apply beendet (rc=$rc) — reaktiviere Overlay + reboot."
    "$OVERLAY_CTL" boot-rw 2>/dev/null || true
    rm -f "$MARKER" 2>/dev/null || true
    sync
    "$OVERLAY_CTL" enable || warn "Overlay-Reaktivierung fehlgeschlagen!"
    sync
    systemctl reboot
}
trap finish EXIT

# ── Auf stabiles Netz warten (bis zu 90s) ────────────────────────────────────
plog "Warte auf Netzwerk (DNS-Auflösung github.com)…"
NET_OK=0
for i in $(seq 1 30); do
    if getent hosts github.com >/dev/null 2>&1 && \
       timeout 8 git ls-remote --quiet https://github.com/behrndt/kniger-kiosk.git HEAD >/dev/null 2>&1; then
        NET_OK=1
        plog "Netz bereit nach ~$((i*3))s"
        break
    fi
    sleep 3
done
[ "$NET_OK" = "1" ] || { warn "Netz nach 90s nicht bereit — Update verschoben (Fail-safe reboot)"; exit 0; }

# ── git pull mit Timeout + Retry ─────────────────────────────────────────────
KIOSK_BRANCH=main
[ -f "$KIOSK_ENV" ] && KIOSK_BRANCH=$(grep '^KIOSK_BRANCH=' "$KIOSK_ENV" | cut -d= -f2 | tr -d '"' 2>/dev/null || echo main)
KIOSK_BRANCH=${KIOSK_BRANCH:-main}

[ -d "$KIOSK_DIR/.git" ] || { warn "Kein Git-Repo in $KIOSK_DIR"; exit 1; }
cd "$KIOSK_DIR" || exit 1
LOCAL=$(git rev-parse HEAD 2>/dev/null)

PULL_OK=0
for attempt in 1 2 3; do
    plog "git pull (Versuch $attempt, Branch $KIOSK_BRANCH)…"
    if timeout 60 git fetch --quiet origin "$KIOSK_BRANCH" 2>&1 | logger -t "$LOG_TAG" && \
       timeout 60 git pull --ff-only origin "$KIOSK_BRANCH" 2>&1 | logger -t "$LOG_TAG"; then
        PULL_OK=1
        break
    fi
    warn "Pull-Versuch $attempt fehlgeschlagen — retry in 10s"
    sleep 10
done
[ "$PULL_OK" = "1" ] || { warn "git pull nach 3 Versuchen fehlgeschlagen — behalte ${LOCAL:0:8}"; exit 0; }

NEW_HEAD=$(git rev-parse HEAD)
plog "Aktualisiert: ${LOCAL:0:8} → ${NEW_HEAD:0:8}"

# ── Executable-Bits + Assets ins System übernehmen ───────────────────────────
chmod +x "$KIOSK_DIR/scripts/"*.sh "$KIOSK_DIR/scanner-trigger.py" "$KIOSK_DIR/install.sh" 2>/dev/null || true

CHANGED=$(git diff --name-only "$LOCAL" "$NEW_HEAD" 2>/dev/null)

if echo "$CHANGED" | grep -q '^systemd/'; then
    plog "Systemd-Units aktualisiert"
    cp "$KIOSK_DIR/systemd/"*.service /etc/systemd/system/ 2>/dev/null || true
    cp "$KIOSK_DIR/systemd/"*.timer   /etc/systemd/system/ 2>/dev/null || true
    systemctl daemon-reload
fi

if echo "$CHANGED" | grep -q 'kniger-wallpaper.png'; then
    cp "$KIOSK_DIR/kniger-wallpaper.png" /usr/share/rpd-wallpaper/kniger-kiosk.png 2>/dev/null && plog "Wallpaper aktualisiert"
fi

if echo "$CHANGED" | grep -q '^plymouth/'; then
    cp "$KIOSK_DIR/plymouth/kniger.plymouth" /usr/share/plymouth/themes/kniger/ 2>/dev/null || true
    cp "$KIOSK_DIR/plymouth/kniger.script"   /usr/share/plymouth/themes/kniger/ 2>/dev/null || true
    [ -f "$KIOSK_DIR/plymouth/logo.png" ] && cp "$KIOSK_DIR/plymouth/logo.png" /usr/share/plymouth/themes/kniger/ 2>/dev/null || true
    update-initramfs -u 2>/dev/null && plog "Plymouth-Theme + initramfs aktualisiert"
fi

plog "Apply erfolgreich — Trap reaktiviert Overlay und rebootet."
# EXIT-Trap (finish) übernimmt Overlay-Reaktivierung + Reboot
