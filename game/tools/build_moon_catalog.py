#!/usr/bin/env python3
"""Refresh SOLAR moon catalog from JPL SSD planetary-satellite mean elements.

There is no JSON satelm API. The live source is the HTML table:

  https://ssd.jpl.nasa.gov/sats/elem/
  https://ssd.jpl.nasa.gov/sats/phys_par/   (GM + mean radius when published)

Usage (on the game PC — network + a few hundred KB):

  python3 game/tools/build_moon_catalog.py
  python3 game/tools/build_moon_catalog.py --update-catalog
  python3 game/tools/build_moon_catalog.py --offline --cache-dir /path/to/cache

Writes:
  ~/.local/share/filament-falcon/cache/jpl/{elem,phys}.html   (raw cache)
  ~/.local/share/filament-falcon/assets/solar/moons_full.json  (runtime overlay)
  and, with --update-catalog, rewrites game/data/solar/catalog.json moons.

Offline / failure: keeps the bundled catalog (placeholders OK) and exits 0.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from html.parser import HTMLParser
from typing import Any

HERE = os.path.dirname(os.path.abspath(__file__))
CAT = os.path.normpath(os.path.join(HERE, "..", "data", "solar", "catalog.json"))
UA = (
    "FilamentFalcon/0.1 (+https://github.com/BreadboardBrothers/filament-falcon; "
    "educational solar visualizer; contact via GitHub issues)"
)
ELEM_URL = "https://ssd.jpl.nasa.gov/sats/elem/"
PHYS_URL = "https://ssd.jpl.nasa.gov/sats/phys_par/"
PARENTS = {
    "earth": "earth",
    "mars": "mars",
    "jupiter": "jupiter",
    "saturn": "saturn",
    "uranus": "uranus",
    "neptune": "neptune",
    "pluto": "pluto",
}


def data_home() -> str:
    return os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")


def default_cache_dir() -> str:
    return os.path.join(data_home(), "filament-falcon", "cache", "jpl")


def default_overlay() -> str:
    return os.path.join(data_home(), "filament-falcon", "assets", "solar", "moons_full.json")


def http_get(url: str, timeout: float = 60.0) -> tuple[int, bytes, str]:
    """Return (status, body, error_note). status 0 means transport failure."""
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html,*/*"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = getattr(resp, "status", None) or resp.getcode() or 200
            body = resp.read()
            return int(status), body, ""
    except urllib.error.HTTPError as ex:
        body = ex.read() if hasattr(ex, "read") else b""
        return int(ex.code), body or b"", str(ex)
    except Exception as ex:  # noqa: BLE001
        return 0, b"", str(ex)


def preview(body: bytes, n: int = 160) -> str:
    text = body[:n].decode("utf-8", errors="replace")
    return re.sub(r"\s+", " ", text).strip()


class TableParser(HTMLParser):
    """Collect rows from the first / matching HTML table as lists of cell strings."""

    def __init__(self, table_id: str = "") -> None:
        super().__init__()
        self.table_id = table_id
        self.in_table = False
        self.in_row = False
        self.in_cell = False
        self.cell_tag = ""
        self.cur_row: list[str] = []
        self.cur_cell: list[str] = []
        self.rows: list[list[str]] = []
        self._depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        ad = {k: (v or "") for k, v in attrs}
        if tag == "table":
            tid = ad.get("id", "")
            if not self.table_id or tid == self.table_id or (not tid and not self.in_table):
                if not self.in_table:
                    self.in_table = True
                    self._depth = 1
                    return
            if self.in_table:
                self._depth += 1
        if not self.in_table:
            return
        if tag == "tr":
            # flush an open cell if the previous row omitted </td>
            if self.in_cell:
                text = re.sub(r"\s+", " ", "".join(self.cur_cell)).strip()
                self.cur_row.append(text)
                self.in_cell = False
            self.in_row = True
            self.cur_row = []
        elif tag in ("td", "th") and self.in_row:
            # JPL pages often omit </td>; close the previous cell first.
            if self.in_cell:
                text = re.sub(r"\s+", " ", "".join(self.cur_cell)).strip()
                self.cur_row.append(text)
            self.in_cell = True
            self.cell_tag = tag
            self.cur_cell = []
        elif tag == "br" and self.in_cell:
            self.cur_cell.append(" ")

    def handle_endtag(self, tag: str) -> None:
        if not self.in_table:
            return
        if tag in ("td", "th") and self.in_cell:
            text = re.sub(r"\s+", " ", "".join(self.cur_cell)).strip()
            self.cur_row.append(text)
            self.in_cell = False
        elif tag == "tr" and self.in_row:
            if self.cur_row:
                self.rows.append(self.cur_row)
            self.in_row = False
        elif tag == "table":
            self._depth -= 1
            if self._depth <= 0:
                self.in_table = False

    def handle_data(self, data: str) -> None:
        if self.in_cell:
            self.cur_cell.append(data)


def parse_elem_html(html: str) -> list[dict[str, Any]]:
    p = TableParser("sat_elem")
    p.feed(html)
    if len(p.rows) < 2:
        p = TableParser("")
        p.feed(html)
    if len(p.rows) < 2:
        raise ValueError(f"no sat_elem rows (got {len(p.rows)})")
    # header may be multi-line; find a data row by looking for numeric a
    out: list[dict[str, Any]] = []
    for row in p.rows:
        if len(row) < 14:
            continue
        # Expected: ID Planet Satellite Code Ephemeris Frame Epoch a e w M i node P ...
        planet = row[1].strip()
        sat = row[2].strip()
        code = row[3].strip()
        if not planet or not sat or planet.lower() == "planet":
            continue
        parent = PARENTS.get(planet.lower())
        if not parent:
            continue
        try:
            a_km = float(row[7].replace(",", ""))
            e = float(row[8].replace(",", "") or "0")
            w = float(row[9].replace(",", "") or "0")
            M = float(row[10].replace(",", "") or "0")
            i = float(row[11].replace(",", "") or "0")
            node = float(row[12].replace(",", "") or "0")
            period = float(row[13].replace(",", "") or "0")
        except ValueError:
            continue
        if a_km <= 0 or period <= 0:
            continue
        out.append(
            {
                "planet": planet,
                "parent": parent,
                "name": sat,
                "code": code,
                "ephemeris": row[4].strip() if len(row) > 4 else "",
                "frame": row[5].strip() if len(row) > 5 else "",
                "epoch": row[6].strip() if len(row) > 6 else "",
                "a_km": a_km,
                "e": e,
                "w_deg": w,
                "mean_anomaly0_deg": M,
                "i_deg": i,
                "Om0_deg": node,
                "period_d": period,
            }
        )
    return out


def _fnum(s: str) -> float | None:
    s = (s or "").strip().replace(",", "")
    if not s or s in ("-", "—", "*", "n/a", "N/A"):
        return None
    try:
        return float(s)
    except ValueError:
        return None


def parse_phys_html(html: str) -> dict[str, Any]:
    """Map JPL code / name -> {gm_km3_s2, radius_km}."""
    p = TableParser("sat_phys_par")
    p.feed(html)
    if len(p.rows) < 3:
        p = TableParser("")
        p.feed(html)
    by_code: dict[str, dict[str, float]] = {}
    by_name: dict[str, dict[str, float]] = {}
    for row in p.rows:
        # Planet Satellite Code GM_value GM_sigma GM_ref R_value R_sigma R_ref Density...
        if len(row) < 7:
            continue
        planet, sat, code = row[0].strip(), row[1].strip(), row[2].strip()
        if not code or not code[0].isdigit():
            continue
        gm = _fnum(row[3])
        rad = _fnum(row[6])
        d: dict[str, float] = {}
        if gm is not None and gm > 0:
            d["gm_km3_s2"] = gm
        if rad is not None and rad > 0:
            d["radius_km"] = rad
        if not d:
            continue
        by_code[code] = d
        by_name[norm_name(sat)] = d
        _ = planet
    return {"by_code": by_code, "by_name": by_name}


def norm_name(name: str) -> str:
    s = name.strip().lower()
    s = s.replace("magaclite", "megaclite")  # JPL typo variant
    s = re.sub(r"[^a-z0-9]+", "_", s)
    return s.strip("_")


def pretty_sat_name(name: str) -> str:
    n = name.strip()
    m = re.match(r"^S(\d{4})_([A-Za-z])_(\d+)$", n)
    if m:
        return f"S/{m.group(1)} {m.group(2).upper()} {int(m.group(3))}"
    m = re.match(r"^S(\d{4})_([A-Za-z])(\d+)$", n)
    if m:
        return f"S/{m.group(1)} {m.group(2).upper()} {int(m.group(3))}"
    m = re.match(r"^S(\d{4})\s*([A-Za-z])\s*(\d+)$", n.replace("/", " "))
    if m and n.upper().startswith("S"):
        return f"S/{m.group(1)} {m.group(2).upper()} {int(m.group(3))}"
    return n.replace("_", " ")


def make_id(name: str, parent: str, code: str) -> str:
    n = norm_name(name)
    # Prefer clean names for well-known moons; keep provisional designations readable.
    if n.startswith("s") and "_" in n:
        return n
    if n and n[0].isalpha() and not n.startswith("s20") and not n.startswith("s19"):
        # avoid collisions across parents (none expected for IAU names)
        return n
    return n or f"{parent}_{code}"


def color_for(parent: str, irregular: bool) -> list[float]:
    base = {
        "earth": [0.7, 0.7, 0.72],
        "mars": [0.55, 0.4, 0.35],
        "jupiter": [0.7, 0.65, 0.55],
        "saturn": [0.75, 0.7, 0.55],
        "uranus": [0.55, 0.7, 0.75],
        "neptune": [0.45, 0.55, 0.8],
        "pluto": [0.7, 0.65, 0.6],
    }.get(parent, [0.5, 0.5, 0.5])
    if irregular:
        return [max(0.2, c - 0.1) for c in base]
    return base


def moon_entry(el: dict[str, Any], phys: dict[str, Any], prev: dict[str, Any] | None) -> dict[str, Any]:
    parent = el["parent"]
    name = el["name"]
    code = el["code"]
    mid = make_id(name, parent, code)
    # Prefer previous id if same name already in catalog (keeps textures / special flags).
    if prev:
        mid = str(prev.get("id", mid))
    irregular = float(el["i_deg"]) > 20.0 or float(el["a_km"]) > 1.0e6 and parent in (
        "jupiter",
        "saturn",
        "uranus",
        "neptune",
    )
    radius = 1.5
    gm = 0.001
    pcode = phys.get("by_code", {}).get(code, {})
    pname = phys.get("by_name", {}).get(norm_name(name), {})
    if "radius_km" in pcode:
        radius = float(pcode["radius_km"])
    elif "radius_km" in pname:
        radius = float(pname["radius_km"])
    elif prev and float(prev.get("radius_km", 0)) > 0 and not prev.get("placeholder"):
        radius = float(prev["radius_km"])
    elif irregular:
        radius = 1.5
    else:
        radius = max(2.0, min(50.0, float(el["a_km"]) / 50000.0))
    if "gm_km3_s2" in pcode:
        gm = float(pcode["gm_km3_s2"])
    elif "gm_km3_s2" in pname:
        gm = float(pname["gm_km3_s2"])
    elif prev and not prev.get("placeholder"):
        gm = float(prev.get("gm_km3_s2", gm))

    rot_hours = float(el["period_d"]) * 24.0  # tidally locked default
    entry: dict[str, Any] = {
        "id": mid,
        "name": pretty_sat_name(name),
        "parent": parent,
        "kind": "moon",
        "a_km": float(el["a_km"]),
        "e": float(el["e"]),
        "i_deg": float(el["i_deg"]),
        "period_d": float(el["period_d"]),
        "mean_anomaly0_deg": float(el["mean_anomaly0_deg"]),
        "Om0_deg": float(el["Om0_deg"]),
        "w_deg": float(el["w_deg"]),
        "radius_km": radius,
        "gm_km3_s2": gm,
        "rot_hours": rot_hours if not (prev and prev.get("rot_hours")) else float(prev.get("rot_hours", rot_hours)),
        "tilt_deg": float(prev.get("tilt_deg", 0.0)) if prev else 0.0,
        "oblateness": float(prev.get("oblateness", 0.0)) if prev else 0.0,
        "color": prev.get("color") if prev and not prev.get("placeholder") else color_for(parent, irregular),
        "tidally_locked": bool(prev.get("tidally_locked", not irregular)) if prev else (not irregular),
        "texture": str(prev.get("texture", "")) if prev else "",
        "normal": str(prev.get("normal", "")) if prev and prev.get("normal") else "",
        "irregular": irregular,
        "jpl_code": code,
        "jpl_frame": el.get("frame", ""),
        "jpl_ephemeris": el.get("ephemeris", ""),
        "source": "jpl_ssd_mean_elements",
    }
    # drop empty optional keys
    if not entry["normal"]:
        entry.pop("normal", None)
    if not entry["texture"]:
        entry["texture"] = ""
    return entry


def index_prev(moons: list[dict[str, Any]]) -> tuple[dict[str, dict], dict[str, dict]]:
    by_id: dict[str, dict] = {}
    by_name: dict[str, dict] = {}
    for m in moons:
        by_id[str(m["id"])] = m
        by_name[norm_name(str(m.get("name", "")))] = m
        # also map jupiter_moon_NNN placeholders loosely — ignored for match
    return by_id, by_name


def merge_moons(
    bundled: list[dict[str, Any]], elements: list[dict[str, Any]], phys: dict[str, Any]
) -> tuple[list[dict[str, Any]], dict[str, int]]:
    _by_id, by_name = index_prev(bundled)
    # Prefer first occurrence per (parent, normalized name); JPL table can list a body twice (e.g. Puck).
    seen: set[tuple[str, str]] = set()
    merged: list[dict[str, Any]] = []
    for el in elements:
        key = (el["parent"], norm_name(el["name"]))
        if key in seen:
            continue
        seen.add(key)
        prev = by_name.get(norm_name(el["name"]))
        # also match by id slug
        if prev is None:
            slug = make_id(el["name"], el["parent"], el["code"])
            for m in bundled:
                if str(m.get("id")) == slug:
                    prev = m
                    break
        merged.append(moon_entry(el, phys, prev if prev and not prev.get("placeholder") else prev))
    stats = {
        "jpl_rows": len(elements),
        "unique": len(merged),
        "with_radius_from_phys": sum(
            1
            for m in merged
            if m.get("jpl_code") in phys.get("by_code", {})
            and "radius_km" in phys["by_code"][m["jpl_code"]]
        ),
        "kept_textures": sum(1 for m in merged if m.get("texture")),
    }
    return merged, stats


def load_or_fetch(url: str, cache_path: str, offline: bool, max_age_s: float) -> tuple[str, str]:
    """Return (html_text, source_note)."""
    if os.path.isfile(cache_path):
        age = time.time() - os.path.getmtime(cache_path)
        if offline or age < max_age_s:
            raw = open(cache_path, "rb").read()
            note = f"cache {cache_path} ({len(raw)} B, age {age / 3600:.1f} h)"
            return raw.decode("utf-8", errors="replace"), note
    if offline:
        if os.path.isfile(cache_path):
            raw = open(cache_path, "rb").read()
            return raw.decode("utf-8", errors="replace"), f"cache {cache_path}"
        raise FileNotFoundError(f"offline and missing cache: {cache_path}")
    status, body, err = http_get(url)
    if status != 200 or not body:
        raise RuntimeError(
            f"GET {url} -> HTTP {status or 'ERR'} {err}; first bytes: {preview(body)!r}"
        )
    # Reject obvious non-HTML failures / homepage bounces that lack our table.
    text = body.decode("utf-8", errors="replace")
    if "sat_elem" not in text and "sat_phys_par" not in text and "<table" not in text.lower():
        raise RuntimeError(
            f"GET {url} -> HTTP {status} but no table; first bytes: {preview(body)!r}"
        )
    os.makedirs(os.path.dirname(cache_path), exist_ok=True)
    open(cache_path, "wb").write(body)
    return text, f"fetched {url} ({len(body)} B) -> {cache_path}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--catalog", default=CAT)
    ap.add_argument("--out", default="", help="overlay JSON path (default: XDG moons_full.json)")
    ap.add_argument("--cache-dir", default="", help="raw HTML cache dir")
    ap.add_argument("--offline", action="store_true", help="use cache only")
    ap.add_argument("--max-age-hours", type=float, default=168.0, help="reuse cache newer than this")
    ap.add_argument("--update-catalog", action="store_true", help="rewrite moons in catalog.json")
    ap.add_argument("--elem-html", default="", help="parse this elem HTML file (test/offline)")
    ap.add_argument("--phys-html", default="", help="parse this phys HTML file (test/offline)")
    args = ap.parse_args()

    cat_path = os.path.abspath(args.catalog)
    cat = json.load(open(cat_path, encoding="utf-8"))
    bundled = list(cat.get("moons", []))
    print(f"[moons] bundled {len(bundled)} moons in {cat_path}")
    ph = sum(1 for m in bundled if m.get("placeholder"))
    print(f"[moons] placeholders before: {ph}")

    cache_dir = args.cache_dir or default_cache_dir()
    elem_html = ""
    phys_html = ""
    try:
        if args.elem_html:
            elem_html = open(args.elem_html, encoding="utf-8", errors="replace").read()
            print(f"[moons] elem from file {args.elem_html} ({len(elem_html)} chars)")
        else:
            elem_html, note = load_or_fetch(
                ELEM_URL,
                os.path.join(cache_dir, "elem.html"),
                args.offline,
                args.max_age_hours * 3600.0,
            )
            print(f"[moons] elem: {note}")
        if args.phys_html:
            phys_html = open(args.phys_html, encoding="utf-8", errors="replace").read()
            print(f"[moons] phys from file {args.phys_html} ({len(phys_html)} chars)")
        else:
            try:
                phys_html, note = load_or_fetch(
                    PHYS_URL,
                    os.path.join(cache_dir, "phys.html"),
                    args.offline,
                    args.max_age_hours * 3600.0,
                )
                print(f"[moons] phys: {note}")
            except Exception as ex:  # noqa: BLE001
                print(f"[moons] phys skipped: {ex}")
                phys_html = ""
    except Exception as ex:  # noqa: BLE001
        print(f"[moons] fetch/parse aborted: {ex}")
        print("[moons] no update (bundled catalog kept)")
        out = args.out or default_overlay()
        os.makedirs(os.path.dirname(out), exist_ok=True)
        json.dump(
            {
                "version": cat.get("version", 1),
                "source": "bundled_fallback",
                "note": str(ex),
                "moons": bundled,
            },
            open(out, "w", encoding="utf-8"),
            indent=1,
        )
        print(f"[moons] wrote bundled snapshot → {out}")
        return 0

    try:
        elements = parse_elem_html(elem_html)
        phys: dict[str, Any] = {"by_code": {}, "by_name": {}}
        if phys_html:
            phys = parse_phys_html(phys_html)
        min_rows = 3 if (args.elem_html or args.offline) else 50
        if len(elements) < min_rows:
            raise ValueError(f"only {len(elements)} element rows — page shape changed? (need ≥ {min_rows})")
    except Exception as ex:  # noqa: BLE001
        print(f"[moons] parse failed: {ex}")
        print("[moons] no update (bundled catalog kept)")
        return 0

    moons, stats = merge_moons(bundled, elements, phys)
    print(
        f"[moons] JPL rows={stats['jpl_rows']} unique={stats['unique']} "
        f"phys_radii={stats['with_radius_from_phys']} textures_kept={stats['kept_textures']}"
    )
    print(f"[moons] placeholders after: {sum(1 for m in moons if m.get('placeholder'))}")

    overlay = {
        "version": int(cat.get("version", 1)) + 0,
        "source": "JPL SSD Planetary Satellite Mean Elements (ssd.jpl.nasa.gov/sats/elem/) + phys_par",
        "fetched_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "elem_url": ELEM_URL,
        "phys_url": PHYS_URL,
        "stats": stats,
        "moons": moons,
    }
    out_path = args.out or default_overlay()
    os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
    json.dump(overlay, open(out_path, "w", encoding="utf-8"), indent=1)
    print(f"[moons] wrote overlay → {out_path} ({len(moons)} moons)")

    if args.update_catalog:
        cat["moons"] = moons
        cat["source"] = (
            str(cat.get("source", ""))
            + " | Moons: JPL SSD mean elements "
            + overlay["fetched_utc"]
        ).strip(" |")
        cat["moon_source"] = overlay["source"]
        cat["moon_count"] = len(moons)
        # backup
        bak = cat_path + ".bak"
        open(bak, "w", encoding="utf-8").write(open(cat_path, encoding="utf-8").read())
        json.dump(cat, open(cat_path, "w", encoding="utf-8"), indent=1)
        print(f"[moons] updated catalog → {cat_path} (backup {bak})")

    return 0


if __name__ == "__main__":
    sys.exit(main())
