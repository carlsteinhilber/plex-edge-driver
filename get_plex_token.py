#!/usr/bin/env python3
"""
get_plex_token.py
Retrieves your X-Plex-Token using one of two methods:
  1. Reads it directly from the Plex Preferences.xml file (no sign-in needed)
  2. Opens a Plex OAuth browser tab — sign in however you normally do
"""

import os
import sys
import platform
import xml.etree.ElementTree as ET
import urllib.request
import urllib.parse
import urllib.error
import json
import time
import uuid
import webbrowser
from pathlib import Path


CLIENT_ID = str(uuid.uuid4())   # unique per run; Plex requires a stable identifier
PRODUCT   = "PlexAmp SmartThings Edge Driver"
HEADERS   = {
    "X-Plex-Client-Identifier": CLIENT_ID,
    "X-Plex-Product": PRODUCT,
    "X-Plex-Version": "1.0",
    "Accept": "application/json",
}


# ── Method 1: Preferences.xml ─────────────────────────────────────────────────

PREFS_PATHS = {
    "Linux":   Path("/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml"),
    "Darwin":  Path.home() / "Library/Application Support/Plex Media Server/Preferences.xml",
    "Windows": Path(os.environ.get("LOCALAPPDATA", "")) / "Plex Media Server/Preferences.xml",
}


def token_from_prefs() -> str | None:
    prefs_path = PREFS_PATHS.get(platform.system())
    if prefs_path is None or not prefs_path.exists():
        return None
    try:
        root = ET.parse(prefs_path).getroot()
        return root.attrib.get("PlexOnlineToken") or None
    except ET.ParseError:
        return None


# ── Method 2: Plex OAuth ──────────────────────────────────────────────────────

def _request(method: str, url: str, body: bytes | None = None) -> dict:
    req = urllib.request.Request(url, data=body, headers=HEADERS, method=method)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())


def token_from_oauth() -> str | None:
    # 1 — Create a pin
    print("  Requesting OAuth pin from plex.tv ...")
    try:
        pin = _request(
            "POST",
            "https://plex.tv/api/v2/pins?" + urllib.parse.urlencode({"strong": "true"}),
            body=b"",
        )
    except Exception as e:
        print(f"  [!] Could not reach plex.tv: {e}")
        return None

    pin_id   = pin["id"]
    pin_code = pin["code"]

    # 2 — Build auth URL and open it in the default browser
    auth_url = (
        "https://app.plex.tv/auth#?"
        + urllib.parse.urlencode({
            "clientID": CLIENT_ID,
            "code":     pin_code,
            "context[device][product]":     PRODUCT,
            "context[device][environment]": "bundled",
            "context[device][layout]":      "desktop",
            "context[device][platform]":    "Web",
            "context[device][version]":     "4.0",
        })
    )

    print(f"\n  Opening Plex sign-in page in your browser ...")
    print(f"  If it doesn't open automatically, visit:\n\n    {auth_url}\n")
    webbrowser.open(auth_url)

    # 3 — Poll until the user signs in (up to 5 minutes)
    print("  Waiting for you to sign in", end="", flush=True)
    poll_url = f"https://plex.tv/api/v2/pins/{pin_id}"
    deadline = time.time() + 300

    while time.time() < deadline:
        time.sleep(3)
        print(".", end="", flush=True)
        try:
            result = _request("GET", poll_url)
        except Exception:
            continue

        token = result.get("authToken")
        if token:
            print("  ✓")
            return token

    print("\n  [!] Timed out waiting for sign-in (5 min).")
    return None


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    print("=" * 55)
    print("  Plex X-Plex-Token Retriever")
    print("=" * 55)

    # Try the local Preferences.xml first — fastest and requires no sign-in
    print("\n[1] Looking for Plex Preferences.xml ...")
    token = token_from_prefs()
    if token:
        print("    Found.")
    else:
        print("    Not found (Plex server may not be on this machine).")
        print("\n[2] Opening Plex OAuth sign-in ...")
        token = token_from_oauth()

    if token:
        print("\n" + "=" * 55)
        print("  Your X-Plex-Token:\n")
        print(f"  {token}")
        print("=" * 55)
        print("\nCopy this value into the 'Plex Token' preference")
        print("in the PlexAmp Player device settings.")
    else:
        print("\n[!] Could not retrieve a token.")
        sys.exit(1)


if __name__ == "__main__":
    main()
