#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

# -define:ODIN_DEBUG=true so the Odin testing runner reports memory tracker stats.
ODIN_OPT="${ODIN_OPT:--debug}"

odin test tests $ODIN_OPT "$@"
