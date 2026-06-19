# forge-i14 — Evaluate `barbies` for the HKD Core

**Status:** Recommendation (brainstorm complete) · **Date:** 2026-06-19
**Bead:** forge-i14 · **Blocks:** forge-2am (per-field read/write/autogen policy)

---

## Recommendation

**Keep the HKD Core hand-rolled. Borrow the vocabulary, not the dependency.**

`barbies` is well-made and the conceptual mapping is real (bmap = pick-a-face,
btraverse = applicative row decode, bzipWith = snapshot diff), but adopting it —
fully *or* the "Bare/Covered only" subset — does not pay for itself here. Use the
barbies class names as *conceptual anchors* (docs, the blog series, reasoning),
and optionally a doc-comment in `Table.hs` mapping each hand-rolled fold to its
barbies-class lineage, so the pedigree is legible without the dep.

## Why

### 1. The "Bare/Covered is the cleanest win" premise is already void
The bead's strongest case was *"Bare/Covered removes Identity noise from every
signature."* But `Field Identity a = Base a` (`Table.hs:43`) already collapses
`Identity` to a bare value **and** strips markers in one step:
`userId :: Field Identity (Pk Int)` reduces to `Int`, not `Identity Int`. There is
no Identity noise to remove. And `barbies`' `Wear Bare` could not do this job
anyway: it yields a bare `a` but cannot perform the `Pk Int → Int` marker-strip.
So "adopt Bare+codec only" buys nothing.

### 2. The shape mismatch is fundamental — and the consumer feature makes it total
`barbies` operates over a **fixed field set with a uniform `f a` wrapper**.
Manifest's value proposition is **per-field type families that branch on context**
(`Field`, soon the read/readwrite + policy markers of forge-2am). The consumer
feature changes a field's *type per context* (`Patch (Base a)`, `Maybe (Base a)`,
`Omitted`) — categorically outside what `bmap`/`btraverse`/`bzipWith` express.
Prior art agrees: opaleye and rel8 hand-roll their projections; none reach for
barbies.

### 3. The only replaceable surface is ~70 LOC of already-clean Generics
| Surface | LOC | barbies-replaceable? |
|---|---|---|
| `Manifest.Core.Table` — `Base`/`Field` families, `FieldMeta` | 76 | No — inner-type marker strip; barbies can't express it |
| `Codec` / `RowDecoder` | 156 | No — leaf profunctor codec, domain-specific |
| `GRowDecode`/`GRowEncode` (`Entity.hs:110`) | ~50 | Yes — `btraverse` + `AllB DbType` |
| `GColumns` (`Meta.hs:63`) | ~20 | Yes — `btraverse` + `AllB FieldMeta` |
| snapshot-diff (`Session.hs:213`) | ~18 | No — value-level `zip3` over `[SqlParam]`, not an HKD fold |

Net reduction if adopted: ~50–80 LOC, in exchange for a new dependency that
surfaces `FunctorB`/`TraversableB`/`ConstraintsB`/`AllB` in owned-Core signatures.

## Dependency cost
`barbies` is small and reputable, but it (a) surfaces four of its classes in
Core type signatures, (b) adds a dependency against the explicit *"thin owned
Core, borrow ideas not deps"* ethos (`README.md`, `manifest/spec/`), for (c) a
sub-100-LOC, low-clarity-gain change to code that is already readable. Cost/benefit
is negative.

## Impact summary (acceptance criteria)
- **`Manifest.Core.Table`:** no change. Extend with the read/readwrite + policy
  markers for forge-2am — barbies cannot touch this layer.
- **Codec + `GRowDecode`/`GRowEncode`/`GColumns`:** the only barbies-replaceable
  surface; keep — stable, readable, already threads `DbType`/`FieldMeta` per field.
- **Snapshot-diff fold:** value-level `zip3`; barbies irrelevant.
- **Dependency:** do **not** add `barbies`; do **not** add `product-profunctors`
  (see forge-2am — three projected shapes can't fit a 2-param profunctor).

## Forward note
forge-2am extends the owned approach (read/readwrite direction + composable policy
markers, `Field`-family projections, Generics folds unified over `Omitted`). This
is a deepening of the Core — exactly where barbies cannot follow.
