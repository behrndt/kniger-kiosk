#!/usr/bin/env bash
# Startet Chromium im Kiosk-Modus mit der URL aus /run/kiosk/schedule.env.
# Watchdog-Loop: Chromium wird bei Absturz automatisch neu gestartet.
#
# Wird von LXDE-Autostart als lxsession-Eintrag ausgeführt (User: pi).

set -uo pipefail

ENV_FILE=/etc/kiosk/kiosk.env
SCHEDULE_ENV=/run/kiosk/schedule.env
LOG_TAG=kiosk-browser
FALLBACK_URL="https://kniger.club/checkin/display"

log()  { logger -t "$LOG_TAG" "$*"; echo "[kiosk-browser] $*" >&2; }

# Bildschirm-Abschalten / Screensaver deaktivieren (X11; no-op unter Wayland)
xset s noblank 2>/dev/null || true
xset s off     2>/dev/null || true
xset -dpms     2>/dev/null || true

# Cursor ausblenden — unclutter ist X11-only; unter Wayland (labwc) Seat-Cursor via gsettings
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    gsettings set org.gnome.desktop.interface cursor-size 1 2>/dev/null || true
else
    unclutter -idle 0.5 -root &
fi

# Netzwerk abwarten (max. 30 s) bevor Supabase erreichbar sein muss
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

# Erstsync — Supabase-URL holen, bevor Chromium startet
log "Initialer Schedule-Sync..."
/opt/kiosk/scripts/sync-schedule.sh 2>&1 || log "Initialer Sync fehlgeschlagen — Fallback-URL wird verwendet"

# Watchdog-Loop
while true; do
    # Schedule-Env laden
    if [ -f "$SCHEDULE_ENV" ]; then
        # shellcheck source=/dev/null
        source "$SCHEDULE_ENV"
        TARGET_URL="${KIOSK_URL:-$FALLBACK_URL}"
    else
        log "schedule.env fehlt — verwende Fallback-URL"
        TARGET_URL="$FALLBACK_URL"
        # KIOSK_TOKEN aus kiosk.env als Fallback
        if [ -f "$ENV_FILE" ]; then
            # shellcheck source=/dev/null
            source "$ENV_FILE"
            [ -n "${KIOSK_TOKEN:-}" ] && TARGET_URL="${TARGET_URL}?token=${KIOSK_TOKEN}"
        fi
    fi

    log "Starte Chromium: $TARGET_URL"

    # Alten Crash-State entfernen, damit kein "Chromium wurde nicht korrekt beendet"-Banner erscheint
    rm -f ~/.config/chromium/Default/Preferences 2>/dev/null || true
    PREF_DIR=~/.config/chromium/Default
    mkdir -p "$PREF_DIR"
    # Minimal-Preferences: kein Session-Restore-Dialog
    if [ ! -f "$PREF_DIR/Preferences" ]; then
        echo '{"session":{"restore_on_startup":4}}' > "$PREF_DIR/Preferences"
    fi

    # Pi OS Bookworm: Binary heißt "chromium"; Bullseye: "chromium-browser"
    CHROMIUM_BIN=$(command -v chromium || command -v chromium-browser)

    # Wayland (labwc) vs. X11 — Ozone-Platform automatisch wählen
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        OZONE_FLAGS="--ozone-platform=wayland --enable-features=UseOzonePlatform"
    else
        OZONE_FLAGS=""
    fi

    "$CHROMIUM_BIN" \
        --kiosk \
        --noerrdialogs \
        --disable-infobars \
        --disable-session-crashed-bubble \
        --disable-translate \
        --no-first-run \
        --password-store=basic \
        --disable-features=TranslateUI,OverscrollHistoryNavigation \
        --disable-pinch \
        --autoplay-policy=no-user-gesture-required \
        --allow-running-insecure-content \
        --disable-web-security=false \
        --check-for-update-interval=31536000 \
        $OZONE_FLAGS \
        --app="$TARGET_URL" \
        2>/dev/null

    EXIT_CODE=$?
    log "Chromium beendet (Exit $EXIT_CODE) — Neustart in 5s..."
    sleep 5

    # Vor Neustart: Schedule nochmals synchronisieren (könnte Remote-Update gewesen sein)
    /opt/kiosk/scripts/sync-schedule.sh 2>&1 || true
done
