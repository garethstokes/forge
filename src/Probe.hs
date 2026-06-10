{-# LANGUAGE OverloadedStrings #-}
module Probe where
import Manifest (DbType)
import Crucible.LLM (Message(..), Role(..), complete)
probe :: [Message]
probe = [Message System "ping"]
