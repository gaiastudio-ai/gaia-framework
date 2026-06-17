#!/usr/bin/env bash
# generate-fixtures.sh — create tiny pre-generated PNG fixtures for pixel-diff
# bats tests. Run once; commit the PNGs so tests need no ImageMagick at runtime.
#
# Requires: ImageMagick 'convert' on PATH, OR python3 as fallback.
#
# Produces:
#   baseline-375.png   — 10x10 white PNG (simulates a baseline screenshot)
#   baseline-768.png   — 10x10 white PNG
#   baseline-1440.png  — 10x10 white PNG
#   screenshot-375.png — 10x10 white PNG (identical to baseline — PASS)
#   screenshot-768.png — 10x10 white PNG (identical to baseline — PASS)
#   screenshot-1440.png— 10x10 white PNG (identical to baseline — PASS)
#   screenshot-768-drifted.png — 10x10 red PNG (differs from baseline — FAIL)
#   screenshot-375-1pct.png — 10x10 white with pixel (0,0) red (1% diff from baseline)
#   screenshot-masked-changed.png — 10x10 with a changed region for mask tests

set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "$0")" && pwd)"

if command -v convert >/dev/null 2>&1; then
  # White 10x10 baselines
  for bp in 375 768 1440; do
    convert -size 10x10 xc:white "$FIXTURE_DIR/baseline-${bp}.png"
    convert -size 10x10 xc:white "$FIXTURE_DIR/screenshot-${bp}.png"
  done

  # Drifted screenshot: red 10x10 (all pixels differ from white baseline)
  convert -size 10x10 xc:red "$FIXTURE_DIR/screenshot-768-drifted.png"

  # 1-pixel diff: white 10x10 with pixel (0,0) red => AE=1, 1.00% on 10x10
  convert -size 10x10 xc:white -fill red -draw "point 0,0" \
    "$FIXTURE_DIR/screenshot-375-1pct.png"

  # Screenshot with a region changed (top-left 5x5 red, rest white) for mask tests
  convert -size 10x10 xc:white -fill red -draw "rectangle 0,0 4,4" \
    "$FIXTURE_DIR/screenshot-masked-changed.png"

elif command -v python3 >/dev/null 2>&1; then
  python3 - "$FIXTURE_DIR" <<'PYEOF'
import struct, zlib, os, sys

FIXTURE_DIR = sys.argv[1]

def create_png(path, width, height, r, g, b):
    sig = b'\x89PNG\r\n\x1a\n'
    ihdr_data = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    ihdr_crc = zlib.crc32(b'IHDR' + ihdr_data) & 0xFFFFFFFF
    ihdr = struct.pack('>I', 13) + b'IHDR' + ihdr_data + struct.pack('>I', ihdr_crc)
    raw = b''
    for y in range(height):
        raw += b'\x00'
        for x in range(width):
            raw += bytes([r, g, b])
    compressed = zlib.compress(raw)
    idat_crc = zlib.crc32(b'IDAT' + compressed) & 0xFFFFFFFF
    idat = struct.pack('>I', len(compressed)) + b'IDAT' + compressed + struct.pack('>I', idat_crc)
    iend_crc = zlib.crc32(b'IEND') & 0xFFFFFFFF
    iend = struct.pack('>I', 0) + b'IEND' + struct.pack('>I', iend_crc)
    with open(path, 'wb') as f:
        f.write(sig + ihdr + idat + iend)

def create_png_with_region(path, width, height, bg, region, fg):
    sig = b'\x89PNG\r\n\x1a\n'
    ihdr_data = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    ihdr_crc = zlib.crc32(b'IHDR' + ihdr_data) & 0xFFFFFFFF
    ihdr = struct.pack('>I', 13) + b'IHDR' + ihdr_data + struct.pack('>I', ihdr_crc)
    rx, ry, rw, rh = region
    raw = b''
    for y in range(height):
        raw += b'\x00'
        for x in range(width):
            if rx <= x < rx + rw and ry <= y < ry + rh:
                raw += bytes(fg)
            else:
                raw += bytes(bg)
    compressed = zlib.compress(raw)
    idat_crc = zlib.crc32(b'IDAT' + compressed) & 0xFFFFFFFF
    idat = struct.pack('>I', len(compressed)) + b'IDAT' + compressed + struct.pack('>I', idat_crc)
    iend_crc = zlib.crc32(b'IEND') & 0xFFFFFFFF
    iend = struct.pack('>I', 0) + b'IEND' + struct.pack('>I', iend_crc)
    with open(path, 'wb') as f:
        f.write(sig + ihdr + idat + iend)

for bp in [375, 768, 1440]:
    create_png(os.path.join(FIXTURE_DIR, f'baseline-{bp}.png'), 10, 10, 255, 255, 255)
    create_png(os.path.join(FIXTURE_DIR, f'screenshot-{bp}.png'), 10, 10, 255, 255, 255)

create_png(os.path.join(FIXTURE_DIR, 'screenshot-768-drifted.png'), 10, 10, 255, 0, 0)
# 1-pixel diff: white 10x10 with pixel (0,0) red => AE=1, 1.00% on 10x10
create_png_with_region(os.path.join(FIXTURE_DIR, 'screenshot-375-1pct.png'),
                       10, 10, [255,255,255], (0,0,1,1), [255,0,0])
create_png_with_region(os.path.join(FIXTURE_DIR, 'screenshot-masked-changed.png'),
                       10, 10, [255,255,255], (0,0,5,5), [255,0,0])
PYEOF

else
  printf 'generate-fixtures.sh: neither convert nor python3 found\n' >&2
  exit 1
fi

printf 'generate-fixtures.sh: created fixture PNGs in %s\n' "$FIXTURE_DIR"
