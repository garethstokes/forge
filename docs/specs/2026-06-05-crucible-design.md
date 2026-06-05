# Crucible — Design Spec

**Date:** 2026-06-05
**Status:** Approved design, pre-implementation
**Author:** Gareth (with Claude)

> Working name: **crucible** — a crucible is where metal is forged and where things
> are tried by fire, fitting a `zinc`-built tool whose point is tests + evals. Rename freely.

## 1. Purpose

Crucible is an **exploration / learning vehicle**: an embedded Haskell eDSL for harnessing
prompts + tool calls, inspired by **BAML** (prompts as typed functions, schema-aligned parsing,
test blocks) and **12-factor-agents** (own your prompts, own your context, tools are structured
outputs, stateless control flow). The goal is **insight over polish** — to understand how the
three core agent patterns compose in Haskell's type system.

Success at 3 months = the three patterns below compose into one coherent design, with a working
example agent that is exercised by both deterministic **tests** and quality **evals**.

Built with **zinc** (git-native, Nix-assisted, no-solver Haskell build tool). Lives at
`~/code/garethstokes/crucible`.

## 2. The three patterns, unified

The intellectual center is that all three compose through **one unification**: in 12-factor
terms, *everything the model emits is a typed structured output*. A tool call and a final answer
are the same kind of thing:

```haskell
data Decision tool answer = CallTool tool | Done answer
```

- **Prompt-as-typed-function** produces a `Decision`. The output *type* drives the schema.
- **Pure reducer** consumes the `Decision` and decides the next step.
- **Typed tool dispatch** executes a `CallTool`, feeds the result back, loops.

Pure core (schema, parser, reducer) in the middle; effects (Anthropic HTTP, tool IO) only at the
edges via interpreters.

## 3. Architectural decisions (locked)

| Decision | Choice | Rationale |
|---|---|---|
| Delivery model | **Embedded eDSL**, no codegen | Lean into the type system; exploration, not a build pipeline |
| Effect substrate | **effectful** | The agent's *type is a capability manifest*; least-privilege tools compiler-enforced. Capability-typing is itself part of the exploration. |
| Structured output | **Own schema + SAP parser** (Approach A) | Schema-aligned parsing is BAML's signature idea and the most educational; provider-neutral; keeps the `Decision` unification clean; makes tests/evals tractable because the parser is *ours*, not a black box |
| Provider | **Anthropic** real interpreter + **scripted** (tests) + **recording** (cassettes) | One real backend in our ecosystem; provider-agnosticism deferred (YAGNI) |
| Test framework | **Dependency-light in-repo harness** | Avoid fighting zinc's no-solver git-pinned dep model over a deep tasty/hspec tree; consistent with the bespoke eval runner |

## 4. The pure core

```haskell
-- 1. A type that describes its own shape, derived for free via Generics.
class HasSchema a where
  schema :: Schema
  default schema :: (Generic a, GSchema (Rep a)) => Schema

data Schema = SObj [(Text, Schema)] | SArr Schema | SEnum [Text]
            | SStr | SNum | SBool | SOpt Schema

-- 2. Schema-aligned parsing: coerce messy model text into a typed value.
parseSAP  :: Schema -> Text -> Either ParseError Value   -- forgiving: fences, partials, trailing prose
fromModel :: HasSchema a => Text -> Either ParseError a  -- schema @a + SAP + decode

-- 3. The unification.
data Decision tool answer = CallTool tool | Done answer

-- 4. A prompt is a typed function whose OUTPUT type drives the injected schema.
data Prompt input output = Prompt
  { renderMessages :: input -> [Message]    -- injects `schema @output` into the prompt text
  , decode         :: Text -> Either ParseError output }
```

`fromModel @(Decision MyTools MyAnswer)` is the trick: one parser turns a reply into
"called a tool" or "done", using the Generics-derived schema of both. No provider-native tool
calling; fully testable.

## 5. The effectful shell

```haskell
-- The model, as an effect.
data LLM :: Effect where
  Complete :: [Message] -> LLM m Text
type instance DispatchOf LLM = Dynamic

-- Tool dispatch, as an effect. Registry hidden inside the interpreter.
data Tools :: Effect where
  Dispatch :: ToolName -> Value -> Tools m ToolResult
type instance DispatchOf Tools = Dynamic

-- Pure: state + parsed decision → next step.
reduce :: AgentState -> Decision ToolCall answer -> Step answer
data Step answer = Continue AgentState ToolCall | Halt answer

-- The control loop. Its TYPE is the capability manifest.
runAgent :: (LLM :> es, Tools :> es)
         => Prompt AgentState (Decision ToolCall answer)
         -> AgentState -> Eff es answer
runAgent p = loop where
  loop st = do
    raw <- complete (renderMessages p st)
    case decode p raw of
      Left err  -> loop (recordParseError st err)         -- feed parse failures back as context
      Right dec -> case reduce st dec of
        Halt answer       -> pure answer
        Continue st' call -> do
          result <- dispatch (toolName call) (toolArgs call)
          loop (appendResult st' call result)
```

### Capability typing

A tool *definition* names exactly the effects it needs; least-privilege is enforced because a
narrow effect's command language simply *lacks* the dangerous constructors:

```haskell
data Tool es = Tool { name :: ToolName, argSchema :: Schema, run :: Value -> Eff es ToolResult }

getWeather :: HTTP :> es     => Tool es   -- network only
readDoc    :: FileRead :> es => Tool es   -- read-only FS effect: no Write/Delete command exists
calcArea   ::                   Tool es   -- pure: provably inert
```

The agent's effect row is the **union** of its tools' authorities, so `runAgent`'s type tells you
everything it can touch, and **authority creep becomes a compile error**. The dynamic-dispatch
collapse (a runtime string can pick any tool, so the registry erases to the union row) lives
inside `runTools`; the teaching property survives at the `runAgent` boundary.

### The three LLM interpreters

```haskell
runLLMAnthropic :: IOE :> es        => Model -> ApiKey -> Eff (LLM : es) a -> Eff es a
runLLMScripted  :: State [Text] :> es =>                  Eff (LLM : es) a -> Eff es a  -- canned replies
recordLLM       :: IOE :> es        => FilePath -> Eff (LLM : es) a -> Eff (LLM : es) a -- wraps real, writes cassette
```

`recordLLM` is a `reinterpret` passing calls through to a real interpreter while appending each
`(request, response)` to a cassette file — the bridge between tests and evals.

## 6. Tests vs evals

The central conceptual split the whole design supports:

- **Tests** = *deterministic*, no model variance. Run against **scripted** or **cassette**
  interpreters. A failure means *your code* broke.
- **Evals** = *measure quality* over a dataset, tolerating variance. Run against the **real**
  model (sampled N times), or against cassettes for cheap regression. A regression means *quality*
  dropped, not that code is "wrong."

Cassettes are the slider: record once live, replay forever deterministically.

### Tests — four layers

1. **Pure reducer** — feed state + decision, assert next step. No effects.
2. **SAP golden tests** — messy fixture in → typed value out. The core parser tests (fenced JSON,
   trailing prose, trailing commas, truncated/partial objects).
3. **Schema golden** — derive `schema @MyType`, snapshot it.
4. **Scripted-loop** (BAML's "test block") — a list of canned replies + expected trajectory.

### Evals — small bespoke harness

```haskell
data Case i      = Case { input :: i, expect :: Expectation }
type Scorer a    = a -> Score                  -- Score = Double in [0,1] + rationale
data Expectation = Exactly Value | Predicate (a -> Bool) | Rubric Text  -- Rubric → LLM-as-judge

runEval :: (LLM :> es) => Dataset i -> Agent a -> [Scorer a] -> Eff es Report
-- Report: pass-rate, mean score, variance, per-case breakdown. Emits JSON + a human table.
```

The LLM-as-judge scorer is itself a crucible `Prompt` — the library evaluates itself. Run the
same eval **live** (is the model+prompt good?) or against **cassettes** (did my parser/reducer/
rendering regress while holding model output fixed?).

## 7. v1 scope (YAGNI) and build order

| # | Milestone | Defers |
|---|---|---|
| 0 | zinc builds hello-world + `aeson` + `http-client` (de-risk the build substrate) | — |
| 1 | `Schema` + Generics derivation + golden tests | recursive / nested-sum-with-fields types |
| 2 | **SAP parser** + golden tests (the meaty bit) | streaming / partial-as-you-go (v2) |
| 3 | `Prompt` + `Decision` + `fromModel` wiring | — |
| 4 | Pure `reduce` + tests | — |
| 5 | `LLM` effect + scripted interpreter → loop runs on canned replies | — |
| 6 | Anthropic interpreter + `recordLLM` → first live run, capture cassettes | provider-agnosticism |
| 7 | `Tools` effect + capability typing + one 2–3 tool example agent | dynamic per-tool row tracking |
| 8 | Eval harness: dataset, exact/predicate/judge scorers, report, cassette replay | — |

**Schema v1** covers: records (`SObj`), enums = nullary sum types (`SEnum`), `Maybe` (`SOpt`),
lists (`SArr`), `Text`/`Int`/`Double`/`Bool`.
**SAP v1** handles: code fences, leading/trailing prose, trailing commas, best-effort partial
objects.

## 8. Risks

- **zinc dependency wrangling** (no solver, git-pinned transitive deps) for `aeson` + an HTTP
  client is the main practical risk. Milestone 0 exists to de-risk it before the design leans on
  those deps.
- **Dynamic-dispatch collapse** of the tool effect row is accepted for v1; finer per-tool tracking
  (existentials / type-level tool lists) is a deliberate later spike, not v1.
- **SAP scope creep** — streaming/partial parsing is explicitly v2.
