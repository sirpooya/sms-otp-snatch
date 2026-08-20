# dmgbuild settings for OTP Snatcher, ported from LaunchpadX. reads ALL layout values from
# packaging/dmg/dmg-settings.json (the single source of truth). Edit the JSON;
# this file just applies it. No hardcoded numbers here.
#
# Why dmgbuild (not create-dmg): dmgbuild writes the DMG's .DS_Store layout
# DIRECTLY — no Finder, no AppleScript — so the background reliably sticks and
# it works HEADLESS in CI. create-dmg's Finder AppleScript silently fails to set
# the background on macOS Tahoe.
#
# Usage (app path via env so the JSON stays version-agnostic):
#   APP_PATH=build/OTPSnatcher.app \
#     dmgbuild -s packaging/dmg/dmgbuild-settings.py "OTPSnatcher" build/OTPSnatcher-<ver>.dmg
#
# Coordinates in the JSON are icon CENTERS in POINTS, Y top-down.

import os
import json

# dmgbuild exec()s this file, so `__file__` is undefined. The JSON lives next to
# this script; find it relative to the repo root (the build must run FROM the
# repo root — see buildCommand in the JSON). An env override is also allowed.
_json = os.environ.get("DMG_SETTINGS_JSON", "packaging/dmg/dmg-settings.json")
_repo_root = os.getcwd()
with open(os.path.join(_repo_root, _json)) as _f:
    _cfg = json.load(_f)

def _p(rel):
    # Paths in the JSON are repo-relative.
    return os.path.join(_repo_root, rel)

# --- Contents: the app (from env) + a link to /Applications ---
app_path = os.environ.get("APP_PATH", "build/OTPSnatcher.app")
if not os.path.isabs(app_path):
    app_path = _p(app_path)
app_name = os.path.basename(app_path)

files = [app_path]
symlinks = {"Applications": "/Applications"}

# --- Window / layout (all from JSON) ---
# The background art is optional. Until it exists, fall back to a flat colour so
# packaging works today instead of failing on a missing PNG. Drop a
# 1320x896 image at the JSON's `background` path and it is picked up
# automatically, no code change.
_bg = _p(_cfg["background"])
background = _bg if os.path.exists(_bg) else "#ececec"

_w, _h = _cfg["windowSize"]
window_rect = ((200, 120), (_w, _h))

icon_size = _cfg["iconSize"]

_app = _cfg["icons"]["app"]
_apps = _cfg["icons"]["applicationsLink"]
icon_locations = {
    app_name: (_app["x"], _app["y"]),
    "Applications": (_apps["x"], _apps["y"]),
}

# Icon view, no chrome, so the background shows cleanly.
default_view = "icon-view"
show_icon_preview = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

format = "UDZO"
