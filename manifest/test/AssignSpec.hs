{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
module AssignSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import GHC.Generics (Generic)
import Manifest.Core.Assign (assignments)
import Manifest.Core.Table (Patch(..), Omitted(..))
import Harness

data Demo = Demo
  { dName  :: Patch String     -- Set -> emit, Keep -> skip
  , dAge   :: Patch Int        -- Keep -> skip
  , dNick  :: Maybe String     -- Just -> emit, Nothing -> skip
  , dPlain :: String           -- always emit
  , dSkip  :: Omitted          -- never emit
  } deriving Generic

tests :: [Test]
tests = group "Assign"
  [ test "emits Set/Just/plain fields, skips Keep/Nothing/Omitted, snake_case names" $
      assertEqual "assignments"
        [ (BC.pack "d_name",  Just (BC.pack "Ada"))
        , (BC.pack "d_nick",  Just (BC.pack "ada"))
        , (BC.pack "d_plain", Just (BC.pack "x"))
        ]
        (assignments (Demo { dName = Set "Ada", dAge = Keep, dNick = Just "ada"
                           , dPlain = "x", dSkip = Omitted }))
  ]
