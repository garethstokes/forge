# Typed Tool Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Value-erased `Tool` with an existential carrying codecs at the JSON boundary, structured `ToolError` dispatch owned by `invoke`, a constructor trio (`tool @"name"` / `toolWith` / `rawTool`), and a Generic record-of-handlers toolbox derivation (`Crucible.Tool.Generic.tools`) with custom TypeErrors.

**Architecture:** Spec at `docs/superpowers/specs/2026-06-11-typed-tool-overhaul-design.md`. Clean break, one branch (`feat/typed-tools`); the wire formats do not change (provider modules untouched). Task 1 is the atomic green gate (core rewrite + every call site compiles + suite passes); later tasks are additive.

**Tech Stack:** Haskell GHC 9.12.2, effectful, autodocodec, GHC.Generics, GHC.TypeLits. Build/test: `nix develop . --command timeout -s KILL 300 zinc build` (exit 0) / `... zinc test` ("1 test suite(s) passed"). On exit 137 (rare GHC iserv flake) retry once; a second 137 = report BLOCKED. Ignore the "Git tree is dirty" warning.

---

## Background for the implementer

- Work in place on branch `feat/typed-tools` (create from master). Do NOT create worktrees.
- House style: `DuplicateRecordFields` + `NoFieldSelectors` + `OverloadedRecordDot`; fields are prefix-free; access via `x.field` or pattern matching. Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Existing modules you will touch: `src/Crucible/Tool.hs` (rewrite), `src/Crucible/Chat.hs` (dispatch), `src/Crucible/Agent.hs` (one line), `src/Crucible/Example.hs` (constructor swap), `app/Main.hs`, `test/Spec.hs`, `docs/tool-calling.md`, `docs/effects.md`. New: `src/Crucible/Tool/Generic.hs`. zinc auto-discovers new modules under src/.
- `Crucible.Decode` exports `DecodeError (..)` with fields `message, raw :: Text`. `Crucible.Codec` exports `JSONCodec, object, field, str, anyValue, schemaValue`. `Crucible.Codec.Generic` exports `HasCodec (codec)` and `genericCodec`. Autodocodec gives `parseJSONVia`, `toJSONVia`.
- GADT existential + record-dot caveat: `t.name` and `t.schema` should still solve via HasField (their types do not mention the existential variables). If GHC refuses to solve HasField on the GADT, fall back to explicit accessors `toolName (Tool n _ _ _ _) = n` / `toolSchema (Tool _ s _ _ _) = s`, export them, and use them at the affected sites (Chat.hs specs list, toolsHelp, runTools filter). Either way the plan's behaviour is identical; do not get stuck on the sugar.

---

### Task 1: core rewrite — existential Tool, ToolError, invoke; all call sites green

**Files:**
- Rewrite: `src/Crucible/Tool.hs`
- Modify: `src/Crucible/Chat.hs` (runToolAgentN dispatch, imports)
- Modify: `src/Crucible/Agent.hs:55` (render upgraded CallTool result)
- Modify: `src/Crucible/Example.hs` (positional `Tool` → `rawTool`)
- Modify: `app/Main.hs` (four tool values → `rawTool`)
- Modify: `test/Spec.hs` (fixtures → `rawTool`; Task-6 `tool` tests → `invoke` + Symbol form)

- [ ] **Step 1: rewrite `src/Crucible/Tool.hs`** to exactly this content (preserving `ToolCall`/`toolCallCodec`/`toolsHelp` behaviour):

```haskell
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

-- | Typed tools. A 'Tool' is an existential sealing a handler's input and
-- output types together with the codecs that mediate the JSON boundary;
-- 'invoke' is the only place JSON enters or leaves. Failures at the boundary
-- are structured 'ToolError's, rendered for the model once by 'renderToolError'.
--
-- Constructors, happy path first: 'tool' (name as a type-level Symbol, codecs
-- from 'HasCodec'), 'toolWith' (explicit codecs), 'rawTool' (hand-written
-- schema, 'Value' in and out; @rawTool n sch = Tool n sch anyValue anyValue@).
--
-- There is deliberately no Profunctor instance: the handler @i -> Eff es o@
-- is already one (dimap it before construction), but codecs are invariant,
-- so a lawful instance on the codec-carrying record cannot exist.
module Crucible.Tool
  ( ToolName, ToolCall(..), toolCallCodec, anyValue
  , Tool(..), tool, toolWith, rawTool
  , ToolError(..), invoke, renderToolError
  , Tools(..), callTool, runTools, toolsHelp
  ) where

import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as LB
import qualified Data.Text.Encoding as TE
import qualified Data.Aeson as A
import Data.Aeson (Value)
import qualified Data.Aeson.Types as AT
import GHC.TypeLits (KnownSymbol, symbolVal)
import Autodocodec (parseJSONVia, toJSONVia)
import Crucible.Codec (JSONCodec, object, field, str, anyValue, schemaValue)
import Crucible.Codec.Generic (HasCodec (codec))
import Crucible.Decode (DecodeError (..))
import Effectful
import Effectful.Dispatch.Dynamic (send, interpret)

type ToolName = Text

-- | A tool invocation as the model emits it: a name and raw args.
data ToolCall = ToolCall { name :: ToolName, args :: Value }
  deriving (Eq, Show)

toolCallCodec :: JSONCodec ToolCall
toolCallCodec = object (ToolCall <$> field "tool" (.name) str <*> field "args" (.args) anyValue)

-- | A named tool: the advertised input schema, the codecs for both ends of
-- the JSON boundary, and a typed runner in the ambient effect row. The
-- handler's types are existential; 'invoke' is their only consumer.
data Tool es where
  Tool ::
    { name   :: ToolName
    , schema :: Value          -- ^ input JSON Schema as advertised on the wire
    , input  :: JSONCodec i
    , output :: JSONCodec o
    , run    :: i -> Eff es o
    } -> Tool es

-- | Build a tool from a typed handler; the name is a type-level Symbol and
-- the schema is derived from the input codec:
-- @tool \@"get_weather" $ \\(Loc city) -> pure (Sky ("sunny in " <> city))@
tool :: forall name i o es. (KnownSymbol name, HasCodec i, HasCodec o)
     => (i -> Eff es o) -> Tool es
tool = toolWith (T.pack (symbolVal (Proxy @name))) (codec @i) (codec @o)

-- | 'tool' with explicit codecs (irregular names, types without 'HasCodec').
toolWith :: ToolName -> JSONCodec i -> JSONCodec o -> (i -> Eff es o) -> Tool es
toolWith n inC outC = Tool n (schemaValue inC) inC outC

-- | The escape hatch: a hand-written schema and a raw 'Value' handler.
rawTool :: ToolName -> Value -> (Value -> Eff es Value) -> Tool es
rawTool n sch = Tool n sch anyValue anyValue

-- | A structured wire-boundary failure, rendered for the model by
-- 'renderToolError'. Handler exceptions are NOT caught; they propagate.
data ToolError
  = UnknownTool ToolName [ToolName]         -- ^ requested, available
  | BadArgs     ToolName DecodeError Value  -- ^ tool, decode failure, its schema
  deriving (Eq, Show)

-- | Run a tool against raw model-supplied args: decode through the input
-- codec (failure: 'BadArgs' carrying the offending args as the error's
-- @raw@), run the handler, encode the result through the output codec
-- (total; the result half has no failure path).
invoke :: Tool es -> Value -> Eff es (Either ToolError Value)
invoke (Tool n sch inC outC f) v =
  case AT.parseEither (parseJSONVia inC) v of
    Left err -> pure (Left (BadArgs n (DecodeError (T.pack err) (renderValue v)) sch))
    Right i  -> Right . toJSONVia outC <$> f i

-- | The model-facing feedback for a 'ToolError': the error, the expected
-- schema, and the args echoed back, so the model can self-correct.
renderToolError :: ToolError -> Text
renderToolError (UnknownTool n avail) =
  "unknown tool: " <> n <> ". available tools: " <> T.intercalate ", " avail
renderToolError (BadArgs n e sch) =
  "tool " <> n <> ": arguments did not decode: " <> e.message
    <> "\nexpected schema: " <> renderValue sch
    <> "\nyou sent: " <> e.raw

-- | The tool-dispatch capability as a dynamic effect.
data Tools :: Effect where
  CallTool :: ToolName -> Value -> Tools m (Either ToolError Value)
type instance DispatchOf Tools = Dynamic

callTool :: (Tools :> es) => ToolName -> Value -> Eff es (Either ToolError Value)
callTool n v = send (CallTool n v)

-- | Interpret Tools against a toolbox; unknown tool -> Left (with the
-- available names); bad args -> Left via 'invoke'.
runTools :: [Tool es] -> Eff (Tools : es) a -> Eff es a
runTools tools = interpret $ \_ -> \case
  CallTool tname targs -> case filter ((== tname) . (.name)) tools of
    (t : _) -> invoke t targs
    []      -> pure (Left (UnknownTool tname (map (.name) tools)))

-- | A prose listing of the toolbox for the system prompt.
toolsHelp :: [Tool es] -> Text
toolsHelp ts = T.intercalate "\n"
  [ "- " <> t.name <> "(args: " <> renderValue t.schema <> ")" | t <- ts ]

-- | Render a JSON Value as compact JSON text.
renderValue :: Value -> Text
renderValue = TE.decodeUtf8 . LB.toStrict . A.encode
```

(If HasField on the GADT fails to solve `(.name)`/`t.schema`, add and export `toolName`/`toolSchema` accessors per the Background note and use them here and in Chat.hs.)

- [ ] **Step 2: update `src/Crucible/Chat.hs`.** Change the Tool import line and `runOne`:

```haskell
-- import line becomes:
import Crucible.Tool (Tool (..), ToolName, ToolError (..), invoke, renderToolError)
```

In `runToolAgentN`, replace the existing `runOne`:

```haskell
    runOne u = case filter ((== u.name) . (.name)) tools of
      (t : _) -> ToolResultBlock u.id . either (A.String . renderToolError) id <$> invoke t u.args
      []      -> pure (ToolResultBlock u.id
                   (A.String (renderToolError (UnknownTool u.name (map (.name) tools)))))
```

(`specs = [(t.name, t.schema) | t <- tools]` is unchanged.)

- [ ] **Step 3: update `src/Crucible/Agent.hs` line 55.** The `callTool` result is now `Either ToolError Value`:

```haskell
import Crucible.Tool (Tools, callTool, ToolCall(..), renderToolError)
-- ...
            loop (append st1 (Message Tool (either (("error: " <>) . renderToolError) encodeValue res)))
```

- [ ] **Step 4: update `src/Crucible/Example.hs`.** The two positional `Tool` constructions become `rawTool` (schemas and behaviour unchanged):

```haskell
weatherTool :: Tool es
weatherTool = rawTool "get_weather" weatherSchema $ \args ->
  pure $ case parseMaybe (A.withObject "" (\o -> o A..: "city")) args of
           Just c  -> A.String ("sunny in " <> c)
           Nothing -> A.String "unknown city"

addTool :: Tool es
addTool = rawTool "add" addSchema $ \args ->
  pure $ case parseMaybe (\v -> A.withObject "" (\o -> (,) <$> o A..: "a" <*> o A..: "b") v) args of
           Just (a, b) -> A.Number (fromIntegral (a + b :: Int))
           Nothing     -> A.String "bad args"
```

(`import Crucible.Tool` is open; `rawTool` arrives automatically.)

- [ ] **Step 5: update `app/Main.hs`.** Replace all four positional constructions (`weatherTool`, `weatherTool2`, `weatherTool3`, `oWeatherTool`) with ONE shared value used at every site (Task 3 upgrades this to the record toolbox; here it just compiles):

```haskell
      let weatherTool = Tl.rawTool "get_weather" weatherSchema
            (\_ -> pure (A.String "It is 26C and sunny."))
```

Delete the `weatherTool2`/`weatherTool3`/`oWeatherTool` lets and use `weatherTool` at their call sites (`Anthropic.usageChat`, `Anthropic.streamChat`, `Anthropic.recordChat`/`replayChat`, and the three OpenAI sites).

- [ ] **Step 6: update `test/Spec.hs`.**

(a) Fixtures become `rawTool` (same names/schemas/behaviour; the `toolsHelp` expected string is untouched because the schema literals are unchanged):

```haskell
weatherToolC :: Tl.Tool es
weatherToolC = Tl.rawTool "get_weather" weatherToolSchema (\_ -> pure (A.String "Sunny in Brisbane!"))
```

and in `agentTools`, change both `Tl.Tool <name> <schema> $ \args -> ...` to `Tl.rawTool <name> <schema> $ \args -> ...` (bodies unchanged).

(b) The two Task-6 `tool` tests change to the Symbol form with a typed output and `invoke` (the existential makes direct `t.run` access impossible by design):

```haskell
  , check "tool: type-driven constructor derives object schema + decodes args"
      (Just (String "object"), Right (A.String "sunny in Hobart"))
      ( let t = Tl.tool @"weather" (\(Loc c) -> pure ("sunny in " <> c :: Text)) :: Tl.Tool '[]
        in ( schemaType t.schema
           , runPureEff (Tl.invoke t (object ["locCity" .= String "Hobart"])) ) )
  , check "tool: bad args yield Left BadArgs (schema attached, raw echoed)"
      (Just True)
      ( let t = Tl.tool @"weather" (\(Loc c) -> pure ("sunny in " <> c :: Text)) :: Tl.Tool '[]
        in case runPureEff (Tl.invoke t (object [])) of
             Left (Tl.BadArgs n e sch) ->
               Just (n == "weather" && sch == t.schema && e.raw == "{}")
             _ -> Nothing )
```

Spec.hs needs `{-# LANGUAGE TypeApplications #-}` (already present) and `DataKinds` (already present). Remove the old `"tool: decode failure yields error string"` check (replaced by the BadArgs check above).

- [ ] **Step 7: build + suite green.**

Run: `nix develop . --command timeout -s KILL 300 zinc build` → exit 0, then `nix develop . --command timeout -s KILL 300 zinc test` → `1 test suite(s) passed`. Fix compile fallout (the compiler enumerates the sites; behaviour must not change).

- [ ] **Step 8: commit.**

```bash
git add -A
git commit -m "$(printf 'feat(tool)!: existential Tool with codecs at the boundary; structured ToolError\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: error-path tests (invoke, UnknownTool, renderToolError, loop feedback)

**Files:**
- Modify: `test/Spec.hs` (new checks near the existing tool tests)

- [ ] **Step 1: add the checks.** Insert after the Task-1 tool checks:

```haskell
  , check "runTools: unknown tool -> Left UnknownTool with available names"
      (Left (Tl.UnknownTool "nope" ["get_weather", "add"]))
      (runPureEff (Tl.runTools agentTools (Tl.callTool "nope" (object []))))
  , check "renderToolError: BadArgs includes schema and echoed args"
      True
      ( let t = Tl.tool @"weather" (\(Loc c) -> pure ("sunny in " <> c :: Text)) :: Tl.Tool '[]
        in case runPureEff (Tl.invoke t (object ["city" .= String "x"])) of
             Left err ->
               let r = Tl.renderToolError err
               in T.isInfixOf "expected schema:" r
                    && T.isInfixOf "you sent:" r
                    && T.isInfixOf "locCity" r       -- schema names the real field
                    && T.isInfixOf "\"city\":\"x\"" r -- echo of what was sent
             Right _ -> False )
  , check "renderToolError: UnknownTool lists available names"
      True
      (T.isInfixOf "available tools: get_weather, add"
        (Tl.renderToolError (Tl.UnknownTool "nope" ["get_weather", "add"])))
  , check "runToolAgent: bad args fed back, model self-corrects (scripted)"
      (Right "fixed")
      (runPureEff (runChatScripted
        [ Turn "" [ToolUse "u1" "typed_weather" (object ["wrong" .= String "x"])]
        , Turn "fixed" [] ]
        (runToolAgent
          [Tl.tool @"typed_weather" (\(Loc c) -> pure ("sunny in " <> c :: Text))]
          "weather?")))
```

Note: `agentTools` element order in `UnknownTool` follows the toolbox list order (`get_weather`, then `add`). If the existing fixture order differs, match the actual order.

- [ ] **Step 2: run the suite.**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: `1 test suite(s) passed` (the new checks appear as `ok` lines).

- [ ] **Step 3: commit.**

```bash
git add test/Spec.hs
git commit -m "$(printf 'test(tool): error-path coverage for invoke/UnknownTool/renderToolError and loop feedback\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: `Crucible.Tool.Generic` — record toolbox derivation

**Files:**
- Create: `src/Crucible/Tool/Generic.hs`
- Modify: `app/Main.hs` (showcase: weather tool becomes a one-field record toolbox)
- Modify: `test/Spec.hs` (record fixture + checks)

- [ ] **Step 1: create `src/Crucible/Tool/Generic.hs`:**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Derive a whole toolbox from a record of handlers: field names become
-- tool names, field types are the contracts, the value is nothing but the
-- functions.
--
-- @
-- data SupportTools es = SupportTools
--   { get_weather  :: Loc -> Eff es Sky
--   , current_time :: Eff es TimeResult     -- zero-arg form
--   } deriving (Generic)
--
-- agent = runToolAgent (tools supportTools)
-- @
--
-- Within one record duplicate tool names are impossible (the language
-- enforces field uniqueness) and a test stub must implement every field.
-- Tool names are limited to legal field names; use 'Crucible.Tool.toolWith'
-- or 'Crucible.Tool.rawTool' for irregular names. @tools a ++ tools b@ keeps
-- plain list semantics (first match wins in dispatch).
module Crucible.Tool.Generic
  ( tools
  , GTools (..)
  ) where

import Data.Proxy (Proxy (..))
import qualified Data.Text as T
import GHC.Generics
import GHC.TypeLits (ErrorMessage (..), KnownSymbol, TypeError, symbolVal)

import Effectful (Eff)

import Crucible.Codec (JSONCodec)
import qualified Crucible.Codec as C
import Crucible.Codec.Generic (HasCodec (codec))
import Crucible.Tool (Tool, toolWith)

-- | Harvest a toolbox from a single-constructor record of handlers.
tools :: (Generic t, GTools (Rep t) es) => t -> [Tool es]
tools = gtools . from

-- | The Rep walk. Instances cover: handler fields @i -> Eff es o@, zero-arg
-- fields @Eff es o@, products, and the D/C metadata wrappers. Malformed
-- shapes get custom TypeErrors naming the field.
class GTools rep es where
  gtools :: rep p -> [Tool es]

instance GTools f es => GTools (M1 D m f) es where
  gtools (M1 f) = gtools f

instance GTools f es => GTools (M1 C m f) es where
  gtools (M1 f) = gtools f

instance (GTools f es, GTools g es) => GTools (f :*: g) es where
  gtools (f :*: g) = gtools f ++ gtools g

-- handler field: i -> Eff es o
instance (KnownSymbol nm, HasCodec i, HasCodec o)
  => GTools (M1 S ('MetaSel ('Just nm) u s l) (K1 R (i -> Eff es o))) es where
  gtools (M1 (K1 f)) =
    [toolWith (T.pack (symbolVal (Proxy @nm))) (codec @i) (codec @o) f]

-- zero-arg field: Eff es o (empty-object schema; any args object accepted)
instance {-# OVERLAPPING #-} (KnownSymbol nm, HasCodec o)
  => GTools (M1 S ('MetaSel ('Just nm) u s l) (K1 R (Eff es o))) es where
  gtools (M1 (K1 m)) =
    [toolWith (T.pack (symbolVal (Proxy @nm))) unitCodec (codec @o) (\() -> m)]

-- non-handler field
instance {-# OVERLAPPABLE #-} TypeError
  ( 'Text "Toolbox field " ':<>: 'ShowType nm ':<>: 'Text " is not a tool handler."
    ':$$: 'Text "Expected a function of shape: i -> Eff es o (or Eff es o for a zero-arg tool)"
    ':$$: 'Text "          but the field has type: " ':<>: 'ShowType t )
  => GTools (M1 S ('MetaSel ('Just nm) u s l) (K1 R t)) es where
  gtools = error "unreachable: TypeError"

-- positional field
instance TypeError
  ('Text "Toolbox fields must be named; the field name becomes the tool name.")
  => GTools (M1 S ('MetaSel 'Nothing u s l) (K1 R t)) es where
  gtools = error "unreachable: TypeError"

-- sum type
instance TypeError
  ('Text "A toolbox must be a single-constructor record.")
  => GTools (f :+: g) es where
  gtools = error "unreachable: TypeError"

-- empty record: a toolbox with no tools
instance GTools U1 es where
  gtools _ = []

-- | Input codec for zero-arg tools: an object with no fields. Decoding ()
-- accepts ANY object the model sends (including invented keys); a zero-arg
-- tool must not fail on enthusiastic argument guessing.
unitCodec :: JSONCodec ()
unitCodec = C.object (pure ())
```

Note on overlap: the zero-arg instance is marked OVERLAPPING because `Eff es o` also matches `t` in the OVERLAPPABLE catch-all AND would otherwise be ambiguous with nothing; the handler instance `i -> Eff es o` is already more specific than the catch-all. If GHC reports overlap ambiguity between the handler instance and the catch-all, add `{-# OVERLAPPING #-}` to the handler instance too.

- [ ] **Step 2: build.**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: exit 0.

- [ ] **Step 3: add the Spec fixture + checks.** In `test/Spec.hs`, add imports:

```haskell
import Crucible.Tool.Generic (tools)
import Effectful (Eff)   -- if not already imported unqualified
```

Add a fixture near `Loc` (which exists from the DevEx cycle):

```haskell
-- crucible typed-tool overhaul: record toolbox fixture
data DemoBox es = DemoBox
  { demo_weather :: Loc -> Eff es Text
  , demo_time    :: Eff es Text
  } deriving (Generic)

demoBox :: DemoBox es
demoBox = DemoBox
  { demo_weather = \(Loc c) -> pure ("sunny in " <> c)
  , demo_time    = pure "noon"
  }
```

Add checks:

```haskell
  , check "tools: record fields become tools, in field order"
      ["demo_weather", "demo_time"]
      (map (.name) (tools demoBox :: [Tl.Tool '[]]))
  , check "tools: derived handler decodes args and encodes result"
      (Right (A.String "sunny in Hobart"))
      (case tools demoBox :: [Tl.Tool '[]] of
         (w : _) -> runPureEff (Tl.invoke w (object ["locCity" .= String "Hobart"]))
         []      -> Left (Tl.UnknownTool "empty" []))
  , check "tools: zero-arg tool accepts an empty object"
      (Right (A.String "noon"))
      (case tools demoBox :: [Tl.Tool '[]] of
         [_, t] -> runPureEff (Tl.invoke t (object []))
         _      -> Left (Tl.UnknownTool "shape" []))
  , check "tools: zero-arg tool tolerates invented keys"
      (Right (A.String "noon"))
      (case tools demoBox :: [Tl.Tool '[]] of
         [_, t] -> runPureEff (Tl.invoke t (object ["surprise" .= String "args"]))
         _      -> Left (Tl.UnknownTool "shape" []))
  , check "tools: zero-arg schema is an object"
      (Just (String "object"))
      (case tools demoBox :: [Tl.Tool '[]] of
         [_, t] -> schemaType t.schema
         _      -> Nothing)
```

If the zero-arg schema check fails because autodocodec renders the empty
object codec without a "type" key, relax that check to assert the schema is
an `Object` (e.g. `case t.schema of A.Object _ -> True; _ -> False`) and note
it in the commit message.

- [ ] **Step 4: run the suite.**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: `1 test suite(s) passed`.

- [ ] **Step 5: showcase in `app/Main.hs`.** Replace the Task-1 `rawTool` weather value with a one-field record toolbox shared by both providers:

```haskell
-- near the other top-level types:
data WeatherQ = WeatherQ { city :: T.Text } deriving (Show, Generic)
instance HasCodec WeatherQ where codec = genericCodec

data WeatherTools es = WeatherTools
  { get_weather :: WeatherQ -> Eff es T.Text }
  deriving (Generic)

weatherBox :: WeatherTools es
weatherBox = WeatherTools { get_weather = \_ -> pure "It is 26C and sunny." }
```

In `main`, delete the `weatherSchema` literal and the `rawTool` let; every
`runToolAgent [weatherTool] ...` becomes `runToolAgent (tools weatherBox) ...`
(all Anthropic and OpenAI sites). Imports to add: `Crucible.Tool.Generic (tools)`,
`Effectful (Eff)` if missing; Main already has `DeriveGeneric`, `HasCodec`,
`genericCodec` imports. The wire result is the same String content as before.

- [ ] **Step 6: build + suite + commit.**

Run both build and test commands (expected green), then:

```bash
git add -A
git commit -m "$(printf 'feat(tool): Generic record-of-handlers toolbox derivation (Crucible.Tool.Generic)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 4: manual update

**Files:**
- Modify: `docs/tool-calling.md` (rewrite around the record toolbox)
- Modify: `docs/effects.md` (Tools row + prose)

- [ ] **Step 1: rewrite `docs/tool-calling.md`.** Keep the page's front-matter, heading structure, and loop-mechanics sections, but re-order the tool-construction story: (1) the record toolbox (`Crucible.Tool.Generic.tools`, the `SupportTools` example from the module haddock, zero-arg fields, the compile-time guarantees: field-name uniqueness, total stubs, TypeError on non-handler fields); (2) single tools via `tool @"name"`; (3) `toolWith` for explicit codecs; (4) `rawTool` as the escape hatch with a hand-written schema. Replace the error-feedback section's prose with the structured story: `invoke` decodes args (failure: `BadArgs`), the loop renders `renderToolError` into the `tool_result`, showing a real rendered message:

```
tool issue_refund: arguments did not decode: key "amountCents" not found
expected schema: {"type":"object","properties":{...},"required":[...]}
you sent: {"orderId":"1234","amount":5900}
```

State explicitly: handler exceptions propagate (the loop's error policy covers the wire boundary only); the output side cannot produce a malformed result (output codec, total encoding). Ground every snippet in the real API (read `src/Crucible/Tool.hs` and `src/Crucible/Tool/Generic.hs`; mirror `app/Main.hs` idioms). House style: no emdashes, no hype words, no mention of the sibling project manifest.

- [ ] **Step 2: update `docs/effects.md`.** The `Tools` row of the effect summary table and any prose stating `CallTool`'s type: result is now `Either ToolError Value`; `runTools` reports unknown tools with the available names. Mention `tools` (record derivation) wherever the page lists tool construction.

- [ ] **Step 3: sweep + commit.**

Run: `grep -rnE 'toolRun|toolSchema|toolName|bad tool args|Either Text Value' docs/*.md` and fix any stale hits (docs/superpowers/ is exempt). Then:

```bash
git add docs/
git commit -m "$(printf 'docs(site): tool-calling manual for the typed Tool overhaul\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 5: final verification + merge + publish

**Files:** none (verification + git).

- [ ] **Step 1: full suite.** `nix develop . --command timeout -s KILL 300 zinc test` → `1 test suite(s) passed`.

- [ ] **Step 2: live smoke, both providers.** (Key names: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`; both live in `.env`, gitignored. NEVER print or echo them.)

```bash
nix develop . --command bash -c 'set -a; . ./.env; set +a; timeout -s KILL 300 .zinc/build/crucible-anthropic'
```

Expected: the full demo passes as before; the tool-agent lines (both providers, plain and streaming, cassette pair) still answer with the 26C weather text, now via the record toolbox.

- [ ] **Step 3: merge + push.** Handled by `superpowers:finishing-a-development-branch` (the user historically picks "merge back to master locally"); after merge: suite on master, `git push`, confirm `gh api repos/garethstokes/crucible/pages/builds/latest` shows a new build.

---

## Self-Review

**1. Spec coverage:** existential + constructors + invoke + renderToolError + Tools upgrade → Task 1. Error tests (BadArgs schema/raw, UnknownTool names, render content, scripted loop feedback) → Task 2. GTools + TypeErrors + zero-arg + unitCodec + field order + Main showcase → Task 3. Manual → Task 4. Live smoke + merge → Task 5. Non-goals (description field, checked merge, Profunctor) are absent by design; the no-Profunctor rationale lands in the Tool.hs haddock (Task 1). ✅

**2. Placeholder scan:** none; every code step is complete. The two consciously flexible points (HasField-on-GADT fallback, zero-arg schema rendering) give the implementer a concrete fallback, not a TODO. ✅

**3. Type consistency:** `Tool es` GADT fields (name/schema/input/output/run) match across Tasks 1-3; `tool @"name"` / `toolWith n inC outC f` / `rawTool n sch f` signatures consistent; `ToolError` constructors `UnknownTool ToolName [ToolName]` / `BadArgs ToolName DecodeError Value` used identically in Tasks 1, 2, and 4's prose; `tools :: (Generic t, GTools (Rep t) es) => t -> [Tool es]` matches between Task 3's module and its Spec/Main call sites; `Loc {locCity}` fixture matches the existing DevEx-cycle fixture. ✅
