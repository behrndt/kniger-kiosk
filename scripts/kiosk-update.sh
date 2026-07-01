#!/usr/bin/env bash
# Remote-Update-Check — overlay-aware.
# Läuft im Wartungsfenster (kiosk-update.timer, nachts) als root.
#
# Zwei Betriebsmodi je nach FS-Zustand:
#
#   Overlay AKTIV (Prod):   Root ist read-only. Ein Update kann nicht direkt
#     angewendet werden. Stattdessen: Marker auf /boot/firmware schreiben,
#     Overlay deaktivieren, reboot. Nach dem Reboot übernimmt
#     kiosk-update-apply.sh (git pull → Overlay wieder an → reboot).
#
#   Overlay INAKTIV (Dev):  Root ist beschreibbar. Update wird direkt
#     angewendet (git pull + gezielte Service-Restarts, kein Reboot).
#
# In beiden Fällen nicht-destruktiv: fehlgeschlagener Fetch/Pull bricht still ab.

set -uo pipefail

KIOSK_DIR=/opt/kiosk
KIOSK_ENV=/etc/kiosk/kiosk.env
MARKER=/boot/firmware/kiosk-update.pending
OVERLAY_CTL="$KIOSK_DIR/scripts/overlay-ctl.sh"
LOG_TAG=kiosk-update

log()  { logger -t "$LOG_TAG" "$*"; }
warn() { logger -t "$LOG_TAG" -p user.warning "$*"; }

# Branch aus kiosk.env lesen (falls vorhanden)
KIOSK_BRANCH=main
if [ -f "$KIOSK_ENV" ]; then
    KIOSK_BRANCH=$(grep '^KIOSK_BRANCH=' "$KIOSK_ENV" | cut -d= -f2 | tr -d '"' || echo main)
fi
KIOSK_BRANCH=${KIOSK_BRANCH:-main}

if [ ! -d "$KIOSK_DIR/.git" ]; then
    warn "Kein Git-Repo in $KIOSK_DIR — Update-Check übersprungen"
    exit 1
fi

cd "$KIOSK_DIR"

log "Update-Check: Branch '$KIOSK_BRANCH'…"

# Fetch (bei aktivem Overlay landet dies im RAM-Overlay — unkritisch)
if ! git fetch --quiet origin "$KIOSK_BRANCH" 2>&1 | logger -t "$LOG_TAG"; then
    warn "git fetch fehlgeschlagen — Update abgebrochen"
    exit 0
fi

LOCAL=$(git rev-parse HEAD 2>/dev/null)
REMOTE=$(git rev-parse "origin/${KIOSK_BRANCH}" 2>/dev/null)

if [ "$LOCAL" = "$REMOTE" ]; then
    log "Bereits aktuell ($LOCAL)"
    exit 0
fi

log "Update verfügbar: ${LOCAL:0:8} → ${REMOTE:0:8}"

# ── Overlay-Pfad: Update kann nicht live angewendet werden ───────────────────
if [ -x "$OVERLAY_CTL" ] && "$OVERLAY_CTL" is-on; then
    log "Overlay aktiv — plane Update über Reboot-Zyklus."
    # Marker auf Boot-Partition (FAT, kein Overlay → persistent über Reboot)
    if "$OVERLAY_CTL" boot-rw; then
        echo "$REMOTE" > "$MARKER" 2>/dev/null || warn "Marker konnte nicht geschrieben werden"
        sync
        "$OVERLAY_CTL" boot-ro || true
    else
        warn "boot-rw fehlgeschlagen — Update abgebrochen"
        exit 0
    fi
    log "Deaktiviere Overlay und reboote für Update-Apply…"
    "$OVERLAY_CTL" disable
    sync
    systemctl reboot
    exit 0
fi

# ── Dev-Pfad: Overlay inaktiv, Root beschreibbar — direkt anwenden ───────────
log "Overlay inaktiv — wende Update direkt an."

if ! git pull --ff-only origin "$KIOSK_BRANCH" 2>&1 | logger -t "$LOG_TAG"; then
    warn "git pull fehlgeschlagen (divergierter Branch?) — Update abgebrochen"
    exit 0
fi

NEW_HEAD=$(git rev-parse HEAD)
log "Aktualisiert auf ${NEW_HEAD:0:8}"

# Executable-Bits nach Pull sicherstellen
chmod +x "$KIOSK_DIR/scripts/"*.sh "$KIOSK_DIR/scanner-trigger.py" "$KIOSK_DIR/install.sh" 2>/dev/null || true

CHANGED=$(git diff --name-only "${LOCAL}" "${NEW_HEAD}")
log "Geänderte Dateien: $(echo "$CHANGED" | tr '\n' ' ')"

# Systemd-Units aktualisieren
if echo "$CHANGED" | grep -q '^systemd/'; then
    log "Systemd-Units aktualisiert — daemon-reload"
    cp "$KIOSK_DIR/systemd/"*.service /etc/systemd/system/ 2>/dev/null || true
    cp "$KIOSK_DIR/systemd/"*.timer /etc/systemd/system/ 2>/dev/null || true
    systemctl daemon-reload
fi

# Scanner-Trigger neu starten
if echo "$CHANGED" | grep -q 'scanner-trigger\.py'; then
    log "scanner-trigger.py geändert — Service neu starten"
    systemctl restart scanner-trigger.service || warn "Restart scanner-trigger fehlgeschlagen"
fi

# sync-schedule Timer/Service neu starten
if echo "$CHANGED" | grep -q 'sync-schedule'; then
    systemctl restart kiosk-sync.timer || true
fi

# Chromium neu starten bei Browser-Skript-Änderung
if echo "$CHANGED" | grep -qE 'scripts/(start-browser|sync-schedule)'; then
    log "Browser-Skript geändert — Chromium wird neu gestartet"
    pkill -TERM -f chromium 2>/dev/null || true
fi

log "Update abgeschlossen ✓"
