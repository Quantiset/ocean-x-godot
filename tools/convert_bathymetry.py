# /// script
# dependencies = ["numpy", "tifffile", "imagecodecs"]
# ///
"""Convert an OceanX bathymetry GeoTIFF (float32, UTM) into files Godot can read.

Outputs (in ../data):
  bathy.r32           raw little-endian float32 depths, row-major, north row first
  bathy.json          grid size, cell size, UTM origin, depth range, nodata value
  bathy_heightmap.png 16-bit grayscale heightmap (black = no data, white = shallowest)

Usage:  uv run tools/convert_bathymetry.py [path/to/_fp.tif]
"""
import json
import sys
from pathlib import Path

import imagecodecs
import numpy as np
import tifffile

DEFAULT_SRC = (Path(__file__).resolve().parents[2] / "OXR20260428/Vessel/Acoustics/Processed/Final/bathy_grid"
               / "OXR20260428_Bathy_Final_EM304_PalauLeg1_75m_WGS84UTM53N_fp.tif")
OUT = Path(__file__).resolve().parents[1] / "data"
NODATA = -9999.0

src = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SRC
with tifffile.TiffFile(src) as tif:
    page = tif.pages[0]
    depth = page.asarray().astype(np.float32)
    sx, sy, _ = page.tags["ModelPixelScaleTag"].value
    _, _, _, x0, y0, _ = page.tags["ModelTiepointTag"].value
    nodata = float(page.tags["GDAL_NODATA"].value.strip("\x00 ")) if "GDAL_NODATA" in page.tags else NODATA

valid = np.isfinite(depth) & (depth != nodata)
# Crop to the area that actually has soundings.
rows, cols = np.where(valid.any(axis=1))[0], np.where(valid.any(axis=0))[0]
r0, r1, c0, c1 = rows[0], rows[-1] + 1, cols[0], cols[-1] + 1
depth, valid = depth[r0:r1, c0:c1], valid[r0:r1, c0:c1]
depth[~valid] = NODATA

h, w = depth.shape
dmin, dmax = float(depth[valid].min()), float(depth[valid].max())
OUT.mkdir(exist_ok=True)
depth.astype("<f4").tofile(OUT / "bathy.r32")

png = np.zeros((h, w), np.uint16)
png[valid] = 1 + np.round((depth[valid] - dmin) / (dmax - dmin) * 65534).astype(np.uint16)
(OUT / "bathy_heightmap.png").write_bytes(imagecodecs.png_encode(png))

meta = {
    "source": src.name,
    "width": w, "height": h,
    "cell_size_m": [sx, sy],
    "utm_zone": "53N (EPSG:32653)",
    "origin_utm_top_left": [x0 + c0 * sx, y0 - r0 * sy],
    "depth_min_m": dmin, "depth_max_m": dmax,
    "nodata": NODATA,
    "valid_fraction": float(valid.mean()),
}
(OUT / "bathy.json").write_text(json.dumps(meta, indent=2))
print(json.dumps(meta, indent=2))
