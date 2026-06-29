# KNIGER Kiosk — Raspberry Pi Self-Checkin

Unbeaufsichtigter Kiosk für den KNIGER-Gym-Eingang. Der Pi startet automatisch, zeigt die Check-in-Seite im Vollbild-Chromium, steuert den TV via HDMI-CEC und lädt den Barcode-Scanner per GPIO-Optokoppler.

---

## Hardware

| Komponente | Modell / Hinweis |
|---|---|
| Raspberry Pi | Pi 4 (4 GB) |
| Boot-Medium | USB-SSD (kein microSD für Dauerbetrieb!) |
| Display | TV via HDMI — CEC muss im TV-Menü aktiviert sein (Anynet+/Bravia Sync/SimpLink/etc.) |
| Scanner | Netum NS-91 (USB-HID, Tastatur-Emulation) |
| Trigger-Modul | JZK-1-Kanal-PC817-Optokoppler-Modul |

### Scanner-Verkabelung (GPIO → Optokoppler → NS-91)

```
Pi GPIO17 (Pin 11) ─────► Modul IN
Pi GND   (Pin 9)  ─────► Modul GND
Modul COM ──────────────► NS-91 Trigger-Kontakt 1
Modul NO  ──────────────► NS-91 Trigger-Kontakt 2
```

**Kein externer Widerstand** — das JZK-Modul hat einen Onboard-Widerstand.

Das Modul ist für 12 V ausgelegt; bei 3,3 V (Pi-GPIO-High) ist der Pegel grenzwertig.
Falls der Scanner nicht triggert: NPN-Transistor-Fallback (BC547):
- Basis über 330 Ω → GPIO17
- Kollektor → Trigger+
- Emitter → Trigger− / GND

NS-91 Trigger-Kontakte: potentialfreier Momentkontakt — mit Multimeter auf Durchgang im manuellen Scan prüfen, bevor der Optokoppler angeschlossen wird.

Alternativ Pulse-Eight USB-CEC-Adapter, falls TV-CEC über HDMI nicht funktioniert.

---

## Schritt 1 — Image flashen

1. **Raspberry Pi Imager** herunterladen: <https://www.raspberrypi.com/software/>
2. OS: **Raspberry Pi OS (64-bit)** — die Desktop-Variante (empfohlen)
3. USB-SSD auswählen
4. Zahnrad-Icon → **Erweiterte Optionen**:
   - Hostname: `kniger-kiosk`
   - SSH aktivieren
   - WLAN konfigurieren (SSID + Passwort)
   - Benutzername: `pi`, Passwort setzen
5. Schreiben → SSD an Pi anschließen → booten

---

## Schritt 2 — Erstkonfiguration via SSH

```bash
ssh pi@kniger-kiosk.local     # oder IP-Adresse
```

Raspi-Config öffnen:

```bash
sudo raspi-config
```

Empfohlene Einstellungen:
- **System → Boot / Auto Login**: `Desktop Autologin` (als pi)
- **Localisation → Timezone**: `Europe/Berlin`
- **Advanced → GL Driver**: `G2 — GL (Fake KMS)` (für Chromium-Kiosk)

---

## Schritt 2b — USB-SSD: UAS-Quirk vorab setzen (Intenso 3823430)

Die Intenso Premium 3823430 nutzt einen JMicron-JMS579-Controller (`VID_152D:PID_0579`) mit UAS-Modus, der beim Pi 4 zum Hängenbleiben in der initramfs-Shell führt. **Vor dem ersten Boot** in `cmdline.txt` auf der `bootfs`-Partition eintragen (alles in einer Zeile, kein Enter!):

```
 usb-storage.quirks=152d:0579:u
```

`install.sh` macht das automatisch, falls die SSD bereits eingebaut ist. Beim allerersten Boot muss es jedoch manuell gesetzt sein, da der Installer erst danach läuft.

**Andere SSD-Modelle:** VID:PID per PowerShell (Windows) ermitteln:
```powershell
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'USB\\VID' } | Select-Object FriendlyName, InstanceId
```
Zeile `Per USB angeschlossenes SCSI (UAS)-Massenspeichergerät` → `VID_XXXX&PID_YYYY` → `usb-storage.quirks=xxxx:yyyy:u`

---

## Schritt 3 — Installer ausführen

```bash
# Repo klonen
git clone https://github.com/behrndt/kniger-kiosk.git /tmp/kniger-kiosk

# Installer starten
sudo bash /tmp/kniger-kiosk/install.sh
```

Der Installer ist **idempotent** — mehrfaches Ausführen ist sicher.

### Was install.sh tut

1. Pakete installieren (`chromium-browser`, `cec-utils`, `python3-gpiozero`, `python3-evdev`, `jq`, `unclutter`, …)
2. `pi`-User zu den Gruppen `gpio`, `input`, `video` hinzufügen
3. Repo nach `/opt/kiosk` klonen
4. `/etc/kiosk/kiosk.env` aus `kiosk.env.example` anlegen (falls nicht vorhanden)
5. Systemd-Units installieren und aktivieren:
   - `scanner-trigger.service` (startet sofort)
   - `kiosk-sync.timer` (alle 5 Minuten)
   - `kiosk-update.timer` (stündlich)
   - `kiosk-cec-check.timer` (jede Minute)
6. LXDE-Autostart für Chromium-Kiosk konfigurieren
7. LightDM-Autologin aktivieren

---

## Schritt 4 — Secrets konfigurieren

```bash
sudo nano /etc/kiosk/kiosk.env
```

Auszufüllende Felder:

```bash
SCREEN_KEY=kniger-main            # muss kiosk_screens.screen_key in Supabase entsprechen
SUPABASE_ANON_KEY=eyJ...          # Supabase-Projekt knigercoapp → Settings → API → anon key
KIOSK_TOKEN=<token>               # Auf der cc-vm: cat ~/.kniger/kiosk-token
```

> **Niemals** den `service_role`-Key oder andere Admin-Credentials auf den Pi legen.
> Der `KIOSK_TOKEN` entspricht `CHECKIN_KIOSK_TOKEN` in der Vercel-Env von kniger-web.
> Für Prod muss `CHECKIN_KIOSK_TOKEN` zusätzlich in der Vercel-Prod-Umgebung gesetzt werden.

---

## Schritt 5 — Neustart

```bash
sudo reboot
```

Der Pi startet nun vollständig unbeaufsichtigt:
1. LightDM loggt `pi` automatisch ein
2. LXDE startet `start-browser.sh`
3. `start-browser.sh` ruft `sync-schedule.sh` auf (URL aus Supabase holen)
4. Chromium öffnet `<checkin_url>?token=<KIOSK_TOKEN>` im Kiosk-Modus
5. `scanner-trigger` wartet auf GPIO-Trigger-Anfragen vom Browser
6. `kiosk-cec-check.timer` steuert TV nach Zeitplan

---

## Architektur

```
/etc/kiosk/kiosk.env          # Secrets (SCREEN_KEY, SUPABASE_ANON_KEY, KIOSK_TOKEN)
/opt/kiosk/                   # Git-Repo (Remote-Updates via kiosk-update.timer)
  ├── scripts/
  │   ├── start-browser.sh    # Watchdog-Loop für Chromium
  │   ├── sync-schedule.sh    # Supabase → /run/kiosk/schedule.env
  │   ├── cec-tv-check.sh     # HDMI-CEC TV ein/aus
  │   └── kiosk-update.sh     # git pull + Service-Restart
  ├── scanner-trigger.py      # GPIO-Daemon + HTTP /arm /disarm
  └── systemd/                # Service- und Timer-Definitionen

/run/kiosk/schedule.env       # Laufzeit-Config (von sync-schedule.sh; nach Reboot leer)
/run/kiosk/tv-state           # Laufzeit-TV-State ("on" / "off")
```

### Datenfluss

```
Supabase kiosk_screens
  └─► sync-schedule.sh ──► /run/kiosk/schedule.env
                                 ├─► start-browser.sh ──► Chromium (checkin_url?token=...)
                                 └─► cec-tv-check.sh  ──► HDMI-CEC → TV

Browser (JS auf checkin_url)
  └─► GET http://127.0.0.1:8770/arm   ──► scanner-trigger.py
  └─► GET http://127.0.0.1:8770/disarm       └─► GPIO17 → Optokoppler → NS-91 Trigger
```

---

## TV-Steuerung (HDMI-CEC)

Die CEC-Befehle basieren auf `tv_on_time`, `tv_off_time` und `tv_on_days` aus der Supabase-Tabelle `kiosk_screens`.

| Feld | Typ | Beispiel |
|---|---|---|
| `tv_on_time` | `time` | `07:00` |
| `tv_off_time` | `time` | `22:00` |
| `tv_on_days` | `int[]` | `{1,2,3,4,5,6}` (Mo–Sa; ISO: 1=Mo, 7=So) |
| `timezone` | `text` | `Europe/Berlin` |

Der CEC-Check läuft jede Minute. State-Changes werden geloggt (`journalctl -u kiosk-cec`).

**TV-CEC aktivieren:** Je nach Hersteller:
- Samsung: `Menü → System → Anynet+ (HDMI-CEC) → Ein`
- Sony: `Einstellungen → Externe Geräteeinstellungen → Bravia Sync`
- LG: `Einstellungen → Ton → Ton → SimpLink → Ein`

Manueller Test:
```bash
echo "on 0"      | sudo cec-client -s -d 1   # TV einschalten
echo "standby 0" | sudo cec-client -s -d 1   # TV auf Standby
```

---

## Remote-Update-Mechanismus

Skripte zentral ändern → Pi zieht automatisch nach:

1. Änderung ins Repo committen und nach `main` pushen
2. `kiosk-update.timer` (stündlich) ruft `kiosk-update.sh` auf
3. Das Skript:
   - Prüft `git diff HEAD origin/main`
   - Wenn Änderungen: `git pull --ff-only`
   - Startet betroffene Services neu (gezielt nach geänderten Dateien)
   - Bei fehlgeschlagenem Pull: kein Service-Crash, einfach beim nächsten Stündchen nochmal

Manuell triggern:
```bash
sudo systemctl start kiosk-update.service
journalctl -u kiosk-update -f
```

---

## Troubleshooting

### Logs ansehen

```bash
journalctl -u scanner-trigger -f     # Scanner-Daemon
journalctl -u kiosk-sync -f          # Schedule-Sync
journalctl -u kiosk-update -f        # Remote-Update
journalctl -u kiosk-cec-check -f     # TV-Steuerung
```

### Chromium startet nicht / zeigt alten Stand

```bash
# schedule.env ansehen
cat /run/kiosk/schedule.env

# Sync manuell anstoßen
sudo -u pi /opt/kiosk/scripts/sync-schedule.sh

# Chromium killen (Watchdog startet ihn neu)
pkill -f chromium-browser
```

### Scanner wird nicht erkannt

```bash
# evdev-Geräte anzeigen
python3 -c "from evdev import list_devices, InputDevice; [print(d, InputDevice(d).name) for d in list_devices()]"

# SCANNER_HINT in kiosk.env anpassen, falls der Geräte-Name abweicht
# Standardwert: "Netum"
```

### TV reagiert nicht auf CEC

```bash
# Manueller Test
echo "on 0" | sudo cec-client -s -d 3

# Aktuellen State zurücksetzen (erzwingt beim nächsten Timer-Lauf einen CEC-Befehl)
sudo rm /run/kiosk/tv-state
```

### Update-Mechanismus manuell testen

```bash
sudo systemctl start kiosk-update.service
journalctl -u kiosk-update --since "1 minute ago"
```

---

## Supabase — `kiosk_screens`-Tabelle

```sql
-- Beispiel-Row ansehen
SELECT * FROM kiosk_screens WHERE screen_key = 'kniger-main';

-- TV-Zeiten ändern (wird beim nächsten sync-schedule.sh-Lauf aktiv)
UPDATE kiosk_screens
SET tv_on_time = '08:00', tv_off_time = '21:30'
WHERE screen_key = 'kniger-main';
```

RLS: `anon` hat Lesezugriff. Der Pi verwendet ausschließlich den Anon-Key.
