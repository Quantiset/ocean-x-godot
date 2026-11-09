# /// script
# dependencies = ["numpy", "scipy", "pyproj", "netCDF4"]
# ///
"""Fill the gaps between multibeam swaths with public SRTM15+ bathymetry (~460 m).

Reads data/bathy.r32 + bathy.json (from convert_bathymetry.py) and writes:
  bathy_filled.r32  float32 depths on the same 75 m grid, no gaps
  bathy_source.u8   one byte per cell: share of ship multibeam nearby, 255 = all
                    ship data, 0 = all SRTM15+ (above 127 counts as measured)
and adds a "filled" section to bathy.json.

Near the swath edges the public grid is nudged toward the ship data so there is
no visible step where the two meet.

Usage:  uv run tools/fill_gaps.py
"""
import json
import urllib.request
from pathlib import Path

import netCDF4
import numpy as np
from pyproj import Transformer
from scipy.interpolate import RegularGridInterpolator
from scipy.ndimage import distance_transform_edt, gaussian_filter

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"
CACHE = ROOT / "tools" / "cache"
ERDDAP = "https://coastwatch.pfeg.noaa.gov/erddap/griddap/srtm15plus.nc"
BLEND_CELLS = 15  # how far (in 75 m cells) the ship data's offset fades out into the fill

meta = json.loads((DATA / "bathy.json").read_text())
w, h = meta["width"], meta["height"]
cell = meta["cell_size_m"][0]
x0, y0 = meta["origin_utm_top_left"]
mb = np.fromfile(DATA / "bathy.r32", "<f4").reshape(h, w)
valid = mb > meta["nodata"] + 1

# Lat/lon box of the grid, with a small margin for interpolation.
to_ll = Transformer.from_crs(32653, 4326, always_xy=True)
ex = np.array([x0, x0 + w * cell, x0, x0 + w * cell])
ny = np.array([y0, y0, y0 - h * cell, y0 - h * cell])
lon, lat = to_ll.transform(ex, ny)
box = (lat.min() - 0.05, lat.max() + 0.05, lon.min() - 0.05, lon.max() + 0.05)

CACHE.mkdir(exist_ok=True)
(CACHE / ".gdignore").touch()
nc_path = CACHE / ("srtm15plus_%.2f_%.2f_%.2f_%.2f.nc" % box)
if not nc_path.exists():
    url = f"{ERDDAP}?z%5B({box[0]}):1:({box[1]})%5D%5B({box[2]}):1:({box[3]})%5D"
    print("Downloading", url)
    urllib.request.urlretrieve(url, nc_path)
ds = netCDF4.Dataset(nc_path)
srtm = RegularGridInterpolator((ds["latitude"][:], ds["longitude"][:]), ds["z"][:].astype(np.float32))
srtm_title = getattr(ds, "title", "SRTM15+")

# Sample SRTM15+ at every grid cell centre, a block of rows at a time.
public = np.empty((h, w), np.float32)
cols = x0 + (np.arange(w) + 0.5) * cell
for r in range(0, h, 256):
    rr = np.arange(r, min(r + 256, h))
    E, N = np.meshgrid(cols, y0 - (rr + 0.5) * cell)
    lo, la = to_ll.transform(E, N)
    public[rr] = srtm((la, lo))

# Offset between ship and public data, smoothed, then carried outward from the
# nearest sounding and faded to zero over BLEND_CELLS.
resid = np.where(valid, mb - public, 0).astype(np.float32)
wsum = gaussian_filter(valid.astype(np.float32), 3)
resid = gaussian_filter(resid, 3) / np.maximum(wsum, 1e-6)
dist, (ir, ic) = distance_transform_edt(~valid, return_indices=True)
fade = np.clip(1 - dist / BLEND_CELLS, 0, 1)
fade = fade * fade * (3 - 2 * fade)
filled = np.where(valid, mb, public + resid[ir, ic] * fade).astype("<f4")

filled.tofile(DATA / "bathy_filled.r32")
# Softened so the change in shading at swath edges is gradual, not jagged.
soft = gaussian_filter(valid.astype(np.float32), 1.5)
soft = np.where(valid, np.maximum(soft, 0.51), np.minimum(soft, 0.49))
np.round(soft * 255).astype(np.uint8).tofile(DATA / "bathy_source.u8")
meta["filled"] = {
    "heights": "bathy_filled.r32",
    "source_mask": "bathy_source.u8",
    "public_source": f"{srtm_title} (NOAA ERDDAP srtm15plus, 15 arc-second)",
    "depth_min_m": float(filled.min()),
    "depth_max_m": float(filled.max()),
    "blend_cells": BLEND_CELLS,
}
(DATA / "bathy.json").write_text(json.dumps(meta, indent=2))
print(json.dumps(meta["filled"], indent=2))
