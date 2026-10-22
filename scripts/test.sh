#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 -m unittest discover -s tests -p 'test_*.py' -v
binary="$PWD/build/ShotKit.app/Contents/MacOS/ShotKit"
if [ ! -x "$binary" ]; then
  echo 'Build the native app with zsh build.sh first.' >&2
  exit 1
fi
task_results="$(mktemp -d "${TMPDIR:-/tmp}/shotkit-tests.XXXXXX")"
trap 'rm -rf "$task_results"' EXIT
"$binary" selection-settings-selftest
"$binary" native-selftest "$task_results/geometry"
"$binary" selftest "$task_results/images"
