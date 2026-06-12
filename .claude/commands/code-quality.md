---
name: code-quality
description: >
  Review and (optionally) fix Move source files against this repository's
  STYLEGUIDE.md. Use this command whenever the user wants to audit, review, or
  improve code quality of a Sui Move module, or mentions "/code-quality".
  Triggers on phrases like "check code quality", "review move style", "apply the
  style guide", "fix move conventions".
user_invocable: true
---

# OpenZeppelin Contracts for Sui — Code Quality Checklist

Reviews `.move` files in this repository for convention violations and either
reports them or fixes them in place — the user picks.

This is a local maintainer tool. It is not wired into CI.

**The rules are not in this file.** They live in
[`STYLEGUIDE.md`](../../STYLEGUIDE.md) at the repository root — the single source
of truth for our conventions (design rationale in
[`ARCHITECTURE.md`](../../ARCHITECTURE.md)). This command is procedure only: it
reads `STYLEGUIDE.md` and checks code against it, so the rules can never drift
from the file every human and agent already follows.

## Usage

- `/code-quality` — review the file(s) changed on the current branch
  (`git diff main...HEAD --name-only`, plus any uncommitted edits).
- `/code-quality <path>` — review a specific file or directory.
- `/code-quality <package-name>` — review a package by name (e.g.
  `openzeppelin_access`).

## Workflow

### 1. Check working tree

```bash
git rev-parse --abbrev-ref HEAD
git status --short
```

If the working tree is dirty, warn the user and ask whether to:

- Continue (the quality-fix commit will mix with their unrelated changes).
- Stash first, run the command, then unstash.
- Abort.

Do not silently mix unrelated changes. If the current branch is `main`, do not
commit there — require a new branch.

### 2. Discover the file set

If a path or package name was provided, expand it:

- **Path** → glob `**/*.move` under it, excluding `build/`.
- **Package name** → find the `Move.toml` whose `[package] name` matches, then
  glob `**/*.move` under its `sources/`, `tests/`, and `examples/`.

If no argument was given, derive the file set from git:

```bash
git merge-base main HEAD                                          # base
git diff $(git merge-base main HEAD) HEAD --name-only             # committed
git diff --name-only ; git ls-files --others --exclude-standard   # uncommitted
```

Filter to `*.move` under `contracts/` and `math/`, excluding `build/`,
`vendor/`, and `.claude/`. If empty, report "no Move files in scope" and stop.

**Edition check.** For each package in scope, parse `edition` from the
`[package]` table of its `Move.toml`. These conventions target **Move 2024**. If
a package is `edition = "legacy"` (or the field is missing/unknown), stop and
tell the user — running 2024 rules on a legacy package produces misleading
findings. Do not proceed on that package unless the user explicitly overrides.

Read every file in scope before checking rules — partial reads produce partial
reviews. **Also read [`STYLEGUIDE.md`](../../STYLEGUIDE.md) now** (and
[`ARCHITECTURE.md`](../../ARCHITECTURE.md) for design constraints it references).

### 3. Identify violations

Walk the file set against the rules in [`STYLEGUIDE.md`](../../STYLEGUIDE.md) —
the codified conventions are explicit, named, and stable there. Check every file
against every rule the style guide defines. Do not invent rules that are not in
`STYLEGUIDE.md`; if the code does something the style guide does not cover, that
is not a violation.

Build a numbered list of findings. Each entry has:

- **file path** (repo-relative)
- **line number** (or line range)
- **rule** — the `STYLEGUIDE.md` section it violates (e.g. `Naming`,
  `Section ordering`, `Idiomatic Move 2024`)
- **finding** — what differs and why it matters
- **fix** — one or two sentences describing what should change

**Borderline findings** — a rule may apply literally but be overridden by design
intent (e.g. `transfer::transfer` inside a function whose semantic *is*
transferring). Do not put these in the numbered list; print them in a separate
"Borderline (review and decide)" section so the user is not forced to reject
them repeatedly.

### 4. Choose an action

Tell the user how many findings were collected and ask which mode to run in:

1. **Apply all** — apply every fix in one pass without further prompts. Stop only
   on a tool error or a finding the command cannot fix on its own.
2. **One-by-one** — walk the findings in order. For each, describe it (file,
   line, what's wrong, what the edit would do), then ask the user to approve
   before editing. Skipped findings are recorded in the final report.
3. **Report only** — print the full list and stop. Do not edit anything. Skip to
   step 7.

The user may also cancel entirely; in that case stop without further action.

If the list is empty, say so plainly and stop:

> ✅ No violations found in <N> file(s).

### 5. Apply fixes

Use the `Edit` tool. After editing, format with prettier so the `.move` files
match the repo's layout. **Preflight first** (prettier silently skips `.move`
files when the Move plugin is absent):

- Ensure `<repo_root>/.prettierrc` lists `@mysten/prettier-plugin-move` in
  `plugins`. If missing, offer to add it (preserve other settings) or skip
  prettier for this run — do not overwrite a custom config.
- Ensure the plugin is resolvable (`node_modules/@mysten/prettier-plugin-move`
  or `package.json` devDependencies); offer to install it with the repo's
  package manager, else skip.

Then, from the repo root (so the root `.prettierrc` is auto-discovered):

```bash
npx prettier --write <files>
```

Do not pass `--config` explicitly. If the user opted out of prettier, note it in
the step 7 report.

### 6. Build, test, lint

Pick `--build-env` by parsing the package's `Move.toml`: prefer a name from
`[environments]` (favouring `testnet` → `mainnet`), fall back to `testnet` when
none is declared. Always pass `--build-env` explicitly — the Sui CLI has no true
default for env-agnostic packages. Run **both** commands (even if the first
fails) so the user sees every issue in one pass:

```bash
# Test-mode compile + lint + run tests
sui move test  --path <package> --build-env <env> --lint --warnings-are-errors

# Production-mode build + lint (catches dead code only test code references)
sui move build --path <package> --build-env <env> --lint --warnings-are-errors
```

**Pre-existing-warning caveat:** `--warnings-are-errors` also fails on warnings
unrelated to this run. If the output is dominated by pre-existing warnings, ask
the user whether to fix them too or drop the flag for this run only — do not
silently swallow the failure.

Coverage gate is defined in [`CONTRIBUTING.md`](../../CONTRIBUTING.md); if a fix
removes test coverage, restore it before finishing
(`sui move test --coverage --path <package>`).

### 7. Report

Summarise what changed, grouped by file. If nothing was edited (report-only or
no violations), say so and stop.

## Rules

This command carries **no rule set of its own**. The conventions live in
[`STYLEGUIDE.md`](../../STYLEGUIDE.md) (with design rationale in
[`ARCHITECTURE.md`](../../ARCHITECTURE.md)) — read it at the start of step 2 and
check every `.move` file against it in step 3. Keeping the rules in the repo (not
in this command) is deliberate: the same file serves humans and every other agent
(Codex / Cursor / Copilot / Gemini), and the rules can never drift from the code
they govern.

The rule categories for step 3 grouping and the step 7 summary are the `##`
section headings of `STYLEGUIDE.md` (Naming, Module & Package, Section ordering,
Imports, Structs, Functions, Idiomatic Move 2024, Collections & object size,
Testing, Lint suppression, Documentation). Use whatever headings `STYLEGUIDE.md`
actually defines — do not assume a fixed list.

## Important notes

- Commit & PR conventions (Conventional Commits, no `Co-Authored-By` trailer, no
  "Test plan" section) live in
  [`CONTRIBUTING.md`](../../CONTRIBUTING.md#commit-and-pr-conventions). A sensible
  default commit message is `refactor: apply STYLEGUIDE.md (<package>)`.
- When unsure whether something is "wrong" or just "uncovered", check
  `STYLEGUIDE.md` — if the rule is not there, it is not a violation. Propose
  adding the rule to `STYLEGUIDE.md` rather than enforcing an unwritten one.
