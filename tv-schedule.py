#!/usr/bin/env python3
"""Switches the TV off at night over HDMI-CEC (cron, every minute, as root).

Off at Yatsı + 1 h, not before 23:00; on at İmsak − 30 min, not after 04:00, from the
prayer times of the kiosk's place. Acts only when the phase changes, so a TV someone
switched on at night stays on. `off` in /etc/fleet/tv-schedule disables it.
"""

import datetime as dt
import json
import os
import re
import subprocess
import syslog
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


def log(message):
    syslog.openlog("tv-schedule")
    syslog.syslog(message)


def at(day, hhmm):
    hours, minutes = hhmm.split(":")
    return dt.datetime.combine(day, dt.time(int(hours), int(minutes)))


def night(table, day):
    """The off window from the evening of `day` to the next morning, or None."""
    next_day = day + dt.timedelta(days=1)
    evening, morning = table.get(day.isoformat()), table.get(next_day.isoformat())
    if not evening or not morning:
        return None
    try:
        off = max(dt.datetime.combine(day, OFF_EARLIEST), at(day, evening["yatsi"]) + AFTER_YATSI)
        on = min(dt.datetime.combine(next_day, ON_LATEST), at(next_day, morning["imsak"]) - BEFORE_IMSAK)
    except (KeyError, ValueError, AttributeError):
        return None
    return (off, on) if off < on else None


def phase(table, now):
    for day in (now.date() - dt.timedelta(days=1), now.date()):
        window = night(table, day)
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


def fetch(place):
    base = base_url()
    if not base:
        return None
    try:
        with urllib.request.urlopen(f"{base}/prayer-times/{place}.json", timeout=20) as res:
            table = json.load(res)
    except (OSError, ValueError):
        return None
    return table if isinstance(table, dict) else None


def load_table(place, now):
    """The cached table of `place`, refreshed weekly; offline the old one still serves."""
    cache = STATE_DIR / "prayer-times.json"
    try:
        cached = json.loads(cache.read_text())
        if cached.get("location") != place:
            cached = None
    except (OSError, ValueError, AttributeError):
        cached = None
    try:
        stale = cached is None or now - dt.datetime.fromisoformat(cached["fetched"]) >= TABLE_MAX_AGE
    except (KeyError, TypeError, ValueError):
        stale = True
    if stale:
        table = fetch(place)
        if table is not None:
            cached = {"location": place, "fetched": now.isoformat(), "times": table}
            write(cache, json.dumps(cached))
    return cached["times"] if cached else None


def switch_tv(command):
    env = {**os.environ, "SSH_ORIGINAL_COMMAND": command}
    try:
        done = subprocess.run([FLEET_CONTROL], env=env, capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired) as err:
        log(f"{command}: {err}")
        return
    log(f"{command}: {'ok' if done.returncode == 0 else (done.stdout + done.stderr).strip()[-200:]}")


def main(now=None):
    if read(SWITCH) == "off":
        return
    now = now or dt.datetime.now()
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    table = load_table(location(), now)
    if table is None:
        return
    want = phase(table, now)
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
