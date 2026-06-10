{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
module ExecuteSpec (main) where

import Control.Monad (unless)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Either (isLeft)
import Data.Text (Text)
import Crucible.LLM (Message (..), Role (..))
import Evals.Execute

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

main :: IO ()
main = do
  assemblySpec
  putStrLn "manifest-evals ExecuteSpec: assembly OK"

-- decodeInput / assembleMessages are pure; no DB, no network.
assemblySpec :: IO ()
assemblySpec = do
  -- a JSON string input becomes a single User message
  expect "string input -> [User]"
    (decodeInput (toJSON ("2+2?" :: Text)) == Right [Message User "2+2?"])
  -- {"messages": [...]} round-trips roles
  let multi = object
        [ "messages" .=
            [ object ["role" .= ("user" :: Text),      "content" .= ("q1" :: Text)]
            , object ["role" .= ("assistant" :: Text), "content" .= ("a1" :: Text)]
            , object ["role" .= ("user" :: Text),      "content" .= ("q2" :: Text)]
            ]
        ]
  expect "messages input -> turns"
    (decodeInput multi == Right [Message User "q1", Message Assistant "a1", Message User "q2"])
  -- an unknown role and a non-string/object input are decode errors
  let badRole = object ["messages" .= [object ["role" .= ("robot" :: Text), "content" .= ("x" :: Text)]]]
  expect "unknown role is an error" (isLeft (decodeInput badRole))
  expect "number input is an error" (isLeft (decodeInput (toJSON (42 :: Int))))
