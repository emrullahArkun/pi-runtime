#!/usr/bin/env python3
"""Wi-Fi setup over the TV.

At boot the kiosk can be without network: first start at a mosque, a changed Wi-Fi
password, a new router. Then the Pi opens its own access point, the TV shows a QR code
to join it and a phone picks the mosque's Wi-Fi on a captive page. kiosk.sh reads the
state file to decide whether the TV shows tv.html or the kiosk.
"""

import hashlib
import json
import os
import secrets
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

IFACE = os.environ.get("WIFI_IFACE", "wlan0")
RUN_DIR = Path(os.environ.get("RUN_DIR", "/run/big-wifi-setup"))
STATE_DIR = Path(os.environ.get("STATE_DIR", "/var/lib/big-wifi-setup"))
# Written by provision-pi.sh: the Wi-Fi given for the first start at home.
HOME_WIFI_FILE = Path(os.environ.get("HOME_WIFI_FILE", "/boot/firmware/fleet-setup-wifi"))
WEB_DIR = Path(__file__).resolve().with_name("web")
PORT = int(os.environ.get("PORT", "80"))

AP_CON = "big-setup"
AP_ADDR = "10.42.0.1"
# Every name in the setup Wi-Fi resolves here (dnsmasq, see setup.sh). Samsung phones skip
# the sign-in page when the check hosts resolve to a private address, so it is one from
# the benchmarking range (RFC 2544, never routed), added to wlan0 next to AP_ADDR.
PROBE_ADDR = "198.18.0.1"
# Left to NetworkManager the channel follows the SSID. A local disturbance on one channel
# (seen on 1: phones dropped right after the handshake) then hit some names only, so the
# channel is fixed and every start takes the next one: switching the Pi off and on is a
# real way out. 12 and 13 are left out, they are not allowed in every country.
AP_CHANNELS = ("6", "11", "1")
AP_PREFIX = "BIG-Setup"
NEW_CON = "big-wifi-new"
LOCAL_HOSTS = {AP_ADDR, "127.0.0.1", "localhost"}
STATIC = {"tv.html", "base.css", "noto-sans.woff2", "noto-sans-tr.woff2", "big-mark.png"}
TYPES = {".html": "text/html; charset=utf-8", ".css": "text/css", ".svg": "image/svg+xml",
         ".woff2": "font/woff2", ".png": "image/png"}

LAN_GRACE_S = 15
HOME_WIFI_GRACE_S = 45
SAVED_WAIT_S = 600
SAVED_TRY_AFTER_S = 60
# A saved Wi-Fi that is not even visible is elsewhere (set up at home), not a router still
# booting after a power cut: those are back within a few minutes.
MISSING_WAIT_S = 180
SCAN_EVERY_S = 30
RETRY_SAVED_S = 300
PAGE_FALLBACK_S = 15
CONNECTED_HOLD_S = 5
# After the decision the page server stays up this long: the kiosk may restart right then
# (enrollment) and must not find port 80 closed.
LINGER_S = 60
AP_CHECK_S = 10
PASSWORD_CHARS = "abcdefghjkmnpqrstuvwxyz23456789"


def split_terse(line):
    """Splits one line of `nmcli -t` output; values escape ':' and '\\' with a backslash."""
    fields, current, escaped = [], [], False
    for ch in line:
        if escaped:
            current.append(ch)
            escaped = False
        elif ch == "\\":
            escaped = True
        elif ch == ":":
            fields.append("".join(current))
            current = []
        else:
            current.append(ch)
    fields.append("".join(current))
    return fields


def unescape(value):
    return "".join(split_terse(value)) if "\\" in value else value


def log(message):
    print(message, file=sys.stderr, flush=True)


def parse_scan(text):
    """Networks a phone can pick: strongest entry per name, own AP and 802.1X left out."""
    best = {}
    for line in text.splitlines():
        if not line:
            continue
        ssid, signal, security = (split_terse(line) + ["", "", ""])[:3]
        security = "" if security.strip() == "--" else security.strip()
        if not ssid or ssid.startswith(AP_PREFIX) or "802.1X" in security or "WEP" in security:
            continue
        strength = int(signal) if signal.isdigit() else 0
        if ssid not in best or strength > best[ssid]["strength"]:
            best[ssid] = {"ssid": ssid, "strength": strength, "security": security}
    return sorted(best.values(), key=lambda n: -n["strength"])


def signal_level(strength):
    return 3 if strength >= 67 else 2 if strength >= 34 else 1


def key_mgmt(security):
    if not security:
        return None
    if "WPA3" in security and "WPA2" not in security and "WPA1" not in security:
        return "sae"
    return "wpa-psk"


def setup_ssid(password):
    """Phones keep a joined network's password by name; a new password needs a new name."""
    return f"{AP_PREFIX}-{hashlib.sha256(password.encode()).hexdigest()[:4].upper()}"


def wifi_qr_payload(ssid, password):
    def esc(value):
        return "".join("\\" + ch if ch in '\\;,:"' else ch for ch in value)
    return f"WIFI:T:WPA;S:{esc(ssid)};P:{esc(password)};;"


def new_password(length=10):
    return "".join(secrets.choice(PASSWORD_CHARS) for _ in range(length))


def setup_password():
    """A new password, and so a new name, on every start: a phone that once failed to join
    ignores that name for good, so switching the Pi off and on gets it a fresh network.
    Kept in the state directory for troubleshooting."""
    password = new_password()
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    path = STATE_DIR / "ap-password"
    path.write_text(password + "\n")
    path.chmod(0o600)
    return password


def setup_channel():
    path = STATE_DIR / "ap-channel"
    try:
        last = path.read_text().strip()
    except OSError:
        last = ""
    channel = AP_CHANNELS[0]
    if last in AP_CHANNELS:
        channel = AP_CHANNELS[(AP_CHANNELS.index(last) + 1) % len(AP_CHANNELS)]
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    path.write_text(channel + "\n")
    return channel


def run(args, timeout=60):
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
        return done.returncode == 0, (done.stdout + done.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as err:
        return False, str(err)


class Network:
    """NetworkManager and friends. Tests replace this with a fake."""

    def unblock(self):
        run(["rfkill", "unblock", "wifi"])
        run(["nmcli", "radio", "wifi", "on"])

    def ready(self):
        ok, out = run(["nmcli", "-t", "-f", "RUNNING", "general"])
        return ok and out.strip() == "running"

    def _devices(self):
        _, out = run(["nmcli", "-t", "-f", "TYPE,STATE,CONNECTION", "device"])
        return [split_terse(line) for line in out.splitlines() if line]

    def ethernet_up(self):
        return any(d[0] == "ethernet" and d[1] == "connected" for d in self._devices())

    def wifi_up(self):
        return any(d[0] == "wifi" and d[1] == "connected" and d[2] != AP_CON for d in self._devices())

    def saved_wifi(self):
        _, out = run(["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"])
        saved = []
        for line in out.splitlines():
            name, kind = (split_terse(line) + ["", ""])[:2]
            if kind != "802-11-wireless" or name in (AP_CON, NEW_CON):
                continue
            ok, values = run(["nmcli", "-g", "802-11-wireless.ssid,802-11-wireless.mode", "connection", "show", "id", name])
            ssid, mode = (values.splitlines() + ["", ""])[:2]
            ssid = unescape(ssid)
            if ok and ssid and mode != "ap":
                saved.append((name, ssid))
        return saved

    def scan(self):
        _, out = run(["nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "yes", "ifname", IFACE])
        return parse_scan(out)

    def activate(self, name, wait=40):
        ok, out = run(["nmcli", "--wait", str(wait), "connection", "up", "id", name], timeout=wait + 15)
        return ok, "password" if "Secrets were required" in out else "other"

    def join(self, ssid, password, mgmt):
        """Adds the network next to the saved ones; old profiles of that name go on success."""
        run(["nmcli", "connection", "delete", "id", NEW_CON])
        args = ["nmcli", "connection", "add", "type", "wifi", "ifname", IFACE, "con-name", NEW_CON, "ssid", ssid,
                "connection.autoconnect-priority", "10"]
        if mgmt:
            args += ["wifi-sec.key-mgmt", mgmt, "wifi-sec.psk", password, "wifi-sec.pmf", "3" if mgmt == "sae" else "2"]
        ok, out = run(args)
        if not ok:
            log(f"could not add the network: {out}")
            return False, "other"
        ok, reason = self.activate(NEW_CON, wait=45)
        if not ok:
            run(["nmcli", "connection", "delete", "id", NEW_CON])
            return False, reason
        for name, saved_ssid in self.saved_wifi():
            if saved_ssid == ssid:
                run(["nmcli", "connection", "delete", "id", name])
        run(["nmcli", "connection", "modify", "id", NEW_CON, "connection.id", ssid])
        return True, ""

    def start_ap(self, ssid, password, channel):
        run(["nmcli", "connection", "delete", "id", AP_CON])
        ok, out = run(["nmcli", "--wait", "20", "device", "wifi", "hotspot", "ifname", IFACE,
                       "con-name", AP_CON, "ssid", ssid, "band", "bg", "channel", channel,
                       "password", password], timeout=35)
        if not ok:
            log(f"hotspot failed: {out}")
        run(["nmcli", "connection", "modify", "id", AP_CON, "connection.autoconnect", "no"])
        if ok:
            run(["ip", "address", "replace", f"{PROBE_ADDR}/32", "dev", IFACE])
        return ok

    def stop_ap(self):
        run(["ip", "address", "del", f"{PROBE_ADDR}/32", "dev", IFACE])
        run(["nmcli", "connection", "down", "id", AP_CON])

    def ap_up(self):
        _, out = run(["nmcli", "-t", "-f", "NAME", "connection", "show", "--active"])
        return AP_CON in [unescape(line) for line in out.splitlines()]

    def forget(self, ssids):
        for name, ssid in self.saved_wifi():
            if ssid in ssids:
                run(["nmcli", "connection", "delete", "id", name])

    def remove_ap(self):
        run(["ip", "address", "del", f"{PROBE_ADDR}/32", "dev", IFACE])
        run(["nmcli", "connection", "delete", "id", AP_CON])

    def stations(self):
        _, out = run(["iw", "dev", IFACE, "station", "dump"])
        return sum(1 for line in out.splitlines() if line.startswith("Station"))


class Setup:
    """The setup session: what the TV shows and what the phone asked for."""

    def __init__(self, net, notice=None, saved=(), home_wifi=(), clock=time.monotonic, sleep=time.sleep):
        self.net = net
        self.home_wifi = set(home_wifi)
        self.clock = clock
        self.sleep = sleep
        self.lock = threading.Lock()
        self.step = "wifi"
        self.notice = notice
        self.saved = list(saved)
        self.networks = []
        self.pending = None
        self.page_seen = False
        self.phone_since = None
        self.last_retry = clock()
        self.last_ap_check = clock()
        self.ap = None
        self.done = False

    def start(self, ssid, password, channel):
        self.ap = (ssid, password, channel)
        self.networks = self.net.scan()
        self._open_ap()

    def _open_ap(self):
        if not self.net.start_ap(*self.ap):
            log(f"could not open the setup Wi-Fi {self.ap[0]}")

    def public_state(self):
        with self.lock:
            waited = self.phone_since is not None and self.clock() - self.phone_since >= PAGE_FALLBACK_S
            return {"step": self.step, "notice": self.notice,
                    "pageFallback": self.step == "phone" and not self.page_seen and waited}

    def public_networks(self):
        with self.lock:
            return [{"ssid": n["ssid"], "signal": signal_level(n["strength"]), "secure": bool(n["security"])}
                    for n in self.networks]

    def mark_page_seen(self):
        with self.lock:
            self.page_seen = True

    def request_connect(self, ssid, password):
        with self.lock:
            network = next((n for n in self.networks if n["ssid"] == ssid), None)
            if network is None:
                return "unknown network"
            if network["security"] and not 8 <= len(password) <= 63:
                return "password length"
            if self.step not in ("wifi", "phone") or self.pending:
                return "busy"
            self.pending = (network, "" if not network["security"] else password)
            return None

    def _set(self, step, notice=None):
        with self.lock:
            self.step = step
            self.notice = notice
            if step != "phone":
                self.phone_since = None

    def tick(self):
        if self.net.ethernet_up():
            self._finish()
            return
        if self.pending:
            self._connect(*self.pending)
            return
        stations = self.net.stations()
        with self.lock:
            if self.step == "wifi" and stations:
                log(f"phone joined the setup Wi-Fi ({stations})")
                self.step = "phone"
                self.phone_since = self.clock()
            elif self.step == "phone" and not stations:
                self.step = "wifi"
                self.phone_since = None
            idle = self.step == "wifi" and not stations
        if idle and self.saved and self.clock() - self.last_retry >= RETRY_SAVED_S:
            self._retry_saved()
        elif self.clock() - self.last_ap_check >= AP_CHECK_S:
            self.last_ap_check = self.clock()
            if not self.net.ap_up():
                log("the setup Wi-Fi went down, opening it again")
                self._open_ap()

    def _connect(self, network, password):
        self._set("connecting")
        self.sleep(1.5)  # the phone gets its answer before its Wi-Fi goes away
        self.net.stop_ap()
        fresh = self.net.scan()
        ok, reason = self.net.join(network["ssid"], password, key_mgmt(network["security"]))
        with self.lock:
            self.pending = None
            if fresh:
                self.networks = fresh
        log(f"joining {network['ssid']!r}: {'ok' if ok else reason}")
        if ok:
            if self.home_wifi:
                self.net.forget(self.home_wifi - {network["ssid"]})
            self._finish()
            return
        self._open_ap()
        self._set("wifi", "failed" if reason == "password" else "error")

    def _retry_saved(self):
        self.last_retry = self.clock()
        self.net.stop_ap()
        fresh = self.net.scan()
        visible = {n["ssid"] for n in fresh}
        for name, ssid in self.saved:
            if ssid not in visible:
                continue
            ok, reason = self.net.activate(name)
            log(f"retrying saved {name!r}: {'ok' if ok else reason}")
            if ok:
                self._finish()
                return
            if reason == "password":
                self._set("wifi", "failed")
        if fresh:
            with self.lock:
                self.networks = fresh
        self._open_ap()

    def _finish(self):
        self._set("connected")
        self.sleep(CONNECTED_HOLD_S)  # the TV plays its animation and leaves for the kiosk
        self.done = True


class Starting:
    """Answers the TV page while the Pi decides whether it needs the setup at all."""

    def public_state(self):
        try:
            step = (RUN_DIR / "state").read_text().strip() or "checking"
        except OSError:
            step = "checking"
        return {"step": step, "notice": None, "pageFallback": False}

    def public_networks(self):
        return []

    def mark_page_seen(self):
        pass

    def request_connect(self, ssid, password):
        return "busy"


def make_handler(current):
    """current.setup is Starting until the setup begins, then the Setup session."""
    seen = set()

    class Handler(BaseHTTPRequestHandler):
        server_version = "big-setup"

        def log_message(self, *args):
            pass

        def _host(self):
            return (self.headers.get("Host") or "").rsplit(":", 1)[0].lower()

        def _from_phone(self):
            ip = self.client_address[0]
            return ip.startswith("10.42.0.") and ip != AP_ADDR

        def _send(self, status, body=b"", kind="text/plain", cache="no-store", location=None):
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", cache)
            if location:
                self.send_header("Location", location)
            self.end_headers()
            self.wfile.write(body)

        def _json(self, value, status=200):
            self._send(status, json.dumps(value).encode(), "application/json")

        def _file(self, path):
            try:
                body = path.read_bytes()
            except OSError:
                return self._send(404)
            cache = "max-age=86400" if path.suffix in (".woff2", ".png") else "no-store"
            self._send(200, body, TYPES.get(path.suffix, "application/octet-stream"), cache)

        def _note(self, what):
            # Diagnosis: which checks a phone sends and whether it loads the page.
            key = (self.client_address[0], what)
            if key not in seen:
                seen.add(key)
                log(f"{self.client_address[0]} {what}")

        def _captive(self):
            # Phones check for internet with their own hosts; answering those with the
            # setup page makes them open it as a sign-in page.
            self._send(302, location=f"http://{AP_ADDR}/")

        def do_GET(self):
            if self._host() not in LOCAL_HOSTS:
                self._note(f"probe {self._host()}{self.path.split('?', 1)[0]}")
                return self._captive()
            path = self.path.split("?", 1)[0]
            if path in ("/", "/phone.html"):
                if self._from_phone():
                    self._note("loaded the setup page")
                    current.setup.mark_page_seen()
                return self._file(WEB_DIR / "phone.html")
            if path == "/api/state":
                return self._json(current.setup.public_state())
            if path == "/api/networks":
                return self._json(current.setup.public_networks())
            if path in ("/qr/wifi.svg", "/qr/page.svg"):
                return self._file(RUN_DIR / path.lstrip("/"))
            if path.lstrip("/") in STATIC:
                return self._file(WEB_DIR / path.lstrip("/"))
            self._captive()

        def do_POST(self):
            if self.path != "/api/connect" or self._host() not in LOCAL_HOSTS:
                return self._send(404)
            length = int(self.headers.get("Content-Length") or 0)
            if not 0 < length <= 2048:
                return self._json({"error": "bad request"}, 400)
            try:
                body = json.loads(self.rfile.read(length))
                ssid, password = str(body["ssid"]), str(body.get("password") or "")
            except (ValueError, KeyError, TypeError):
                return self._json({"error": "bad request"}, 400)
            error = current.setup.request_connect(ssid, password)
            self._json({"error": error} if error else {"ok": True}, 400 if error else 200)

    return Handler


def write_state(value):
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    tmp = RUN_DIR / "state.tmp"
    tmp.write_text(value + "\n")
    tmp.chmod(0o644)
    tmp.replace(RUN_DIR / "state")


def write_qr_codes(ssid, password):
    qr = RUN_DIR / "qr"
    qr.mkdir(parents=True, exist_ok=True)
    for name, payload in (("wifi", wifi_qr_payload(ssid, password)), ("page", f"http://{AP_ADDR}/")):
        ok, out = run(["qrencode", "-t", "SVG", "-m", "0", "-l", "M", "--svg-path", "-o", str(qr / f"{name}.svg"), payload])
        if not ok:
            log(f"qrencode failed: {out}")


def restart_kiosk():
    run(["pkill", "-SIGHUP", "-x", "cage"])
    run(["pkill", "-SIGHUP", "-x", "cog"])


def restart_wireguard(only_if_failed):
    # wg-quick resolves the server name once at start and gives up without network.
    if not run(["systemctl", "is-enabled", "--quiet", "wg-quick@wg0"])[0]:
        return
    if only_if_failed and not run(["systemctl", "is-failed", "--quiet", "wg-quick@wg0"])[0]:
        return
    run(["systemctl", "restart", "wg-quick@wg0"])


def read_home_wifi():
    try:
        return {line.strip() for line in HOME_WIFI_FILE.read_text().splitlines() if line.strip()}
    except OSError:
        return set()


def wait_for_network(net, home_wifi=frozenset(), clock=time.monotonic, sleep=time.sleep):
    """Returns None when the Pi is online, else (notice, saved profiles) for the setup.

    The Wi-Fi from the first start at home does not count as the mosque's: without it
    in reach the setup starts right away instead of waiting for a router to come back.
    """
    saved = [(name, ssid) for name, ssid in net.saved_wifi() if ssid not in home_wifi]
    start = clock()
    if not saved:
        grace = HOME_WIFI_GRACE_S if home_wifi else LAN_GRACE_S
        while clock() - start < grace:
            if net.ethernet_up() or net.wifi_up():
                return None
            sleep(3)
        return (None, saved)
    write_state("waiting")
    tried = False
    last_scan = None
    while clock() - start < SAVED_WAIT_S:
        if net.ethernet_up() or net.wifi_up():
            return None
        waited = clock() - start
        if waited >= SAVED_TRY_AFTER_S and (last_scan is None or clock() - last_scan >= SCAN_EVERY_S):
            last_scan = clock()
            visible = {n["ssid"] for n in net.scan()}
            in_reach = [name for name, ssid in saved if ssid in visible]
            if not in_reach and waited >= MISSING_WAIT_S:
                return ("lost", saved)
            if in_reach and not tried:
                tried = True
                for name in in_reach:
                    ok, reason = net.activate(name)
                    if ok:
                        return None
                    if reason == "password":
                        return ("failed", saved)
        sleep(5)
    return ("lost", saved)


def main():
    write_state("checking")
    # kiosk.sh opens the TV page right away; it shows a boot screen until the decision.
    current = SimpleNamespace(setup=Starting())
    server = ThreadingHTTPServer(("", PORT), make_handler(current))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    net = Network()
    net.unblock()
    for _ in range(30):
        if net.ready():
            break
        time.sleep(2)

    if not Path(f"/sys/class/net/{IFACE}").exists():
        log(f"no {IFACE}, nothing to set up")
        write_state("online")
        time.sleep(LINGER_S)
        return

    home_wifi = read_home_wifi()
    decision = wait_for_network(net, home_wifi)
    if decision is None:
        log("online")
        write_state("online")
        restart_wireguard(only_if_failed=True)
        time.sleep(LINGER_S)
        return

    notice, saved = decision
    log(f"starting the setup ({notice or 'no saved Wi-Fi'})")
    password = setup_password()
    ssid = setup_ssid(password)
    setup = Setup(net, notice=notice, saved=saved, home_wifi=home_wifi)
    write_qr_codes(ssid, password)
    channel = setup_channel()
    log(f"setup Wi-Fi {ssid} on channel {channel}")
    setup.start(ssid, password, channel)
    current.setup = setup
    write_state("setup")
    # While a saved Wi-Fi was awaited the TV went on to the kiosk; bring it back.
    if saved:
        restart_kiosk()

    while not setup.done:
        setup.tick()
        time.sleep(1)

    write_state("online")
    net.remove_ap()
    log("setup finished")
    restart_wireguard(only_if_failed=False)
    time.sleep(LINGER_S)


if __name__ == "__main__":
    main()
