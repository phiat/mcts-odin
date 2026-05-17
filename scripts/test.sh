#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

# -debug enables Odin's memory tracker so leaks fail the suite.
ODIN_OPT="${ODIN_OPT:--debug}"

# Each suite is a separate Odin package, so test them individually.
SUITES=(
	tests
	tests/games/amazons
	tests/games/breakthrough
	tests/games/connect_four
	tests/games/dots_and_boxes
	tests/games/go
	tests/games/gomoku
	tests/games/hex
	tests/games/morris
	tests/games/quoridor
	tests/games/reversi
)

for s in "${SUITES[@]}"; do
	echo "=== $s ==="
	odin test "$s" $ODIN_OPT "$@"
done
