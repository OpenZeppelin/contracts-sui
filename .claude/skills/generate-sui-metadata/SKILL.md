---
name: generate-sui-metadata
description: Generating AI-native semantic metadata YAML (v1.0 public schema; internal historical naming v2.2) for an OpenZeppelin Sui Move module from a GitHub URL (either a contracts-sui pull request OR a direct link to the module's Move source). Use when the user says "generate metadata for PR X", "create metadata yaml for this PR", "extract metadata for contracts-sui module Y", "produce row 7 metadata", "generate metadata for <github blob URL>", or mentions metadata for `openzeppelin_access::*`, `openzeppelin_math::*`, or any other contracts-sui module. Also trigger when a new module lands in a contracts-sui PR and needs its metadata file, or when refreshing metadata after a module's source or tests change. Lean toward triggering — this is the canonical generator for `<module>.yaml` files consumed by AI integrator agents.
allowed-tools: Bash, Read, Write, Glob, Grep, mcp__claude_ai_Notion__notion-fetch
inputs:
  source_url:
    type: text
    prompt: "GitHub URL — either a contracts-sui PR (https://github.com/OpenZeppelin/contracts-sui/pull/313) OR a direct link to the module's Move source (https://github.com/OpenZeppelin/contracts-sui/blob/<ref>/contracts/<pkg>/sources/<name>.move)"
    required: true
  module_name:
    type: text
    prompt: "Module name (only needed if a PR URL was given and the PR touches multiple modules — e.g., access_control)"
    required: false
  notion_design_url:
    type: text
    prompt: "URL of the module's Notion R&D design page (optional — legacy modules may not have one)"
    required: false
  docs_pr_url:
    type: text
    prompt: "URL of the docs PR adding the MDX guide for this module (optional — e.g., https://github.com/OpenZeppelin/docs/pull/153)"
    required: false
  output_path:
    type: text
    prompt: "Where to write the YAML (optional; defaults to /workspace/generated/sui-metadata/<module-name>.yaml)"
    required: false
---

# Generate Sui Move Module Metadata (v1.0 public schema)

The output YAML conforms to the public JSON Schema published at [`schemas/llms-metadata-v1.json`](https://raw.githubusercontent.com/OpenZeppelin/contracts-sui/main/schemas/llms-metadata-v1.json) in `OpenZeppelin/contracts-sui`. When the spec and the schema disagree, the JSON Schema is authoritative because that is what external integrator tooling validates against. Run `python3 -c "import json, yaml, jsonschema; jsonschema.validate(yaml.safe_load(open('<output>.yaml')), json.load(open('<path>/schemas/llms-metadata-v1.json')))"` on the output before declaring done.

Generates an AI-native semantic metadata YAML for a single OpenZeppelin Sui Move module. The output is read by **AI integrator agents** (Cursor, Claude Code, Cline, GitHub Copilot) when they add `@openzeppelin-move/<package>` as a dependency and start writing code against it.

**Primary persona for the OUTPUT**: AI integrator agent. NOT auditor, NOT OZ-internal-dev. Anti-pattern detection heuristics, full test inventories, and proof-grounding lists live under a separate `_audit_grounding:` section that the agent skips during code generation.

## How this skill gets its source files

This skill operates off **GitHub URLs**, not local files. The contracts-sui repo is not necessarily checked out in the workspace, so the skill uses the `gh` CLI to download the Move source, tests, Move.toml, and README from GitHub into a temporary directory. The existing extractor scripts then run against that tempdir as if the repo were local.

Two `source_url` formats are accepted:
- **PR URL** — `https://github.com/<owner>/<repo>/pull/<number>` — used while a new module is in review. The skill resolves the PR's head SHA and stages files at that commit; sibling files not touched by the PR fall back to the base branch.
- **Blob URL** — `https://github.com/<owner>/<repo>/blob/<ref>/<package_path>/sources/<...>.move` — used for modules on a branch / tag / commit (e.g., `main` for landed work, a release tag for audited versions, or `contracts/access/...` vs `math/fixed_point/...` for packages at different repo layouts).

Same idea for the docs MDX guide: it's fetched from the docs PR if `docs_pr_url` was given. The Notion R&D design page is optional — for legacy modules that pre-date the R&D process there is no Notion page, and the skill degrades gracefully.

---

## Reference material

Two files in `references/` ground the synthesis. Re-read them at the start of each run so the format and quality bar stay consistent:

- **`references/format-spec.md`** — human-readable companion to the public JSON Schema. The output YAML MUST match this 6-stage integrator-first structure (Selection / Install / Bootstrap / Integration / Decisions / Anti-pattern compliance), plus the optional `_audit_grounding:` block.
- **`references/golden-rbac.yaml`** — the actual published v1.0 YAML for `openzeppelin_access::access_control`, copied verbatim from contracts-sui. Shape reference for what every YAML should look like AFTER schema validation passes.

---

## Workflow

### 1. Stage sources from the URL(s)

```bash
scripts/stage_sources.sh "<source_url>" "<module_name_or_empty>"
```

Parse the stdout — line-oriented `KEY|value`. Treat the staged paths as authoritative inputs. If the script exits non-zero, return its `ERR|` message to the calling agent.

If `docs_pr_url` was provided, also run:

```bash
scripts/stage_docs_pr.sh "<docs_pr_url>" "<MODULE_NAME>" "<STAGE_DIR>"
```

If the docs match fails on file basename, also try the actual module declaration name (read from the staged source — `^module <pkg>::<name>;`). File basename and module name often diverge (e.g., `two_step.move` declares `two_step_transfer`).

Read the staged Move source, the staged tests file (if present), the staged README (if present), the staged Move.toml (if present), and the staged docs MDX (if present) into context.

If `notion_design_url` was provided, attempt to fetch the page via `mcp__claude_ai_Notion__notion-fetch`. Capture especially:
- **Problem** section → feeds `module.one_liner`
- **Why this is better** / **Tradeoffs introduced** → feeds `do_not[]`
- **What it does NOT solve** → feeds `does_not_solve[]`
- **Constraints from Sui's model** → feeds anti-patterns about VM model

**Environment dependency:** `mcp__claude_ai_Notion__notion-fetch` is provided by an MCP server that has to be wired into the workspace. The skill's `allowed-tools` lists it, but a runtime that has not connected the Notion MCP (e.g. a freshly-spawned subagent in a workspace where the MCP server is not configured) will not have the tool registered. In that case the ToolSearch lookup returns "no matching deferred tools" — treat that result the same as the `notion_available=false` fallback below.

If Notion is empty, fails to fetch, or the MCP tool is not registered, set `notion_available=false` and degrade gracefully — synthesis still works from source + docs + README. Stress-test evidence (2026-05-25, suite 06 + RBAC regen by subagent without Notion): the fallback path produces a structurally-equivalent YAML to the Notion-aware path on every load-bearing axis (errors, types, do_not[] ids, preconditions, decisions). Notion adds sharper one-liner Problem wording and richer severity calibration in do_not[]; it does NOT change which functions / errors / types get documented.

### 2. Run deterministic extractors

```bash
scripts/extract_move_structure.sh <MODULE_FILE>
```

emits:
- `MODULE=<fully-qualified name>` (used for `module.name`)
- `ENTRY_POINT|<name>|<kind>|<signature>` (one per public fn) — feeds `api[].sig` and indirectly `api[].role`
- `ABORTS|<fn_name>|<E1,E2,...>` — feeds `api[].aborts`
- `EMITS|<fn_name>|<EventName>` — multiple lines per fn (one per emit site); aggregate into `api[].emits`
- `ERROR|<name>|<code>|<message>` — feeds `errors:` map: `EXxx: { code: N, message: "..." }`. `<code>` may be empty for legacy `#[error]` form
- `TYPE|<name>|<type-params>|<capabilities>|<fields>` — feeds top-level `types:` block. Excludes event structs (those carry only `copy,drop`)
- `EVENT|<name>|<comma-fields>` — feeds `_audit_grounding.events`

If `TESTS_FILE` is non-empty:

```bash
scripts/extract_tests.sh <TESTS_FILE>
```

emits `TEST|<name>|<expected_abort_or_empty>` lines.

Treat extractor output as authoritative; do not re-extract by reading source yourself.

### 3. Synthesize the v1.0 YAML

Always emit `schema_version: "1.0"` (string, not integer — schema enforces `const: "1.0"`). Write each section in the order it appears in `references/format-spec.md`. Always frame as "you, the integrator agent" — second-person imperative.

**Do NOT emit process artifacts** in the YAML — no `# WARN: Notion R&D not consulted` headers, no `⚠️ PARTIAL METADATA` banners, no validator-internal commentary. These are signals to the GENERATOR, not to the integrator agent who will eventually read the YAML. If a source is unavailable, degrade quality silently and note it in your final return message instead.

#### Stage 1 — Selection

**`module.name`** — from `MODULE=` extractor line.
**`module.package`** — from staged `Move.toml` `[package].name`.
**`module.re_exports_from`** — OPTIONAL list of sibling module names (no package prefix) whose APIs this module re-exports via `public use fun`. Emit when `grep "^public use fun" <module>.move` finds entries pointing at OTHER modules in the same package (e.g., `sd29x9.move` line `public use fun openzeppelin_fp_math::sd29x9_base::add as SD29x9.add;` → `re_exports_from: [sd29x9_base]`). Omit the field entirely when there are no re-exports — schema enforces `minItems: 1`. Signals to integrators that the module's reachable surface extends beyond its own YAML; agents should also fetch the listed siblings' YAMLs to see the full method-style API.
**`module.one_liner`** — single sentence, **≤240 characters** (schema-enforced `maxLength: 240`). What the module does + the dominant load-bearing constraint (e.g., frequency-class warning when `frequency: admin-frequency`). This is the FIRST thing the agent reads — make it agent-classifiable in one token.
**`module.summary`** — optional multi-paragraph elaboration. If the one_liner can't carry the necessary context (history, layering, sibling pointers, performance model), put the prose here. No length cap, no required field. Default path: condense Notion "Problem" + README intro + Move source first doc-comment block. Fallback: condense README intro + Move source first doc-comment block.

**`domain`** — kebab-case category, e.g. `access-control`, `math`, `governance`, `tokens`, `data-structures`, `infra`. From Notion ancestor breadcrumb (default path) or `PACKAGE_NAME` mapping (fallback). Schema is open via pattern (`^[a-z][a-z0-9-]*$`) — new categories don't require a schema bump, but coordinate with the package maintainer before introducing one.

**`frequency`** — from Notion "Constraints" / "Tradeoffs" or Move source structural-invariants block. Controlled vocabulary: `admin-frequency`, `user-frequency`, `mixed`. If unstated, leave empty and flag in provenance.

**No `audit:` field.** Audit reports — when they exist — live in the repo's `audits/` directory at the ref pinned by `install.repo_ref` (e.g. `https://github.com/OpenZeppelin/contracts-sui/tree/main/audits`). Integrator navigates there if they care. Do NOT surface a binary status (`audited` / `in-progress`) in the YAML — it invites false claims or drift, and the agent does not change generated code based on it anyway.

**`does_not_solve[]`** — 1-line bullets only. Pull from Notion "What it does NOT solve" (default) or docs guide "Limitations" / Move source "Misuse Paths" (fallback). Drop rationale — boundary signal only.

#### Stage 2 — Install

**`install.mvr`** — from staged `Move.toml` or README import line. Primary install path; always emit it.
**`install.repo_ref`** — from `stage_sources.sh` `SOURCE_REF|<full commit SHA>` output. ALWAYS a full 40-char commit SHA — the staging script resolves branch refs (e.g. `main`) and tags to a SHA before emitting, so the YAML carries a reproducible pin. Never write a branch name here; if `SOURCE_REF` looks like a branch, the staging script has a bug — surface it rather than copying the value verbatim. Schema-enforced pattern: `^[0-9a-f]{40}$`.

**`install.release`** — semver-prefixed release tag (e.g. `"v1.2.0"`) when the YAML was extracted at a tagged release, OR `null` when extracted from main between tags. Schema enforces `^v[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.-]+)?$` for the non-null case. Determine by comparing `install.repo_ref` against `git tag --contains <sha>` results from `gh api repos/$OWNER/$REPO/commits/<sha>/tags` — if exactly one release tag points at the SHA, emit that tag; if none or multiple non-release tags, emit `null`. Inline comment must clarify: `# release tag this matches (null if extracted between tags); install.repo_ref is the actual pin`.

**`install.use_statement`** — verbatim from the docs guide "Import" section, OR from the README, OR template-generated.
**`install.move_toml_snippet`** — assemble from `package` name + MVR pin.
**`install.github_alternative`** — secondary install path for environments where MVR is not configured (CI, forks, audits pinning an exact commit). Assemble from:
- `git`: always `https://github.com/<SOURCE_OWNER>/<SOURCE_REPO>.git` (from `stage_sources.sh`)
- `subdir`: path from the repo root to the package directory. Derive from the staged `MODULE_FILE` path — strip everything from `/sources/` onward. e.g. `contracts/access/sources/access_control.move` → `contracts/access`; `math/fixed_point/sources/ud30x9/ud30x9.move` → `math/fixed_point`
- `rev`: emit the literal placeholder `<commit-sha-or-tag>` (NOT a concrete SHA, NOT a branch). The integrator agent picks the right ref at code-generation time based on user intent — latest stable tag for production builds, audited release SHA for audits, a branch for active development. The recorded `install.repo_ref` field tells the agent which commit the documented API describes; the agent should warn the user if their chosen `rev` diverges.

#### Stage 3 — Bootstrap

**`setup_snippet`** — verbatim from docs guide "Default pattern" / "Default Pattern" code block when present. Otherwise template-generated using module + package + one example role.

**`quick_start`** — the minimal end-to-end sequence (3-5 calls) showing the typical happy path *after* `init` has run. NOT a copy of `setup_snippet` — that one is init only. `quick_start` shows the FIRST USEFUL CALL: for RBAC, mint Auth + call protected; for a wrapper module, wrap + initiate; for math, construct + arithmetic. Goal: an integrator agent that sees this knows the canonical 3-step shape and does not have to derive it from the 17-function `api[]`. Source: docs guide "Quick start" / "Usage" section if present, else synthesize from the load-bearing functions in `api[]` (constructor + canonical caller + one supporting call).

For pure-type-wrapper modules (e.g., `ud30x9` constructors only) `quick_start` MAY be omitted — the API surface IS the quick start.

#### Stage 4 — Integration

**`types[]`** — one entry per `TYPE|<name>|<type-params>|<caps>|<fields>` line from the extractor.
- `name`: the struct name (without `<type-params>`).
- `type_params`: contents of `<...>` if any, e.g. `"phantom RootRole"`, `"phantom Role"`. Empty string if none.
- `capabilities`: split the comma list — typical values are `[key, store]` (shared / owned objects) or `[drop]` (values like `Auth<Role>`).
- `role`: one phrase explaining what the type represents in caller terms, and the canonical way to construct/store it (`transfer::public_share_object`, drops at end of PTB, etc.). Synthesize from doc comments above the struct OR from the module overview.

**CRITICAL — `type_params` explanation:** when a type carries `<phantom T: ...>` (or any other generic constraint), the `role:` field MUST explain that `T` is a CONSTRAINT, not something the caller has to re-introduce on their own type. Stress-test result (2026-05-25, suite 06): without this guidance, an integrator agent that sees `DelayedTransferWrapper<phantom T: key + store>` will hallucinate a generic on the user's own cap type (`TreasuryCap<phantom_marker>`) and break compile. The fix is to add explicit "Instantiate concretely as `Wrapper<MyCap>` — your `MyCap` is a non-generic `key + store` struct" inside `role`, with a "Common mistake: ..." callout.

Skip internal helper structs whose presence in the API surface is purely incidental (e.g., `RoleData`, `PendingDelayChange`) — types[] is the integrator's hit list, not an inventory.

**Hot-potato types** (no abilities, e.g. `Borrow { ... }` declared as `public struct Borrow { ... }` with NO `has` clause) are NOT emitted by the extractor's `TYPE|` line because the regex requires `has`. They must be added manually during synthesis when they appear in any `api[].sig`. Mark them with `capabilities: []` — agents interpret this as "must be consumed before tx ends, cannot be stored or dropped."

**`capabilities: []` (empty) vs `capabilities: [drop]` are NOT the same.** Empty means "no abilities at all" (true hot-potato — must be consumed in same tx). `[drop]` means "drops automatically at end of PTB but cannot be stored or copied" — that is the right pattern for ephemeral typed proofs like `Auth<Role>`. Pick `[]` only when the struct declaration carries no `has` clause at all.

**`api[]`** — one entry per `ENTRY_POINT` line.
- `name` and `kind` direct from extractor.
- `sig`: from extractor's signature column. Strip the `public fun ` prefix and the function name to leave just `<type-params>(<args>) -> <return>`. Use `->` (not `:`) for return type since YAML doesn't like raw colons.
- `role`: one phrase in caller terms. Synthesize from the function's `#### Parameters` / `#### Returns` doc comments, or from Move source comment immediately above the function. Be terse.
- `aborts`: from extractor `ABORTS|` line. Convention for the empty case:
   - Function HAS no abort path ever (pure getter, simple comparison, total function over its domain) → `aborts: []`. ALWAYS emit the empty list explicitly; do NOT omit the field. Agent uses absence-of-field as "unknown / not analyzed"; explicit empty list means "verified no aborts."
   - Function CAN abort but lacks a `#### Aborts` doc-comment block → fall back to scanning the function body for `assert!(_, EErr)` and `abort EErr` patterns. Source body is the ground truth; the doc comment is best-effort prose.
- `emits`: aggregate of all `EMITS|<fn_name>|<event>` lines for this function. De-dupe but preserve order of first appearance. Omit field entirely if the function emits nothing.
- `notes`: ONLY when the function has non-obvious caller constraints (idempotent? consumes by value? hot-potato? when to use vs sibling?). Pull from `#### Parameters`/`#### Returns` notes or Move source narrative comments. Map any `/// Security Warning` (or equivalent `/// #### Security`) block in the function's doc-comment 1:1 into `notes:` — that block exists specifically because the constraint is non-obvious. Skip `notes:` entirely if the function is obvious.

Order: **constructor first, then writes, then mints, then reads, then schedule/finalize/cancel, then pending-state queries.** The "actions first, queries last" ordering matches integrator-agent attention: the agent scans top-down for what it can DO before reading what it can ASK. Diverged-from-spec ordering in golden files supersedes this only when the golden is the explicit shape reference (currently golden-rbac.yaml uses this order — it IS the source of truth for shape).

**`errors`** — map of objects from extractor `ERROR|<name>|<code>|<message>` lines:
```yaml
EXxx:
  code: <N>          # integer from #[error(code = N)]. Omit when code is empty.
  message: "..."
```
Quote messages. When the extractor emits no code (legacy `#[error]` form), set `code: null` or omit it.

#### Stage 4.5 — Decisions

**`decisions[]`** — top-level list of "agent picks the right function" guidance. ONE source of truth: do NOT duplicate this in `api[].notes:`.

Emit a `decisions[]` entry whenever the module has **two or more functions that could plausibly answer the same user prompt**. Examples that warrant a decision:

- Two ways to authorize a call (`&Auth<Role>` vs `assert_has_role`)
- Two ways to mutate state (e.g., `transfer` vs `transfer_and_share`)
- Two-step flow with a cancel option (`accept_*` vs `cancel_*`)
- A choice of constants / parameters (e.g., delay duration)
- A "use this NOT that" between siblings already in `composes_with[]`

Each entry has:
- `question`: the question in user-facing terms — what they would actually ask. Plain English, not API jargon.
- `options[]`: 2-4 alternatives. Each option has:
  - `use`: the function / pattern name the agent should reach for, terse
  - `when`: the concrete condition that makes this the right choice
  - `why`: one sentence on the consequence — what goes right (or wrong if the other branch is taken)

Order options by frequency / default first (the option a typical integrator should pick goes top). For "never do this" branches (e.g., user-frequency RBAC), still include them — agent matches against bad intent too. Keep the entry list tight: 3-5 questions per module is the sweet spot. If the module has no real choices (pure-type wrapper, single-call API), `decisions: []` is correct.

Source: docs guide "Choosing X" / "Authorization styles" / comparison tables; Notion "Tradeoffs"; user-frequency reasoning from `do_not[user-frequency-*]`. Synthesize the rest from `api[]` notes that already encode picking guidance — and then DELETE those notes (single source of truth).

#### Stage 5 — Anti-pattern compliance

**`preconditions[]`** — one entry per caller-side rule:
- `must`: imperative — "You must define every Role marker type in the SAME module as your OTW." Pull rationale from Notion + Move source structural-invariants. Each entry maps 1:1 to an error code via `fails_with:`.
- `fails_with`: the error code that fires if violated. **MUST be a real error name from the `errors:` block.** Validator rejects `fails_with: null`.
- `affects`: **mechanical union** of every function whose extractor `ABORTS|` line includes this error code. Do NOT curate or trim to a "load-bearing subset" — the agent grep-confirms preconditions against this list, and a curated subset means the agent will miss real abort paths. If a trivial pending-state getter re-checks authorization and can abort `EUnauthorized`, it goes in the list.

**Silent-failure constraints** (mistakes that compile and run but produce wrong / unrecoverable state — e.g., sending a wrapper to an object's address via TTO causes permanent lock with no abort) do NOT belong in `preconditions[]`. They live exclusively in `do_not[]`, where the `example_bad` / `example_good` pattern is the right educational surface.

**`do_not[]`** — one entry per consumer-side mistake mined from:
1. Notion "Tradeoffs introduced" (default path)
2. Move source module-level doc comment "DO NOT" warnings + "Misuse Paths" / "Security Model" sections
3. Docs guide "Authorization styles" or comparison sections

For each:
- `description`: one-sentence "what NOT to do".
- `why_bad`: one-sentence consequence.
- `fix`: one or two sentences pointing at the right alternative (often referencing `composes_with[]`).
- `example_bad`: Move snippet showing the wrong shape. Keep it short (5-15 lines). Synthesize from the mined rationale, naming concrete types from the module (e.g., for RBAC `&Auth<TraderRole>` not `&Auth<X>`).
- `example_good`: matching Move snippet showing the correct shape, same scenario.
- `severity`: `high` if Notion says "fatal", "kills protocol"; `medium` for "avoid"; `low` for stylistic.

For `frequency: admin-frequency` modules, ALWAYS synthesize a `user-frequency-<module-shortname>` `do_not` entry even if Notion does not state it explicitly.

**`composes_with[]`** — **DEFAULT: `composes_with: []`**. Emit an entry ONLY when the composition is documented in one of the canonical sources of truth: a comment in the module's `.move` source, an in-tree test that actually composes the two modules, the R&D Notion page, or the official docs MDX guide. Do NOT synthesize "this is how you could combine them" — that creates false-confidence guidance and the agent's generated code may not even compile (a real case from earlier iterations: TwoStepTransferWrapper lacks `store`, so wrapping it in delayed_transfer is structurally impossible; an invented snippet would have shipped a broken pattern).

If an entry IS justified:
- `module`: sibling module FQN.
- `when`: one sentence.
- `source`: REQUIRED proof — `<file:line>` (source/test) or URL (Notion / docs guide). If the synthesis cannot produce this field, the entry must not exist.
- `example`: Move snippet derived from the cited source. Must type-check against the actual API surface.

Where related material goes when it does NOT qualify for `composes_with[]`:
- "Use module X for use case Y" (sibling pointer) → already lives in `does_not_solve[]`. Do not duplicate.
- "Pick between sibling A vs B for situation X" → `decisions[]`.
- "Structural incompatibility / why these don't compose" → also `decisions[]`, not a forced-empty `composes_with[]` entry.

**Empty `composes_with[]` MUST carry an inline comment** explaining that the list is intentionally empty (vs accidentally unfilled). One-line form, e.g.:

```yaml
composes_with: []   # Empty — no compositions are source-cited. Sibling pointers
                    # live in does_not_solve[]; choosing between siblings lives in decisions[].
```

Without the comment a future maintainer cannot tell whether the skill author finished the section or forgot it.

#### Optional `_audit_grounding:`

Always emit (it's where the structural data lives that auditors/maintainers consume):
- `canonical_test`: pointer to ONE happy-path test. Heuristic order:
   1. Test literally named `test_<core_fn>_happy_path` or `<core_fn>_happy_path` if it exists.
   2. Otherwise the test that exercises the **full canonical end-to-end choreography** of the module (e.g. wrap → initiate → accept for `two_step_transfer`; new → grant_role → new_auth → revoke for `access_control`; schedule → execute for `delayed_transfer`).
   3. Otherwise pick the longest test that exercises >=3 public functions in sequence.
   4. If no end-to-end test exists (pure type wrappers like `ud30x9`, or modules with only sharded operation-by-operation tests like `ud30x9_base`), set `canonical_test: null`. The agent reads `null` as "no single happy-path exists; consult the sharded suite if stuck."
- `precondition_proofs[]`: one entry per `preconditions[]`; group test_functions by the abort code they exercise. When the test list cannot be enumerated (sharded test directory, time pressure), emit `test_functions: []` — leave the entry as a placeholder pointing at the right `test_file`. The validator's "test_function not in tests file: " ERR on the empty value is a known false positive; ignore it.
- `do_not_demonstrations[]`: convention — emit **one entry per `do_not[]` id**, even when no in-tree test demonstrates the pattern. Entries that have no demonstrating test get `test_functions: []`. This is more uniform than omit-entry-when-no-tests; reviewers can verify coverage at a glance.
   ```yaml
   do_not_demonstrations:
     - do_not_id: user-frequency-rbac
       test_functions: []   # consumer-side pattern; not in-tree
     - do_not_id: rbac-via-late-added-module
       test_functions: []
   ```
- `do_not_detection[]`: detection heuristics (regex/rule) for static analyzers.
- `events[]`: from extractor `EVENT|` lines.

### 4. Validate cross-references AND schema conformance

Write the YAML to a tempfile, then run BOTH:

```bash
# (a) Cross-reference check (function names, error codes, emits)
scripts/validate_metadata.sh <tempfile> <MODULE_FILE> <TESTS_FILE_or_empty>

# (b) JSON Schema validation against the public v1.0 contract.
# Fetch the schema once (sibling skill scripts can cache it):
#   curl -s https://raw.githubusercontent.com/OpenZeppelin/contracts-sui/main/schemas/llms-metadata-v1.json > /tmp/llms-schema.json
# Then validate (requires Python `jsonschema` + `pyyaml`):
python3 -c "import json,yaml,jsonschema; jsonschema.validate(yaml.safe_load(open('<tempfile>')), json.load(open('/tmp/llms-schema.json')))" \
  && echo "SCHEMA_PASS" || echo "SCHEMA_FAIL"
```

Address any `ERR|` lines from (a) AND any `SCHEMA_FAIL` from (b). `WARN|` from (a) is informational and may be a known false positive (cross-module errors in `internal::macros`, sharded test suites — document inline in the YAML, do not paper over).

**Critical schema constraints that fail silently in cross-ref check:**
- `module.one_liner` MUST be ≤240 chars (schema `maxLength: 240`).
- `schema_version` MUST be the string `"1.0"`, not the integer `2`.
- `install.mvr` MUST match `^@openzeppelin-move/[a-z][a-z0-9-]*$` — note hyphens only, no underscores (e.g., `fixed-point-math`, NOT `fp_math`).
- `do_not[].id` MUST be kebab-case (`^[a-z][a-z0-9-]*$`) — no underscores even when the underlying Move function uses one (rename `from_u128-on-untrusted-input` → `from-u128-on-untrusted-input`).
- Top-level `additionalProperties: false` — typos like `summay:` instead of `summary:` will fail. Triple-check field names.

### 5. Write the YAML

Resolve `output_path`. Default: `/workspace/generated/sui-metadata/<MODULE_NAME>.yaml`. Create the parent directory if needed. Write the YAML.

### 6. Print provenance report

Stdout report (not in the YAML), one line per top-level field. Mark `[FALLBACK]` for any field synthesized without Notion. End with GAPS and VALIDATION sections.

---

## Error handling

Return a clear error message to the calling agent for any of:

- `source_url` is not a recognized GitHub URL OR `gh` cannot fetch
- A blob URL does not point to `<pkg>/sources/<...>.move`
- A PR URL does not touch any `<pkg>/sources/<...>.move` file
- A PR URL touches multiple `sources/*.move` files AND `module_name` was not provided
- `Move.toml` cannot be located in the staged package root
- `docs_pr_url` was provided but `gh` cannot fetch it
- An extractor script returns a non-zero exit code
- Validation produces `ERR|` lines

Notion unavailability is NOT an error — it triggers the fallback path.

Do NOT prompt the user via `AskUserQuestion`.

---

## Quality bar

When re-run on `openzeppelin_access::access_control` with the Notion AccessControl page URL provided, this skill must produce output substantially equivalent to `references/golden-rbac.yaml`:

- **`module.one_liner`** mentions "admin-frequency" explicitly.
- **`api[]`** covers the load-bearing API surface — at minimum: `new`, all `*_role` functions, `new_auth`, `has_role`, `assert_has_role`, `get_role_admin`, every `begin_*`/`accept_*`/`cancel_*` function for both the root-role and delay-change flows. Trivial getters (`is_pending_*`, `pending_*`, constant accessors) may be omitted. Every included entry has non-empty `sig` and non-empty `role`.
- **`errors:`** has all 13 error names with messages.
- **`preconditions[]`** has at least 7 entries covering every load-bearing error code (ENotOneTimeWitness, EForeignRole, ECannotManageRootRole, EZeroAddress, ECannotRenounceForOtherAccount, EDelayTooLarge, EUnauthorized).
- **`do_not[]`** has all 4 named anti-patterns: `user-frequency-rbac`, `rbac-via-late-added-module`, `registry-id-comparison-in-protected-fn`, `assert-has-role-on-greenfield`. Each has BOTH `example_bad` AND `example_good` Move snippets.
- **`composes_with[]`** has entries for `two_step_transfer` and `delayed_transfer`, each with a concrete Move snippet.
- **`_audit_grounding.precondition_proofs[]`** references real `test_*` functions from `access_control_tests.move`.
- **No `examples[]` block at the top level** — full test inventory belongs in `_audit_grounding`.

When `notion_design_url` is absent, the bar relaxes: `module.one_liner` may be a thinner pitch, `do_not[]` may be smaller (1-2 entries from source comments only), the `user-frequency-<shortname>` entry remains mandatory for admin-frequency modules.

If the output materially diverges from the golden file on the Notion-available run, iterate on the synthesis prompts in this SKILL.md or on the source artifacts — do NOT hand-patch the output file.
