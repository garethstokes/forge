# Rename `HasRelation.Target` → `Related` — Design

**Status:** Approved design (brainstorm complete). · **Date:** 2026-06-11 · **Issue:** manifest-jkq

**Goal:** Entities can be named `Target` (a plausible noun — the eval schema has
one) without clashing with `HasRelation`'s associated type family. The family
becomes `Related`: `type Related User "posts" = [Post]`,
`load :: HasRelation a name => Rel a name -> a -> Db (Related a name)`.

## 1. The rename (manifest)

- `Manifest.Core.Relation`: `type Target a name :: Type` → `type Related a
  name :: Type`; `relSpec :: RelSpec (Related a name)`; haddocks updated.
  `Cardinality` is unchanged.
- Library signatures follow mechanically: `Manifest.Relation` (`load`,
  `loadRel`, the `through` constraints `Related a n1 ~ [mid]` etc.) and
  `Manifest.Relation.Loaded` (`joined`/`joinedLoad`/`rel` constraints).
- **Clean break, no deprecated alias.** All callers are in-house, and an alias
  would keep exporting the clashing name — defeating the point. The umbrella
  `Manifest` export changes implicitly via `HasRelation(..)`.
- Verified pre-conditions: `Related` is unused anywhere in manifest src/test/
  tutorials; the literate tutorials declare no `type Target` instances; the
  only manual page referencing the family is `docs/relationships.md`.

## 2. Consumers

- `test/Fixtures.hs`: 6 `type Target X "rel" = ...` instances → `type Related`.
- `docs/relationships.md`: the same one-word rename in its code blocks/prose.
- Historical documents under `docs/superpowers/{plans,specs}` are records, not
  documentation — untouched.

## 3. The payoff (manifest-evals, follow-up after re-pin)

`Evals.Schema` drops every workaround the clash forced:

- `import Manifest` without `hiding (Target)` (also in `Evals.Migrate` and the
  test modules that hide it).
- No qualified `T.Target` instance heads.
- `Evals.Schema.Types` merges back into `Evals.Schema` as one module — the
  split existed solely so the `Target` ENTITY synonym and the family could
  coexist. `Evals.Schema` keeps exporting the same names, so
  `Evals.Execute`/`Evals.Execute.Anthropic`/tests are untouched apart from
  hiding-list cleanups.

## 4. Testing & risk

Pure compile-time rename. The manifest suite (147/147, including the
relationship/joined/self-ref specs that exercise every `Related` signature)
and the manifest-evals suite (SchemaSpec + ExecuteSpec) are the proof. Sweep
greps (`Target a name`, `type Target`, `hiding (Target)`) confirm no
stragglers outside historical docs.

## 5. Out of scope

- Renaming anything else in the relation vocabulary (`Rel`, `RelSpec`,
  `Cardinality`).
- A deprecation/compat shim.
- Any behavioural change.
