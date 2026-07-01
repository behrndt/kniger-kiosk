#!/usr/bin/env bash
# Overlay-FS-Steuerung für den KNIGER-Kiosk.
#
# Kapselt die raspi-config-Overlay-Funktionen mit klaren Exit-Codes und
# sorgt dafür, dass /boot/firmware im Overlay-Modus beschreibbar gemacht
# werden kann (für Marker-Dateien und Config-Änderungen).
#
# Verwendung:
#   overlay-ctl.sh status     → gibt "on" | "off" aus, Exit 0
#   overlay-ctl.sh is-on      → Exit 0 wenn Overlay aktiv, sonst 1
#   overlay-ctl.sh enable      → Overlay aktivieren (wirkt ab nächstem Boot)
#   overlay-ctl.sh disable    → Overlay deaktivieren (wirkt ab nächstem Boot)
#   overlay-ctl.sh boot-rw    → /boot/firmware rw remounten (sofort)
#   overlay-ctl.sh boot-ro    → /boot/firmware ro remounten (sofort)
#
# raspi-config get_overlay_now: 0 = Overlay aktiv, 1 = inaktiv.

set -uo pipefail

LOG_TAG=kiosk-overlay
log()  { logger -t "$LOG_TAG" "$*"; echo "[overlay] $*" >&2; }
warn() { logger -t "$LOG_TAG" -p user.warning "$*"; echo "[overlay] WARN: $*" >&2; }

RASPI_CONFIG=/usr/bin/raspi-config
BOOT_MNT=/boot/firmware

[ -x "$RASPI_CONFIG" ] || { warn "raspi-config nicht gefunden"; exit 2; }

overlay_active() {
    # get_overlay_now: 0 = aktiv → wir liefern Exit 0 wenn aktiv
    [ "$("$RASPI_CONFIG" nonint get_overlay_now 2>/dev/null)" = "0" ]
}

case "${1:-status}" in
    status)
        if overlay_active; then echo "on"; else echo "off"; fi
        ;;
    is-on)
        overlay_active
        ;;
    enable)
        if overlay_active; then
            log "Overlay bereits aktiv"
            exit 0
        fi
        log "Aktiviere Overlay-FS (Read-Only Root, wirkt ab nächstem Boot)…"
        "$RASPI_CONFIG" nonint enable_overlayfs
        ;;
    disable)
        if ! overlay_active; then
            log "Overlay bereits inaktiv"
            exit 0
        fi
        log "Deaktiviere Overlay-FS (wirkt ab nächstem Boot)…"
        "$RASPI_CONFIG" nonint disable_overlayfs
        ;;
    boot-rw)
        mount -o remount,rw "$BOOT_MNT" && log "$BOOT_MNT rw gemountet"
        ;;
    boot-ro)
        sync
        mount -o remount,ro "$BOOT_MNT" && log "$BOOT_MNT ro gemountet"
        ;;
    *)
        warn "Unbekanntes Kommando: ${1:-}"
        echo "Verwendung: $0 {status|is-on|enable|disable|boot-rw|boot-ro}" >&2
        exit 2
        ;;
esac
