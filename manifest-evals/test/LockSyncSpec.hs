-- | Guards against silent drift between the root forge @zinc.lock@ and the
-- @evals-ui/zinc.lock@. evals-ui is dual-purpose (a member of the root workspace
-- AND its own wasm32-wasi workspace root); its lock copies the aeson closure
-- verbatim from the root lock. A @zinc update@ that bumps a shared dep in the
-- root lock but not evals-ui's would diverge the wasm build silently — this test
-- fails when any dep present in BOTH locks has a mismatched @sha256@.
--
-- Uses the same tiny 'expect' harness as the other manifest-evals specs (no hspec).
-- CWD is anchored to the manifest-evals member dir by Spec.hs, so the locks are at
-- @../zinc.lock@ (root) and @evals-ui/zinc.lock@.
module LockSyncSpec (main) where

import Control.Monad (unless)
import Data.List (isPrefixOf, stripPrefix)
import Data.Maybe (listToMaybe, mapMaybe)
import qualified Data.Map.Strict as M
import Data.Map.Strict (Map)

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

-- | name -> (version-or-rev, sha256) for every @[[locked]]@ block.
parseLock :: String -> Map String (String, String)
parseLock txt =
  M.fromList
    [ (nm, (ver, sha))
    | blk <- blocks (lines txt)
    , nm  <- maybe [] pure (firstField "name" blk)
    , let ver = case firstField "vendored" blk of
                  Just v  -> v
                  Nothing -> maybe "?" id (firstField "rev" blk)
    , let sha = maybe "?" id (firstField "sha256" blk)
    ]
  where
    -- split the line list into chunks, one per [[locked]] block (the leading
    -- preamble chunk has no "name" line and is dropped by the comprehension).
    blocks :: [String] -> [[String]]
    blocks = go []
      where
        go cur []                              = [reverse cur]
        go cur (l:ls)
          | "[[locked]]" `isPrefixOf` l = reverse cur : go [] ls
          | otherwise                   = go (l : cur) ls

    firstField :: String -> [String] -> Maybe String
    firstField key = listToMaybe . mapMaybe (field key)

    -- @field "name" "name = \"aeson\""@ -> @Just "aeson"@
    field :: String -> String -> Maybe String
    field key l = stripPrefix (key <> " = ") l >>= quoted

    quoted :: String -> Maybe String
    quoted s = case dropWhile (/= '"') s of
      ('"' : rest) -> Just (takeWhile (/= '"') rest)
      _            -> Nothing

main :: IO ()
main = do
  rootM <- parseLock <$> readFile "../zinc.lock"
  uiM   <- parseLock <$> readFile "evals-ui/zinc.lock"
  let shared = M.keys (M.intersectionWith (,) rootM uiM)
      drifts =
        [ "  " <> nm <> ": root=" <> rver <> " " <> rsha
                     <> "  evals-ui=" <> uver <> " " <> usha
        | nm <- shared
        , let (rver, rsha) = rootM M.! nm
        , let (uver, usha) = uiM   M.! nm
        , rsha /= usha                       -- STRICT: any sha difference is drift
        ]
  expect ("shared lock entries non-empty (got " <> show (length shared) <> ")")
         (not (null shared))
  expect ("lock drift between root zinc.lock and evals-ui/zinc.lock:\n"
            <> unlines drifts
            <> "re-sync the shared (aeson-closure) entries in evals-ui/zinc.lock "
            <> "with the root lock after a `zinc update`.")
         (null drifts)
  putStrLn ("manifest-evals LockSyncSpec: " <> show (length shared)
              <> " shared lock entries match (sha) OK")
