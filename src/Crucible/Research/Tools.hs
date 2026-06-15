{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- | The 'Crucible.Research' operations as model-callable 'Tool's, so the stock
-- agent loop ('Crucible.Chat.runToolAgent') can maintain a Research store.
-- 'researchInstructions' is a default editing-discipline prompt fragment (plain
-- text, the caller prepends and can replace). Lives apart from
-- 'Crucible.Research' so that module keeps no dependency on the tool machinery.
module Crucible.Research.Tools
  ( researchTools
  , researchInstructions
  ) where

import Data.Text (Text)
import NeatInterpolation (text)

import Effectful

import Crucible.Codec (JSONCodec, object, field, str, list', nullable')
import Crucible.Tool (Tool, toolWith)
import Crucible.Research (Page (..), Research, readPage, writePage, search, pageCodec, slugCodec)

researchTools :: forall meta es. (Research meta :> es) => JSONCodec meta -> [Tool es]
researchTools mc =
  [ toolWith "read_page"    (object (field "slug" Prelude.id slugCodec)) (nullable' (pageCodec mc)) readPage
  , toolWith "write_page"   (pageCodec mc) slugCodec (\p -> writePage p >> pure ((.slug) (p :: Page meta)))
  , toolWith "search_pages" (object (field "query" Prelude.id str)) (list' slugCodec) (search @meta)
  ]

researchInstructions :: Text
researchInstructions = [text|
You maintain a research knowledge base with these tools:
- search_pages: find existing pages by a query.
- read_page: read one page by its slug.
- write_page: create or update a page (slug, title, body, and typed links).

Before writing, search for an existing page and prefer updating it over creating
a near-duplicate. When a new finding conflicts with a page, add a link of type
contradicts or supersedes rather than overwriting silently. Keep each page
focused on one topic.
|]
