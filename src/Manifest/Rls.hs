{-# LANGUAGE ScopedTypeVariables #-}

module Manifest.Rls
  ( policy
  , using
  , withCheck
  , forCommand
  ) where

import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Manifest.Core.Rls (Policy (..), PolicyCmd (..), PolicyDef (..))
import Manifest.Query (Expr, Self (..), renderPredicate)

-- | A bare policy (FOR ALL, no predicates). Refine with 'using'/'withCheck'/'forCommand'.
policy :: Text -> Policy a
policy name = Policy (PolicyDef (TE.encodeUtf8 name) CmdAll Nothing Nothing)

-- | Set the USING predicate.
using :: forall a. Policy a -> (Self a -> Expr Bool) -> Policy a
using (Policy pd) f = Policy pd { pdUsing = Just (renderPredicate (f Self)) }

-- | Set the WITH CHECK predicate (for INSERT/UPDATE).
withCheck :: forall a. Policy a -> (Self a -> Expr Bool) -> Policy a
withCheck (Policy pd) f = Policy pd { pdCheck = Just (renderPredicate (f Self)) }

-- | Restrict the policy to one command (default 'CmdAll').
forCommand :: Policy a -> PolicyCmd -> Policy a
forCommand (Policy pd) c = Policy pd { pdCmd = c }
