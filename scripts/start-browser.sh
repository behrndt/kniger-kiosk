#!/usr/bin/env bash
# Startet Chromium im Kiosk-Modus mit der URL aus /run/kiosk/schedule.env.
# Watchdog-Loop: Chromium wird bei Absturz automatisch neu gestartet.

set -uo pipefail

ENV_FILE=/etc/kiosk/kiosk.env
SCHEDULE_ENV=/run/kiosk/schedule.env
LOADING_PAGE="file:///opt/kiosk/loading.html"
SPLASH_PROFILE=/tmp/kiosk-splash-profile
FALLBACK_URL="https://kniger.club/checkin/display"
LOG_TAG=kiosk-browser

log()  { logger -t "$LOG_TAG" "$*"; echo "[kiosk-browser] $*" >&2; }

# Bildschirm-Abschalten / Screensaver deaktivieren (X11; no-op unter Wayland)
xset s noblank 2>/dev/null || true
xset s off     2>/dev/null || true
xset -dpms     2>/dev/null || true

# Cursor ausblenden
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    gsettings set org.gnome.desktop.interface cursor-size 1 2>/dev/null || true
else
    unclutter -idle 0.5 -root &
fi

# Display sicherstellen — XWayland läuft unter Pi OS labwc auf :0
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    export DISPLAY=:0
fi

CHROMIUM_BIN=$(command -v chromium || command -v chromium-browser)

# Gemeinsame Chromium-Flags (kein --user-data-dir: benutzt ~/.config/chromium)
CHROMIUM_FLAGS=(
    --kiosk
    --noerrdialogs
    --disable-infobars
    --disable-session-crashed-bubble
    --no-first-run
    --password-store=basic
    --disable-features=TranslateUI,OverscrollHistoryNavigation,PrivateNetworkAccessSendPreflights,PrivateNetworkAccessPermissionPrompt,PrivateNetworkAccessRespectPreflightResults,LocalNetworkAccessChecks,LocalNetworkAccessPermissionPrompt
    --disable-pinch
    --autoplay-policy=no-user-gesture-required
    --allow-running-insecure-content
    --check-for-update-interval=31536000
)

chromium_start() {
    local url="$1"
    local PREF_DIR="${HOME}/.config/chromium/Default"
    mkdir -p "$PREF_DIR"
    [ -f "$PREF_DIR/Preferences" ] || \
        echo '{"session":{"restore_on_startup":4},"profile":{"exit_type":"Normal"}}' \
        > "$PREF_DIR/Preferences"

    "$CHROMIUM_BIN" "${CHROMIUM_FLAGS[@]}" --app="$url" 2>/dev/null
}

# ── Splash-Phase ───────────────────────────────────────────────────────────────
# Splash nutzt EIGENES Profil-Verzeichnis → kein SingletonLock-Konflikt mit Hauptinstanz
log "Zeige Splash..."
mkdir -p "$SPLASH_PROFILE"
"$CHROMIUM_BIN" "${CHROMIUM_FLAGS[@]}" \
    --user-data-dir="$SPLASH_PROFILE" \
    --app="$LOADING_PAGE" &
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
/opt/kiosk/scripts/sync-schedule.sh 2>&1 || log "Sync fehlgeschlagen — Fallback-URL"

# ── Watchdog-Loop ──────────────────────────────────────────────────────────────
FIRST_START=true
while true; do
    if [ -f "$SCHEDULE_ENV" ]; then
        # shellcheck source=/dev/null
        source "$SCHEDULE_ENV"
        TARGET_URL="${KIOSK_URL:-$FALLBACK_URL}"
    else
        log "schedule.env fehlt — Fallback-URL"
        TARGET_URL="$FALLBACK_URL"
        if [ -f "$ENV_FILE" ]; then
            source "$ENV_FILE"
            [ -n "${KIOSK_TOKEN:-}" ] && TARGET_URL="${TARGET_URL}?token=${KIOSK_TOKEN}"
        fi
    fi

    log "Starte Chromium: $TARGET_URL"

    if [ "$FIRST_START" = "true" ]; then
        FIRST_START=false
        # Haupt-Chromium erst starten, dann Splash killen — verhindert Desktop-Flash
        chromium_start "$TARGET_URL" &
        MAIN_PID=$!
        sleep 3
        kill "$SPLASH_PID" 2>/dev/null || true
        pkill -f "user-data-dir=$SPLASH_PROFILE" 2>/dev/null || true
        wait "$MAIN_PID" 2>/dev/null || true
    else
        chromium_start "$TARGET_URL"
    fi

    EXIT_CODE=$?
    log "Chromium beendet (Exit $EXIT_CODE) — Neustart in 5s..."
    sleep 5
    /opt/kiosk/scripts/sync-schedule.sh 2>&1 || true
done
