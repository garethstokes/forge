{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedLabels #-}

module THSpec (tests) where

import Data.Text (Text)
import Manifest (Key (..), Entity (..), withSession, add, get)
import Manifest.Core.Meta (ColumnMeta (..), SqlType (..), tmTable, tmColumns)
import Manifest.Core.Table (PrimaryKey, Serial)
import Manifest.Postgres (execText, withConnection)
import Manifest.Derive.TH (field, mkEntity)
import Fixtures (withEmptyDb)
import Harness

-- The terse declaration under test. One block generates WidgetT, Widget, and
-- the Entity Widget instance — equivalent to the hand-written UserT in Fixtures.
$(mkEntity "Widget" "widgets"
    [ field "id"   [t| PrimaryKey (Serial Int) |]
    , field "name" [t| Text |]
    , field "size" [t| Maybe Int |]
    ])

tests :: [Test]
tests = group "TH"
  [ test "mkEntity generates correct table metadata" $ do
      let tm = tableMeta @Widget
      assertEqual "table name" "widgets" (tmTable tm)
      assertEqual "columns"
        [ ColumnMeta "widget_id"   True  True  SqlBigSerial False
        , ColumnMeta "widget_name" False False SqlText      False
        , ColumnMeta "widget_size" False False SqlBigInt    True
        ]
        (tmColumns tm)
  , test "mkEntity wires primKey to the PrimaryKey field" $
      assertEqual "primKey selects widget_id" 7
        (primKey (Widget { widgetId = 7, widgetName = "x", widgetSize = Nothing } :: Widget))
  ]
