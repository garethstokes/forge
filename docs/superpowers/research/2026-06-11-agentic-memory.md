# Agentic memory architectures: survey and implications for crucible (research notes)

Date: 2026-06-11. In-repo notes surveying memory systems for LLM agents:
the founding papers, the last six months (Dec 2025 - Jun 2026), failure
modes, and what (if anything) crucible should do about it. Companion to
the other notes in this directory. Not published.

## Summary

Every serious agent memory system, from MemGPT to OpenAI's June 2026
Dreaming rollout, decomposes into the same three policies: a write policy
(what is worth remembering), a consolidation policy (how stored memories
get compacted, merged, and invalidated), and a retrieval policy (what
surfaces into context, under a token budget). Writes happen inline and
cheap; consolidation increasingly runs as background "sleep-time" compute;
retrieval is moving from "load everything" to just-in-time tool calls.
The field's strongest recent results (Mem0, Zep, Dreaming V3) come from
treating memory as explicit update operations over typed records with
provenance and time validity, not from bigger context windows. For coding
agents specifically, plain files won: curated CLAUDE.md-style indexes,
Anthropic's file-command memory tool, and beads-style git-backed issue
graphs. The main failure modes are poisoning, staleness, retrieval
drowning, and write amplification; all four are mitigated by gating,
provenance, invalidation-not-deletion, and budgeted recall.

## Architectures

### Core canon

**MemGPT / Letta (Oct 2023).** "MemGPT: Towards LLMs as Operating
Systems" ([arXiv 2310.08560](https://arxiv.org/abs/2310.08560)) frames
the LLM as a process on a memory-constrained OS and pages between tiers:
main context (the window: system prompt, recent messages, pinned memory
blocks), recall storage (searchable log of all past messages), and
archival storage (vector-indexed cold store). The defining move is that
the agent itself manages memory via tool calls (`core_memory_append`,
`archival_memory_search`); memory management is in-band, not a wrapper
([Letta docs](https://docs.letta.com/letta-memgpt)). The lasting
contributions are the tiered hierarchy and self-editing memory blocks.

**Generative Agents (Apr 2023).** Park et al.
([arXiv 2304.03442](https://arxiv.org/abs/2304.03442)) introduced the
memory stream: an append-only log of natural-language observations with
timestamps. Retrieval scores every memory as a weighted sum of recency
(exponential decay since last access), importance (an LLM-assigned
scalar per memory), and relevance (embedding similarity to the query).
Reflection periodically clusters recent memories and writes higher-level
inferences back into the stream as first-class memories. This paper
contributed the three-factor retrieval score and the idea that
consolidation output is itself a memory.

**CoALA (Sep 2023).** "Cognitive Architectures for Language Agents"
([arXiv 2309.02427](https://arxiv.org/abs/2309.02427)) is the canonical
taxonomy: episodic memory (instance-specific experiences), semantic
memory (abstracted facts), procedural memory (skills and code). The
2025-2026 ecosystem converged on exactly this split; LangMem, for
example, ships the three types directly
([LangMem docs](https://langchain-ai.github.io/langmem/)).

**HippoRAG (May 2024) and HippoRAG 2 (Feb 2025).** HippoRAG
([arXiv 2405.14831](https://arxiv.org/abs/2405.14831), NeurIPS 2024)
models the hippocampal index: an LLM extracts a schemaless knowledge
graph from the corpus, and at query time the query's concepts seed
Personalized PageRank over that graph, so retrieval follows association
chains rather than flat similarity; up to 20% gains on multi-hop QA.
HippoRAG 2 ([arXiv 2502.14802](https://arxiv.org/abs/2502.14802),
ICML 2025) reframes this as non-parametric continual learning and fixes
the factual-recall regression that graph-first methods had versus plain
RAG. Contribution: retrieval as graph traversal seeded by the query, and
the framing that a good index is what makes a store a memory.

**A-MEM (Feb 2025).** "A-MEM: Agentic Memory for LLM Agents"
([arXiv 2502.12110](https://arxiv.org/abs/2502.12110), NeurIPS 2025)
applies Zettelkasten discipline: each write becomes a structured note
(content, context description, keywords, tags), the system links it to
related existing notes, and crucially new notes can trigger updates to
old notes' attributes ("memory evolution"). Contribution: writes are
enrichment plus linking, and old memories are mutable on new evidence.

**Mem0 (Apr 2025).** ([arXiv 2504.19413](https://arxiv.org/abs/2504.19413))
The production-engineering paper. Two phases: extraction (pull salient
facts out of the rolling conversation) and update (an LLM decides per
fact whether to ADD, UPDATE, DELETE, or NOOP against the existing store).
Mem0g adds a typed entity-relation graph with conflict flagging. Reported
26% relative improvement over OpenAI's then-memory on LoCoMo judge
metrics, 91% lower p95 latency and >90% token savings versus full
context. Contribution: memory writes as an explicit four-way decision,
and evidence that a small curated store beats hauling full history.

**Zep / Graphiti (Jan 2025).** "Zep: A Temporal Knowledge Graph
Architecture for Agent Memory"
([arXiv 2501.13956](https://arxiv.org/abs/2501.13956);
[Graphiti](https://neo4j.com/blog/developer/graphiti-knowledge-graph-memory/))
contributes bi-temporality: every edge carries valid time (when the fact
was true in the world) and ingestion time, as explicit t_valid/t_invalid
intervals. When new knowledge conflicts with old, the old edge is
invalidated, not deleted, preserving history and provenance
([Zep](https://www.getzep.com/ai-agents/temporal-knowledge-graph/)).
Contribution: staleness is a temporal-validity problem, and the right
mutation is supersession.

### The last six months (Dec 2025 - Jun 2026)

**Consolidation went background and became product.** Letta's sleep-time
compute ([arXiv 2504.13171](https://arxiv.org/abs/2504.13171),
[blog](https://www.letta.com/blog/sleep-time-compute)) pairs a primary
agent with a sleep agent that runs during idle time, turning raw context
into "learned context"; in 2026 these workflows moved client-side with
the agent's own tools ([Letta](https://www.letta.com/blog/our-next-phase)).
OpenAI shipped the same shape at consumer scale on June 4, 2026:
Dreaming V3 ([OpenAI](https://openai.com/index/chatgpt-memory-dreaming/))
replaces the manually curated saved-memories list with an asynchronous
background process that synthesizes across years of conversations and
revises memories as time passes ("you're going to Singapore in July"
becomes "you went to Singapore in July 2026"). Their evals: factual
recall task success 41.5% (2024 saved memories) to 82.8% (Dreaming V3),
time-sensitive updates 9.4% to 75.1%, with a ~5x compute reduction in
the synthesis pipeline
([coverage](https://www.edtechinnovationhub.com/news/openai-rolls-out-new-chatgpt-memory-system-to-keep-personalization-current)).
Consolidation quality, not retrieval cleverness, drove the gains.

**Files won for coding agents.** Anthropic's memory tool
([docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool))
is deliberately boring: client-side file commands (view, create,
str_replace, insert, delete, rename) against a `/memories` directory,
with a system-prompt protocol of "check memory first, record progress,
assume interruption." It pairs with context editing and compaction so
memory survives context resets. Claude Managed Agents memory stores
(public beta April 23, 2026) mount workspace-scoped document stores as
directories the agent edits with ordinary file tools, with audit logs
and export ([Claude blog](https://claude.com/blog/claude-managed-agents-memory),
[docs](https://platform.claude.com/docs/en/managed-agents/memory));
Rakuten reports 97% fewer first-pass errors on long-running task agents.
CLAUDE.md / AGENTS.md files are the static layer: a small curated index
loaded every session, deliberately exempt from context expiry
([Milvus analysis](https://milvus.io/blog/claude-code-memory-memsearch.md)).
Steve Yegge's beads ([GitHub](https://github.com/steveyegge/beads),
[intro](https://steve-yegge.medium.com/introducing-beads-a-coding-agent-memory-system-637d7d92514a))
treats a git-backed, dependency-aware graph issue tracker as the agent's
long-horizon memory, with hash-based IDs to survive merges and semantic
"memory decay" that summarizes old closed tasks. The shared insight:
for coding agents, memory that lives in versioned plain text the agent
already knows how to edit beats a bespoke memory service. This repo's
own bd usage is exactly this pattern.

**Benchmarks matured past LoCoMo.** LoCoMo (1,540 questions over
multi-session conversations) is still the most-reported number but is
now considered short by 2026 standards and does not score knowledge
updates ([Mem0 state-of-memory](https://mem0.ai/blog/state-of-ai-agent-memory-2026),
[EmergentMind](https://www.emergentmind.com/topics/locomo-benchmark-d06cff1a-d4a5-4df8-ab85-fdca157d190b)).
Successors: LongMemEval (500 questions including knowledge-update and
multi-session categories), BEAM (1M and 10M token scales; systems lose
about 25% scaling 10x, e.g. 64.1 to 48.6, so the open problem is
temporal abstraction, not retrieval), MemoryAgentBench (four
competencies: accurate retrieval, test-time learning, long-range
understanding, selective forgetting), and AMA-Bench for agentic
applications ([arXiv 2602.22769](https://arxiv.org/abs/2602.22769)).
Surveys: [arXiv 2603.07670](https://arxiv.org/abs/2603.07670) (memory
mechanisms and evaluation), [arXiv 2602.19320](https://arxiv.org/abs/2602.19320)
(taxonomy and system limitations).

**Forgetting became a designed policy.** FadeMem
([arXiv 2601.18642](https://arxiv.org/abs/2601.18642)) implements
Ebbinghaus-style differential decay where important memories decay
slower. FSFM ([arXiv 2604.20300](https://arxiv.org/abs/2604.20300))
gives a taxonomy of forgetting mechanisms: passive decay, active
deletion, safety-triggered, and adaptive reinforcement-based. An
ACT-R-inspired architecture retrieves and forgets by context, time, and
usage frequency ([HAI 2025](https://dl.acm.org/doi/10.1145/3765766.3765803)).
AgeMem-style work treats the five memory operations (store, retrieve,
update, summarize, discard) as tools in the agent's policy and trains
the pipeline with RL; the learned tactics are mundane and instructive,
e.g. discard records semantically similar to existing ones
([survey discussion](https://arxiv.org/html/2603.07670v1)). The
episodic/semantic/procedural split also got procedural-specific work:
ProcMEM learns reusable procedures from experience
([arXiv 2602.01869](https://arxiv.org/abs/2602.01869)).

## Memory shapes: linear, star, tree, graph

The architectures above differ less in their policies than in the shape
of the store those policies operate on. The literature does draw this
line, though not always with these names. The graph-memory survey
([arXiv 2602.05665](https://arxiv.org/abs/2602.05665)) splits memory
into non-structural ("linear or buffer-based memory, such as fixed-length
token windows or conversation histories, which maintain recent
interactions but suffer from information loss and lack relational
context") and structural (trees, knowledge graphs, temporal graphs,
hypergraphs, hybrids). A unified benchmark
([arXiv 2604.01707](https://arxiv.org/abs/2604.01707)) compares flat,
hierarchical, vector, and graph storage head to head. The star shape is
the one the papers do not name; the closest published concept is the
profile versus collection distinction in LangMem
([conceptual guide](https://langchain-ai.github.io/langmem/concepts/conceptual_guide/))
and entity-centric user-model work
([arXiv 2510.07925](https://arxiv.org/abs/2510.07925)). The lens earns
its keep because each shape makes a different set of operations cheap,
and most memory-system pathology is a shape mismatch.

**Linear: an ordered, append-only sequence.** Transcripts, episodic
streams, event logs. Generative Agents' memory stream is the canonical
example; MemGPT's recall storage is a searchable linear log. Cheap:
append (constant time, no reconciliation), replay, recency windows, and
compaction by summarizing a prefix. Expensive: cross-cutting recall
("everything we know about X") needs a scan or an external index, and
multi-hop relational questions fail outright; the unified benchmark
finds systems without connection mechanisms (MemoryBank, MemGPT) do
poorly on exactly those tasks. Linear is also the only shape that
preserves full ordering and provenance for free, which is why every
other shape is derived from a linear substrate rather than replacing it.
In crucible: a Skill call's message transcript is a linear memory, a
cassette is a linear memory persisted to disk (an ordered recording you
replay), and `AgentState` is literally
`newtype AgentState = AgentState { transcript :: [Message] }`.

**Star: one hub entity with typed spokes.** A profile: a single record
about a known subject (the user, the project, the deployment) whose
fields are slots filled and overwritten in place. LangMem's profile is
the explicit version: a schema-bound document representing current
state, where "when new information arrives, it updates the existing
document rather than creating a new one," versus a collection, which
must reconcile each insert against prior beliefs. ChatGPT's pre-Dreaming
saved-memories list and classic slot-filling user models are stars.
Cheap: retrieval is a constant-time lookup of the whole record, it
always fits a known token budget, and humans can read and edit it.
Expensive: the write side, because every update is read-modify-write
with conflict resolution at write time; anything outside the schema is
dropped or shoehorned; history is lost unless versions are kept; and
queries across many entities are unsupported (many stars do not make a
graph until you link them). Star is the natural consolidation target
for personalization: Dreaming-style pipelines read linear transcripts
and emit star-shaped state.

**Tree: hierarchy of summaries.** Leaves hold raw items, internal nodes
hold summaries of their children, so the same store answers at any
granularity. MemTree ([arXiv 2410.14052](https://arxiv.org/abs/2410.14052))
routes each new item from the root toward semantically similar leaves
and recursively updates ancestor summaries; MemForest adds hierarchical
temporal indexing ([arXiv 2605.23986](https://arxiv.org/abs/2605.23986)).
Cheap: budget-bounded recall (take a shallow summary or descend for
detail) and built-in consolidation, since compaction is the structure.
Expensive: write amplification (every insert touches its ancestors'
summaries) and repair when early clustering was wrong. Empirically
trees are the strongest single shape on long-conversation benchmarks:
the unified benchmark has MemTree topping LongMemEval F1 at the 7B
scale, with the caveat that accuracy correlated with token spend and
rule-based hierarchical systems degraded more gracefully at scale.

**Graph: arbitrary nodes and links.** A-MEM's Zettelkasten notes,
Zep/Graphiti's bi-temporal knowledge graph, HippoRAG's hippocampal
index, Mem0g's entity-relation store. Cheap at read time: multi-hop and
relational recall, entity-centric queries, per-edge temporal validity.
Expensive at write time: each insert is extraction plus linking plus
conflict resolution, typically one or more LLM calls, and retrieval
pays traversal latency. The costs are measurable: Mem0's own evaluation
([arXiv 2504.19413](https://arxiv.org/abs/2504.19413)) has the graph
variant Mem0g buying about 1.5 points of LoCoMo judge score over flat
Mem0 at roughly half again the search latency, which is why their
production guidance keeps the graph as an augmentation, not the base
([Mem0 graph-memory comparison](https://mem0.ai/blog/graph-memory-solutions-ai-agents)).

**When does which shape win?** The graph survey's own verdict is "there
is no single paradigm that fits all scenarios." Linear wins when order
and completeness matter (debugging, audit, replay, short tasks) and
when write cost must be near zero. Star wins when there is one obvious
subject, a stable schema, and a hard recall budget. Tree wins on long
single-stream histories needing recall at mixed granularity. Graph wins
when questions are relational and multi-hop across many entities, or
when fact validity changes over time. Two recent results push back on
reaching for structure early: SimpleMem
([arXiv 2601.02553](https://arxiv.org/abs/2601.02553)) gets a 26.4%
average F1 gain on LoCoMo with up to 30x fewer inference tokens from
aggressive semantic compression over a flat store, arguing density beats
topology; and FluxMem ([arXiv 2602.14038](https://arxiv.org/abs/2602.14038))
treats the shape itself as a learned per-interaction choice among
complementary structures, which only makes sense if no fixed shape
dominates.

**Consolidation is a shape change.** Read the three-policy summary
through this lens and consolidation is the pump that moves information
from linear toward star and graph: Mem0's extract-and-update reads a
rolling linear transcript and maintains a star-ish fact store, A-MEM
turns linear arrivals into graph notes and links, Dreaming reads years
of linear history and rewrites star-shaped user state, MemTree folds a
linear stream into a tree as it arrives. The linear layer is where
truth enters; the structured layers are derived views bought with
consolidation compute. In crucible's terms: skills and cassettes stay
linear, a profile record with a `HasCodec` instance is the star, a wiki
of linked pages is the graph, and a consolidation Skill is the thing
that moves content across shapes.

## Failure modes and disciplines

**Memory poisoning.** Persistent memory turns prompt injection into a
time bomb: poison written today fires weeks later when semantically
triggered. MINJA achieves >95% injection success and ~70% attack success
through query-only interaction in idealized settings, though realistic
stores with pre-existing legitimate memories blunt it substantially
([arXiv 2601.05504](https://arxiv.org/abs/2601.05504)). MemoryGraft
implants fake "successful experiences" that the agent later imitates
([ResearchGate](https://www.researchgate.net/publication/398936727_MemoryGraft_Persistent_Compromise_of_LLM_Agents_via_Poisoned_Experience_Retrieval));
Zombie Agents shows self-reinforcing injections in self-evolving agents
([arXiv 2602.15654](https://arxiv.org/abs/2602.15654)). Disciplines:
gate writes (trust scoring, two-stage static plus semantic filters),
record provenance on every memory so entries can be traced and bulk
revoked, and trust-aware retrieval with temporal decay
([survey, arXiv 2604.16548](https://arxiv.org/html/2604.16548v1)).

**Stale facts.** A memory that was true becomes confidently wrong;
Mem0's 2026 review lists staleness as a top production gap
([state of memory](https://mem0.ai/blog/state-of-ai-agent-memory-2026)).
Disciplines: bi-temporal validity and supersession instead of deletion
(Zep/Graphiti), update-or-invalidate decisions at write time (Mem0's
UPDATE/DELETE), and time-aware background revision (Dreaming V3's
explicit tense rewriting).

**Retrieval drowning / context rot.** Indiscriminately loading memory
degrades reasoning even below synthetic-benchmark expectations; the
lost-in-the-middle effect compounds it
([TechAhead overview](https://www.techaheadcorp.com/blog/context-rot-problem/),
[survey](https://arxiv.org/abs/2602.06052)). Disciplines: just-in-time
retrieval through tools rather than preloading, hard token budgets on
recall, and a small pinned core (CLAUDE.md-sized) with everything else
behind search. Anthropic's memory tool docs explicitly frame memory as
the primitive for just-in-time context
([docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool)).

**Write amplification.** Storing everything makes every later stage
worse: bigger stores, noisier retrieval, costlier consolidation. The
discipline is a salience gate at write time (Mem0's extraction phase and
NOOP option; A-MEM's structured note creation) plus dedupe against
near-identical existing records, and periodic summarize-and-drop of cold
entries (beads' decay of closed issues is the coding-agent version).

**The recurring pattern.** Write policy runs inline but cheap (extract,
gate, tag, NOOP when in doubt). Consolidation runs in the background
(merge, supersede, reflect, decay); this is where sleep-time compute
spends. Retrieval runs inline under a budget (scored or searched, never
"all of it"). Systems that collapse these into one mechanism (append
everything, embed, top-k) exhibit all four failure modes at once.

## Recommendations for crucible

Crucible models capabilities as dynamic effects with scripted, cassette,
and live interpreters (`Crucible.LLM`, `Crucible.Emit`, `Crucible.Chat`).
Memory fits this house style unusually well, because the literature's
winning storage layer for coding agents is plain files and the winning
write discipline is typed records, both of which crucible already has
machinery for (Codec, Skill, Eval). Concretely:

1. **A `Memory` effect, small like `Emit`.** Two or three operations:

   ```haskell
   data Memory :: Effect where
     Remember :: MemoryItem -> Memory m MemoryId
     Recall   :: Query -> Memory m [MemoryItem]
     Forget   :: MemoryId -> Memory m ()   -- supersede, not erase
   ```

   `MemoryItem` is a record with a kind (`Episodic | Semantic |
   Procedural`, per CoALA), text content, tags, and provenance (source
   skill or session, created-at, optional superseded-by). Provenance is
   not optional; it is the poisoning and staleness discipline made
   structural. `Query` starts as tags plus a free-text needle and a
   result budget (`maxItems`). The budget lives in the type so retrieval
   drowning is a caller decision, not an accident.

   Name the shape in the design instead of implying it. The operations
   above are shape-agnostic, but the shipped story should be linear
   plus star: the store itself is a linear append-ordered log (which is
   what a JSONL file interpreter is anyway, and what crucible's
   cassettes already are), and the one structured view is the star, a
   typed profile record recalled whole (point 3 below). Tree and graph
   stay interpreter territory: `Recall` by tags and needle works
   unchanged against a MemTree- or Graphiti-backed interpreter, and the
   comparative evidence (SimpleMem, the Mem0 versus Mem0g gap) says
   relational structure should be bought when multi-hop recall
   demonstrably needs it, not by default.

2. **Interpreters in the existing three flavors.**
   `runMemoryScripted` (canned recalls, for tests, mirroring
   `runLLMScripted`), `runMemoryPure` (a `Map` in local `State`, for
   property tests of write/recall laws), and `runMemoryFile` (a
   directory of JSON or markdown files under a root, one file per item
   or a JSONL log plus index). The file interpreter is the right first
   live backend: it matches Anthropic's memory tool, CLAUDE.md practice,
   and beads, it is git-diffable so humans can audit what the agent
   believes, and it needs no services. Lexical and tag matching first;
   no embeddings.

3. **Typed memories via Codec.** Offer an optional typed payload:
   `rememberTyped :: JSONCodec a -> a -> ...` storing the value plus its
   schema text, and `recallTyped` decoding through the existing tolerant
   `Crucible.Decode` path. This is the one thing crucible can do that no
   Python memory library does: a recalled memory that fails to decode
   against today's schema is automatically stale, which turns schema
   evolution into a forgetting policy for free. It is also the star
   shape made concrete: a `HasCodec` profile record is a hub entity
   with typed spokes, recalled whole under a known budget, the LangMem
   profile pattern with a compiler behind it.

4. **Consolidation as an offline Skill, not a daemon.** Define a
   `Skill [MemoryItem] ConsolidationPlan` where the plan is keep, merge
   (with replacement text), supersede, or drop per item, then a pure
   function applies the plan to the store. This is exactly the
   sleep-time-compute shape, but crucible should ship the skill and the
   apply function, not the scheduler; when it runs (cron, session end,
   bd session-close protocol) is the host application's business.
   Because it is just a Skill, it runs under scripted and cassette
   interpreters, and its prompt can be iterated with `testSkill` like
   any other. In shape terms this Skill is the pump from linear to
   star: transcript-derived items in, an updated profile and a pruned
   log out. Graph-building consolidation is the same signature with a
   different output type, which is another reason to keep it a Skill
   rather than a baked-in pipeline.

5. **Eval hooks: memories must pay rent.** The cheapest honest measure
   of a memory is ablation: run a skill's attached cases with and
   without a candidate memory rendered into the preamble and compare
   `Report` pass rates from `runEval`/`testSkill`. A helper like
   `memoryLift :: Skill i o -> [MemoryItem] -> Eff es (Report, Report)`
   makes "does this memory help" a number instead of a vibe, which is
   precisely what the benchmark literature says is missing at the
   application level ([Mem0 gaps](https://mem0.ai/blog/state-of-ai-agent-memory-2026)).
   This also gives a principled write gate: keep procedural memories
   that raise scores, drop ones that do not.

6. **What does NOT belong in crucible.** Vector databases and embedding
   models (heavy deps, and the file-plus-lexical tier is where coding
   agents actually live); background schedulers or sleep agents (a
   typed-LLM library must stay a library; expose the consolidation
   skill, let hosts schedule it); temporal knowledge graph engines
   (Graphiti exists; if someone wants it, it is one `Memory` interpreter
   away, which is the point of the effect); trust-scoring or
   sanitization services (provenance fields enable them, implementing
   them is application security work); and multi-tenant scoping
   (user_id/org_id tagging is a host concern). The effect boundary is
   the product: crucible defines what remember and recall mean, ships
   honest test interpreters and one file-backed one, and keeps the
   exotic backends as someone else's interpreter.

## Sources

- MemGPT paper: https://arxiv.org/abs/2310.08560
- Letta MemGPT docs: https://docs.letta.com/letta-memgpt
- Generative Agents: https://arxiv.org/abs/2304.03442
- CoALA: https://arxiv.org/abs/2309.02427
- HippoRAG: https://arxiv.org/abs/2405.14831
- HippoRAG 2: https://arxiv.org/abs/2502.14802
- A-MEM: https://arxiv.org/abs/2502.12110
- Mem0: https://arxiv.org/abs/2504.19413
- Zep temporal KG: https://arxiv.org/abs/2501.13956
- Zep temporal KG explainer: https://www.getzep.com/ai-agents/temporal-knowledge-graph/
- Graphiti: https://neo4j.com/blog/developer/graphiti-knowledge-graph-memory/
- Sleep-time compute paper: https://arxiv.org/abs/2504.13171
- Letta sleep-time blog: https://www.letta.com/blog/sleep-time-compute
- Letta next phase: https://www.letta.com/blog/our-next-phase
- OpenAI Dreaming: https://openai.com/index/chatgpt-memory-dreaming/
- Dreaming rollout coverage: https://www.edtechinnovationhub.com/news/openai-rolls-out-new-chatgpt-memory-system-to-keep-personalization-current
- Anthropic memory tool docs: https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool
- Claude Managed Agents memory: https://claude.com/blog/claude-managed-agents-memory
- Managed agents memory docs: https://platform.claude.com/docs/en/managed-agents/memory
- Claude Code memory layers analysis: https://milvus.io/blog/claude-code-memory-memsearch.md
- beads: https://github.com/steveyegge/beads
- beads introduction: https://steve-yegge.medium.com/introducing-beads-a-coding-agent-memory-system-637d7d92514a
- Mem0 state of agent memory 2026: https://mem0.ai/blog/state-of-ai-agent-memory-2026
- Mem0 benchmarks 2026: https://mem0.ai/blog/ai-memory-benchmarks-in-2026
- LoCoMo overview: https://www.emergentmind.com/topics/locomo-benchmark-d06cff1a-d4a5-4df8-ab85-fdca157d190b
- AMA-Bench: https://arxiv.org/abs/2602.22769
- Memory survey (mechanisms, evaluation): https://arxiv.org/abs/2603.07670
- Anatomy of agentic memory: https://arxiv.org/abs/2602.19320
- Foundation agent memory survey: https://arxiv.org/abs/2602.06052
- FadeMem: https://arxiv.org/abs/2601.18642
- FSFM selective forgetting: https://arxiv.org/abs/2604.20300
- ACT-R memory for agents: https://dl.acm.org/doi/10.1145/3765766.3765803
- ProcMEM: https://arxiv.org/abs/2602.01869
- Memory poisoning attack and defense: https://arxiv.org/abs/2601.05504
- MemoryGraft: https://www.researchgate.net/publication/398936727_MemoryGraft_Persistent_Compromise_of_LLM_Agents_via_Poisoned_Experience_Retrieval
- Zombie Agents: https://arxiv.org/abs/2602.15654
- Memory security survey: https://arxiv.org/html/2604.16548v1
- Context rot overview: https://www.techaheadcorp.com/blog/context-rot-problem/
- LangMem: https://langchain-ai.github.io/langmem/
- Graph-based agent memory taxonomy: https://arxiv.org/abs/2602.05665
- Memory in the LLM era (unified benchmark): https://arxiv.org/abs/2604.01707
- MemTree: https://arxiv.org/abs/2410.14052
- MemForest: https://arxiv.org/abs/2605.23986
- FluxMem (adaptive memory structures): https://arxiv.org/abs/2602.14038
- SimpleMem: https://arxiv.org/abs/2601.02553
- LangMem profiles vs collections: https://langchain-ai.github.io/langmem/concepts/conceptual_guide/
- Persistent memory and user profiles: https://arxiv.org/abs/2510.07925
- Mem0 graph memory comparison: https://mem0.ai/blog/graph-memory-solutions-ai-agents
