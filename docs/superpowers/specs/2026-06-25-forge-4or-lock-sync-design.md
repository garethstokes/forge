# forge-4or — Detect evals-ui/root zinc.lock drift

**Status:** Approved design (brainstorm complete) · **Date:** 2026-06-25
**Bead:** forge-4or

---

## Problem

`manifest-evals/evals-ui` is dual-purpose: a member of the root forge workspace
(native build) AND its own workspace root for the `wasm32-wasi` build. zinc builds
the entire lock closure per target, and the root `zinc.lock` carries native-only
deps (`postgresql-libpq`, `network`) that cannot cross-compile to wasm — so evals-ui
keeps its own `zinc.lock` (miso closure + the **aeson closure copied verbatim from
the root lock**). A future `zinc update` that bumps a shared dep in the root lock
will NOT touch evals-ui's lock, silently diverging the wasm build's dependency set.

There is no CI in this repo. The thing that reliably runs is `zinc test`.

## Decision

A **suite test** (`LockSyncSpec`) in the manifest-evals test suite that asserts every
dependency present in BOTH locks has a matching `sha256`. Drift fails `zinc test` with
a clear message. Chosen over a standalone script (not auto-run) and docs-only (relies
on memory). Eliminating the duplication (deriving the wasm lock from the root lock) is
the ideal end-state but needs a zinc feature (target-aware lock filtering) that does
not exist — filed upstream, out of scope here.

## Design

- **File:** `manifest-evals/test/LockSyncSpec.hs`, registered in
  `manifest-evals/test/Spec.hs` (chained `>> LockSyncSpec.main`, matching the suite's
  `main :: IO ()` / tiny `expect` harness style).
- **Paths:** `Spec.hs` anchors CWD to the member dir (`manifest-evals/`) at startup, so
  the locks are at stable relative paths: root = `../zinc.lock`, evals-ui =
  `evals-ui/zinc.lock`.
- **Parser (no TOML dep):** split the file into `[[locked]]` blocks; from each block
  read `name`, the version line (`vendored` or `rev`), and `sha256`. The lock format is
  rigid (no indentation, one field per line) so a line-based parser suffices.
- **Assertions:**
  1. For every dep name in BOTH locks, assert `sha256` is identical (STRICT on sha —
     any content difference fails). Report each drift as
     `name: root=<ver> <sha>  evals-ui=<ver> <sha>`.
  2. Assert the shared set is non-empty (~30+ from the aeson closure) — guards against a
     parser bug passing vacuously.
- **Excluded naturally:** miso / character-ps / other wasm-only deps are not in the root
  lock, so they are not in the intersection. No allowlist for now; the invariant is
  "shared deps are byte-identical". A deliberate wasm-specific divergence (none today)
  would be when an allowlist is introduced.

## Testing / verification

- The test PASSES on the current (in-sync) locks.
- Meaningfulness is verified by perturbing one `sha256` in `evals-ui/zinc.lock`,
  confirming the test FAILS with the drift message, then reverting.

## Out of scope / follow-up

- Deriving evals-ui's wasm lock from the root lock (needs zinc target-aware lock
  filtering) — file as a zinc feature request.
