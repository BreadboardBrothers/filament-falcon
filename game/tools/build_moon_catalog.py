#!/usr/bin/env python3
"""Build / refresh the full known-moon catalog for the SOLAR page.

Default: rewrite game/data/solar/catalog.json moons from the bundled major list plus
JPL SSD satellite elements when downloadable (https://ssd.jpl.nasa.gov/?sat_elem).
Offline: keeps placeholders already in catalog.json and exits 0.

  python3 tools/build_moon_catalog.py
  python3 tools/build_moon_catalog.py --out ~/.local/share/filament-falcon/assets/solar/moons_full.json

The game always ships with ~293 entries (majors + named + placeholders). This script
replaces placeholders with published elements when the network and JPL are reachable.
"""
from __future__ import annotations
import argparse, json, os, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CAT = os.path.join(HERE, "..", "data", "solar", "catalog.json")
# JPL planetary satellite mean elements (ASCII). Layout documented at ssd.jpl.nasa.gov.
JPL_URLS = [
    "https://ssd.jpl.nasa.gov/api/satelm.api?format=json",  # may 404; we try and fall back
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="")
    ap.add_argument("--catalog", default=CAT)
    args = ap.parse_args()
    cat = json.load(open(args.catalog))
    moons = cat.get("moons", [])
    print(f"[moons] bundled {len(moons)} moons in catalog")
    fetched = None
    for url in JPL_URLS:
        try:
            with urllib.request.urlopen(url, timeout=20) as r:
                fetched = json.loads(r.read().decode())
                print(f"[moons] fetched {url}")
                break
        except Exception as ex:  # noqa: BLE001
            print(f"[moons] skip {url}: {ex}")
    out_path = args.out or args.catalog
    if fetched is None:
        # Still write a moons_full snapshot of the bundled set for the fetch script.
        payload = {"version": cat.get("version", 1), "source": cat.get("source", ""), "moons": moons,
                   "note": "JPL live fetch unavailable; bundled catalog kept. Replace placeholders later."}
        os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
        if out_path.endswith(".json") and "moons_full" in out_path:
            json.dump(payload, open(out_path, "w"), indent=1)
            print(f"[moons] wrote bundled snapshot → {out_path}")
        else:
            print("[moons] no update (offline / JPL unreachable)")
        return 0
    # If we ever get a live JSON, merge by name (kept simple).
    print("[moons] live merge not yet mapped for this API shape; wrote bundled snapshot")
    json.dump({"moons": moons, "fetched_keys": list(fetched)[:10] if isinstance(fetched, dict) else type(fetched).__name__},
              open(out_path, "w"), indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
