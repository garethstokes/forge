{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Manifest.Core.Query
  ( Column(..)
  , Rel(..)
  , Op(..)
  , Cond(..)
  , Assign(..)
  , (==.), (/=.), (>.), (<.)
  , (=.)
  ) where

import Data.ByteString (ByteString)
import Data.Kind (Type)
import Data.Proxy (Proxy(..))
import GHC.OverloadedLabels (IsLabel(..))
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)
import Manifest.Core.Codec (SqlParam, DbType, encode)
import Manifest.Core.Meta (camelToSnake)

-- | A typed reference to column @t@ of table @a@. @#userName :: Column User Text@.
-- The column name is computed from the label via the same camel→snake rule the
-- deriver uses, so labels and metadata agree.
newtype Column a (t :: Type) = Column { colName :: ByteString }

instance (KnownSymbol name) => IsLabel name (Column a t) where
  fromLabel = Column (camelToSnake (symbolVal (Proxy @name)))

-- | A typed reference to /relation/ @name@ of entity @a@. Unlike 'Column', whose
-- phantom is the column's value type, a relation reference carries the relation
-- name 'Symbol' itself in its phantom, so @#posts :: Rel User "posts"@ pins the
-- relation @name@ from the @#label@ alone. This is what @load@ / @selectin@ take.
newtype Rel a (name :: Symbol) = Rel ByteString

-- | The single, non-overlapping instance: the label 'Symbol' /is/ the phantom, so
-- @#posts@ unambiguously elaborates to @Rel a \"posts\"@. The @name ~ name'@
-- equality lets GHC improve the phantom from the label (and vice-versa).
instance (KnownSymbol name, name ~ name') => IsLabel name (Rel a name') where
  fromLabel = Rel (camelToSnake (symbolVal (Proxy @name)))

-- | Comparison operators supported in SP1.
data Op = OpEq | OpNeq | OpGt | OpLt
  deriving (Eq, Show)

-- | A single condition: @column op value@. A list of conditions is ANDed.
data Cond a = Cond ByteString Op SqlParam
  deriving (Eq, Show)

-- | A single SET assignment in the command path.
data Assign a = Assign ByteString SqlParam
  deriving (Eq, Show)

infix 4 ==., /=., >., <.
(==.), (/=.), (>.), (<.) :: DbType t => Column a t -> t -> Cond a
Column n ==. v = Cond n OpEq  (encode v)
Column n /=. v = Cond n OpNeq (encode v)
Column n >.  v = Cond n OpGt  (encode v)
Column n <.  v = Cond n OpLt  (encode v)

infix 4 =.
(=.) :: DbType t => Column a t -> t -> Assign a
Column n =. v = Assign n (encode v)
