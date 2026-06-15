# CoALA memory systems: gap analysis against crucible (research notes)

Date: 2026-06-15. Companion to `2026-06-11-agentic-memory.md` and the CoALA
memory framework (`Crucible.Memory`, `Crucible.Memory.Consolidate`,
`Crucible.Memory.Eval`, `Crucible.Embed`). Maps eleven published memory
systems against crucible's current implementation and identifies the gaps.

## Crucible baseline

| Component | Current state |
|---|---|
| `MemoryItem` fields | `memId`, `kind` (Episodic/Semantic/Procedural), `content`, `tags`, `source` (Provenance), `createdAt :: Int` |
| Recall | lexical only: case-folded infix `needle` + tag intersection, most-recent-first, `maxItems` budget |
| Persistence | append-only JSONL file; `forget` is a tombstone, never erases |
| Embeddings | `Embed` effect + `cosine` helper exist; **not wired to memory store** |
| Consolidation | explicit on-demand `consolidate` skill: `[MemoryItem] → ConsolidationPlan (Keep\|Drop\|Supersede\|Merge)` |
| Context injection | manual: `withMemories` / `memoryLift` in Eval; no automatic injection |
| Skill type | static Haskell definitions; no runtime skill store |
| Chat / working memory | stateless; caller manages the message list; no paging |

Already-filed beads issues:
- `crucible-try` — semantic retrieval (embedding-indexed recall from the memory store)
- `crucible-5yg` — working memory / context window paging
- `crucible-omw` — cross-session episodic recall with recency+importance+relevance ranking

---

## Episodic memory — "what happened"

### Generative Agents (Park et al., Stanford 2023) — arXiv 2308.09234

25 simulated agents in "Smallville": memory stream per agent, every observation
stored with timestamp, LLM self-rated importance (1–10), and embedding.
Retrieval = weighted sum of recency (exponential decay) + relevance (cosine) +
importance. A "reflection" pass periodically clusters related episodes and
distils them into semantic facts. Without reflection, social coordination
collapsed entirely.

| Requirement | Crucible | Gap |
|---|---|---|
| Timestamp per item | ✓ `createdAt :: Int` | — |
| **Importance score at write time** (LLM self-rates 1–10) | ✗ no field | Add `importance :: Maybe Double` to `MemoryItem`; call LLM once at `remember` to score |
| **Embedding stored per item** | ✗ `Embed` exists but not called at write time | Store `[Double]` on `MemoryItem`; `runMemoryFile` must call `embed` on every `remember` |
| **Weighted retrieval** recency + relevance + importance | ✗ lexical only | `score = α·recency_decay + β·cosine(query_vec, item_vec) + γ·importance` — `crucible-omw` covers the ranking shape; importance + embedding are prerequisites |
| **Embedding-based clustering before reflection** | ✗ consolidation picks items freely | Cluster by cosine similarity before calling `consolidationSkill`, so related episodes distil together |

New gaps: importance field (`crucible-TBD-1`), embedding at write time (`crucible-TBD-2`), clustering before consolidation (`crucible-TBD-3`). `crucible-omw` covers weighted ranking once those prerequisites land.

---

### Reflexion (Shinn et al., NeurIPS 2023) — arXiv 2303.11366

Verbal reinforcement learning without weight updates. After each failed trial
the agent writes a self-critique and stores it in a bounded episodic buffer
(max 3 entries, FIFO). Buffer is prepended to the next trial's context.
91% pass@1 on HumanEval vs GPT-4's 80%.

| Requirement | Crucible | Gap |
|---|---|---|
| Write self-critique after failure | ✓ `remember` with `BySession` provenance can do this | Needs a `reflectOnFailure :: Report → Eff es MemoryDraft` helper |
| **Bounded FIFO buffer** (max N, oldest dropped) | ✗ `maxItems` is a read-budget, not a write cap | A `recallLatest :: Int → Eff es [MemoryItem]` that returns only the N most-recent episodic items |
| **Auto-prepend buffer to next trial context** | ✗ `withMemories` exists but is manual | A `withReflections :: Int → Skill i o → Skill i o` combinator: recall last-N episodic, prepend to preamble |

This is the simplest system to approximate — all pieces exist, only the combinator is missing.

---

### MemGPT / Letta (Packer et al., UC Berkeley 2023) — arXiv 2310.08560

OS-inspired virtual memory. Two tiers: in-context working memory (FIFO
conversation queue + scratchpad) and external disk store. The LLM itself
issues function calls (`read_from_archival`, `write_to_archival`,
`edit_core_memory`) to page data between tiers.

| Requirement | Crucible | Gap |
|---|---|---|
| External store (disk) | ✓ JSONL file | — |
| **In-context working memory tier** (FIFO queue + scratchpad) | ✗ `Chat` is stateless | Needs a `WorkingMemory` record `{systemPrompt, conversationQueue :: Seq Message, scratchpad :: Text}` managed by the chat runner (`crucible-5yg`) |
| **LLM-callable memory tools** | ✗ no tool interface to `Memory` effect | Expose `remember`/`recall`/`forget` as `Tool` definitions; wire into `runToolAgentN` |
| Automatic paging when context fills | ✗ | Token-count tracking + eviction in the chat runner (`crucible-5yg`) |
| Scratchpad (writable in-context zone) | ✗ | Mutable `Text` cell updated via tool call |

The paging and scratchpad belong to `crucible-5yg`. The tool-callable memory
interface is a separate new gap.

---

### OpenAI ChatGPT Memory / "dreaming" (production, 2024–2025)

Cross-session episodic + semantic. A background synthesis process
auto-curates facts from past chats and injects them into the system prompt.
Factual recall improved 67.9% → 82.8% with the 2025 "dreaming" update.

| Requirement | Crucible | Gap |
|---|---|---|
| Cross-session persistence | ✓ JSONL store | — |
| Background/post-session consolidation trigger | ✓ partial — `consolidate` exists but is explicit/on-demand | A session lifecycle hook: `onSessionEnd :: Eff es ()` that runs `consolidate` automatically |
| **Auto-injection of top memories at session start** | ✗ `withMemories` is manual | A session initializer: `recall` top-k, prepend to `Instruction.preamble` |
| Importance/preference weighting at write time | ✗ | Same as Generative Agents gap |

---

## Semantic memory — "what is true"

### RAG (Lewis et al., Facebook AI 2020)

Documents embedded into a vector store; query-time ANN retrieval injects
relevant chunks into context. Now production-ubiquitous.

| Requirement | Crucible | Gap |
|---|---|---|
| Documents embedded and stored | ✗ | Ingest pipeline: chunk → `embed` → store `(chunk, vector)` as `Semantic` `MemoryItem` |
| **Query-time ANN / cosine retrieval** | ✗ lexical only | Brute-force cosine over stored vectors is sufficient to ~10k items; `crucible-try` |
| Injection of retrieved chunks into context | ✗ manual only | Auto-injection helper (same as session-start gap above) |

`crucible-try` covers the retrieval path; the ingest pipeline is the write-side complement.

---

### Microsoft GraphRAG (2024) — github.com/microsoft/graphrag

Extends RAG to a knowledge graph: GPT-4 extracts entities and relationships,
builds a relational store with Leiden community detection. Enables multi-hop
reasoning. 20k+ GitHub stars, used in Copilot/Azure AI.

| Requirement | Crucible | Gap |
|---|---|---|
| Entity/relationship extraction | ✗ | A `Skill` returning `[(Entity, Relation, Entity)]` — doable with structured output |
| **Knowledge graph store** | ✗ no graph data structure | New `Graph` module — entirely absent |
| Community detection (Leiden) | ✗ | External algorithm |
| Multi-hop relational queries | ✗ | Graph traversal on the store |

Large architectural gap — a full graph store is a new module category. Out of
scope until RAG (flat vector) is solid.

---

### HuggingGPT / JARVIS (Shen et al., Microsoft/Zhejiang, NeurIPS 2023) — arXiv 2303.17580

LLM as controller: routes subtasks to specialist models by reading a semantic
store of tool capability metadata.

| Requirement | Crucible | Gap |
|---|---|---|
| Tool capability registry | ✓ partial — `Tool` type has `name`, `description`, `inputSchema`; injected statically into prompt | Gap: descriptions are in the prompt, not in a queryable store |
| **Semantic tool routing** (embed query → cosine over tool descriptions → select tool) | ✗ | `selectTool :: [Tool] → Text → Eff es Tool` using `embed` + `cosine` over tool descriptions |
| Multi-model orchestration | ✗ | Single LLM interpreter per run; no sub-agent dispatch |

Tool routing is achievable with existing `Embed` + `cosine` — just needs the combinator.

---

## Procedural memory — "how to act"

### Voyager (Wang et al., NVIDIA/Caltech 2023) — arXiv 2305.16291

Ever-growing library of verified executable routines, each stored with an NL
description and indexed by embedding. New skills added compositionally, never
overwritten. 3.3× more unique items, 15.3× faster tech-tree progression.

| Requirement | Crucible | Gap |
|---|---|---|
| Named reusable skills | ✓ `Skill i o` with `name` | — |
| **Runtime skill store** (skills added/retrieved at run time) | ✗ skills are static Haskell definitions | A `SkillStore`: `Procedural` `MemoryItem`s whose `content` is the skill's serialized description; retrieved by embedding similarity |
| **Embedding-indexed skill retrieval** | ✗ | `embed` the task goal, cosine over stored skill descriptions, return top-k |
| Compositional skill building | ✓ partial — Haskell function composition is static | Dynamic composition is blocked on the runtime store |
| **Verification before adding to library** | ✗ | Run `testSkill` on the candidate before `remember`-ing it; a `verifyAndStore` combinator |

---

### Agent Workflow Memory / AWM (Wang et al., CMU/MIT, ICML 2025) — arXiv 2409.07429

Compresses episodic traces into reusable `{goal, routine}` workflow objects.
Online (test-time) induction from current session. +24.6% Mind2Web, +51.1%
WebArena.

| Requirement | Crucible | Gap |
|---|---|---|
| Distil episodes into procedures | ✓ partial — `consolidate` can produce `ByConsolidation` items | Gap: consolidation output is free-form `MemoryItem`; no typed `Workflow = {goal :: Text, routine :: [Step]}` |
| **Typed `Workflow` type** | ✗ | New type; `recallAs` with a `WorkflowCodec` could retrieve it from `Procedural` memory items |
| **Workflow store with goal-similarity retrieval** | ✗ | Needs embedding at write time + cosine retrieval (`crucible-try` is prerequisite) |
| Online (mid-session) induction | ✗ | `consolidate` running on the current session's `[MemoryItem]` before each new task |
| Inject retrieved workflow as plan | ✗ | `withWorkflow :: Text → Skill i o → Skill i o`: recall best-fit workflow by goal, prepend steps to preamble |

`consolidate.hs` covers the distillation; typed `Workflow` + similarity
retrieval are the missing pieces.

---

### CodeAct (Wang et al., UIUC/MIT, ICML 2024) — arXiv 2402.01030

Action space is executable Python. Stateful interpreter persists across turns;
prior code actions become reusable procedural artifacts. Up to 20% higher
success across 17 LLMs.

| Requirement | Crucible | Gap |
|---|---|---|
| Stateful code interpreter | ✗ | Sandboxed process (Python/shell) exposed as a `Tool` — different action model entirely |
| Prior code reusable across turns | ✗ | Requires the interpreter; blocked on that |
| Action space as executable code | ✗ | Crucible's action space is typed tool calls (JSON); code-as-action is a distinct paradigm |

Largest gap — requires a new action model, not a new store. Low priority
unless crucible grows a code-execution tool.

---

### LangMem SDK procedural (LangChain 2025) — langchain.com/blog/langmem-sdk-launch

Stores procedural memory as live system prompt updates. Three algorithms
analyse interaction trajectories and rewrite the agent's instructions; the
updated prompt becomes default behaviour with no retrieval step.

| Requirement | Crucible | Gap |
|---|---|---|
| Trajectory analysis for behavioral patterns | ✗ | A `Skill` that reads `[MemoryItem]` and extracts recurring patterns — structurally like `consolidationSkill` |
| **`improveInstruction` — rewrite instruction from memory** | ✗ | Analogous to `improveSkill` in `Crucible.Skill.Improve`; takes `[MemoryItem] → Instruction → Eff es Instruction` |
| **Persistent instruction store** (updated instruction survives across sessions) | ✗ `Instruction` is static at call site | A persisted `Instruction` file read at session start, written after `improveInstruction` runs |
| No retrieval step — updated prompt IS default behavior | ✗ | Achieved once the instruction store is persistent |

`improveSkill` is the closest existing piece; the gap is durability —
making the improved instruction persist to disk rather than being returned
to the caller to re-supply.

---

## Summary matrix

| System | Biggest single gap | Closest existing piece | Beads |
|---|---|---|---|
| Generative Agents | Importance field + embedding at write + weighted recall | `crucible-omw` (ranking), `crucible-try` (embedding) | new: importance field, embedding at write, clustering |
| Reflexion | `withReflections N` combinator | `withMemories` + `recall` almost sufficient | new: combinator |
| MemGPT | Tool-callable memory interface + working memory tier | `crucible-5yg`; `Tool` type exists | new: tool-callable memory interface |
| ChatGPT Memory | Auto-injection at session start + lifecycle hooks | `consolidate` + `withMemories` both exist | new: session lifecycle hooks |
| RAG | Embedding at ingest + cosine retrieval | `crucible-try`; `Embed` + `cosine` exist | ingest pipeline is write-side of `crucible-try` |
| GraphRAG | Graph store (no analogue exists) | `Skill` for extraction only | low priority; skip until flat RAG solid |
| HuggingGPT | `selectTool` by embedding similarity | `Tool` type + `Embed` both exist | new: selectTool combinator |
| Voyager | Runtime `SkillStore` + embedding retrieval + `verifyAndStore` | `Skill` + `Memory` JSONL + `Embed` — need wiring | new: SkillStore |
| AWM | Typed `Workflow` + similarity retrieval + online induction | `consolidate.hs` covers distillation | new: Workflow type + retrieval |
| CodeAct | Stateful code interpreter as a `Tool` | nothing — different action model | skip / very low priority |
| LangMem | Persistent instruction store + `improveInstruction` | `improveSkill` in `Skill.Improve` | new: persistent instruction store |

## High-leverage cross-cutting gaps

Two gaps unblock the most systems simultaneously:

1. **Importance scoring at write time** (new field on `MemoryItem`, LLM call
   in `remember`) — unblocks Generative Agents ranking, ChatGPT Memory
   preference weighting, any composite recall score.

2. **Embedding at write time + cosine recall** (write-side of `crucible-try`)
   — unblocks RAG ingest, Voyager skill retrieval, HuggingGPT tool routing,
   AWM workflow retrieval. All four are currently blocked on the same
   missing write-side wiring.
