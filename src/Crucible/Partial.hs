{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeOperators #-}

-- | Incremental decoding of one growing JSON object over 'Emit': as deltas
-- arrive, close the partial buffer to valid JSON and decode it through a
-- caller-supplied all-optional codec, so the caller receives progressively
-- more complete typed partial values. This is to one growing object what
-- "Crucible.Rows" is to JSONL lines. The caller writes the partial type
-- (every field 'Maybe') and its codec; crucible does not generate it.
module Crucible.Partial
  ( closeJson
  , runPartialWith
  , runPartial
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Effectful
import Effectful.Dispatch.Dynamic (reinterpret)
import Effectful.State.Static.Local (get, modify, put, runState)

import Crucible.Emit (Emit (..))
import Crucible.Decode (DecodeError, decodeLLM)
import Crucible.Codec (JSONCodec)

-- | Close a partial JSON buffer for a single top-level object into the
-- longest valid JSON it can form. Performs a left-to-right scan tracking:
--   - open-bracket stack (innermost first: '{' or '[')
--   - whether we are inside a JSON string
--   - whether an escape is pending (backslash seen)
--   - whether the innermost '{' context is in key position (before the ':')
--
-- Blank input or input whose first non-space char is not '{' is returned
-- unchanged.  In all other cases, dangling syntax is trimmed and open
-- brackets are closed.
closeJson :: Text -> Text
closeJson t
  | T.null (T.strip t)        = t
  | T.head (T.strip t) /= '{' = t
  | otherwise                  =
      let ScanResult{..} = scanAll t
      in  buildClosed srText srStack srInStr srEsc srInKey

-- | Result of scanning the full input text.
data ScanResult = ScanResult
  { srText  :: !Text   -- the full input text (unchanged)
  , srStack :: ![Char] -- remaining open-bracket stack, innermost first
  , srInStr :: !Bool   -- ended inside a string
  , srEsc   :: !Bool   -- escape pending
  , srInKey :: !Bool   -- innermost '{' is in key position
  }

-- | Scan the entire text, returning the state at the end.
-- 'inKey' tracks whether the innermost object context is awaiting a value
-- (True means we are "in key position" — the current key has no ':' yet,
-- or we are between the '{' / ',' and the next key's opening '"').
scanAll :: Text -> ScanResult
scanAll t = go 0 [] False False True
  where
    len = T.length t

    go :: Int -> [Char] -> Bool -> Bool -> Bool -> ScanResult
    go i stk inStr esc inKey
      | i >= len  = ScanResult t stk inStr esc inKey
      | otherwise =
          let c = T.index t i
          in if inStr
             then if esc
                  then go (i+1) stk True  False inKey
                  else case c of
                         '"'  -> go (i+1) stk False False inKey
                         '\\' -> go (i+1) stk True  True  inKey
                         _    -> go (i+1) stk True  False inKey
             else case c of
               '"'  -> go (i+1) stk True  False inKey
               '{' ->
                 -- Push current inKey onto notional stack; new context is
                 -- in key position (empty object, waiting for first key or '}')
                 go (i+1) ('{':stk) False False True
               '[' ->
                 go (i+1) ('[':stk) False False False
               '}' ->
                 case stk of
                   (_:rest) -> go (i+1) rest False False (newInKey rest)
                   []       -> ScanResult t [] False False False
               ']' ->
                 case stk of
                   (_:rest) -> go (i+1) rest False False (newInKey rest)
                   []       -> ScanResult t [] False False False
               ':' ->
                 -- After the colon we are now in value position
                 go (i+1) stk False False False
               ',' ->
                 -- After a comma inside an object, back to key position
                 go (i+1) stk False False (case stk of ('{':_) -> True; _ -> False)
               _ ->
                 go (i+1) stk False False inKey

    -- After closing a bracket from the stack, the new top's inKey state
    -- is unknown without re-parsing.  We conservatively use False and let
    -- buildClosed handle the trimming on the actual text suffix.
    newInKey :: [Char] -> Bool
    newInKey ('{':_) = False   -- we'll inspect text suffix in buildClosed
    newInKey _       = False

-- | Build the closed version of the text given end-scan state.
buildClosed :: Text -> [Char] -> Bool -> Bool -> Bool -> Text
buildClosed t stk inStr esc inKey
  -- Already closed (no open brackets, not in string)
  | null stk && not inStr = t

  -- Ended inside a string
  | inStr =
      if inKey && not (null stk) && head stk == '{'
        -- Mid KEY string: drop the partial key back to its opening '"'
        -- and any preceding comma, then close brackets.
        then dropPartialKey t stk
        -- Mid VALUE string: optionally drop a trailing backslash, close
        -- the string, then close brackets.
        else let t' = if esc then T.dropEnd 1 t else t
             in  t' <> "\"" <> closers stk

  -- Not in a string
  | otherwise =
      let -- 1. Strip trailing whitespace
          t1 = T.stripEnd t
          -- 2. Drop a trailing comma
          t2 = dropIf ',' t1
          -- 3. Drop a trailing partial literal or partial number
          t3 = dropPartialLiteralOrNum t2
          -- 4. If now ending in ':', drop the colon and its key (+ comma)
          t4 = if not (T.null t3) && T.last t3 == ':'
               then dropColonAndKey t3
               else t3
          -- 5. Drop a trailing comma again (in case step 4 exposed one)
          t5 = dropIf ',' (T.stripEnd t4)
      in  t5 <> closers stk

-- | Drop the last character if it equals the given char, then strip trailing
-- whitespace.
dropIf :: Char -> Text -> Text
dropIf c t =
  if not (T.null t) && T.last t == c
  then T.stripEnd (T.dropEnd 1 t)
  else t

-- | Drop a partial key string that we're in the middle of:
-- find the opening unescaped '"' and drop from there, then also drop any
-- preceding comma/whitespace, then close brackets.
dropPartialKey :: Text -> [Char] -> Text
dropPartialKey t stk =
  let idx     = findOpeningQuote t
      without  = T.take idx t
      trimmed  = dropIf ',' (T.stripEnd without)
  in  trimmed <> closers stk

-- | Find the index of the opening (unescaped) '"' for the string we are
-- currently inside (i.e., the last unescaped '"' in the text).
findOpeningQuote :: Text -> Int
findOpeningQuote t = go (T.length t - 1)
  where
    go (-1) = 0
    go i    =
      let c = T.index t i
      in if c == '"'
         then let slashes = countBack t (i - 1)
              in if even slashes then i else go (i - 1)
         else go (i - 1)

-- | Count consecutive backslashes ending at position j (scanning left).
countBack :: Text -> Int -> Int
countBack t = go 0
  where
    go n j
      | j < 0                 = n
      | T.index t j == '\\'   = go (n + 1) (j - 1)
      | otherwise             = n

-- | Drop a trailing ':' together with its key string (and any preceding
-- comma/whitespace).
dropColonAndKey :: Text -> Text
dropColonAndKey t =
  -- t ends with ':'
  let t1 = T.dropEnd 1 t            -- remove ':'
      t2 = T.stripEnd t1
  in  if not (T.null t2) && T.last t2 == '"'
      then -- The key ends with the closing '"'.
           -- Find the matching opening '"' of the key string.
           let idx     = findStringOpen t2
               without  = T.take idx t2
               trimmed  = dropIf ',' (T.stripEnd without)
           in  trimmed
      else t2  -- shouldn't happen in valid partial JSON, but be safe

-- | Given text ending with a complete JSON string (closing '"' at the end),
-- return the index of the opening '"' of that string.  Scans backwards from
-- the penultimate character.
findStringOpen :: Text -> Int
findStringOpen t = go (T.length t - 2)  -- start one before the closing '"'
  where
    go (-1) = 0
    go i    =
      let c = T.index t i
      in if c == '"'
         then let slashes = countBack t (i - 1)
              in if even slashes then i else go (i - 1)
         else go (i - 1)

-- | Drop a trailing token that is:
--   * a strict prefix of "true", "false", or "null" (partial literal), or
--   * a partial number ending in '.', 'e', 'E', '+', or '-'.
-- Drops back to (and including) the last separator character.
dropPartialLiteralOrNum :: Text -> Text
dropPartialLiteralOrNum t
  | T.null t  = t
  | otherwise =
      -- Find where the last separator is
      case breakAtLastSep t of
        ("", _) -> t   -- no separator found; don't drop anything
        (pre, suf) ->
          let suf' = T.stripStart suf
          in if isPartialLit suf' || isPartialNum suf'
             then T.stripEnd pre
             else t

-- | Split at the last separator (one of :,{[ or whitespace).
-- Returns (everything up to AND INCLUDING the separator, everything after).
breakAtLastSep :: Text -> (Text, Text)
breakAtLastSep t =
  let rev = T.reverse t
  in  case T.findIndex isSep rev of
        Nothing -> ("", t)
        Just ri ->
          let i = T.length t - ri  -- index after the sep in the original
          in  (T.take i t, T.drop i t)
  where
    isSep c = c `elem` (":,{[ \t\n\r" :: String)

-- | Strict prefix of "true", "false", or "null" (not the complete word).
isPartialLit :: Text -> Bool
isPartialLit s =
  not (T.null s) &&
  any (\w -> s `T.isPrefixOf` w && s /= w) ["true", "false", "null"]

-- | Partial number: the text ends in a character that cannot close a JSON
-- number (.eE+-).
isPartialNum :: Text -> Bool
isPartialNum s =
  not (T.null s) && T.last s `elem` (".eE+-" :: String)

-- | Build the closing bracket suffix from the open-bracket stack
-- (innermost first: '{' closes to '}', '[' closes to ']').
closers :: [Char] -> Text
closers = T.pack . map closer
  where
    closer '{' = '}'
    closer _   = ']'

-- ---------------------------------------------------------------------------
-- Effectful interpreters
-- ---------------------------------------------------------------------------

-- | Interpret 'Emit' for one growing object: accumulate the whole buffer,
-- and on each delta close it and decode through the partial codec, handing
-- the 'Either DecodeError p' to the sink immediately. A blank buffer emits
-- nothing. Use a codec whose fields are all optional so partials decode as
-- fields arrive.
runPartialWith
  :: JSONCodec p
  -> (Either DecodeError p -> Eff es ())
  -> Eff (Emit : es) r
  -> Eff es r
runPartialWith c sink action = do
  (r, _buf) <-
    reinterpret (runState T.empty)
      (\_ -> \case
        Emit t -> do
          buf <- get
          let buf' = buf <> t
          put buf'
          if T.null (T.strip buf')
            then pure ()
            else raise (sink (decodeLLM c (closeJson buf'))))
      action
  pure r

-- | Like 'runPartialWith', but collect the partials alongside the result.
runPartial :: JSONCodec p -> Eff (Emit : es) r -> Eff es (r, [Either DecodeError p])
runPartial c action = do
  (r, ps) <- runState [] (runPartialWith c (\p -> modify (p :)) (inject action))
  pure (r, reverse ps)
