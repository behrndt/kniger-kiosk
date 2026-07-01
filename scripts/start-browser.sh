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
LOCKFILE=/run/kiosk/start-browser.lock

log()  { logger -t "$LOG_TAG" "$*"; echo "[kiosk-browser] $*" >&2; }

# ── Singleton-Guard: nur eine Instanz pro Session ──────────────────────────────
mkdir -p /run/kiosk 2>/dev/null || true
if [ -f "$LOCKFILE" ]; then
    OLD_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        log "Bereits laufend (PID $OLD_PID) — beende Duplikat $$"
        exit 0
    fi
fi
echo "$$" > "$LOCKFILE"
trap "rm -f $LOCKFILE" EXIT INT TERM

# ── Hilfsfunktion: auf eigentlichen Browser-Prozess warten ────────────────────
# Chromium kann intern forken; der initiale Prozess exitet dann sofort.
# tail --pid wartet auf den tatsächlichen Browser-Prozess unabhängig von der PID-Herkunft.
wait_for_browser() {
    local init_pid="$1"
    wait "$init_pid" 2>/dev/null || true
    # Falls init_pid sofort exitiert hat (Fork-Architektur), noch auf echten Browser warten
    local browser_pid
    browser_pid=$(pgrep -f "chromium.*--app=" 2>/dev/null | head -1 || true)
    if [ -n "$browser_pid" ]; then
        log "Browser läuft als Prozess $browser_pid — warte via tail --pid"
        tail --pid="$browser_pid" -f /dev/null 2>/dev/null || true
    fi
}

# ── Bildschirm / Cursor ────────────────────────────────────────────────────────
xset s noblank 2>/dev/null || true
xset s off     2>/dev/null || true
xset -dpms     2>/dev/null || true

if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    gsettings set org.gnome.desktop.interface cursor-size 1 2>/dev/null || true
else
    unclutter -idle 0.5 -root &
fi

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
    # Overlay-FS: Cache in tmpfs mit hartem Limit (50 MB) — verhindert, dass der
    # Browser-Cache über lange Laufzeit den RAM-Overlay füllt.
    --disk-cache-dir=/tmp/kiosk-chromium-cache
    --disk-cache-size=52428800
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
        # Stale Chromium + Singleton-Lock aus vorherigem Boot bereinigen
        pkill -f "chromium.*--app=" 2>/dev/null || true
        sleep 1
        rm -f "${HOME}/.config/chromium/SingletonLock" \
               "${HOME}/.config/chromium/SingletonSocket" 2>/dev/null || true
        # Haupt-Chromium starten, nach 3 s Splash killen (verhindert Desktop-Flash)
        chromium_start "$TARGET_URL" &
        MAIN_PID=$!
        sleep 3
        kill "$SPLASH_PID" 2>/dev/null || true
        pkill -f "user-data-dir=$SPLASH_PROFILE" 2>/dev/null || true
        wait_for_browser "$MAIN_PID"
    else
        # Alle laufenden Instanzen beenden — verhindert Tab-Akkumulierung via Singleton
        pkill -f "chromium.*--app=" 2>/dev/null || true
        sleep 2
        rm -f "${HOME}/.config/chromium/SingletonLock" \
               "${HOME}/.config/chromium/SingletonSocket" 2>/dev/null || true
        chromium_start "$TARGET_URL" &
        MAIN_PID=$!
        wait_for_browser "$MAIN_PID"
    fi

    EXIT_CODE=$?
    log "Chromium beendet (Exit $EXIT_CODE) — Neustart in 5s..."
    sleep 5
    /opt/kiosk/scripts/sync-schedule.sh 2>&1 || true
done
