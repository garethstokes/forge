{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | A typed, persistent knowledge base the agent maintains: typed 'Page's with
-- typed 'Link's, read/written/listed/searched through the 'Research' effect.
-- 'runResearchState' is the pure test interpreter; 'runResearchDir' stores one
-- markdown file per page in a directory (git-diffable, outlives sessions).
-- Sibling of 'Crucible.Memory' and 'Crucible.Ledger'. (The research notes call
-- this a "Wiki"; it ships as "Research".)
module Crucible.Research
  ( Slug (..)
  , LinkType (..)
  , Link (..)
  , Page (..)
  , Research (..)
  , readPage, writePage, index, search, appendLog
  , runResearchState
  , runResearchDir
  , slugCodec, linkTypeCodec, linkCodec
  ) where

import Control.Exception (IOException, try)
import Data.List (find, sort, sortOn)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO

import Effectful
import Effectful.Dispatch.Dynamic (interpret, reinterpret, send)
import Effectful.State.Static.Local (runState, get, modify)

import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory)
import System.FilePath ((</>), (<.>), takeBaseName, takeExtension)

import Crucible.Codec (JSONCodec, object, field, list', enum, str, dimapCodec, encodeText)
import Crucible.Decode (decodeLLM)

newtype Slug = Slug Text deriving (Eq, Ord, Show)

unSlug :: Slug -> Text
unSlug (Slug s) = s

data LinkType = Relates | Contradicts | Extends | Supersedes
  deriving (Eq, Show)

data Link = Link { target :: Slug, linkType :: LinkType }
  deriving (Eq, Show)

data Page meta = Page
  { slug  :: Slug
  , title :: Text
  , links :: [Link]
  , body  :: Text
  , meta  :: meta
  }
  deriving (Eq, Show)

data Research meta :: Effect where
  ReadPage  :: Slug -> Research meta m (Maybe (Page meta))
  WritePage :: Page meta -> Research meta m ()
  Index     :: Research meta m [Slug]
  Search    :: Text -> Research meta m [Slug]
  AppendLog :: Text -> Research meta m ()
type instance DispatchOf (Research meta) = Dynamic

readPage :: (Research meta :> es) => Slug -> Eff es (Maybe (Page meta))
readPage = send . ReadPage

writePage :: (Research meta :> es) => Page meta -> Eff es ()
writePage = send . WritePage

index :: forall meta es. (Research meta :> es) => Eff es [Slug]
index = send (Index :: Research meta (Eff es) [Slug])

search :: forall meta es. (Research meta :> es) => Text -> Eff es [Slug]
search q = send (Search q :: Research meta (Eff es) [Slug])

appendLog :: forall meta es. (Research meta :> es) => Text -> Eff es ()
appendLog t = send (AppendLog t :: Research meta (Eff es) ())

-- | Does a page match a query (case-insensitive substring in title or body)?
matchesQuery :: Text -> Page meta -> Bool
matchesQuery q p =
  let q' = T.toCaseFold q
  in T.isInfixOf q' (T.toCaseFold p.title) || T.isInfixOf q' (T.toCaseFold p.body)

-- | Pure interpreter (tests): seed pages, return the result, the final pages in
-- slug order, and the appended log lines in order.
runResearchState :: forall meta es a. [Page meta]
                 -> Eff (Research meta : es) a -> Eff es (a, [Page meta], [Text])
runResearchState seed action = do
  (a, (pages, logRev)) <- reinterpret (runState (seed, [] :: [Text])) (\_ -> \case
    ReadPage s   -> do (ps, _) <- get @([Page meta], [Text]); pure (find (\p -> p.slug == s) ps)
    WritePage p  -> modify @([Page meta], [Text]) (\(ps, l) -> (p : filter (\q -> q.slug /= p.slug) ps, l))
    Index        -> do (ps, _) <- get @([Page meta], [Text]); pure (sort (map ((.slug) :: Page meta -> Slug) ps))
    Search q     -> do (ps, _) <- get @([Page meta], [Text]); pure (sort [((.slug) :: Page meta -> Slug) p | p <- ps, matchesQuery q p])
    AppendLog ln -> modify @([Page meta], [Text]) (\(ps, l) -> (ps, ln : l))) action
  pure (a, sortOn ((.slug) :: Page meta -> Slug) pages, reverse logRev)

slugCodec :: JSONCodec Slug
slugCodec = dimapCodec Slug unSlug str

linkTypeCodec :: JSONCodec LinkType
linkTypeCodec = enum
  [ ("relates", Relates), ("contradicts", Contradicts)
  , ("extends", Extends), ("supersedes", Supersedes) ]

linkCodec :: JSONCodec Link
linkCodec = object (Link <$> field "target" ((.target) :: Link -> Slug) slugCodec
                         <*> field "linkType" ((.linkType) :: Link -> LinkType) linkTypeCodec)

-- The serialized page head (everything but the slug, which is the filename).
data PageHead meta = PageHead { title :: Text, links :: [Link], meta :: meta }

pageHeadCodec :: JSONCodec meta -> JSONCodec (PageHead meta)
pageHeadCodec mc = object (PageHead <$> field "title" ((.title) :: PageHead meta -> Text) str
                                    <*> field "links" ((.links) :: PageHead meta -> [Link]) (list' linkCodec)
                                    <*> field "meta"  ((.meta)  :: PageHead meta -> meta)  mc)

pagePath :: FilePath -> Slug -> FilePath
pagePath dir s = dir </> T.unpack (unSlug s) <.> "md"

renderPage :: JSONCodec meta -> Page meta -> Text
renderPage mc p =
  "---\n" <> encodeText (pageHeadCodec mc) (PageHead p.title p.links p.meta)
    <> "\n---\n" <> p.body

parsePage :: JSONCodec meta -> Slug -> Text -> Maybe (Page meta)
parsePage mc s contents = case T.lines contents of
  ("---" : rest) ->
    let (headLines, afterHead) = break (== "---") rest
        bodyText = T.intercalate "\n" (drop 1 afterHead)
        headJson = T.intercalate "\n" headLines
    in case decodeLLM (pageHeadCodec mc) headJson of
         Right h -> Just (Page s h.title h.links bodyText h.meta)
         Left _  -> Nothing
  _ -> Nothing

readPageFile :: JSONCodec meta -> FilePath -> Slug -> IO (Maybe (Page meta))
readPageFile mc dir s = do
  let path = pagePath dir s
  exists <- doesFileExist path
  if not exists then pure Nothing
  else do
    r <- try (TIO.readFile path) :: IO (Either IOException Text)
    pure (either (const Nothing) (parsePage mc s) r)

writePageFile :: JSONCodec meta -> FilePath -> Page meta -> IO ()
writePageFile mc dir p = do
  createDirectoryIfMissing True dir
  TIO.writeFile (pagePath dir p.slug) (renderPage mc p)

indexDir :: FilePath -> IO [Slug]
indexDir dir = do
  createDirectoryIfMissing True dir
  fs <- listDirectory dir
  pure (sort [ Slug (T.pack (takeBaseName f)) | f <- fs, takeExtension f == ".md", f /= "log.md" ])

searchDir :: JSONCodec meta -> FilePath -> Text -> IO [Slug]
searchDir mc dir q = do
  slugs <- indexDir dir
  matched <- mapM (\s -> maybe False (matchesQuery q) <$> readPageFile mc dir s) slugs
  pure [ s | (s, True) <- zip slugs matched ]

-- | Directory interpreter: one <slug>.md per page (--- JSON head --- + body),
-- AppendLog -> log.md. Outlives sessions; git-diffable. Tolerant: a page file
-- whose head does not decode reads as absent.
runResearchDir :: (IOE :> es) => JSONCodec meta -> FilePath -> Eff (Research meta : es) a -> Eff es a
runResearchDir mc dir = interpret $ \_ -> \case
  ReadPage s   -> liftIO (readPageFile mc dir s)
  WritePage p  -> liftIO (writePageFile mc dir p)
  Index        -> liftIO (indexDir dir)
  Search q     -> liftIO (searchDir mc dir q)
  AppendLog ln -> liftIO (createDirectoryIfMissing True dir >> TIO.appendFile (dir </> "log.md") (ln <> "\n"))
