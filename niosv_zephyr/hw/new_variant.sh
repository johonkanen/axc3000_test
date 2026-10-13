#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# new_variant.sh <name> - clone hw/'s tracked SOURCE files (not generated
# build output) into a sibling niosv_zephyr/hw_<name>/ directory, for
# building a different hardware configuration in parallel with this one
# (e.g. while bringing up HyperRAM: different cache sizes, clock rates,
# ...). Uses `git ls-files` as the source/generated boundary, so it always
# matches .gitignore with no separate list to keep in sync.
#
#   ./new_variant.sh hyperram_experiment
#   cd ../hw_hyperram_experiment
#   # edit build_niosv_system.tcl / niosv_zephyr_top.vhd / ... for this variant
#   ./build_all.sh
# ---------------------------------------------------------------------------
set -euo pipefail

NAME="${1:?usage: new_variant.sh <name>}"
cd "$(git rev-parse --show-toplevel)"

DEST="niosv_zephyr/hw_$NAME"
if [ -e "$DEST" ]; then
    echo "already exists: $DEST" >&2
    exit 1
fi

mkdir -p "$DEST"
git ls-files niosv_zephyr/hw | while IFS= read -r f; do
    rel="${f#niosv_zephyr/hw/}"
    mkdir -p "$DEST/$(dirname "$rel")"
    cp "$f" "$DEST/$rel"
done
chmod +x "$DEST"/*.sh "$DEST"/gdb-wrapper/* 2>/dev/null || true

echo "created $DEST from the tracked source files in niosv_zephyr/hw/"
