#!/usr/bin/env bash
# TV-Steuerung via HDMI-CEC basierend auf dem Zeitplan aus kiosk_screens.
# Wird von kiosk-cec-check.timer jede Minute aufgerufen.
#
# Benötigt: cec-utils (cec-client)
# State-Datei: /run/kiosk/tv-state ("on" oder "off")

set -uo pipefail

SCHEDULE_ENV=/run/kiosk/schedule.env
STATE_FILE=/run/kiosk/tv-state
LOG_TAG=kiosk-cec

log()  { logger -t "$LOG_TAG" "$*"; }
warn() { logger -t "$LOG_TAG" -p user.warning "$*"; }

# schedule.env muss vorhanden sein (wird von kiosk-sync erstellt)
if [ ! -f "$SCHEDULE_ENV" ]; then
    warn "schedule.env fehlt — CEC-Check übersprungen"
    exit 0
fi
# shellcheck source=/dev/null
source "$SCHEDULE_ENV"

: "${TV_ON_TIME:?}"
: "${TV_OFF_TIME:?}"
: "${TV_ON_DAYS:?}"
: "${TIMEZONE:?}"

# Aktuelle Zeit und Wochentag in der konfigurierten Zeitzone
NOW_TIME=$(TZ="$TIMEZONE" date +%H:%M)
TODAY_DOW=$(TZ="$TIMEZONE" date +%u)   # 1=Montag, 7=Sonntag

# Prüfen ob heute ein Einschalttag ist
DAY_MATCH=0
for DAY in $TV_ON_DAYS; do
    if [ "$DAY" = "$TODAY_DOW" ]; then
        DAY_MATCH=1
        break
    fi
done

# Ziel-Zustand ermitteln
# HH:MM ist lexikografisch korrekt vergleichbar (date liefert zero-padded)
if [ "$DAY_MATCH" -eq 1 ] \
   && [[ "$NOW_TIME" >= "$TV_ON_TIME" ]] \
   && [[ "$NOW_TIME" <  "$TV_OFF_TIME" ]]; then
    TARGET=on
else
    TARGET=off
fi

# Aktuellen State lesen
CURRENT=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")

if [ "$CURRENT" = "$TARGET" ]; then
    exit 0  # Kein Handlungsbedarf
fi

# CEC-Kommando senden
log "TV-Übergang: $CURRENT → $TARGET (Zeit: $NOW_TIME, Tag: $TODAY_DOW)"

CEC_CMD="on 0"
[ "$TARGET" = "off" ] && CEC_CMD="standby 0"

# cec-client -s = single command, -d 1 = nur Fehler ausgeben
if echo "$CEC_CMD" | cec-client -s -d 1 2>/dev/null; then
    echo "$TARGET" > "$STATE_FILE"
    log "CEC '$CEC_CMD' erfolgreich → State: $TARGET"
else
    warn "CEC-Kommando '$CEC_CMD' fehlgeschlagen (TV antwortet nicht?)"
    # State NICHT aktualisieren, beim nächsten Lauf erneut versuchen
fi
