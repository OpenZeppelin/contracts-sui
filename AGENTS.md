# Agent Guide

Lean entry point for AI agents (Codex, Cursor, Copilot, Gemini, Claude Code) and
new contributors. This file does **not** restate the rules - it points to the
single sources of truth and lists the boundaries you need.

## Sources of truth - read these first

- [`STYLEGUIDE.md`](./STYLEGUIDE.md) - **how** we write Move: naming, section
  ordering, imports, idiomatic Move 2024, testing, documentation. Follow it
  exactly; do not invent conventions from generic internet patterns.
- [`ARCHITECTURE.md`](./ARCHITECTURE.md) - **why** the library is shaped this
  way: package split, capability-based access control, owned vs. shared objects,
  PTB composability, bounded state, upgrade safety.
- [`CONTRIBUTING.md`](./CONTRIBUTING.md) - PR workflow, build/test/lint commands,
  commit & PR conventions, coverage gate, and the dependency/package-split policy.

## Build & test

Commands operate **one package at a time** (`--path <package>`, e.g.
`contracts/access`, `math/core`) - there is no workspace-wide build. The full
command list (build, test, coverage, lint, doc) is in
[`CONTRIBUTING.md`](./CONTRIBUTING.md#a-typical-workflow); the required Sui CLI
version is pinned in [`README.md`](./README.md).

Review changes against the style guide before committing:

- **Claude Code**: run the `/code-quality` command.
- **Other agents** (Codex / Cursor / Copilot / Gemini): the slash command is
  Claude-specific, but the procedure is plain markdown - read and follow
  [`.claude/commands/code-quality.md`](./.claude/commands/code-quality.md).

Either way the rules come from `STYLEGUIDE.md`; the procedure restates none of them.

## Packages

Each `Move.toml` directory under `contracts/` and `math/` is a separate package; `collections/` is itself the single `openzeppelin_collections` package (modules `sorted_map`, `sorted_set`, `big_sorted_map`).
For the catalog - what each package/module does, install snippets, docs links -
read the group and package READMEs (the single source of truth):

- [`contracts/README.md`](./contracts/README.md) + each package's `README.md`
- [`math/README.md`](./math/README.md) + each package's `README.md`
- [`collections/README.md`](./collections/README.md) (the `openzeppelin_collections` package README)

For agents **integrating this library into a downstream project** (rather than
contributing to this repo), [`llms.txt`](./llms.txt) is the discovery entry point -
it points to these catalogs, each package's `examples/`, the generated API reference,
and `audits/`.

## Boundaries - do not touch

- `**/build/` - compiler output (generated)
- `**/artifacts/` - generated reference data; never hand-edit
- `audits/` - published audit reports; adding a new report is fine, but don't
  modify or delete existing ones

For commit & PR conventions and the dependency/package-split policy, see
[`CONTRIBUTING.md`](./CONTRIBUTING.md#commit-and-pr-conventions).
