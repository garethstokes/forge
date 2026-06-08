{-# LANGUAGE TemplateHaskell #-}

-- | A Template Haskell front-end for declaring entities. @mkEntity@ generates
-- the HKD record + @deriving Generic@ + the @type E = ET Identity@ synonym +
-- the @Entity@ instance from a terse field list — the same code one would write
-- by hand (see @test/Fixtures.hs@), with none of the boilerplate.
--
-- Required pragmas at the splice site: TemplateHaskell, TypeFamilies,
-- TypeApplications, DeriveGeneric, FlexibleInstances.
module Manifest.Derive.TH
  ( mkEntity
  , field
  ) where

import Data.Char (toLower, toUpper)
import Data.Functor.Identity (Identity)
import Data.String (fromString)
import GHC.Generics (Generic)
import Language.Haskell.TH
import Manifest.Core.Meta (genericTableMeta)
import Manifest.Core.Table (Col, PrimaryKey, Serial)
import Manifest.Entity (Entity (..), genericRowDecoder, genericRowEncode)

-- | One field in a terse entity declaration: a short name (the record selector
-- without the entity-name prefix) and its marker/runtime type. @field = (,)@.
field :: String -> Q Type -> (String, Q Type)
field = (,)

-- | Generate an entity. @mkEntity "Widget" "widgets" [field "id" …, …]@ emits
-- @data WidgetT f = Widget { widgetId :: Col f …, … } deriving Generic@,
-- @type Widget = WidgetT Identity@, and @instance Entity Widget@.
--
-- Exactly one field must have type @PrimaryKey …@; it becomes @primKey@ and
-- determines @type PrimKey@.
mkEntity :: String -> String -> [(String, Q Type)] -> Q [Dec]
mkEntity ename table fields = do
  let tyName  = mkName (ename ++ "T")
      conName = mkName ename
      synName = mkName ename
      prefix  = lower1 ename
      selName short = mkName (prefix ++ upper1 short)
  f <- newName "f"
  resolved <- mapM (\(s, qt) -> fmap ((,) s) qt) fields
  pkShort <- case [ s | (s, t) <- resolved, isPrimaryKey t ] of
    [s] -> pure s
    []  -> fail ("mkEntity: entity " ++ ename ++ " has no PrimaryKey field")
    _   -> fail ("mkEntity: entity " ++ ename ++ " has multiple PrimaryKey fields")
  pkType <- maybe (fail "mkEntity: internal: PK type lost") pure (lookup pkShort resolved)
  -- Reduce @Base pkType@ at macro time so the emitted @type PrimKey@ is a
  -- concrete type (e.g. @Int@), matching the hand-written instances and
  -- avoiding the need for UndecidableInstances at the splice site.
  let primKeyType = baseReduce pkType

  let recFields =
        [ varBangType (selName s)
            (bangType (bang noSourceUnpackedness noSourceStrictness)
                      [t| Col $(varT f) $(pure t) |])
        | (s, t) <- resolved
        ]
  dataDec <- dataD (pure []) tyName [plainTV f] Nothing
               [ recC conName recFields ]
               [ derivClause Nothing [ conT ''Generic ] ]

  synDec <- tySynD synName [] [t| $(conT tyName) Identity |]

  let tableMetaE =
        appE (appTypeE (varE 'genericTableMeta) (conT tyName))
             (appE (varE 'fromString) (litE (stringL table)))
  instDec <- instanceD (pure []) [t| Entity $(conT synName) |]
    [ tySynInstD (tySynEqn Nothing [t| PrimKey $(conT synName) |] (pure primKeyType))
    , funD 'tableMeta  [clause [] (normalB tableMetaE) []]
    , funD 'rowDecoder [clause [] (normalB (varE 'genericRowDecoder)) []]
    , funD 'rowEncode  [clause [] (normalB (varE 'genericRowEncode)) []]
    , funD 'primKey    [clause [] (normalB (varE (selName pkShort))) []]
    ]

  pure [dataDec, synDec, instDec]

-- | Reduce a type the way the @Base@ type family does: strip @PrimaryKey@ and
-- @Serial@ wrappers down to the runtime base type. Mirrors the equations in
-- "Manifest.Core.Table" so the generated @type PrimKey@ is concrete.
baseReduce :: Type -> Type
baseReduce = go
  where
    go (ParensT a)           = go a
    go (SigT a _)            = go a
    go (AppT (ConT n) inner)
      | n == ''PrimaryKey    = go inner
      | n == ''Serial        = peel inner
    go a                     = a
    -- @Serial@'s argument is already the base type; just discard markers/sigs.
    peel (ParensT a)         = peel a
    peel (SigT a _)          = peel a
    peel a                   = a

-- | Structurally: is a resolved type @PrimaryKey …@ ?
isPrimaryKey :: Type -> Bool
isPrimaryKey = go
  where
    go (AppT a _)  = go a
    go (ParensT a) = go a
    go (SigT a _)  = go a
    go (ConT n)    = n == ''PrimaryKey
    go _           = False

lower1, upper1 :: String -> String
lower1 []     = []
lower1 (c:cs) = toLower c : cs
upper1 []     = []
upper1 (c:cs) = toUpper c : cs
