{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Manifest.Core.Meta
  ( ColumnMeta(..)
  , TableMeta(..)
  , camelToSnake
  , pkColumn
  , GColumns(..)
  , genericTableMeta
  ) where

import Data.Char (isUpper, toLower)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.Functor.Identity (Identity)
import Data.Kind (Type)
import Data.List (find)
import GHC.Generics
import Manifest.Core.Table (Exposed, FieldMeta(..))

-- | One column's persistence metadata.
data ColumnMeta = ColumnMeta
  { cmName     :: ByteString
  , cmIsPK     :: Bool
  , cmIsSerial :: Bool
  } deriving (Eq, Show)

-- | A table's metadata. Phantom @a@ ties it to the runtime row type.
data TableMeta a = TableMeta
  { tmTable   :: ByteString
  , tmColumns :: [ColumnMeta]
  } deriving (Eq, Show)

-- | The single primary-key column (SP1 assumes exactly one).
pkColumn :: TableMeta a -> ColumnMeta
pkColumn tm = case find cmIsPK (tmColumns tm) of
  Just c  -> c
  Nothing -> error ("Manifest: table " <> BC.unpack (tmTable tm) <> " has no primary key")

-- | camelCase → snake_case, no prefix stripping. @userName@ → @user_name@.
camelToSnake :: String -> ByteString
camelToSnake = BC.pack . go
  where
    go [] = []
    go (c:cs)
      | isUpper c = '_' : toLower c : go cs
      | otherwise = c : go cs

-- | Derive @[ColumnMeta]@ from a Generic rep of @t Exposed@.
class GColumns (rep :: Type -> Type) where
  gColumns :: [ColumnMeta]

instance GColumns f => GColumns (D1 m f) where gColumns = gColumns @f
instance GColumns f => GColumns (C1 m f) where gColumns = gColumns @f
instance (GColumns a, GColumns b) => GColumns (a :*: b) where
  gColumns = gColumns @a ++ gColumns @b

instance (Selector m, FieldMeta t) => GColumns (S1 m (Rec0 (Exposed t))) where
  gColumns =
    [ ColumnMeta
        { cmName     = camelToSnake (selName (undefined :: S1 m (Rec0 (Exposed t)) p))
        , cmIsPK     = fieldIsPK @t
        , cmIsSerial = fieldIsSerial @t
        }
    ]

-- | Build a 'TableMeta' for @t Identity@ from the Generic rep of @t Exposed@.
genericTableMeta
  :: forall t. (Generic (t Exposed), GColumns (Rep (t Exposed)))
  => ByteString
  -> TableMeta (t Identity)
genericTableMeta name =
  TableMeta { tmTable = name, tmColumns = gColumns @(Rep (t Exposed)) }
