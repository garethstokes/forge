---
title: Row-level security
nav_order: 9
---

# Row-level security

Manifest can drive PostgreSQL Row-Level Security so multi-tenant access is enforced
by the database. You declare policies on the entity, the migration engine creates
them, and `withRlsContext` sets the per-request context the policies read.

## Declaring a policy

Policies are an entity method (`rlsPolicies`), with a typed predicate built from the
same `#label` columns the query builder uses. `currentSetting` reads a GUC variable;
`lit` is an inline literal:

```haskell
instance Entity Secret where
  -- … tableMeta / rowDecoder / rowEncode / primKey …
  rlsPolicies =
    [ policy "org_isolation"
        `using` (\s -> s ^. #secretOrg .== currentSetting "app.current_org") ]
```

`using` sets the `USING` predicate (SELECT/UPDATE/DELETE visibility); `withCheck`
sets `WITH CHECK` (INSERT/UPDATE); `forCommand` restricts a policy to one command.
Predicates use `lit` / `currentSetting`, not `val` (a policy is DDL, not a
parameterised query).

## Migrating policies

`migrate` / `migrateUp` reconcile the live database to the declared policies: they
`ENABLE` and `FORCE ROW LEVEL SECURITY` on policied tables, `CREATE` declared
policies that are absent, and `DROP` policies that are present but no longer
declared. Reconciliation is by policy name, so a fully-migrated schema is a no-op on
re-run.

## Setting the request context

`withRlsContext` sets GUC variables for the enclosing transaction with
`set_config(..., true)`, so they are LOCAL-scoped and cannot leak to the next pooled
connection. Use it inside `withTransaction`:

```haskell
withTransaction $ withRlsContext [("app.current_org", currentOrg)] $ do
  rows <- selectWhere []          -- only the current org's rows, enforced by Postgres
  ...
```

## Notes and limits

* RLS does not apply to superusers or roles with `BYPASSRLS`; connect as a normal
  application role. `FORCE ROW LEVEL SECURITY` makes policies apply to the table
  owner too.
* Policy bodies are reconciled by name. Changing a policy's predicate while keeping
  its name is not detected; rename the policy or drop it manually.
* Rows hidden by RLS are simply absent from reads. The identity map caches what was
  read; it does not cache negative lookups, so a row invisible under one context can
  be read under another.
* `SET ROLE`-based contexts and per-role policies (`TO role`) are not built; this is
  GUC-variable based.
