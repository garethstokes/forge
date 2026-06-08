---
title: Tutorials
nav_order: 9
has_children: true
---

# Tutorials

These pages are literate Haskell. Each one is a `.lhs` file under
`docs/tutorials/Tutorial/`, and each is wired into the test suite as a runnable
test: the suite compiles the page's `haskell` code blocks and runs them against a
real Postgres. The code you read here is the code that runs. If a change broke a
tutorial it would break a test, so these examples cannot silently rot. (The suite,
like the library, needs a Postgres; it spins up an ephemeral one per run.)

- **[Unit of Work](Tutorial/UnitOfWork.lhs)**: edit a plain value, get a minimal
  `UPDATE`. The snapshot-diff the session is built around.
- **[Relationships](Tutorial/Relationships.lhs)**: load related rows two ways, the
  A-path (`load`) and the D-path (`Ent` / `with` / `rel`), and `selectin` vs
  `joined`.
- **[Cascades](Tutorial/Cascades.lhs)**: delete a parent and its children go too,
  via onDelete policies declared on the parent entity and applied at flush.
