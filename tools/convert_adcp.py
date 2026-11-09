# /// script
# dependencies = ["numpy", "pyproj", "netCDF4"]
# ///
"""Export the ship's 75 kHz ADCP (UHDAS os75nb) current profiles for Godot.

Writes data/adcp.json: one profile every 5 minutes along the ship track, each
with east/north current (m/s) and approximate relative backscatter (dB) per
depth bin. Bins flagged bad by UHDAS editing, or with under 50% good pings, are null.

Backscatter is the received signal strength with a simple range and absorption
correction. It is uncalibrated, so only compare values with each other.

Usage:  uv run tools/convert_adcp.py [path/to/os75nb/contour]
"""
import datetime as dt
import json
import sys
from pathlib import Path

import netCDF4
import numpy as np
from pyproj import Transformer

DEFAULT_SRC = (Path(__file__).resolve().parents[2] / "OXR20260428/Vessel/Acoustics/UHDAS/proc/os75nb/contour")
OUT = Path(__file__).resolve().parents[1] / "data" / "adcp.json"
BEAM_ANGLE = 30.0     # degrees, from UHDAS dbinfo.txt
ABSORPTION = 0.024    # dB/m, sea water at 75 kHz
COUNTS_TO_DB = 0.45   # typical RDI receiver scale
NOISE_COUNTS = 30.0   # signal strength in the deepest (empty) bins
MIN_PERCENT_GOOD = 50 # same cutoff UHDAS uses for its own plots
MAX_DEEP_SPEED = 1.0  # m/s, below 200 m
MIN_BIN_COVERAGE = 0.01  # keep depth bins that have data in at least 1% of profiles

src = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SRC
to_utm = Transformer.from_crs(4326, 32653, always_xy=True)

profiles, depth_ref = [], None
for path in sorted(src.glob("*_compr.nc")):
    ds = netCDF4.Dataset(path)
    ds.set_auto_mask(False)
    t, lon, lat = ds["time"][:], ds["lon"][:], ds["lat"][:]
    depth, u, v = ds["depth"][:], ds["u"][:], ds["v"][:]
    amp, pflag, pg = ds["amp"][:].astype(np.float32), ds["pflag"][:], ds["pg"][:]
    good = (pflag == 0) & (pg >= MIN_PERCENT_GOOD) & np.isfinite(u) & np.isfinite(v) & (np.abs(u) < 5) & (np.abs(v) < 5)
    good &= np.isfinite(lon[:, None]) & np.isfinite(lat[:, None])
    # Deep currents here are slow; a fast deep bin is a bad ping, not a jet.
    good &= ~((depth > 200) & (np.hypot(u, v) > MAX_DEEP_SPEED))

    if depth_ref is None:
        depth_ref = depth[0]
    assert np.allclose(depth, depth_ref, atol=1), f"{path.name}: depth bins differ"

    rng = depth_ref / np.cos(np.radians(BEAM_ANGLE))
    sv = COUNTS_TO_DB * (amp - NOISE_COUNTS) + 20 * np.log10(rng) + 2 * ABSORPTION * rng
    east, north = to_utm.transform(lon, lat)
    year0 = dt.datetime(int(ds.yearbase), 1, 1, tzinfo=dt.timezone.utc)

    for i in range(len(t)):
        if not good[i].any():
            continue
        g = good[i]
        profiles.append({
            "time": (year0 + dt.timedelta(days=float(t[i]))).strftime("%Y-%m-%d %H:%M UTC"),
            "lon": round(float(lon[i]), 5), "lat": round(float(lat[i]), 5),
            "easting": round(float(east[i]), 1), "northing": round(float(north[i]), 1),
            "u": [round(float(x), 3) if ok else None for x, ok in zip(u[i], g)],
            "v": [round(float(x), 3) if ok else None for x, ok in zip(v[i], g)],
            "backscatter": [round(float(x), 1) if ok else None for x, ok in zip(sv[i], g)],
        })

# Drop deep bins that almost never have good data.
counts = np.sum([[x is not None for x in p["u"]] for p in profiles], axis=0)
last = int(np.nonzero(counts >= MIN_BIN_COVERAGE * len(profiles))[0].max()) + 1
for p in profiles:
    for key in ("u", "v", "backscatter"):
        p[key] = p[key][:last]

OUT.write_text(json.dumps({
    "source": f"UHDAS os75nb (75 kHz narrowband) from {src}",
    "crs": "EPSG:32653",
    "depth_m": [round(float(d), 1) for d in depth_ref[:last]],
    "profiles": profiles,
}, separators=(",", ":")))
print(f"{len(profiles)} profiles, {last} bins to {depth_ref[last - 1]:.0f} m -> {OUT}")
