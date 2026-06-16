# Prompt performance techniques for crucible Skills

Research notes, 2026-06-11. Audience: crucible maintainers. Covers structured-output
prompting, few-shot, instruction quality, reprompting/self-correction, and automated
prompt optimization, mapped onto `Crucible.Skill` / `Crucible.Decode` / `Crucible.Eval`.

## Summary

Crucible's Skill prompt (schema in System, instruction + `Input: <json>` in User,
error-feedback retry) is already close to best practice. The highest-leverage upgrades,
roughly in order: (1) a reasoning-field convention, since a "reasoning" field placed
*before* the answer fields measurably improves accuracy (+13pp in one controlled test,
much more on math); (2) few-shot rendering of attached Cases through the existing
codecs, since 3-5 format-matched examples are the single most reliable formatting and
accuracy lever; (3) field descriptions in the schema text, which carry instruction
content to exactly where the model needs it; (4) richer retry feedback (failed output +
error + restated schema) which recovers most decode failures in one round; and (5) a
testSkill-driven optimization loop, which crucible is unusually well positioned for
because every Skill already carries a scored test set.

## Techniques

### 1. Schema-first / structured-output prompting

**Prompt-contract vs constrained decoding.** Crucible uses a prompt-only contract
(schema injected as text, tolerant decode, retry). The 2024 "Let Me Speak Freely?"
paper (Tam et al., arXiv 2408.02442) claimed format restriction degrades reasoning by
10-15% on math/symbolic tasks while *helping* classification. The dottxt rebuttal "Say
What You Mean" re-ran the experiments and found structured generation slightly
*helped* every task (GSM8K 0.77 -> 0.78, Last Letter 0.73 -> 0.77, Shuffle 0.41 ->
0.44) once the prompts were fixed: the original paper's prompts never showed the
expected JSON shape and used examples whose format didn't match the test items. The
practitioner consensus that emerged: format restriction is cheap when the prompt
states the exact shape and includes a reasoning field; degradation appears when the
schema forces the model to answer before it can think. JSONSchemaBench (arXiv
2501.10868) confirms constrained-decoding engines guarantee syntactic validity but not
semantic quality, and that prompt-side schema statement matters either way. Anthropic's
current guidance for prompt-only structured output is the same: "Try simply asking the
model to conform to your output structure first ... especially if implemented with
retries", which is exactly crucible's design.

**Schema placement.** There is no controlled study showing System-vs-User placement of
the format contract matters much; vendor docs (OpenAI, Anthropic) put format contracts
in the system prompt, and the system message survives multi-turn retry loops better
because it stays pinned at the top. Crucible's current System placement is fine. What
does matter, per long-context research ("Lost in the Middle", Liu et al., arXiv
2307.03172) and Anthropic's docs, is that with long inputs the *task instruction*
should sit near the end, after the data ("queries at the end can improve response
quality by up to 30%"). Crucible currently renders instruction *then* input; for
skills with large inputs the order `Input: <json>` then instruction would follow the
recommendation better. For typical small JSON inputs the difference is negligible.

**Field descriptions in the schema.** Instructor's "Bad Schemas could break your LLM
Structured Outputs" and IBM's JSON-prompting guidance both show that per-field
descriptions and good field *names* act as inline micro-instructions: naming and
describing fields is often more effective than adding the same sentence to the main
instruction, because the description is adjacent to where the model generates the
value. Poorly named fields (e.g. `final_choice` vs `answer`) measurably move accuracy.
autodocodec supports doc comments on object fields (`<?>` / documentation combinators),
so crucible can surface these in `schemaText` if it doesn't already.

**Reasoning field before answer fields.** The strongest single result in this area:
adding a free-text `reasoning` field as the *first* field of the output object lets
the model do chain-of-thought inside the JSON. Dylan Castillo's controlled experiment
(GPT-4o, LiveBench reasoning) got 46.7% with reasoning-first vs 33.3% with
answer-first, p < 0.01. Instructor reports +60% on GSM8K from adding a
reasoning/`chain_of_thought` field. The mechanism is purely autoregressive: if the
answer token is emitted first, the "reasoning" is post-hoc rationalization. Two
caveats: (a) JSON field order must actually be preserved in the rendered schema and in
generation, crucible renders the schema as text so the model follows the textual
order; (b) for trivial classification skills the reasoning field adds tokens/latency
for little gain (and "Brief Is Better", arXiv 2604.02155, finds CoT budget effects are
non-monotonic for function-calling, more reasoning is not always better). Also note
that with reasoning models (extended thinking), an explicit reasoning field is mostly
redundant; it pays off on non-thinking tiers like Haiku.

**Flat over nested.** Multiple sources (TianPan production writeup, JSONSchemaBench)
agree deeply nested schemas degrade both prompt-following and constrained decoders.
Keep skill output codecs flat; prefer two skills over one skill with a deep tree.

### 2. Few-shot examples

**How many.** Anthropic's docs recommend 3-5 well-chosen examples for format/tone/
structure steering and call examples "one of the most reliable ways to steer" output.
Diminishing returns set in quickly for formatting purposes; many-shot (100s) helps
mainly for hard classification with large label spaces.

**Format match is critical.** The dottxt analysis traced much of the "Let Me Speak
Freely" anomaly to examples whose structure didn't match the test items (2-name
examples, 4-name questions). For structured output, examples must show the *exact*
output JSON shape the schema demands, which is an argument for generating examples
mechanically from the same codec that defines the schema, so they can never drift.

**Selection and ordering.** Example order measurably changes accuracy ("Order Matters",
arXiv 2511.09700; permutation-search methods like arXiv 2501.15030 recover several
points by reordering alone). Selection by input similarity (retrieve nearest cases
per query, e.g. Skill-KNN, arXiv 2305.14210) beats static example sets, especially for
heterogeneous inputs. Practical defaults when you can't afford search: order from
easiest/most-canonical to hardest/most-recent (recency bias means the last example
exerts the most pull), keep examples diverse so the model doesn't latch onto
spurious patterns, and delimit them clearly (Anthropic: `<example>` tags).

**Dynamic few-shot from a case bank.** DSPy's bootstrapping shows the practical
pattern: run the program over labelled cases, keep the (input, output) pairs that
scored well, and use those as demonstrations. Crucible's `tests :: [Case i o]` is
already a case bank; cases with `Exactly e` expectations are ready-made
demonstrations (input via the input codec, expected output via the output codec).

### 3. Instruction quality

**Positive over prohibitive.** Anthropic's docs state it directly: "Tell Claude what
to do instead of what not to do" ("Do not use markdown" -> "Write smoothly flowing
prose"). The 16x.engineer "Pink Elephant" analysis and a KAIST study on negated
prompts both find negative instructions are followed less reliably (and larger models
are not better at negation). Where a prohibition is necessary, pair it with the
positive alternative. Crucible's retry line "Respond with valid JSON only" is fine
(it's a positive imperative); the initial "Respond ONLY with JSON matching this
schema" likewise.

**Explain why.** Anthropic finds that giving the motivation for a constraint ("the
output is parsed by a machine, so any prose will break the parser") improves
adherence over the bare rule. Cheap to add to the System message.

**Constraint placement.** "Lost in the Middle" (arXiv 2307.03172) and follow-ups
(LIFBench, arXiv 2411.07037): content at the start and end of the context gets the
most attention. Put long data first, instructions/constraints last. For crucible this
mostly matters for large inputs (see section 1); for the format contract, repeating a
one-line reminder at the very end of the User message ("Reply with a single JSON
object matching the schema.") is a cheap end-position anchor used widely in
production guides.

**Role prompting.** Measured value for *accuracy* is near zero: "Prompting Science
Report 4" (Mollick et al., arXiv 2512.05858) found expert personas matched to the
domain gave no significant gain on GPQA/MMLU-Pro across six models; an earlier
systematic test of 162 roles also found no gain. Roles still steer tone/format. So:
don't spend Skill instruction budget on "You are an expert X" expecting accuracy;
spend it on task specifics. (The one crucible spot where a role earns its keep is the
Eval judge's "You are a strict grader", which is steering behavior, not knowledge.)

**Delimit input data.** Anthropic recommends XML tags to separate instructions from
variable input so the model never confuses data with instructions. Crucible's
`Input:\n<json>` is adequate for JSON (the braces self-delimit), but
`<input>...</input>` is the more robust convention, particularly when input fields
contain instruction-like text (prompt-injection-shaped inputs).

### 4. Reprompting and self-correction

**What error feedback works.** The practitioner literature (apxml output-parsing
course, Elder Scripts self-correction review) converges on a feedback message with
three parts: (1) the failed output (crucible already replays it as an Assistant turn,
which is the right mechanism), (2) the parse error verbatim, (3) a *restatement of the
expected format*, the error alone tells the model what broke but not what right looks
like. Iterative refinement loops of this shape recover ~90% of failed outputs without
a full rerun. Crucible's current retry message has (1) and (2) but not (3); appending
"Return a single JSON object matching the schema from the system message" (or
re-inlining the schema for weaker models) is the standard fix. Also worth noting:
empirically a plain same-prompt retry at temperature > 0 fixes a fair share of
failures, so retry budget 2 is well spent even before better phrasing.

**Self-consistency.** Wang et al. (arXiv 2203.11171): sample n completions, majority
vote on the answer. Works for skills with discrete/comparable outputs (`Eq o` gives
crucible the vote for free) and reliably adds a few points on reasoning tasks at n=5-10
times the cost. Best reserved for high-stakes skills; expose as `withSelfConsistency n`
rather than a default.

**Plan-then-answer decomposition.** For complex skills, the two-call pattern , 
free-form reasoning call first, then a cheap "format this into the schema" call , 
preserves reasoning quality while guaranteeing structure (the production consensus
post-"Let Me Speak Freely"; one writeup measured 48% -> 61% on a reasoning task). The
single-call alternative is the reasoning-first field (section 1), which captures most
of the benefit at half the cost. Rule of thumb from the literature: reasoning field
for moderately hard skills, two-call decomposition only when outputs are long/complex
enough that reasoning and formatting interfere; plain schema-only for classification,
where CoT can actually *hurt* (Tam et al. found format restriction helps
classification; "Brief Is Better" finds excess CoT degrades function-calling).

### 5. Automated prompt optimization

**The landscape.** OPRO (Yang et al., arXiv 2309.03409) keeps a trajectory of
(instruction, score) pairs and asks an LLM to propose a better instruction given that
history. Promptbreeder (arXiv 2309.16797) evolves a population of prompts with
LLM-driven mutation, also self-mutating the mutation prompts. DSPy MIPROv2 jointly
optimizes instructions *and* few-shot demos: (a) bootstrap demos by running the
program and keeping high-scoring traces, (b) propose instruction candidates from a
dataset summary + program summary + bootstrapped demos + a random "tip", (c) Bayesian
search (TPE) over instruction x demo combinations against the validation metric. GEPA
(arXiv 2507.19457, ICLR 2026) currently leads: reflective mutation (an LLM reads error
traces from failed cases and proposes targeted instruction edits) plus a Pareto front
of candidates; it beats MIPROv2 by ~10pp and RL (GRPO) with 35x fewer rollouts. The
trend: feedback-driven *reflection* on concrete failures beats blind search.

**Minimal loop for crucible.** Everything needed already exists: `testSkill` gives a
scored Report per candidate, `Skill.instruction` is the parameter, and `call` of a
meta-skill is the proposer. Sketch:

1. Hold out: split `tests` into train (for demos/reflection) and dev (for scoring).
2. Score the current instruction with `testSkill` on dev.
3. Reflect: a built-in `Skill ReflectionInput Text` whose input is the current
   instruction text plus the failing Results (case name, input JSON, output, score
   rationale, `renderReport` is nearly the right rendering) and whose output is a
   revised instruction. This is GEPA-style reflective mutation, one LLM call per round.
4. Re-score the candidate on dev; keep it if meanScore improves, else keep the
   incumbent (hill-climb). Optionally keep a beam of k candidates (Pareto-lite).
5. Stop after a fixed budget (e.g. 10 rounds) or convergence; emit the best
   instruction *as text* for the developer to paste back into source, instructions in
   crucible are `i -> Text` functions, so the optimizer should target a textual
   template, not the function.

Caveat: `instruction :: i -> Text` is opaque to an optimizer. A practical path is to
optimize skills whose instruction is constant or a template with named holes, or to
have the loop optimize a "preamble" Text that `prompt` prepends. Demo selection
(which Exactly-cases to include as few-shot, in what order) is a second, cheaper
search axis once few-shot support exists, and per MIPROv2's results, jointly varying
instruction and demos beats either alone.

## Recommendations for crucible

1. **Reasoning-field convention (`withReasoning`).** Add a combinator that wraps the
   output codec in `{"reasoning": <string>, "result": <o>}` (reasoning field first),
   decodes through to `o`, and optionally surfaces the reasoning for logging/judging.
   Schema text must list `reasoning` first. Document: use for reasoning-heavy skills,
   skip for classification. This is the cheapest measured accuracy win available
   (+13pp to +60% in the cited experiments).

2. **Few-shot from attached Cases (`withExamples` or auto-render).** Render `Exactly`
   test cases as examples in the prompt, mechanically, via the same input/output
   codecs that define the schema, so example format can never drift from the contract:

   ```
   <example>
   Input: {...via input codec...}
   Output: {...via output codec...}
   </example>
   ```

   Default to at most 3-5; let the caller pick which cases (don't silently burn the
   eval set as demos, examples used in the prompt must be excluded from `testSkill`
   scoring or the report lies). Order: canonical first, hardest last.

3. **Prompt template tweaks in `Skill.prompt`.**
   - System: add one motivation line, "Your reply is parsed by a machine; any text
     outside the JSON object will cause a failure." (positive, explains why).
   - User: wrap the rendered input in `<input>...</input>` instead of bare `Input:`,
     and end with a one-line format reminder ("Reply with a single JSON object
     matching the schema.") as an end-of-context anchor.
   - For large inputs, consider input-before-instruction ordering (data first, task
     last); could be a per-skill flag rather than a default change.
   - Surface autodocodec field documentation in `schemaText` if not already; then
     encourage per-field doc comments in skill codecs as the place for field-level
     guidance.

4. **Richer retry message.** Current: "Your reply did not parse: <err>. Respond with
   valid JSON only." Add the missing third ingredient, restate the contract:
   "Your previous reply did not parse: <err>. Reply again with ONLY a single JSON
   object matching the schema given in the system message. No prose, no code fences."
   For weaker models, re-inline the schema itself in the retry turn.

5. **`testSkill`-driven optimizer (`improveSkill`).** A GEPA-lite hill-climb as
   sketched in section 5: built-in reflection Skill takes (current instruction text,
   failing Results) and proposes a revision; `testSkill` on a held-out split is the
   fitness function; fixed round budget; output is the best instruction text plus the
   before/after Reports so the developer can review and commit it. Requires either
   constant-Text instructions or an optimizable preamble slot in `prompt`. Later:
   extend the search to which Cases serve as few-shot demos (MIPROv2-style joint
   search), and self-consistency (`withSelfConsistency n`, majority vote via `Eq o`)
   as an orthogonal accuracy knob for high-stakes skills.

Non-recommendations: don't add role/persona boilerplate to skill prompts (no measured
accuracy value); don't default to two-call plan-then-answer (reasoning field captures
most of it at half the cost); don't pursue constrained decoding in the Anthropic
backend, prompt contract + tolerant decode + retries is the vendor-recommended path
and the evidence says it does not cost accuracy when the prompt shows the shape.

## Sources

- Tam et al., "Let Me Speak Freely? A Study on the Impact of Format Restrictions on
  Performance of LLMs", https://arxiv.org/html/2408.02442v1
- dottxt, "Say What You Mean: A Response to 'Let Me Speak Freely'" , 
  https://blog.dottxt.ai/say-what-you-mean.html
- Geng et al., "JSONSchemaBench / Generating Structured Outputs from Language Models:
  Benchmark and Studies", https://arxiv.org/pdf/2501.10868
- Dylan Castillo, "Structured outputs: don't put the cart before the horse" (field
  order experiment), https://dylancastillo.co/posts/llm-pydantic-order-matters.html
- Instructor, "Bad Schemas could break your LLM Structured Outputs" , 
  https://python.useinstructor.com/blog/2024/09/26/bad-schemas-could-break-your-llm-structured-outputs/
- TianPan, "Beyond JSON Mode: Getting Reliable Structured Outputs from LLMs in
  Production", https://tianpan.co/blog/2025-10-29-structured-outputs-llm-production
- BAML, "Structured Outputs Create False Confidence" , 
  https://boundaryml.com/blog/structured-outputs-create-false-confidence
- Anthropic, "Prompting best practices" (examples, XML tags, long-context placement,
  positive format instructions, structured-output migration) , 
  https://platform.claude.com/docs/en/docs/build-with-claude/prompt-engineering/long-context-tips
- IBM Developer, "JSON prompting for LLMs" , 
  https://developer.ibm.com/articles/json-prompting-llms/
- Liu et al., "Lost in the Middle: How Language Models Use Long Contexts" , 
  https://arxiv.org/pdf/2307.03172
- LIFBench (long-context instruction following), https://arxiv.org/pdf/2411.07037
- "Order Matters: Rethinking Prompt Construction in In-Context Learning" , 
  https://arxiv.org/pdf/2511.09700
- "Optimizing Example Ordering for In-Context Learning" , 
  https://arxiv.org/html/2501.15030v1
- An et al., "Skill-Based Few-Shot Selection for In-Context Learning" (Skill-KNN) , 
  https://arxiv.org/abs/2305.14210
- 16x.engineer, "The Pink Elephant Problem: Why 'Don't Do That' Fails with LLMs" , 
  https://eval.16x.engineer/blog/the-pink-elephant-negative-instructions-llms-effectiveness-analysis
- Meincke, Mollick et al., "Prompting Science Report 4: Expert Personas Don't Improve
  Factual Accuracy", https://arxiv.org/abs/2512.05858
- apxml, "Handling LLM Output Parsing Errors" , 
  https://apxml.com/courses/prompt-engineering-llm-application-development/chapter-7-output-parsing-validation-reliability/handling-parsing-errors
- The Elder Scripts, "Self-correction in LLM calls: a review" , 
  https://theelderscripts.com/self-correction-in-llm-calls-a-review/
- Wang et al., "Self-Consistency Improves Chain of Thought Reasoning" , 
  https://arxiv.org/abs/2203.11171
- "Brief Is Better: Non-Monotonic CoT Budget Effects in Function-Calling Agents" , 
  https://arxiv.org/pdf/2604.02155
- DSPy MIPROv2 docs, https://dspy.ai/api/optimizers/MIPROv2/
- Langtrace, "Grokking MIPROv2" , 
  https://www.langtrace.ai/blog/grokking-miprov2-the-new-optimizer-from-dspy
- Yang et al., OPRO: "Large Language Models as Optimizers" , 
  https://arxiv.org/abs/2309.03409
- Fernando et al., "Promptbreeder: Self-Referential Self-Improvement via Prompt
  Evolution", https://arxiv.org/abs/2309.16797
- Agrawal et al., "GEPA: Reflective Prompt Evolution Can Outperform Reinforcement
  Learning", https://arxiv.org/pdf/2507.19457
- Arize, "GEPA vs Prompt Learning: Benchmarking Prompt Optimization Approaches" , 
  https://arize.com/blog/gepa-vs-prompt-learning-benchmarking-different-prompt-optimization-approaches/
