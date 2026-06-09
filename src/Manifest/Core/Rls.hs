module Manifest.Core.Rls
  ( PolicyCmd (..)
  , PolicyDef (..)
  , Policy (..)
  , policyDef
  ) where

import Data.ByteString (ByteString)

-- | Which commands a policy applies to.
data PolicyCmd = CmdAll | CmdSelect | CmdInsert | CmdUpdate | CmdDelete
  deriving (Eq, Show)

-- | An entity-erased policy: name, command, rendered USING / WITH CHECK SQL.
data PolicyDef = PolicyDef
  { pdName  :: ByteString
  , pdCmd   :: PolicyCmd
  , pdUsing :: Maybe ByteString
  , pdCheck :: Maybe ByteString
  } deriving (Eq, Show)

-- | A policy attached to entity @a@ (phantom). Built with the "Manifest.Rls" DSL.
newtype Policy a = Policy PolicyDef

policyDef :: Policy a -> PolicyDef
policyDef (Policy pd) = pd
