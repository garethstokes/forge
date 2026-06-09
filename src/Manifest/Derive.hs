{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

-- | The @deriving via@ carrier's 'Entity' instance. With this instance in
-- scope, a plain entity is one line:
-- @deriving via (Table "posts" PostT) instance Entity Post@.
module Manifest.Derive
  ( Table(..)
  ) where

import qualified Data.ByteString.Char8 as BC
import Data.Coerce (coerce)
import Data.Functor.Identity (Identity)
import Data.Proxy (Proxy(..))
import GHC.Generics (Generic, Rep)
import GHC.TypeLits (KnownSymbol, symbolVal)
import Type.Reflection (Typeable)
import Manifest.Core.Codec (DbType)
import Manifest.Core.Meta (GColumns, genericTableMeta)
import Manifest.Core.Table (Exposed)
import Manifest.Entity
  ( Entity(..), Table(..), PrimKey, GRowDecode, GRowEncode
  , genericRowDecoder, genericRowEncode, genericPrimKey )

instance
  ( KnownSymbol name
  , Typeable (Table name t)
  , Generic (t Exposed), GColumns (Rep (t Exposed))
  , Generic (t Identity), GRowDecode (Rep (t Identity)), GRowEncode (Rep (t Identity))
  , DbType (PrimKey (Table name t))
  ) => Entity (Table name t) where
  -- coerce is sound: Table name t is a newtype over t Identity; TableMeta's param
  -- is phantom and RowDecoder's is representational.
  tableMeta  = coerce (genericTableMeta @t (BC.pack (symbolVal (Proxy @name))))
  rowDecoder = coerce (genericRowDecoder @(t Identity))
  rowEncode  (Table x) = genericRowEncode x
  primKey    = genericPrimKey
