#!/usr/bin/env bash
# Startet Chromium im Kiosk-Modus mit der URL aus /run/kiosk/schedule.env.
# Watchdog-Loop: Chromium wird bei Absturz automatisch neu gestartet.

set -uo pipefail

ENV_FILE=/etc/kiosk/kiosk.env
SCHEDULE_ENV=/run/kiosk/schedule.env
LOADING_PAGE="file:///opt/kiosk/loading.html"
FALLBACK_URL="https://kniger.club/checkin/display"
LOG_TAG=kiosk-browser

log()  { logger -t "$LOG_TAG" "$*"; echo "[kiosk-browser] $*" >&2; }

# Bildschirm-Abschalten / Screensaver deaktivieren (X11; no-op unter Wayland)
xset s noblank 2>/dev/null || true
xset s off     2>/dev/null || true
xset -dpms     2>/dev/null || true

# Cursor ausblenden — unclutter ist X11-only; unter Wayland (labwc) via gsettings
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    gsettings set org.gnome.desktop.interface cursor-size 1 2>/dev/null || true
else
    unclutter -idle 0.5 -root &
fi

# Chromium-Binary ermitteln
CHROMIUM_BIN=$(command -v chromium || command -v chromium-browser)

chromium_start() {
    local url="$1"
    PREF_DIR="${HOME}/.config/chromium/Default"
    mkdir -p "$PREF_DIR"
    # Nur beim allerersten Start anlegen — NICHT bei jedem Neustart löschen,
    # damit gespeicherte Permissions (Private Network Access) erhalten bleiben
    if [ ! -f "$PREF_DIR/Preferences" ]; then
        echo '{"session":{"restore_on_startup":4},"profile":{"exit_type":"Normal"}}' \
            > "$PREF_DIR/Preferences"
    fi

    "$CHROMIUM_BIN" \
        --kiosk \
        --noerrdialogs \
        --disable-infobars \
        --disable-session-crashed-bubble \
        --disable-translate \
        --no-first-run \
        --password-store=basic \
        --disable-features=TranslateUI,OverscrollHistoryNavigation,PrivateNetworkAccessSendPreflights \
        --disable-pinch \
        --autoplay-policy=no-user-gesture-required \
        --allow-running-insecure-content \
        --check-for-update-interval=31536000 \
        --ozone-platform=auto \
        --app="$url" \
        2>/dev/null
}

# ── Splash-Phase ───────────────────────────────────────────────────────────────
# Chromium zeigt sofort die lokale Loading-Seite, während Netzwerk + Sync laufen
log "Zeige Splash..."
rm -f "${HOME}/.config/chromium/Default/Preferences" 2>/dev/null || true
chromium_start "$LOADING_PAGE" &
SPLASH_PID=$!

# Netzwerk abwarten (max. 30 s)
log "Warte auf Netzwerkverbindung..."
for i in $(seq 1 30); do
    if curl -sf --connect-timeout 2 --max-time 3 \
        "https://vtrewducfipnegrlomrx.supabase.co/rest/v1/" \
        -H "apikey: placeholder" -o /dev/null 2>/dev/null; then
        log "Netzwerk bereit (${i}s)"
        break
    fi
    sleep 1
done

# Erstsync
log "Initialer Schedule-Sync..."
/opt/kiosk/scripts/sync-schedule.sh 2>&1 || log "Sync fehlgeschlagen — Fallback-URL wird verwendet"

# Splash beenden
kill "$SPLASH_PID" 2>/dev/null || true
wait "$SPLASH_PID" 2>/dev/null || true
sleep 0.5

# ── Watchdog-Loop ──────────────────────────────────────────────────────────────
while true; do
    if [ -f "$SCHEDULE_ENV" ]; then
        # shellcheck source=/dev/null
        source "$SCHEDULE_ENV"
        TARGET_URL="${KIOSK_URL:-$FALLBACK_URL}"
    else
        log "schedule.env fehlt — verwende Fallback-URL"
        TARGET_URL="$FALLBACK_URL"
        if [ -f "$ENV_FILE" ]; then
            # shellcheck source=/dev/null
            source "$ENV_FILE"
            [ -n "${KIOSK_TOKEN:-}" ] && TARGET_URL="${TARGET_URL}?token=${KIOSK_TOKEN}"
        fi
    fi

    log "Starte Chromium: $TARGET_URL"
    chromium_start "$TARGET_URL"

    EXIT_CODE=$?
    log "Chromium beendet (Exit $EXIT_CODE) — Neustart in 5s..."
    sleep 5

    /opt/kiosk/scripts/sync-schedule.sh 2>&1 || true
done
