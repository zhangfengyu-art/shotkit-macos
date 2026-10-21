#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 -m unittest discover -s tests -p 'test_*.py' -v
lua -e 'local r=dofile("tests/snap.lua"); assert(r.ok); print("Snap: "..r.tests.." assertions passed")'
lua -e 'local r=dofile("tests/overlay.lua"); assert(r.ok); print("Overlay: "..r.tests.." assertions passed; idle canvas writes: "..r.idleCanvasWrites)'
