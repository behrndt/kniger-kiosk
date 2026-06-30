#!/usr/bin/env bash
# Holt die Kiosk-Konfiguration aus Supabase (kiosk_screens) und schreibt
# /run/kiosk/schedule.env — wird von start-browser.sh und cec-tv-check.sh gelesen.
#
# Benötigt: curl, jq
# Konfiguration: /etc/kiosk/kiosk.env

set -euo pipefail

ENV_FILE=/etc/kiosk/kiosk.env
SCHEDULE_ENV=/run/kiosk/schedule.env
LOG_TAG=kiosk-sync

log()  { logger -t "$LOG_TAG" "$*"; }
warn() { logger -t "$LOG_TAG" -p user.warning "$*"; }

if [ ! -f "$ENV_FILE" ]; then
    warn "Keine $ENV_FILE gefunden — abbruch"
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

: "${SCREEN_KEY:?SCREEN_KEY nicht gesetzt in $ENV_FILE}"
: "${SUPABASE_URL:?SUPABASE_URL nicht gesetzt}"
: "${SUPABASE_ANON_KEY:?SUPABASE_ANON_KEY nicht gesetzt}"

# Supabase REST-API: kiosk_screens für diesen SCREEN_KEY abfragen
# RLS: anon read erlaubt (kein Service-Role-Key nötig)
RESPONSE=$(curl -sf \
    --connect-timeout 10 \
    --max-time 20 \
    -H "apikey: ${SUPABASE_ANON_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_ANON_KEY}" \
    "${SUPABASE_URL}/rest/v1/kiosk_screens?screen_key=eq.${SCREEN_KEY}&select=checkin_url,tv_on_time,tv_off_time,tv_on_days,timezone,active") || {
    warn "Supabase-Anfrage fehlgeschlagen — behalte bisherige schedule.env"
    exit 0
}

# Validieren: Antwort-Array muss ein Element enthalten
COUNT=$(echo "$RESPONSE" | jq 'length' 2>/dev/null || echo "0")
if [ "$COUNT" -lt 1 ]; then
    warn "Kein Eintrag für SCREEN_KEY='${SCREEN_KEY}' in kiosk_screens"
    exit 1
fi

ACTIVE=$(echo "$RESPONSE" | jq -r '.[0].active')
if [ "$ACTIVE" != "true" ]; then
    warn "Screen '${SCREEN_KEY}' ist inaktiv (active=false) — keine Änderung"
    exit 0
fi

CHECKIN_URL=$(echo "$RESPONSE" | jq -r '.[0].checkin_url')
TV_ON_TIME=$(echo "$RESPONSE"  | jq -r '.[0].tv_on_time[:5]')   # "07:00:00" → "07:00"
TV_OFF_TIME=$(echo "$RESPONSE" | jq -r '.[0].tv_off_time[:5]')
TIMEZONE=$(echo "$RESPONSE"    | jq -r '.[0].timezone')

# tv_on_days: Postgres int[] → JSON-Array → Space-separated ("1 2 3 4 5 6")
# ISO-Wochentag: 1=Montag, 7=Sonntag (wie date +%u)
TV_ON_DAYS=$(echo "$RESPONSE" | jq -r '.[0].tv_on_days | map(tostring) | join(" ")')

# Token an URL hängen (?token=...) — globaler KIOSK_TOKEN aus kiosk.env
KIOSK_TOKEN="${KIOSK_TOKEN:-}"
if [ -n "$KIOSK_TOKEN" ]; then
    KIOSK_URL="${CHECKIN_URL}?token=${KIOSK_TOKEN}"
else
    KIOSK_URL="$CHECKIN_URL"
    warn "KIOSK_TOKEN nicht gesetzt — Kiosk-URL ohne Token (wird PIN-gegated sein)"
fi

# /run/kiosk/ anlegen (tmpfs, nach Reboot leer)
mkdir -p /run/kiosk

# schedule.env atomar schreiben (kein halb-gelesenes File)
TMP=$(mktemp /run/kiosk/schedule.env.XXXXXX)
cat > "$TMP" <<EOF
# Automatisch generiert von sync-schedule.sh — nicht manuell bearbeiten
KIOSK_URL=${KIOSK_URL}
CHECKIN_URL=${CHECKIN_URL}
TV_ON_TIME=${TV_ON_TIME}
TV_OFF_TIME=${TV_OFF_TIME}
TV_ON_DAYS="${TV_ON_DAYS}"
TIMEZONE=${TIMEZONE}
SCREEN_KEY=${SCREEN_KEY}
UPDATED_AT=$(date -Iseconds)
EOF
mv "$TMP" "$SCHEDULE_ENV"
chmod 644 "$SCHEDULE_ENV"

log "schedule.env aktualisiert: URL=${KIOSK_URL} on=${TV_ON_TIME} off=${TV_OFF_TIME} days=[${TV_ON_DAYS}] tz=${TIMEZONE}"
