{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Derive a whole toolbox from a record of handlers: field names become
-- tool names, field types are the contracts, the value is nothing but the
-- functions.
--
-- @
-- data SupportTools es = SupportTools
--   { get_weather  :: Loc -> Eff es Sky
--   , current_time :: Eff es TimeResult     -- zero-arg form
--   } deriving (Generic)
--
-- agent = runToolAgent (tools supportTools)
-- @
--
-- Within one record duplicate tool names are impossible (the language
-- enforces field uniqueness) and a test stub must implement every field.
-- Tool names are limited to legal field names; use 'Crucible.Tool.toolWith'
-- or 'Crucible.Tool.rawTool' for irregular names. @tools a ++ tools b@ keeps
-- plain list semantics (first match wins in dispatch).
module Crucible.Tool.Generic
  ( tools
  , GTools (..)
  ) where

import Data.Proxy (Proxy (..))
import qualified Data.Text as T
import GHC.Generics
import GHC.TypeLits (KnownSymbol, symbolVal, TypeError, ErrorMessage (..))

import Effectful (Eff)

import Crucible.Codec (JSONCodec)
import qualified Crucible.Codec as C
import Crucible.Codec.Generic (HasCodec (codec))
import Crucible.Tool (Tool, toolWith)

-- | Harvest a toolbox from a single-constructor record of handlers.
--
-- The toolbox type must be parameterised by the effect row @es@ (e.g.
-- @data MyTools es = ...@); the @es@ in the argument and the @es@ in the
-- returned list are the same, so GHC can always infer the concrete row from
-- context without extra type annotations.
tools :: forall f es. (Generic (f es), GTools (Rep (f es)) es) => f es -> [Tool es]
tools = gtools . from

-- | The Rep walk. Instances cover: handler fields @i -> Eff es o@, zero-arg
-- fields @Eff es o@, products, and the D/C metadata wrappers.
class GTools rep es where
  gtools :: rep p -> [Tool es]

instance GTools f es => GTools (M1 D m f) es where
  gtools (M1 f) = gtools f

instance GTools f es => GTools (M1 C m f) es where
  gtools (M1 f) = gtools f

instance (GTools f es, GTools g es) => GTools (f :*: g) es where
  gtools (f :*: g) = gtools f ++ gtools g

-- handler field: i -> Eff es o
instance {-# OVERLAPPING #-} (KnownSymbol nm, HasCodec i, HasCodec o)
  => GTools (M1 S ('MetaSel ('Just nm) u s l) (K1 R (i -> Eff es o))) es where
  gtools (M1 (K1 f)) =
    [toolWith (T.pack (symbolVal (Proxy @nm))) (codec @i) (codec @o) f]

-- zero-arg field: Eff es o (empty-object schema; any args object accepted)
instance {-# OVERLAPPING #-} (KnownSymbol nm, HasCodec o)
  => GTools (M1 S ('MetaSel ('Just nm) u s l) (K1 R (Eff es o))) es where
  gtools (M1 (K1 m)) =
    [toolWith (T.pack (symbolVal (Proxy @nm))) unitCodec (codec @o) (\() -> m)]

-- non-handler field catch-all: OVERLAPPABLE so the OVERLAPPING handler/zero-arg
-- instances above win when GHC can determine the field type. A non-handler field
-- reaching here is a programming error caught by the TypeError constraint.
instance {-# OVERLAPPABLE #-} TypeError
  ( 'Text "Crucible.Tool.Generic: field '"
    ':<>: 'ShowType nm
    ':<>: 'Text "' is not a tool handler."
    ':$$: 'Text "Expected: i -> Eff es o   (or  Eff es o  for a zero-arg tool)"
    ':$$: 'Text "Got:      " ':<>: 'ShowType t )
  => GTools (M1 S ('MetaSel ('Just nm) u s l) (K1 R t)) es where
  gtools = error "unreachable: TypeError"

-- positional field
instance GTools (M1 S ('MetaSel 'Nothing u s l) (K1 R t)) es where
  gtools = error
    "Crucible.Tool.Generic: positional fields are not supported. \
    \Use named record fields; the field name becomes the tool name."

-- sum type
instance GTools (f :+: g) es where
  gtools = error
    "Crucible.Tool.Generic: sum types are not supported. \
    \A toolbox must be a single-constructor record."

-- empty record: a toolbox with no tools
instance GTools U1 es where
  gtools _ = []

-- | Input codec for zero-arg tools: an object with no fields. Decoding ()
-- accepts ANY object the model sends (including invented keys); a zero-arg
-- tool must not fail on enthusiastic argument guessing.
unitCodec :: JSONCodec ()
unitCodec = C.object (pure ())
