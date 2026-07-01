#!/usr/bin/env python3
"""
Netum NS-91 Scanner-Trigger-Daemon — KNIGER Check-in Kiosk.

Aktiviert den externen Trigger-Kontakt des Scanners über GPIO → Optokoppler,
sodass der Scanner nur dann aktiviert ist, wenn der Kiosk einen Scan erwartet.
Im "bewaffneten" Zustand wird alle PULSE_INTERVAL Sekunden neu getriggert, bis
ein Scan erkannt wird oder ARM_TIMEOUT abläuft.

Verkabelung (JZK-1-Kanal-PC817-Modul, 12 V–ausgelegt):
  Pi GPIO17 (Pin 11) → Modul IN
  Pi GND   (Pin 9)  → Modul GND
  Modul-Ausgang (COM/NO) → Trigger-Kontakte des NS-91

  WICHTIG: Kein externer Widerstand — das Modul hat Onboard-Widerstand.
  Das Modul ist auf 12 V ausgelegt; bei 3,3 V Betrieb ist der High-Pegel
  grenzwertig. Fallback: 5V-NPN-Transistor direkt (Basis 330Ω ← GPIO17,
  Kollektor → Trigger+, Emitter → Trigger-/GND).

HTTP-Schnittstelle (localhost:8770):
  GET /arm     → Scanner bewaffnen (Kiosk-Idle-Screen ruft dies auf)
  GET /disarm  → Scanner deaktivieren (Kiosk verlässt Idle-Screen)
  GET /status  → "armed" oder "idle"
  GET /healthz → "ok" (für Monitoring)

Deps:
  sudo apt install python3-gpiozero python3-evdev python3-lgpio  # Pi 4/5
"""
import os
import signal
import sys
import threading
import time
import http.server
import socketserver
import logging

from gpiozero import LED
from evdev import InputDevice, ecodes, list_devices

# ── Konfiguration (überschreibbar per Env-Var) ───────────────────────────────
TRIGGER_PIN    = int(os.environ.get("TRIGGER_PIN", 17))
PULSE_MS       = int(os.environ.get("PULSE_MS", 120))
PULSE_INTERVAL = float(os.environ.get("PULSE_INTERVAL", 3.0))
ARM_TIMEOUT    = float(os.environ.get("ARM_TIMEOUT", 60.0))
COOLDOWN       = float(os.environ.get("COOLDOWN", 1.5))
HTTP_PORT      = int(os.environ.get("SCANNER_HTTP_PORT", 8770))
SCANNER_HINT   = os.environ.get("SCANNER_HINT", "BF SCAN")
ALWAYS_ARM     = os.environ.get("ALWAYS_ARM", "1") not in ("0", "false", "False")

# ── Logging ──────────────────────────────────────────────────────────────────
logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="%(asctime)s [scanner-trigger] %(levelname)s: %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("scanner-trigger")

# ── State ────────────────────────────────────────────────────────────────────
trigger   = LED(TRIGGER_PIN)
armed     = threading.Event()
scan_seen = threading.Event()
_shutdown = threading.Event()

if ALWAYS_ARM:
    armed.set()


def find_scanner() -> InputDevice | None:
    for path in list_devices():
        try:
            dev = InputDevice(path)
            if SCANNER_HINT.lower() in (dev.name or "").lower():
                log.info("Scanner gefunden: %s (%s)", dev.name, path)
                return dev
        except Exception:
            pass
    return None


def reader_loop() -> None:
    """Überwacht den Scanner (read-only) und setzt scan_seen bei Enter."""
    while not _shutdown.is_set():
        dev = find_scanner()
        if not dev:
            log.debug("Kein Scanner gefunden, retry in 2s…")
            time.sleep(2)
            continue
        try:
            for event in dev.read_loop():
                if _shutdown.is_set():
                    return
                if (event.type == ecodes.EV_KEY
                        and event.value == 1
                        and event.code in (ecodes.KEY_ENTER, ecodes.KEY_KPENTER)):
                    log.info("Scan erkannt")
                    scan_seen.set()
        except Exception as exc:
            log.warning("Lesefehler vom Scanner: %s — reconnect in 2s", exc)
            time.sleep(2)


def trigger_loop() -> None:
    """
    Hält Trigger-Kontakt dauerhaft geschlossen solange bewaffnet.
    Der NS-91 im Trigger-Mode benötigt geschlossenen Kontakt für Beam-ON.
    Nach 3s Hardware-Timeout (kein Scan): PULSE_MS öffnen → wieder schließen.
    """
    while not _shutdown.is_set():
        if not armed.is_set():
            trigger.off()
            armed.wait(timeout=1.0)
            continue

        scan_seen.clear()
        arm_start = time.monotonic()
        trigger.on()  # Kontakt schließen: Beam EIN
        log.info("Arm: Scanner-Kontakt geschlossen (arm_timeout=%.0fs)", ARM_TIMEOUT)

        scanned = False
        while armed.is_set() and not _shutdown.is_set():
            if (time.monotonic() - arm_start) >= ARM_TIMEOUT:
                log.info("ARM_TIMEOUT — Scanner deaktiviert")
                trigger.off()
                if not ALWAYS_ARM:
                    armed.clear()
                break

            if scan_seen.wait(timeout=PULSE_INTERVAL):
                log.info("Scan erkannt — Kontakt öffnen, Cooldown %.1fs", COOLDOWN)
                trigger.off()
                scanned = True
                break
            else:
                # 3s Hardware-Timeout: Scanner hat sich abgeschaltet
                # Kurz öffnen (Reset), sofort wieder schließen (neues Scan-Fenster)
                log.info("Scanner-Timeout — Reset (%.0fms öffnen)", PULSE_MS)
                trigger.off()
                time.sleep(PULSE_MS / 1000.0)
                trigger.on()

        if ALWAYS_ARM and not _shutdown.is_set():
            time.sleep(COOLDOWN)
            if scanned:
                scan_seen.clear()


class Handler(http.server.BaseHTTPRequestHandler):
    def _respond(self, body: bytes, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        path = self.path.split("?")[0]
        if path == "/arm":
            armed.set()
            log.info("HTTP /arm — bewaffnet")
            return self._respond(b"armed")
        if path == "/disarm":
            armed.clear()
            log.info("HTTP /disarm — deaktiviert")
            return self._respond(b"disarmed")
        if path == "/status":
            return self._respond(b"armed" if armed.is_set() else b"idle")
        if path == "/healthz":
            return self._respond(b"ok")
        self._respond(b"not found", 404)

    def log_message(self, fmt, *args) -> None:  # noqa: N802
        log.debug("HTTP %s", fmt % args)


def http_loop() -> None:
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("127.0.0.1", HTTP_PORT), Handler) as srv:
        log.info("HTTP-Server auf 127.0.0.1:%d", HTTP_PORT)
        srv.serve_forever()


def handle_shutdown(sig, _frame):
    log.info("Signal %s empfangen — fahre herunter", signal.Signals(sig).name)
    _shutdown.set()
    trigger.off()
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, handle_shutdown)
    signal.signal(signal.SIGINT, handle_shutdown)
    log.info(
        "Start: pin=%d, pulse=%dms, interval=%.1fs, timeout=%.0fs, always_arm=%s",
        TRIGGER_PIN, PULSE_MS, PULSE_INTERVAL, ARM_TIMEOUT, ALWAYS_ARM,
    )
    threading.Thread(target=reader_loop, daemon=True).start()
    threading.Thread(target=trigger_loop, daemon=True).start()
    http_loop()
