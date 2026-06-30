#!/usr/bin/env bash
# KNIGER Kiosk Installer — idempotent
# Ausführen als root auf einem frischen Raspberry Pi OS Desktop (Bookworm).
#
# Verwendung:
#   sudo bash install.sh
#
# Nach der Installation:
#   sudo nano /etc/kiosk/kiosk.env   # Secrets eintragen
#   sudo reboot

set -euo pipefail

KIOSK_USER=${KIOSK_USER:-pi}
KIOSK_DIR=/opt/kiosk
KIOSK_ENV=/etc/kiosk/kiosk.env
REPO_URL=https://github.com/behrndt/kniger-kiosk.git
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[install]${NC} $*"; }
warn()    { echo -e "${YELLOW}[install]${NC} $*"; }
error()   { echo -e "${RED}[install]${NC} $*" >&2; exit 1; }

# ── Root-Check ────────────────────────────────────────────────────────────────
[ "$EUID" -eq 0 ] || error "Bitte als root ausführen: sudo bash $0"

# ── User prüfen ───────────────────────────────────────────────────────────────
if ! id "$KIOSK_USER" &>/dev/null; then
    error "Benutzer '$KIOSK_USER' existiert nicht. Anderen User mit KIOSK_USER=... setzen."
fi
KIOSK_HOME=$(getent passwd "$KIOSK_USER" | cut -d: -f6)

info "Kiosk-User: $KIOSK_USER (Home: $KIOSK_HOME)"

# ── Pakete installieren ───────────────────────────────────────────────────────
info "Paket-Update und Installation…"
apt-get update -qq
apt-get install -y --no-install-recommends \
    chromium \
    cec-utils \
    python3-gpiozero \
    python3-evdev \
    python3-lgpio \
    curl \
    jq \
    git \
    unclutter \
    xdotool \
    2>/dev/null

# Pi 5: libgpiod (gpiozero braucht lgpio oder libgpiod)
# python3-lgpio bereits oben — deckt Pi 4 + 5 ab.

# ── Gruppen-Mitgliedschaft ────────────────────────────────────────────────────
info "Gruppen-Zuweisung für $KIOSK_USER…"
usermod -aG gpio,input,video "$KIOSK_USER" 2>/dev/null || warn "Gruppen-Zuweisung teilweise fehlgeschlagen (evtl. nicht alle Gruppen vorhanden)"

# ── /etc/kiosk einrichten ─────────────────────────────────────────────────────
info "Kiosk-Konfigurationsverzeichnis /etc/kiosk anlegen…"
mkdir -p /etc/kiosk
chown root:"$KIOSK_USER" /etc/kiosk
chmod 750 /etc/kiosk

if [ ! -f "$KIOSK_ENV" ]; then
    info "kiosk.env.example → $KIOSK_ENV kopieren (bitte ausfüllen!)"
    if [ -f "$SCRIPT_DIR/kiosk.env.example" ]; then
        cp "$SCRIPT_DIR/kiosk.env.example" "$KIOSK_ENV"
    else
        cp "$KIOSK_DIR/kiosk.env.example" "$KIOSK_ENV" 2>/dev/null \
            || warn "kiosk.env.example nicht gefunden — bitte manuell anlegen"
    fi
    chmod 640 "$KIOSK_ENV"
    chown root:"$KIOSK_USER" "$KIOSK_ENV"
    warn "WICHTIG: Trage die Secrets in $KIOSK_ENV ein, bevor du neu startest!"
else
    info "$KIOSK_ENV existiert bereits — wird nicht überschrieben"
fi

# ── /run/kiosk (tmpfs, bei Reboot leer) — via tmpfiles.d persistent anlegen ──
echo "d /run/kiosk 0755 ${KIOSK_USER} ${KIOSK_USER} -" > /etc/tmpfiles.d/kiosk.conf
systemd-tmpfiles --create /etc/tmpfiles.d/kiosk.conf

# ── Kiosk-Repo nach /opt/kiosk klonen oder aktualisieren ─────────────────────
info "Git-Repo in $KIOSK_DIR installieren…"
if [ -d "$KIOSK_DIR/.git" ]; then
    info "$KIOSK_DIR existiert bereits — update…"
    cd "$KIOSK_DIR"
    git pull --ff-only origin main 2>&1 || warn "git pull fehlgeschlagen — aktuelle Version behalten"
else
    # Installer läuft evtl. direkt aus dem geklonten Repo (Bootstrap-Fall)
    if [ -f "$SCRIPT_DIR/install.sh" ] && [ -d "$SCRIPT_DIR/.git" ]; then
        info "Installiere aus lokalem Repo ($SCRIPT_DIR) nach $KIOSK_DIR"
        cp -r "$SCRIPT_DIR" "$KIOSK_DIR"
    else
        info "Klone $REPO_URL nach $KIOSK_DIR"
        git clone "$REPO_URL" "$KIOSK_DIR"
    fi
fi
chown -R root:"$KIOSK_USER" "$KIOSK_DIR"
chmod -R g+rX "$KIOSK_DIR"

# ── Skripte ausführbar machen ─────────────────────────────────────────────────
chmod +x "$KIOSK_DIR/scripts/"*.sh
chmod +x "$KIOSK_DIR/scanner-trigger.py"
chmod +x "$KIOSK_DIR/install.sh"

# ── USB-SSD UAS-Quirk in cmdline.txt setzen ──────────────────────────────────
# Intenso Premium 3823430 (JMicron JMS579, VID_152D:PID_0579) hat UAS-Probleme
# mit dem Pi 4 — ohne diesen Eintrag bleibt der Pi in der initramfs-Shell hängen.
CMDLINE=/boot/firmware/cmdline.txt
UAS_QUIRK="usb-storage.quirks=152d:0579:u"
if [ -f "$CMDLINE" ]; then
    if grep -q "$UAS_QUIRK" "$CMDLINE"; then
        info "UAS-Quirk bereits in $CMDLINE vorhanden"
    else
        info "UAS-Quirk in $CMDLINE eintragen…"
        sed -i "s|$| $UAS_QUIRK|" "$CMDLINE"
    fi
else
    warn "$CMDLINE nicht gefunden — UAS-Quirk bitte manuell eintragen"
fi

# ── Systemd-Units installieren ────────────────────────────────────────────────
info "Systemd-Units installieren…"
cp "$KIOSK_DIR/systemd/"*.service /etc/systemd/system/
cp "$KIOSK_DIR/systemd/"*.timer /etc/systemd/system/

# Units für den korrekten Kiosk-User anpassen (falls nicht pi)
if [ "$KIOSK_USER" != "pi" ]; then
    warn "Kiosk-User ist nicht 'pi' — passe Units an…"
    sed -i "s/^User=pi$/User=$KIOSK_USER/" /etc/systemd/system/scanner-trigger.service
    sed -i "s/^User=pi$/User=$KIOSK_USER/" /etc/systemd/system/kiosk-sync.service
    sed -i "s/^User=pi$/User=$KIOSK_USER/" /etc/systemd/system/kiosk-cec-check.service
fi

systemctl daemon-reload

# ── Services aktivieren und starten ──────────────────────────────────────────
info "Services aktivieren…"

# Scanner-Trigger direkt starten (kein Netz nötig)
systemctl enable --now scanner-trigger.service

# Schedule-Sync + Update + CEC als Timer
systemctl enable --now kiosk-sync.timer
systemctl enable --now kiosk-update.timer
systemctl enable --now kiosk-cec-check.timer

# ── LXDE-Autostart für Chromium-Kiosk ────────────────────────────────────────
# Ersetzt den Standard-Autostart (kein lxpanel, kein pcmanfm, kein Screensaver)
# für einen reinen Kiosk-Betrieb.
AUTOSTART_DIR="$KIOSK_HOME/.config/lxsession/LXDE-pi"
AUTOSTART_FILE="$AUTOSTART_DIR/autostart"

if command -v lxsession &>/dev/null || [ -d "/etc/xdg/lxsession/LXDE-pi" ]; then
    info "LXDE-Autostart konfigurieren…"
    mkdir -p "$AUTOSTART_DIR"

    cat > "$AUTOSTART_FILE" <<'AUTOSTART'
# KNIGER Kiosk — LXDE Autostart
# Kein lxpanel, kein pcmanfm: reiner Kiosk-Modus

# Bildschirmschoner + DPMS deaktivieren
@xset s noblank
@xset s off
@xset -dpms

# Kiosk-Browser mit Watchdog starten
@/opt/kiosk/scripts/start-browser.sh
AUTOSTART

    chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/.config"
    info "LXDE-Autostart geschrieben: $AUTOSTART_FILE"
else
    warn "LXDE nicht gefunden — Chromium-Autostart muss manuell eingerichtet werden."
    warn "Für Pi OS Lite: 'startx' nach Login konfigurieren + ~/.xinitrc → start-browser.sh"
fi

# ── Autologin aktivieren ──────────────────────────────────────────────────────
# Pi OS Desktop: LightDM-Autologin für $KIOSK_USER aktivieren
LIGHTDM_AUTOLOGIN=/etc/lightdm/lightdm.conf
if [ -f "$LIGHTDM_AUTOLOGIN" ]; then
    if grep -q "^#autologin-user=" "$LIGHTDM_AUTOLOGIN" 2>/dev/null \
       || ! grep -q "^autologin-user=" "$LIGHTDM_AUTOLOGIN" 2>/dev/null; then
        info "LightDM-Autologin für $KIOSK_USER aktivieren…"
        # Idempotent: Zeile ersetzen oder hinzufügen
        if grep -q "autologin-user" "$LIGHTDM_AUTOLOGIN"; then
            sed -i "s/^#*autologin-user=.*/autologin-user=$KIOSK_USER/" "$LIGHTDM_AUTOLOGIN"
        else
            sed -i '/^\[Seat:\*\]/a autologin-user='"$KIOSK_USER" "$LIGHTDM_AUTOLOGIN"
        fi
        info "Autologin aktiviert"
    else
        info "Autologin bereits konfiguriert"
    fi
else
    warn "LightDM-Konfiguration nicht gefunden — Autologin manuell einrichten"
fi

# ── Abschluss ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   KNIGER Kiosk Installation abgeschlossen!          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Nächste Schritte:"
echo -e "  1. ${YELLOW}sudo nano $KIOSK_ENV${NC}"
echo -e "     → SUPABASE_ANON_KEY, KIOSK_TOKEN, SCREEN_KEY eintragen"
echo -e "     → KIOSK_TOKEN-Wert: cat ~/.kniger/kiosk-token (auf der cc-vm)"
echo -e ""
echo -e "  2. ${YELLOW}sudo reboot${NC}"
echo -e ""
echo -e "  Logs prüfen nach Reboot:"
echo -e "    journalctl -u scanner-trigger -f"
echo -e "    journalctl -u kiosk-sync -f"
echo -e "    journalctl -u kiosk-update -f"
echo ""
