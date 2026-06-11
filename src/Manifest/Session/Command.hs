{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | The explicit-command escape hatch: blind/bulk writes that bypass the
-- identity map and snapshot diff. 'update' issues an @UPDATE ... WHERE pk = $n@
-- for a single key; 'deleteWhere' issues a bulk @DELETE@ over arbitrary
-- conditions. Both run through 'execDb' (logged, autocommit) and touch neither
-- the pending queue nor the baseline snapshot.
module Manifest.Session.Command
  ( update
  , deleteWhere
  ) where

import Manifest.Core.Codec (DbType, encode)
import Manifest.Core.Meta (TableMeta(..), pkColumn, cmName)
import Manifest.Core.Query (Assign(..), Cond(..))
import Manifest.Core.Sql (renderConds, renderUpdate)
import Manifest.Entity (Entity(..), Key(..), PrimKey)
import Manifest.Session (Db, execDb, emitChange)

-- | Blind single-row UPDATE by primary key. Sets the given assignments with no
-- snapshot diff; the PK placeholder is bound LAST (after the SET values).
update :: forall a. (Entity a, DbType (PrimKey a)) => Key a -> [Assign a] -> Db ()
update key assigns = do
  let tm  = tableMeta @a
      sql = renderUpdate tm [ c | Assign c _ <- assigns ] (cmName (pkColumn tm))
      ps  = [ v | Assign _ v <- assigns ] ++ [ encode (unKey key) ]
  _ <- execDb sql ps
  emitChange @a (encode (unKey key))

-- | Bulk DELETE over arbitrary (ANDed) conditions. No per-row identity.
deleteWhere :: forall a. Entity a => [Cond a] -> Db ()
deleteWhere conds = do
  let tm                = tableMeta @a
      (whereTxt, _)     = renderConds 1 conds
      sql               = "DELETE FROM " <> tmTable tm <> whereTxt
      ps                = [ v | Cond _ _ v <- conds ]
  _ <- execDb sql ps
  emitChange @a Nothing
