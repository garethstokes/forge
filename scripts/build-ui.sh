#!/usr/bin/env bash
# Build the evals-ui miso wasm reactor and stage its artifacts into static/.
#
# The wasm build runs from evals-ui/ (its OWN zinc workspace + lock): zinc
# builds the entire lockfile closure for a target, and the root lock carries
# native-only deps (network, postgresql-libpq) that cannot cross-compile to
# wasm. evals-ui's lock closure is just miso.
set -euo pipefail

cd "$(dirname "$0")/.."

(cd evals-ui && nix develop .. -c zinc build --target wasm32-wasi)

cp -v evals-ui/.zinc/build/evals-ui.wasm static/
cp -v evals-ui/.zinc/build/ghc_wasm_jsffi.js static/
# miso's js-sources, surfaced by zinc next to the .wasm. miso 1.11 TH-embeds
# js/miso.js into the wasm (the loader does not fetch it); staged anyway so a
# future non-embedded framework JS has a serving path.
mkdir -p static/js
cp -v evals-ui/.zinc/build/js/miso.js static/js/

echo "done. serve with: EVALS_STATIC_DIR=static .zinc/build/evals-dashboard"
