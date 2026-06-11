#!/usr/bin/env bash
# Build the evals-ui miso wasm reactor and stage its artifacts into static/.
#
# The wasm build runs from evals-ui/ (its OWN zinc workspace + lock): zinc
# builds the entire lockfile closure for a target, and the root lock carries
# native-only deps (network, postgresql-libpq) that cannot cross-compile to
# wasm. evals-ui's lock closure is miso + the aeson closure (for the shared
# evals-api DTO package, a "../evals-api" member of the evals-ui workspace).
#
# DUAL PINS (keep in sync with the root workspace):
#  - miso: pinned in BOTH root zinc.toml and evals-ui/zinc.toml (same rev).
#  - aeson + its ~40-package vendored closure: [[locked]] entries copied
#    VERBATIM from the root zinc.lock into evals-ui/zinc.lock (same versions
#    + sha256), EXCEPT os-string, which is dropped from the wasm lock — the
#    wasm toolchain's GHC (9.14, vs native 9.12.2) ships os-string as a boot
#    library, and the vendored 2.0.10 needs 9.14's template-haskell-lift split;
#    zinc resolves the dangling "os-string" dep edge to the boot unit-id.
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
