# Architecture

The design decisions behind OpenZeppelin Contracts for Sui and the reasoning
that holds them together. This document answers **why** the library is shaped
the way it is. For **how** to write code that fits - naming, ordering, idioms -
see [`STYLEGUIDE.md`](./STYLEGUIDE.md).

This file is read by humans and by AI agents (every Dev3 stage, Codex, Cursor,
Copilot, Gemini) to ground design choices in the project's conventions rather
than generic internet patterns.

## Overview

OpenZeppelin Contracts for Sui is a collection of secure, reusable Move
**libraries** - not a dApp. Components are designed to be composed into
downstream applications via Programmable Transaction Blocks (PTBs), audited
independently, and adopted piecemeal. Every design choice favours integrator
safety and composability over end-to-end convenience.

The library targets the Sui CLI version pinned in [`README.md`](./README.md) and
every package is on **Move 2024** (`edition = "2024"`).

## Repository layout

Packages are grouped by domain (`contracts/`, `math/`, `collections/`). Each leaf directory with
a `Move.toml` is an independently buildable, independently publishable package.

**The package catalog is owned by the READMEs, not this file.** What each
package and module does, install snippets, and docs links live in the group
READMEs and each package's own README - the single source of truth for that
information:

- [`contracts/README.md`](./contracts/README.md) → per-package READMEs (e.g.
  [`contracts/access/README.md`](./contracts/access/README.md))
- [`math/README.md`](./math/README.md) → per-package READMEs
- [`collections/README.md`](./collections/README.md) → the `openzeppelin_collections` package README (modules `sorted_map`, `sorted_set`, `big_sorted_map`)

This document covers only the *principles* behind the layout, never the catalog.

**Why split into many small packages?** Each package has its own dependency set,
its own audit surface, and its own published address. Integrators depend only on
the components they use, and a vulnerability in one package never forces a
republish of the others - the package boundary is an audit boundary.

**Conventional package layout.** Every package follows the same internal shape:

- `sources/` - public modules; `sources/internal/` for package-private helpers
- `tests/` - unit tests (mirrors the `sources/` grouping)

## Core design principles

### Capability-based access control

Authorization is carried by **capability objects** (`*Cap`), not by address
allow-lists stored in shared state. Holding the object *is* the permission. This
keeps authorization checks local, composable, and free of global mutable lists
that grow unboundedly. See `openzeppelin_access` for the canonical pattern.

### Owned vs. shared objects

- **Owned objects** for 1-to-1 relationships - cheaper, no consensus ordering.
- **Shared objects** for multi-user / concurrent access.
- **Shared-object creation is two functions**: one creates and returns the
  object, one shares it - so callers can run setup logic before the object
  becomes shared.

### Composability first (PTB-friendly)

These are defaults that keep components reusable in PTBs - not absolutes. Some
functions legitimately transfer (when transferring *is* the operation's
semantic); treat those as documented exceptions, not reasons to drop the
guideline.

- Prefer functions that **return objects** over self-transferring them. Returning
  lets the caller chain the result into the next PTB command; an internal
  `transfer::transfer` ends the value's life and breaks composition.
- Mint/create functions should return the created object rather than transferring
  it internally.
- Return excess coins (even zero-value) rather than transferring them internally.
- Keep core logic mostly free of `transfer::*` - push transfers to the edges
  (entry functions / the integrator) where practical.

### Bounded state

Sui objects are capped at 250 KB and abort the transaction if exceeded. The
library therefore:

- uses `vector` / `VecSet` / `VecMap` only for bounded collections (≤ 1000 items),
- uses `Table` / `Bag` / `ObjectBag` / `ObjectTable` / `LinkedTable` for large or
  unbounded collections,
- never embeds an ever-growing vector inside a long-lived object.

## Storage & object model

Prefer explicit, typed storage keys (positional `*Key` structs) for dynamic
fields over ad-hoc primitive keys - they document intent and prevent key
collisions across features in the same object.

## Upgrade safety

This is a library: downstream packages depend on published bytecode that cannot
be retracted. Design for forward compatibility from day one.

- **`public` function signatures are permanent.** Once published, a `public`
  signature can never change. Expose only the stable external API as `public`;
  keep anything you may want to evolve `public(package)` or private (the rule
  lives in [`STYLEGUIDE.md`](./STYLEGUIDE.md#functions)).
- **Struct types are immutable across upgrades** - they cannot be deleted,
  redefined, or have their abilities changed once published. Introduce a struct
  only when its shape is settled.
- **Error codes are append-only.** Never renumber an existing
  `#[error(code = N)]` - integrators match on the numeric abort code (the rule
  lives in [`STYLEGUIDE.md`](./STYLEGUIDE.md#naming)).
- **Version long-lived shared state** so a module published in a later upgrade
  can reject calls made against a stale version of the object.
- **Keep extension-package interfaces unchanging** so a change never breaks the
  packages that depend on or extend them.

## Testing architecture

- Unit tests live in `tests/`; in-module test code is limited to `#[test_only]`
  helpers and `#[test]` functions that reach private items (see
  [`STYLEGUIDE.md`](./STYLEGUIDE.md#testing)).
- Property-style tests use Sui's `#[random_test]` attribute (see the
  `sd29x9` / `ud30x9` test suites for the established pattern).
- New code must meet the coverage gate in
  [`CONTRIBUTING.md`](./CONTRIBUTING.md#code-quality-standards).

## AI usage guidelines

When extending this library with AI assistance:

- **Match existing patterns** in the touched package before introducing new ones;
  consistency across the library outranks local cleverness.
- **Treat this file and [`STYLEGUIDE.md`](./STYLEGUIDE.md) as authoritative** over
  generic Move/Sui patterns learned from the wider internet.
- The package split is an audit boundary, not just an organisational one - which
  is why changing it (or adding dependencies) requires sign-off; see the policy
  in [`CONTRIBUTING.md`](./CONTRIBUTING.md#commit-and-pr-conventions).
- Prefer the boring, explicit solution; this is security-critical library code.
