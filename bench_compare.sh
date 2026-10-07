#!/usr/bin/env bash
# Interleaved before/after timing of ImageInput::open() + spec().
#
# Usage:  ./bench_compare.sh <image> [runs]
#
# Expects two builds of oiio_open_bench next to this script:
#   build-base/oiio_open_bench  -> linked against the "before" OIIO install
#   build-pr/oiio_open_bench    -> linked against the "after" OIIO install
#
# Runs alternate before/after so that drift (thermal, background load) hits
# both sides equally. One warm-up run of each is discarded.

set -u
img=${1:?usage: $0 <image> [runs]}
runs=${2:-10}

# Default binaries are looked up next to this script, not in the current
# directory, so the script can be run from anywhere.
here=$(cd "$(dirname "$0")" && pwd)
B=${BEFORE:-$here/build-base/oiio_open_bench}
A=${AFTER:-$here/build-pr/oiio_open_bench}

[ -r "$img" ] || { echo "ERROR: image not found: $img"; exit 1; }

# --- Refuse to measure the wrong library -------------------------------------
fail=0
for b in "$B" "$A"; do
    if [ ! -x "$b" ]; then
        echo "ERROR: not found or not executable: $b"
        fail=1
        continue
    fi
    lib=$(ldd "$b" 2>/dev/null | awk '/libOpenImageIO\.so/ {print $3}')
    printf '%s\n    -> %s\n' "$b" "${lib:-<not resolved>}"
    case "$lib" in
        *vcpkg/installed*) echo "ERROR: loads vcpkg's OpenImageIO, not your build"; fail=1 ;;
        "")                echo "ERROR: could not resolve libOpenImageIO"; fail=1 ;;
    esac
done
if [ "$fail" -ne 0 ]; then
    echo
    echo "Build both benchmarks next to this script (build-base/, build-pr/),"
    echo "or point at existing binaries:"
    echo "  BEFORE=/path/to/before/bench AFTER=/path/to/after/bench $0 <image>"
    exit 1
fi
echo

extract() { sed -n 's/^open+spec: \([0-9.]*\) s.*/\1/p'; }

stats() {
    sort -g "$1" | awk '{ v[NR] = $1 } END {
        if (NR == 0) { print "no data"; exit }
        m = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
        printf "median %7.3f ms   range %7.3f - %7.3f ms   (n=%d)\n",
               m * 1000, v[1] * 1000, v[NR] * 1000, NR
    }'
}

out_b=$(mktemp); out_a=$(mktemp)
trap 'rm -f "$out_b" "$out_a"' EXIT

# Warm-up: page cache and dynamic loader. Discarded.
"$B" "$img" > /dev/null
"$A" "$img" > /dev/null

for i in $(seq "$runs"); do
    "$B" "$img" | extract >> "$out_b"
    "$A" "$img" | extract >> "$out_a"
done

echo "image:   $img"
printf 'before:  '; stats "$out_b"
printf 'after:   '; stats "$out_a"
