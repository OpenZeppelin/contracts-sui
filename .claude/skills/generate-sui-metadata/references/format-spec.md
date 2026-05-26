# AI-native semantic metadata format — v1.0 (public)

**Audience: AI integrator agents building Sui Move modules on top of `OpenZeppelin/contracts-sui`.** No other consumer is in scope for the integrator-facing top-level structure. Everything that serves auditors / maintainers / dashboards lives under `_audit_grounding:` (last section), which agents skip during code generation.

**Authoritative schema:** the public JSON Schema lives in the contracts-sui repository at [`schemas/llms-metadata-v1.json`](https://raw.githubusercontent.com/OpenZeppelin/contracts-sui/main/schemas/llms-metadata-v1.json) (per-module YAMLs) and [`schemas/llms-package-index-v1.json`](https://raw.githubusercontent.com/OpenZeppelin/contracts-sui/main/schemas/llms-package-index-v1.json) (per-package index files). Every YAML the skill emits MUST validate against the relevant schema. This file is the human-readable companion to those schemas — when the two disagree, the JSON Schema is authoritative because it is what external integrators run their tooling against.

## Design rule

Every top-level field must answer one of these six questions an integrator agent asks while building:

1. **Selection** — "Is this the right module for what I'm building?"
2. **Install** — "How do I add it as a dependency?"
3. **Bootstrap** — "What's the canonical `init` shape? What's the minimal end-to-end sequence?"
4. **Integration** — "What functions do I call? What are their signatures, aborts, and emitted events?"
5. **Decisions** — "Two functions look applicable — which one do I pick?"
6. **Anti-pattern compliance** — "What mistakes should I avoid? What's the right shape instead?"

If a field doesn't serve one of these six → it goes under `_audit_grounding:` or doesn't exist.

## Schema

```yaml
schema_version: "1.0"

# ============================================================
# STAGE 1 — SELECTION
# ============================================================

module:
  name: <fully-qualified module name, e.g., openzeppelin_access::access_control>
  package: <package name from Move.toml>
  re_exports_from: [sibling_module_a, sibling_module_b]   # OPTIONAL — emit only when this module re-exports APIs from sibling modules via `public use fun`. Signals to agents that the FULL reachable surface includes the listed siblings' YAMLs too (e.g., `sd29x9.move` re-exports method-style calls from `sd29x9_base` and `sd29x9_convert`). Omit the field entirely when there are no re-exports.
  one_liner: "Single sentence (≤240 chars). What the module does + the dominant load-bearing gotcha (e.g., frequency-class warning). First thing the agent reads; schema-enforced length cap keeps it agent-classifiable in one token."
  summary: |
    OPTIONAL multi-paragraph elaboration that doesn't fit in one_liner.
    Agents read this only when the one_liner is not enough to decide
    whether and how to use the module. No length cap.

domain: <kebab-case category>                 # e.g., access-control, math, governance, tokens, data-structures, infra. Schema is open via pattern — new categories don't require a schema bump.
frequency: admin-frequency | user-frequency | mixed
does_not_solve:
  - "one-line boundary statement"           # MUST: 1 line max each, no rationale
  - "another one-liner"

# ============================================================
# STAGE 2 — INSTALL
# ============================================================

install:
  use_statement: |
    use openzeppelin_<pkg>::<module>::{Self, <Types>};
  # NOTE: the per-module `install:` block holds ONLY `use_statement`. All package-level
  # install metadata (MVR slug, commit pin, Move.toml snippets, github alternative) lives
  # in the package's `<pkg>/llms/index.yaml` under its own `install:` block. This avoids
  # duplication and drift across modules in the same package — see the index sample below.

# ============================================================
# STAGE 3 — BOOTSTRAP
# ============================================================

setup_snippet: |
  module my_app::my_module;

  use openzeppelin_<pkg>::<module>;
  // ... canonical init / wrap / setup shape the agent copies and adapts

quick_start: |
  // Minimal end-to-end happy path. 3-5 calls max — the typical sequence
  // a first-time integrator runs. Should compile against the module as
  // documented. Different from `setup_snippet` (which is just `init`):
  // this includes the FIRST USEFUL CALL after setup.

# ============================================================
# STAGE 4 — INTEGRATION
# ============================================================

types:
  # Integrator-facing structs the agent will reference by type — both
  # objects (`has key`) and reusable values (`has store`). Excludes events.
  - name: <TypeName>
    type_params: "<phantom T, ...>"           # empty string if none
    capabilities: [key, store]                # any of: key, store, copy, drop
    role: "One phrase: what this type represents in caller terms."

api:
  - name: <fn_name>
    sig: "<type-param-list>(<param-list>) -> <return-type>"
    role: "one phrase: what this call does in caller terms"
    aborts: [E1, E2, ...]                    # error names — see errors: block
    emits: [Event1, Event2]                  # OPTIONAL — events emitted on success
    notes: |                                  # OPTIONAL — only for non-obvious
      Anything an agent might miss: idempotency, hot-potato constraints,
      ordering requirements, when to pick this vs a sibling function.

errors:
  # Each error name maps to a small object with the on-chain abort `code`
  # and the human-readable `message`. `code` is the integer Sui surfaces
  # in `MoveAbort`; the integrator agent needs it to map runtime aborts
  # back to error names without re-reading source.
  EXxx:
    code: <N>                                 # integer from #[error(code = N)]; null if absent
    message: "human-readable abort message (verbatim from #[error] const)"
  EYyy:
    code: <M>
    message: "..."

# ============================================================
# STAGE 4.5 — DECISIONS
# Agent picks between siblings / overlapping functions when intent is
# ambiguous from user prompt alone. ONE source of truth; do not also
# encode this in `api[].notes`.
# ============================================================

decisions:
  - question: "Plain-English question the agent matches user intent against."
    options:
      - use: "<function or pattern name>"
        when: "Concrete condition: what makes this the right choice."
        why: "One sentence on the consequence — what the agent gets right vs wrong."
      - use: "<alternative>"
        when: "..."
        why: "..."

# ============================================================
# STAGE 5 — ANTI-PATTERN COMPLIANCE
# ============================================================

preconditions:
  # Things the integrator MUST satisfy in their code or the call aborts.
  - must: "Imperative statement: what the integrator must do."
    fails_with: EXxx                          # which error fires if violated
    affects: [fn1, fn2, ...]                  # which entry-points enforce it

do_not:
  # Concrete mistakes the integrator is most likely to make. Each entry
  # includes a wrong shape and the right shape — agents pattern-match on
  # code, not on prose.
  - id: <kebab-case-id>
    severity: high | medium | low
    description: "One sentence: what NOT to do."
    why_bad: "One sentence on the consequence (perf, security, correctness)."
    fix: "One or two sentences: what to do instead."
    example_bad: |
      // Move code that exhibits the anti-pattern
      ...
    example_good: |
      // Move code that does it correctly
      ...

composes_with: []
  # DEFAULT: empty. Only emit an entry when the composition is documented in
  # one of the three sources of truth — source code comments, an in-tree test,
  # the R&D Notion page, or the official docs guide. Invented "you could
  # combine these like this" patterns are NOT allowed here — they create
  # false confidence and the example_code may not even compile.
  #
  # Where to put related material instead:
  # - "use module X for use case Y"           → does_not_solve[] (already pointer-style)
  # - "pick between sibling A vs B for X"     → decisions[]
  # - documented combination with cited proof → composes_with[] (this block)
  #
  # When an entry IS justified, shape:
  # - module: openzeppelin_<pkg>::<sibling>
  #   when: "One sentence: when to reach for the combination."
  #   source: "<file:line | docs URL | Notion section>"   # REQUIRED — proof
  #   example: |
  #     // Move snippet — MUST type-check against the cited source.
  #     ...

# ============================================================
# OPTIONAL — agent skips this section during code generation.
# Audit / maintainer surfaces consume it. Reviewer of the generated
# metadata uses it to spot-check claims. NOT integrator-facing.
# ============================================================

_audit_grounding:
  # Proof grounding for preconditions
  precondition_proofs:
    - precondition_fails_with: EXxx
      test_file: contracts/<pkg>/tests/<...>.move
      test_functions: [test_x_rejects_y, test_x_rejects_z]

  # Proof grounding for do_not entries (when they have in-tree tests)
  do_not_demonstrations:
    - do_not_id: <kebab>
      test_functions: [...]

  # Detection heuristics for static analyzers (auditor tooling)
  do_not_detection:
    - do_not_id: <kebab>
      pattern: "prose description of the bug shape"
      heuristic: "regex or rule the auditor uses to spot it"

  # Optional pointer for an integrator agent that wants to consult ONE
  # canonical happy-path test when stuck.
  canonical_test:
    file: contracts/<pkg>/tests/<...>.move
    function: <test_function_name>

  # Events emitted by the module — only matters when the agent writes
  # indexing/observability code. Most integration agents skip it.
  events:
    - name: EventName
      fields: [field1, field2, ...]
```

**No `audit:` field anywhere in the YAML.** Audit information (when it exists) lives in the repo's `audits/` directory at the ref pinned by the package's `index.yaml` `install.repo_ref`. Integrator navigates there if they care. Surfacing a binary status (audited / in-progress) in YAML invites either false claims or drift; just don't.

## Index schema (per-package `index.yaml`)

Each package owns one `<pkg>/llms/index.yaml`. It enumerates every per-module YAML in the package AND owns the **package-level install metadata** that used to be duplicated across every module YAML (hoisted in v1.0). Module YAMLs reference it implicitly: they keep only `install.use_statement`; everything else lives here.

```yaml
schema_version: "1.0"
package: openzeppelin_<pkg>
install:
  mvr: "@openzeppelin-move/<slug>"            # Primary install path — Move Package Registry pin.
  repo_ref: <full-commit-sha>                 # Single source of truth — the commit every module YAML in this package was extracted from. ALWAYS a full 40-char SHA — never a branch or tag.
  release: <"v1.2.0" | null>                  # Release tag this index (and the per-module YAMLs under it) matches (semver-prefixed) when extracted at a tagged release. `null` when extracted from main between tags. install.repo_ref is the actual reproducible pin.
  move_toml_snippet: |
    [dependencies]
    openzeppelin_<pkg> = { r.mvr = "@openzeppelin-move/<slug>" }
  github_alternative: |
    # Uses TOML table-heading form (`[dependencies.name]`) — inline tables
    # cannot span multiple lines in TOML, so the heading form is the only
    # readable option with inline comments.
    [dependencies.openzeppelin_<pkg>]
    git = "https://github.com/OpenZeppelin/contracts-sui.git"
    subdir = "<path-to-pkg-from-repo-root>"   # e.g., contracts/access or math/fixed_point
    rev = "<commit-sha-or-tag>"   # Agent fills in. Prefer the latest release tag for stable
                                  # builds; pin a SHA for audits; use a branch only during
                                  # active development. See `install.repo_ref` above for the
                                  # commit this metadata was extracted from.

modules:
  - name: <module_name>                       # Module declaration name (e.g., access_control). Pattern: ^[a-z_][a-z_0-9]*$.
    path: <relative-path-to-yaml>             # e.g., access_control.yaml or ownership_transfer/two_step_transfer.yaml. Mirrors the package's sources/ layout.
    summary: "One-line summary (≤240 chars) — what the module does."
  - name: ...
```

**No `repo_ref` at the module level.** The package's `index.yaml` is the single source of truth for the commit pin; module YAMLs only carry their `use_statement`. This eliminates the drift surface where a per-module `repo_ref` could diverge from the index's.

**`github_alternative` comment is canonical and package-agnostic.** All three pinning strategies (release tag / SHA / branch) are spelled out; the `rev = "<commit-sha-or-tag>"` is the agent-fills-in slot. Do NOT bake a concrete version number (e.g. `v1.1.0`) into the comment — it goes stale on every release.

## Internal evolution (development-time history)

Internal-only naming context for skill maintainers. The PUBLIC schema released to integrators is **v1.0** (see top of file). What's tracked below is the development-time evolution from skill `v1` (initial draft) → `v2.0/2.1/2.2` (internal iterations) → public v1.0 (today). External integrators never see the internal `v2.x` numbering; their JSON Schema and every YAML they fetch carry `schema_version: "1.0"`.

Public v1.0 also adds two fields beyond internal v2.2: `module.summary` (multi-paragraph elaboration when one_liner can't carry context) and `install.release` (semver tag the package matches, or null between tags).

Public v1.0 also **hoists package-level install fields out of per-module YAMLs into the per-package `index.yaml`**: `mvr`, `repo_ref`, `release`, `move_toml_snippet`, and `github_alternative` now live in the index's `install:` block. Per-module `install:` shrinks to a single field, `use_statement`. This eliminates ~300 lines of duplication and the cross-file drift surface where a module's `repo_ref` could diverge from the index's.

| v1 field | v2 status | Where it went |
|---|---|---|
| `tags.domain` / `tags.frequency` | Promoted to top level | `domain:`, `frequency:` |
| `tags.audit` | Promoted to top level | `audit:` (was briefly demoted to `_audit_grounding.audit`) |
| `overview` (3-4 paras) | Cut | Merged into `module.one_liner` + per-`do_not` `why_bad` |
| `api.entry_points` (name + kind only) | Expanded | `api[]` now carries `sig`, `role`, `aborts`, `emits`, `notes` |
| (new in v2.1) | New | `types[]` — integrator-facing structs with capabilities |
| (new in v2.1) | New | `api[].emits` — events emitted on success |
| (new in v2.1) | New | `install.repo_ref` — git ref the YAML was extracted from |
| (new in v2.1) | New | `install.github_alternative` — direct git pin Move.toml snippet |
| (new in v2.2) | New | `quick_start` — minimal end-to-end sequence (3-5 calls) after init |
| (new in v2.2) | New | `decisions[]` — agent picks between siblings / overlapping functions |
| `api.errors` (list of objects) | Restructured | `errors:` as map of `{code, message}` (v2.1 carries abort code) |
| `api.events` | Demoted | `_audit_grounding.events` |
| `invariants[]` | Renamed + slimmed | `preconditions[]` (no `proven_by` inline; proofs moved to `_audit_grounding`) |
| `anti_patterns[]` | Renamed + enriched | `do_not[]` with `example_bad` / `example_good` |
| `anti_patterns[].detection.*` | Demoted | `_audit_grounding.do_not_detection` |
| `composes_with[].use_case` | Renamed + tightened | `composes_with[].when` + REQUIRED `composes_with[].source` citation; default `composes_with: []` (only emit when documented in source / tests / Notion / docs — v2.2 quality bar) |
| `does_not_solve[]` | Kept, trimmed | 1-line max each |
| `examples[]` (73 test refs) | Demoted + reduced | `_audit_grounding.precondition_proofs` (only what proves each precondition) + `canonical_test` pointer |
| `setup_snippet` | Kept as-is | `setup_snippet:` |
| `install.*` | Kept as-is | `install:` |

## Authoring rules

- **Be terse**. Every paragraph competes for the agent's context window. Cut anything not directly serving one of the five stages.
- **Code over prose**. Anti-patterns and compositions MUST have Move snippets. Agents pattern-match on code.
- **Imperative voice in preconditions/do_not**. "Define every Role in the same module as your OTW" — not "The library checks that role types share a home module".
- **Signatures are mandatory in `api`**. Without them an agent has to fetch the source — defeats the whole point.
- **One canonical example, not 73**. If the agent needs to look at a test, point them at exactly one. The rest is `_audit_grounding`.
- **`_audit_grounding:` is opt-in** for the agent. The skill emits it; the agent prompt configures whether to load it.

## Persona check — read this aloud before authoring

> A user asks an AI agent to build module X on top of this library. The agent has 200K tokens of context, half of it the user's existing codebase. It loads this YAML. Did the YAML earn its place in context? Did every field measurably increase the agent's chance of writing correct, idiomatic Move on the first try?

If a field doesn't pass that check — it goes under `_audit_grounding:` or doesn't exist.
