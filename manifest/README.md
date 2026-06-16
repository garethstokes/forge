# Manifest

A Haskell database / ORM library — **the Unit-of-Work layer Haskell never had.**

Haskell has excellent type-safe SQL *Core* layers (beam, rel8, esqueleto) but no SQLAlchemy-style
*ORM*: a `Session` with an identity map, change tracking that emits minimal `UPDATE`s, relationship
loading strategies, and cascades. Manifest fills that gap, on a thin owned Higher-Kinded-Data Core,
with a Generics-based derive layer for schema, CRUD, relationships, and migrations.

Sibling to [Lune](../lune).

## Status

Design phase. See [`spec/manifest_design_v0_1.md`](spec/manifest_design_v0_1.md) for the full
architecture and the settled design decisions.

First buildable slice: **Sub-project 1 — "Prove the UoW"** (single-table snapshot-diff Unit-of-Work,
end to end, on Postgres).
