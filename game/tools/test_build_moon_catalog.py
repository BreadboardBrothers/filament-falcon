#!/usr/bin/env python3
"""Offline parser checks for build_moon_catalog.py (no network)."""
from __future__ import annotations
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_moon_catalog as b  # noqa: E402

ELEM = os.path.join(HERE, "testdata", "jpl", "elem_mini.html")
PHYS = os.path.join(HERE, "testdata", "jpl", "phys_mini.html")
CAT = os.path.normpath(os.path.join(HERE, "..", "data", "solar", "catalog.json"))


def main() -> int:
    elem = open(ELEM, encoding="utf-8").read()
    phys = open(PHYS, encoding="utf-8").read()
    rows = b.parse_elem_html(elem)
    assert len(rows) == 4, rows
    io = next(r for r in rows if r["name"] == "Io")
    assert abs(io["a_km"] - 421800) < 1
    assert abs(io["period_d"] - 1.762732) < 1e-6
    ph = b.parse_phys_html(phys)
    assert "501" in ph["by_code"]
    assert abs(ph["by_code"]["501"]["radius_km"] - 1821.49) < 0.01
    assert abs(ph["by_code"]["501"]["gm_km3_s2"] - 5959.91547) < 0.01
    # end-to-end via CLI against mini fixtures (does not rewrite catalog)
    out = tempfile.mktemp(suffix=".json")
    rc = os.system(
        f"{sys.executable} {HERE}/build_moon_catalog.py --catalog {CAT} "
        f"--elem-html {ELEM} --phys-html {PHYS} --out {out}"
    )
    assert rc == 0
    data = json.load(open(out))
    assert data["stats"]["unique"] == 4
    moons = {m["id"]: m for m in data["moons"]}
    assert moons["io"]["radius_km"] == 1821.49
    assert moons["s2010_j_1"]["name"].startswith("S/")
    print("test_build_moon_catalog: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
