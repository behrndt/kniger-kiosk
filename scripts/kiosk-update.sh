#!/usr/bin/env bash
# Remote-Update-Mechanismus: git pull + Services neu starten bei Änderungen.
# Wird stündlich von kiosk-update.timer als root ausgeführt.
#
# Strategie:
#   - git fetch, dann lokalen Stand mit Remote vergleichen
#   - Nur bei tatsächlichen Änderungen: pull + Service-Restart
#   - Kein Service-Crash bei fehlgeschlagenem Pull (silent abort)
#   - Systemd-Units werden ebenfalls aus dem Repo übernommen

set -uo pipefail

KIOSK_DIR=/opt/kiosk
KIOSK_ENV=/etc/kiosk/kiosk.env
LOG_TAG=kiosk-update

log()  { logger -t "$LOG_TAG" "$*"; }
warn() { logger -t "$LOG_TAG" -p user.warning "$*"; }

# Branch aus kiosk.env lesen (falls vorhanden)
KIOSK_BRANCH=main
if [ -f "$KIOSK_ENV" ]; then
    # shellcheck source=/dev/null
    KIOSK_BRANCH=$(grep '^KIOSK_BRANCH=' "$KIOSK_ENV" | cut -d= -f2 | tr -d '"' || echo main)
fi
KIOSK_BRANCH=${KIOSK_BRANCH:-main}

if [ ! -d "$KIOSK_DIR/.git" ]; then
    warn "Kein Git-Repo in $KIOSK_DIR — Update-Check übersprungen"
    exit 1
fi

cd "$KIOSK_DIR"

log "Update-Check: Branch '$KIOSK_BRANCH'…"

# Fetch (nicht destruktiv — kein Checkout)
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

# Pull (nur fast-forward — kein Force, kein Merge-Commit)
if ! git pull --ff-only origin "$KIOSK_BRANCH" 2>&1 | logger -t "$LOG_TAG"; then
    warn "git pull fehlgeschlagen (divergierter Branch?) — Update abgebrochen"
    exit 0
fi

NEW_HEAD=$(git rev-parse HEAD)
log "Aktualisiert auf ${NEW_HEAD:0:8}"

# Geänderte Dateien für gezielten Service-Restart ermitteln
CHANGED=$(git diff --name-only "${LOCAL}" "${NEW_HEAD}")
log "Geänderte Dateien: $(echo "$CHANGED" | tr '\n' ' ')"

# Systemd-Units aktualisieren, falls sie sich geändert haben
if echo "$CHANGED" | grep -q '^systemd/'; then
    log "Systemd-Units aktualisiert — daemon-reload"
    cp "$KIOSK_DIR/systemd/"*.service /etc/systemd/system/ 2>/dev/null || true
    cp "$KIOSK_DIR/systemd/"*.timer /etc/systemd/system/ 2>/dev/null || true
    systemctl daemon-reload
fi

# Scanner-Trigger neu starten, wenn sich scanner-trigger.py geändert hat
if echo "$CHANGED" | grep -q 'scanner-trigger\.py'; then
    log "scanner-trigger.py geändert — Service neu starten"
    systemctl restart scanner-trigger.service || warn "Restart scanner-trigger fehlgeschlagen"
fi

# sync-schedule Timer/Service neu starten bei Script-Änderung
if echo "$CHANGED" | grep -q 'sync-schedule'; then
    systemctl restart kiosk-sync.timer || true
fi

# Chromium neu starten wenn start-browser.sh oder sync-schedule.sh sich geändert hat
# (der Watchdog-Loop in start-browser.sh startet Chromium nach dem Kill neu)
if echo "$CHANGED" | grep -qE 'scripts/(start-browser|sync-schedule)'; then
    log "Browser-Skript geändert — Chromium wird neu gestartet"
    pkill -TERM -f chromium-browser 2>/dev/null || true
    # Der Watchdog-Loop in start-browser.sh startet Chromium automatisch neu
fi

log "Update abgeschlossen ✓"
