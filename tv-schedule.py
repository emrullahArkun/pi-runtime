#!/usr/bin/env python3
"""Switches the TV off at night over HDMI-CEC (cron, every minute, as root).

Off at Yatsı + 1 h, not before 23:00; on at İmsak − 30 min, not after 04:00, from the
prayer times of the kiosk's place. Acts only when the phase changes, so a TV someone
switched on at night stays on. `off` in /etc/fleet/tv-schedule disables it.

Some TVs acknowledge the wake-up and stay in standby, so switching on is checked and
tried twice. The result goes to the heartbeat via /var/lib/fleet/tv-switch.
"""

import datetime as dt
import json
import os
import re
import subprocess
import syslog
import time
import urllib.request
from pathlib import Path

CONFIG = Path(os.environ.get("FLEET_CONFIG", "/etc/fleet/config"))
SWITCH = Path(os.environ.get("TV_SCHEDULE_SWITCH", "/etc/fleet/tv-schedule"))
STATE_DIR = Path(os.environ.get("STATE_DIR", "/var/lib/fleet"))
FLEET_CONTROL = os.environ.get("FLEET_CONTROL", "/usr/local/sbin/fleet-control")

DEFAULT_LOCATION = "hamburg"
OFF_EARLIEST = dt.time(23, 0)
ON_LATEST = dt.time(4, 0)
AFTER_YATSI = dt.timedelta(hours=1)
BEFORE_IMSAK = dt.timedelta(minutes=30)
TABLE_MAX_AGE = dt.timedelta(days=7)
# Holy nights keep the TV on until 02:00; in Ramadan it comes on in time for sahur.
KANDIL_UNTIL = dt.time(2, 0)
BEFORE_IMSAK_RAMADAN = dt.timedelta(minutes=90)
KANDIL_NIGHTS = {"Regaib Kandili", "Miraç Kandili", "Berat Kandili", "Mevlid Kandili", "Kadir Gecesi"}
RAMADAN_START = "Ramazan Başlangıcı"
RAMADAN_END = "Ramazan Bayramı (1. Gün)"
ON_ATTEMPTS = 2
ON_CHECKS = 6
CHECK_EVERY_S = 10
sleep = time.sleep


class Special:
    """Days from holidays.json that change the night: kandil evenings and fasting days."""

    def __init__(self, holidays=()):
        named = [(h.get("date"), h.get("tr")) for h in holidays if isinstance(h, dict)]
        self.kandil = {date for date, name in named if name in KANDIL_NIGHTS}
        # A date marks the evening the holy night begins, and the first day of fasting.
        self.fasting = set()
        ends = sorted(date for date, name in named if name == RAMADAN_END and isinstance(date, str))
        for start in sorted(date for date, name in named if name == RAMADAN_START and isinstance(date, str)):
            end = next((e for e in ends if e > start), None)
            try:
                day, last = dt.date.fromisoformat(start), dt.date.fromisoformat(end) if end else None
            except ValueError:
                continue
            while last and day < last:
                self.fasting.add(day.isoformat())
                day += dt.timedelta(days=1)


NO_SPECIAL = Special()


def log(message):
    syslog.openlog("tv-schedule")
    syslog.syslog(message)


def at(day, hhmm):
    hours, minutes = hhmm.split(":")
    return dt.datetime.combine(day, dt.time(int(hours), int(minutes)))


def night(table, day, special=NO_SPECIAL):
    """The off window from the evening of `day` to the next morning, or None."""
    next_day = day + dt.timedelta(days=1)
    evening, morning = table.get(day.isoformat()), table.get(next_day.isoformat())
    if not evening or not morning:
        return None
    before_imsak = BEFORE_IMSAK_RAMADAN if next_day.isoformat() in special.fasting else BEFORE_IMSAK
    try:
        off = max(dt.datetime.combine(day, OFF_EARLIEST), at(day, evening["yatsi"]) + AFTER_YATSI)
        on = min(dt.datetime.combine(next_day, ON_LATEST), at(next_day, morning["imsak"]) - before_imsak)
    except (KeyError, ValueError, AttributeError):
        return None
    if day.isoformat() in special.kandil:
        off = max(off, dt.datetime.combine(next_day, KANDIL_UNTIL))
    return (off, on) if off < on else None


def phase(table, now, special=NO_SPECIAL):
    for day in (now.date() - dt.timedelta(days=1), now.date()):
        window = night(table, day, special)
        if window and window[0] <= now < window[1]:
            return "off"
    return "on"


def read(path):
    try:
        return path.read_text().strip()
    except OSError:
        return ""


def write(path, text):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(text)
    tmp.replace(path)


def location():
    place = read(STATE_DIR / "location")
    return place if re.fullmatch(r"[A-Za-z0-9_-]{1,64}", place) else DEFAULT_LOCATION


def base_url():
    for line in read(CONFIG).splitlines():
        if line.startswith("KIOSK_BASE_URL="):
            return line.split("=", 1)[1].strip().rstrip("/")
    return ""


def fetch(path, kind):
    base = base_url()
    if not base:
        return None
    try:
        with urllib.request.urlopen(f"{base}/{path}", timeout=20) as res:
            data = json.load(res)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, kind) else None


def load_cached(name, key, path, kind, now):
    """`path` from the kiosk site, refreshed weekly; offline the old copy still serves."""
    cache = STATE_DIR / name
    try:
        cached = json.loads(cache.read_text())
        if "times" in cached:  # written by the version before holidays were cached
            cached = {"key": cached.get("location"), "fetched": cached.get("fetched"), "data": cached["times"]}
        if cached.get("key") != key:
            cached = None
    except (OSError, ValueError, AttributeError, TypeError):
        cached = None
    try:
        stale = cached is None or now - dt.datetime.fromisoformat(cached["fetched"]) >= TABLE_MAX_AGE
    except (KeyError, TypeError, ValueError):
        stale = True
    if stale:
        data = fetch(path, kind)
        if data is not None:
            cached = {"key": key, "fetched": now.isoformat(), "data": data}
            write(cache, json.dumps(cached))
    return cached["data"] if cached else None


def load_table(place, now):
    return load_cached("prayer-times.json", place, f"prayer-times/{place}.json", dict, now)


def load_special(now):
    return Special(load_cached("holidays.json", "holidays", "holidays.json", list, now) or ())


def control(command):
    """Runs a fleet-control command; returns whether it worked and the end of its output."""
    env = {**os.environ, "SSH_ORIGINAL_COMMAND": command}
    try:
        done = subprocess.run([FLEET_CONTROL], env=env, capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired) as err:
        return False, str(err)
    return done.returncode == 0, (done.stdout + done.stderr).strip()[-200:]


def switch_on():
    """on, on-failed (the TV says it is in standby) or on-unverified (it does not say)."""
    power = ""
    for attempt in range(1, ON_ATTEMPTS + 1):
        ok, out = control("tv-on")
        if not ok:
            log(f"tv-on: {out}")
        for _ in range(ON_CHECKS):
            sleep(CHECK_EVERY_S)
            ok, out = control("tv-power")
            power = out if ok else ""
            if power == "on":
                log(f"tv-on: an (Versuch {attempt})")
                return "on"
    if power == "standby":
        log(f"tv-on: Fernseher blieb aus ({ON_ATTEMPTS} Versuche)")
        return "on-failed"
    log("tv-on: gesendet, der Fernseher meldet seinen Zustand nicht")
    return "on-unverified"


def switch_tv(command):
    if command == "tv-on":
        result = switch_on()
    else:
        ok, out = control(command)
        log(f"{command}: {'ok' if ok else out}")
        result = "off" if ok else "off-failed"
    write(STATE_DIR / "tv-switch", f"{result} {int(time.time())}")


def main(now=None):
    if read(SWITCH) == "off":
        return
    now = now or dt.datetime.now()
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    table = load_table(location(), now)
    if table is None:
        return
    want = phase(table, now, load_special(now))
    state = STATE_DIR / "tv-schedule-state"
    last = read(state)
    if last == want:
        return
    write(state, want)
    # The first run only learns the phase: switching mid-window would surprise.
    if last:
        switch_tv("tv-off" if want == "off" else "tv-on")


if __name__ == "__main__":
    main()
