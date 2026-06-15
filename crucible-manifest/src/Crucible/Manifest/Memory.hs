{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-unused-imports #-}
module Crucible.Manifest.Memory () where

import Manifest.Core.Table (Field)   -- from manifest-core (pure)
import Manifest (withSession)         -- from manifest (libpq umbrella)
import Crucible.Memory (MemoryStore)  -- from crucible (sibling workspace package)

-- placeholder: forces manifest-core, manifest, and crucible to all resolve and
-- co-build under GHC 9.12.2 with libpq linked. Real backend lands in a later task.
_unused :: ()
_unused = ()
