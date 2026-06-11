# Multi-agent harnesses: Gas Town and the field (research notes)

Date: 2026-06-11. Survey of multi-agent coding harnesses, anchored on Steve
Yegge's Gas Town, covering peer frameworks, the older academic lineage, and
what it all implies for crucible. Companion to
`2026-06-11-reasoning-trap.md` (closed-loop judging) and
`2026-06-11-evaluation-rubrics.md` (judge machinery). Not published.

## Summary

Gas Town (Jan 2026) is a Go orchestrator that runs 20-30 coding agents in
parallel over tmux, with seven fixed roles, git-worktree-backed work state,
and the beads (bd) issue tracker as the persistent ledger. It works, at high
cost and with quality losses its own author documents. Across Gas Town,
Anthropic's research system, Claude Code subagents, LangGraph, CrewAI, the
OpenAI Agents SDK, and the AutoGen succession, the design that survived
practice is orchestrator-worker with isolated child contexts and typed,
result-only handoffs. Free-form group chat and closed-loop debate did not
survive (AutoGen's own migration guide retreats to typed graphs; the
Reasoning Trap quantifies why debate fails). For crucible the orthogonal
library concerns are small: a Spawn effect with codec-typed handoffs, judge
gates on handoff artifacts, a ledger effect, and budgets. Everything else
(roles, worktrees, daemons, merge queues, human UI) is application territory.

## Gas Town

### What it is

Gas Town is Steve Yegge's multi-agent workspace manager, launched January 1
2026 (https://steve-yegge.medium.com/welcome-to-gas-town-4f25ee16dd04,
https://github.com/steveyegge/gastown). It coordinates 20-30 parallel
coding agent instances (Claude Code primarily; presets exist for Codex,
Gemini, Cursor, Copilot) working on the same set of repositories, with tmux
as the UI and Go as the implementation (about 75k lines at launch). It is
explicitly aimed at operators already comfortable hand-managing ten or more
agents; Yegge warns everyone else off.

### Architecture

Seven worker roles plus the human Overseer
(https://github.com/steveyegge/gastown):

- Mayor: the agent you talk to. Files issues, drafts plans, dispatches work,
  reports status. A concierge and controller in one.
- Polecats: ephemeral per-repo workers. Spin up, take a task, produce a
  merge request, get decommissioned.
- Refinery: the merge queue. Sequences and merges parallel work to main,
  Bors-style, so 20 workers do not trample each other.
- Witness: per-rig lifecycle monitor. Watches polecat health, unsticks
  stalled workers.
- Deacon: cross-rig supervisor running periodic patrol cycles.
- Dogs: town-level maintenance workers assisting the Deacon.
- Crew: long-lived named agents for design-heavy back-and-forth with the
  human.

Vocabulary: a town (the HQ directory) manages rigs (git repos). Convoys
bundle related issues into a trackable work order. Each agent has a hook, a
git worktree holding its in-flight work, so state survives crashes and
context exhaustion: sessions are ephemeral, agents are persistent
identities. GUPP, the propulsion rule, says any agent with work on its hook
must run it; when an agent stalls anyway, a tmux nudge restarts it, and
`gt seance` lets a fresh session interrogate its predecessor. The MEOW
layer (molecules, wisps, formulas) encodes multi-step workflows as chained
issues so a workflow can resume mid-flight regardless of which session
executes each step (https://steve-yegge.medium.com/welcome-to-gas-town-4f25ee16dd04).

Communication is mailbox-based: work assignments and status arrive as mail
injected into agent sessions (via Claude Code settings hooks), and
heartbeats flow Deacon to Witness to Polecats. There is no shared mutable
memory; coordination state lives in git and beads.

### Beads integration

Beads (bd) is Yegge's git-backed issue tracker (October 2025) and is Gas
Town's load-bearing layer: every task, agent identity, workflow step, and
decision rationale is a bead. Originally JSONL plus a SQLite cache with
last-write-wins sync; the v1.0 release (April 3 2026) replaced that with
embedded Dolt, a versioned SQL database, which eliminated the two-sources-
of-truth and merge-conflict problems
(https://steve-yegge.medium.com/gas-town-from-clown-show-to-v1-0-c239d9a407ec).
The design lesson Yegge draws: the work ledger must outlive sessions and
must merge well, because dozens of writers update it concurrently.

### Claims and trajectory

Claimed problems solved: coordination of dozens of agents without losing
track of work; survival of context exhaustion and crashes; merge conflicts
at scale; agent stalling; durable multi-step workflows
(https://steve-yegge.medium.com/welcome-to-gas-town-4f25ee16dd04). The
project moved fast in the survey window: v1.0 on April 3 2026; the
Wasteland (March 2026), a trust network linking many towns
(https://steve-yegge.medium.com/welcome-to-the-wasteland-a-thousand-gas-towns-a5eb9bc8dc1f);
Gas City (April 24 2026), an SDK that deconstructs Gas Town into
declarative "packs" so users assemble their own topologies, shipping a Gas
Town pack for compatibility
(https://steve-yegge.medium.com/welcome-to-gas-city-57f564bb3607); and a
hosted version from Kilo (https://blog.kilo.ai/p/gas-town-ga). The Gas City
post names the durable primitives as agent identity, messaging, history,
context, state, and skills, with work as a first-class object.

### Criticisms and limits

- Cost. A one-hour trial at DoltHub burned about $100 in tokens, roughly
  10x a plain Claude Code session
  (https://www.dolthub.com/blog/2026-01-15-a-day-in-gas-town/).
  Collaborators report token burns around $60k/year
  (https://steve-yegge.medium.com/the-future-of-coding-agents-e9451a84207c).
- Quality. In the same DoltHub trial all four parallel PRs were unusable
  despite agents reporting success, and autonomous merging corrupted the
  repo, requiring force resets. Throughput over correctness is explicit
  policy: "some work gets lost."
- Reliability, especially early. A week-long independent trial found broken
  mail delivery, daemons not running, agents needing manual prodding, 141
  orphaned processes, and weak observability about when work is actually
  done (https://tenzinwangdhen.com/posts/gastown-good-bad-ugly/). Yegge's
  own v1.0 retrospective describes the launch period as a clown show with
  repeated catastrophic data loss, since stabilized.
- Operating model. Requires `--dangerously-skip-permissions`, wholesale
  buy-in to the workflow, and constant human supervision at the wheel; it
  is poorly suited to iterative human-in-the-loop work or small tasks.

The honest read: Gas Town demonstrates that persistent identity plus a
git-merged ledger plus a merge queue can keep dozens of agents from losing
work, and simultaneously demonstrates that supervision, verification, and
cost remain unsolved. Its value to a library designer is the inventory of
mechanisms it needed, not the implementation.

## The harness landscape

### Anthropic's multi-agent research system

The published architecture for Claude's Research feature is
orchestrator-worker: a lead agent plans, saves the plan to external memory,
spawns parallel subagents with explicit objectives, output formats, tool
guidance, and task boundaries, then synthesizes results
(https://www.anthropic.com/engineering/multi-agent-research-system). Key
numbers: multi-agent used about 15x the tokens of chat and beat
single-agent Opus by 90.2% on their research eval. Key engineering notes:
subagent execution was synchronous (a known bottleneck); failures compound
across turns so they resume from checkpoints rather than restart; deploys
are rainbow (both versions live) because agents are long-running. Their
fit guidance is the most quoted sentence in the field: multi-agent wins on
breadth-first parallelizable work that exceeds one context window, and
loses on tasks with tight interdependencies, which includes most coding.

### Claude Code subagents and the Task tool

The Task tool spawns a named subagent with its own system prompt, context
window, tool list, and permission mode; the parent sees only the final
result, never the child's intermediate tool calls
(https://code.claude.com/docs/en/sub-agents,
https://claude.com/blog/subagents-in-claude-code). The design point is
context isolation: exploration noise stays in the child. Guidance is to
parallelize only genuinely independent tasks and run dependent work
sequentially. This is the smallest viable multi-agent design and the one
most directly relevant to crucible.

### Cognition's counterargument

"Don't Build Multi-Agents" argues parallel subagents fail because actions
carry implicit decisions and siblings cannot see each other's decisions, so
outputs conflict; their principles are to share full traces and otherwise
stay single-threaded with context compression for long tasks
(https://cognition.ai/blog/dont-build-multi-agents). Read jointly with
Anthropic's post, the two agree more than they disagree: decompose only
where subtasks are independent enough that result-only handoff loses
nothing important.

### LangGraph

Control flow is an explicit state graph; multi-agent arrives as supervisor,
hierarchical (nested supervisors), or peer patterns, with handoffs as
tools that transfer control and (by default) message history
(https://github.com/langchain-ai/langgraph-supervisor-py,
https://reference.langchain.com/python/langgraph-supervisor). Its
distinctive contribution is checkpointing: state is snapshotted at every
step into a pluggable store (SQLite dev, Postgres prod), giving durable
execution, resume after crash, and human-in-the-loop interrupts as a graph
primitive (https://devops.gheware.com/blog/posts/langgraph-multi-agent-orchestration-enterprise-2026.html).

### AutoGen, AG2, Microsoft Agent Framework

AutoGen's original idea was conversation programming: conversable agents
plus GroupChat with an LLM manager picking the next speaker
(https://arxiv.org/abs/2308.08155). By 2026 the line split three ways:
Microsoft Agent Framework (production successor with typed graph workflows
and built-in checkpointing), AutoGen 0.7.x in maintenance, and the AG2
community fork keeping the GroupChat style
(https://learn.microsoft.com/en-us/agent-framework/migration-guide/from-autogen/,
https://github.com/microsoft/autogen). The migration guide is itself a
finding: Microsoft moved from an implicit manager-agent deciding who speaks
to explicit typed nodes and edges. Free-form group chat lost to explicit
control flow in the very framework that popularized it.

### CrewAI

Role-based crews (role, goal, backstory per agent; sequential or
hierarchical process) for autonomy, plus Flows as a deterministic backbone
with state management, conditional paths, and a human feedback decorator
for approval gates (https://docs.crewai.com/en/concepts/flows,
https://github.com/crewaiinc/crewai). Memory is short-term vector store
plus long-term SQLite scoring. The trajectory mirrors AutoGen's: the
production story (Flows) is deterministic orchestration wrapping bounded
pockets of agent autonomy, not autonomous crews all the way down.

### OpenAI Agents SDK (ex-Swarm)

Deliberately minimal primitives: agents (model, instructions, tools),
handoffs (transfer the conversation to another agent), guardrails
(validation running alongside execution, input gates on the first agent,
output gates on the last), sessions for persistent context, and built-in
tracing of every model call, tool call, handoff, and guardrail outcome
(https://openai.github.io/openai-agents-python/,
https://developers.openai.com/api/docs/guides/agents). The handoff model is
a market-of-specialists topology, suited to routing-style applications more
than coding factories.

### claude-flow / ruflo

Community "meta-harness" for Claude Code with a queen-led hive-mind
topology, dozens of role agents, shared memory, and aggressive self-reported
benchmarks (84.8% SWE-bench solve rate)
(https://github.com/ruvnet/ruflo). Widely adopted, but its claims are
self-published and its design (shared memory, many roles, neural
terminology) runs opposite to the isolation-and-typed-handoff consensus of
the systems above. Treat as a popularity data point, not a design source.

## The older papers, and what survived

- CAMEL (https://arxiv.org/abs/2303.17760): two role-playing agents driven
  by inception prompting. Survived as role prompts, which every harness
  uses; the two-agent autonomous society did not.
- Multi-agent debate (https://arxiv.org/abs/2305.14325, society-of-mind
  framing): agents critique each other to improve factuality. Did not
  survive. The Reasoning Trap result (see
  `2026-06-11-reasoning-trap.md`) shows closed-loop debate preserves
  accuracy while reasoning detaches from evidence (88% accuracy retained,
  43% faithfulness lost; majority-vote debate collapsed faithfulness to
  1.7% of baseline). No major production harness ships debate as a
  primitive.
- AutoGen (https://arxiv.org/abs/2308.08155): conversation programming.
  Partially survived; the conversable-agent abstraction persists but its
  flagship GroupChat pattern was retired in favor of typed graphs by its
  own successor.
- MetaGPT (https://arxiv.org/abs/2308.00352): software-company SOPs where
  agents exchange structured artifacts (PRDs, designs, code) instead of
  chat. The artifact-handoff insight survived everywhere (Task tool
  result-only returns, Gas Town merge requests, typed handoffs); the
  company simulation did not.
- ChatDev (https://arxiv.org/abs/2307.07924): virtual software company via
  chat chains. Same verdict: the waterfall-of-roles theater is gone, the
  phase-gated pipeline idea persists as controller loops.
- MAST, "Why Do Multi-Agent LLM Systems Fail?"
  (https://arxiv.org/abs/2503.13657): 14 failure modes over 1600+ traces
  across 7 frameworks: specification issues 41.8%, inter-agent misalignment
  36.9%, verification failures 21.3%. The headline is that most failures
  are system design failures (ambiguous specs, no verification step), not
  model failures. This is the empirical backing for reviewer gates and
  explicit task contracts.

## Primitives that recur

Every surveyed harness reassembles roughly the same parts:

1. Persistent work ledger (beads/Dolt, LangGraph checkpoints, CrewAI flow
   state, Anthropic's external memory). Survives sessions, merges under
   concurrent writers.
2. Task queue and assignment (hooks and convoys, lead-agent spawning,
   supervisor routing).
3. Controller loop (Mayor, lead agent, supervisor node, queen). One agent
   plans and dispatches; peers-only topologies are rare in production.
4. Role prompts (universal, and the cheapest part).
5. Typed artifact handoff (Task tool result-only returns, MetaGPT
   artifacts, OpenAI handoffs, LangGraph handoff tools). The parent
   consumes a structured result, not a transcript.
6. Reviewer gates (Refinery merge queue, guardrails, human feedback
   decorators, LangGraph interrupts). MAST says their absence is the
   third-largest failure class.
7. Budget and stopping (iteration caps, token budgets, effort-scaling
   rules; Anthropic's 15x multiplier and Gas Town's costs make this
   non-optional).
8. Context isolation (subagent context windows; Gas Town worktrees are the
   filesystem analogue).
9. Observability (tracing in every SDK; its weakness is the top complaint
   about Gas Town).

Which are library concerns for crucible? The ones that are about typed
boundaries and control flow: handoff typing, spawn/collect control, judge
gates, budgets, ledger and observability as effect interfaces with swappable
interpreters. Which are application concerns: role prompt content, process
and worktree management, mail transports, merge queues, daemons and
nudging, human approval UI, scheduling. Gas City's own evolution confirms
the split: Yegge ended up extracting an SDK (identity, messaging, state,
work-as-data) from the application (towns, patrols, tmux).

## Recommendations for crucible

crucible today is a single-agent substrate: `runToolAgent`
(src/Crucible/Chat.hs) drives a Chat-effect tool loop with an iteration
cap, `runAgent` (src/Crucible/Agent.hs) drives the text-path Decision loop,
`Tools`/`Tool` give codec-typed tool dispatch, `Skill` gives codec-typed
one-shot calls, and Eval/Judge gives independent judges with vote
aggregation. The field's surviving design (orchestrator-worker, isolated
child context, typed result-only handoff) is a small, natural extension of
exactly these pieces. Concretely:

1. A `SubAgent i o` value and an `Agents` effect. A subagent is a named
   bundle: input codec, output codec, system instruction, toolbox, and
   iteration cap; semantically a `Skill` whose body is a tool loop. The
   effect is one constructor to start:

   ```haskell
   data Agents :: Effect where
     Spawn :: SubAgent i o -> i -> Agents m (Either AgentFailure o)
   ```

   The local interpreter runs the child as a fresh transcript under the
   ambient `Chat` interpreter and decodes the final text through the output
   codec; the parent never sees the child's transcript. That is the Claude
   Code Task design expressed in crucible types, and the typed handoff is
   the part no mainstream harness has: handoffs everywhere else are JSON or
   prose by convention. A scripted interpreter (canned `o` per spawn)
   follows the `runChatScripted`/`runTools` house pattern and makes parent
   logic testable without a model.

2. Synchronous spawn first. Anthropic shipped synchronous subagents and
   called async an open problem; Cognition's failure mode is precisely
   uncoordinated parallel siblings. Sequential spawn captures the context
   isolation win with none of the coordination cost. Concurrent spawn can
   arrive later as a different interpreter without changing the effect.

3. Reviewer gates as judge calls. A combinator, not a role:

   ```haskell
   gated :: Judge o -> SubAgent i o -> SubAgent i o
   ```

   The child's decoded output goes to the existing Eval/Judge machinery
   (independent one-shot judges plus a mechanical vote, honoring the
   no-closed-loop rule from the Reasoning Trap notes); on fail, bounded
   retry with the judge's critique appended, mirroring `Skill` decode
   retries. This addresses MAST's verification failure class with machinery
   crucible already has.

4. A work ledger effect, not a tracker. A small effect (record, claim,
   complete, list-ready) with an in-memory interpreter for tests and a
   file-backed one for apps. The beads lesson is about properties, not
   product: the ledger must outlive sessions and tolerate concurrent
   writers, which is an interpreter concern. A bd-backed interpreter
   belongs in an example or a separate package, not in core.

5. Budgets across the spawn tree. The existing per-loop iteration cap and
   `Usage` accounting extend to a spawn-tree budget (tokens or spawns),
   threaded by the Agents interpreter, with exhaustion a typed failure like
   `ToolLoopExceeded`. The 15x token multiplier and Gas Town's bills make
   this a first-class concern, not an afterthought.

What crucible should NOT try to be:

- Not a process manager. Worktrees, tmux, daemons, nudges, seances, and
  orphaned-process cleanup are Gas Town's domain and the source of most of
  its operational pain. crucible stays in-process, in `Eff`.
- Not a role catalog. Mayors and polecats are prompt content plus an app's
  process topology; a library shipping seven blessed roles would be
  shipping opinions that expire.
- Not a merge queue or VCS layer. The Refinery solves a git problem, not
  an LLM problem.
- No group chat, blackboard, or debate combinators. Free-form group chat
  was retired by its own inventors; shared mutable memory invites the
  conflicting-implicit-decisions failure; closed-loop debate is ruled out
  by the Reasoning Trap and by the existing hard rule in the reasoning-trap
  notes.
- No human-approval UI. Provide the seam (a gate is just an effect the
  application interprets, possibly by asking a person); the interaction
  surface is the application's.

The strongest position for crucible is the typed substrate that harness
applications are built on: Spawn with codec-typed handoffs, judge-gated
artifacts, ledger and budget effects with deterministic test interpreters.
Nobody in the surveyed field has the typed boundary; everybody needs it.

## Sources

- https://steve-yegge.medium.com/welcome-to-gas-town-4f25ee16dd04
- https://steve-yegge.medium.com/the-future-of-coding-agents-e9451a84207c
- https://steve-yegge.medium.com/gas-town-from-clown-show-to-v1-0-c239d9a407ec
- https://steve-yegge.medium.com/welcome-to-the-wasteland-a-thousand-gas-towns-a5eb9bc8dc1f
- https://steve-yegge.medium.com/welcome-to-gas-city-57f564bb3607
- https://github.com/steveyegge/gastown
- https://www.dolthub.com/blog/2026-01-15-a-day-in-gas-town/
- https://tenzinwangdhen.com/posts/gastown-good-bad-ugly/
- https://thenewstack.io/steve-yegges-ai-agent-orchestration-project-gas-town-comes-to-the-cloud-and-brings-the-wasteland-with-it/
- https://blog.kilo.ai/p/gas-town-ga
- https://softwareengineeringdaily.com/2026/02/12/gas-town-beads-and-the-rise-of-agentic-development-with-steve-yegge/
- https://www.anthropic.com/engineering/multi-agent-research-system
- https://code.claude.com/docs/en/sub-agents
- https://claude.com/blog/subagents-in-claude-code
- https://cognition.ai/blog/dont-build-multi-agents
- https://github.com/langchain-ai/langgraph-supervisor-py
- https://reference.langchain.com/python/langgraph-supervisor
- https://devops.gheware.com/blog/posts/langgraph-multi-agent-orchestration-enterprise-2026.html
- https://learn.microsoft.com/en-us/agent-framework/migration-guide/from-autogen/
- https://github.com/microsoft/autogen
- https://docs.crewai.com/en/concepts/flows
- https://github.com/crewaiinc/crewai
- https://openai.github.io/openai-agents-python/
- https://developers.openai.com/api/docs/guides/agents
- https://github.com/ruvnet/ruflo
- https://arxiv.org/abs/2303.17760 (CAMEL)
- https://arxiv.org/abs/2305.14325 (multi-agent debate)
- https://arxiv.org/abs/2308.08155 (AutoGen)
- https://arxiv.org/abs/2308.00352 (MetaGPT)
- https://arxiv.org/abs/2307.07924 (ChatDev)
- https://arxiv.org/abs/2503.13657 (MAST: Why Do Multi-Agent LLM Systems Fail?)
- https://arxiv.org/abs/2605.01704 (The Reasoning Trap; see
  2026-06-11-reasoning-trap.md in this directory)
