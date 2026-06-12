# Style Guide

The single source of truth for coding style and conventions in this repository.
It serves humans and AI agents alike: contributors follow it by hand, and every
Dev3 stage and code-review tool reads it instead of restating the rules.

> Scope: **how** we write Move in this repo — naming, ordering, idioms, testing,
> documentation. For **why** the library is shaped the way it is (design
> decisions, package layout, object model), see [`ARCHITECTURE.md`](./ARCHITECTURE.md).

These conventions target **Move 2024** (module label syntax, receiver syntax,
`#[error(code = N)]`, macros). Every package in this repo declares
`edition = "2024"`.

## Naming

- **Error constants**: `EPascalCase`, declared with `#[error(code = N)]`, type
  `vector<u8>`, plain `"..."` string literal (NOT `b"..."`). Codes are sequential
  from 0 and **append-only** — never renumber existing errors when adding new
  ones. Callers (frontends, integrators, tests in other packages) may match on
  the numeric abort code; renumbering silently breaks them. New errors go at the
  bottom with `code = N+1`.
- **Regular constants**: `UPPER_SNAKE_CASE`
- **Capability structs**: suffix with `Cap` (e.g. `AdminCap`)
- **Event structs**: past tense (e.g. `RoleGranted`, `TraderAccountCreated`)
- **Getters**: field name without `get_` prefix; `_mut` suffix for the mutable variant
- **CRUD**: `new`/`create`, `empty`, `borrow`/`borrow_mut`, `add`/`remove`,
  `exists`/`contains`, `drop`/`destroy`/`destroy_empty`, `to_name`/`from_name`
- **Dynamic field keys**: positional struct with `Key` suffix
- **Generic type parameters**: `T`, `U` — use descriptive names only when they
  materially aid readability
- No "Potato" in hot-potato struct names

## Module & Package

- `module my_package::my_module;` — no braces, 2024 edition label syntax
- One module per object/data structure
- PascalCase package names, snake_case named addresses; prefix named addresses
  with the project name (`openzeppelin_*`)
- Since Sui 1.45, Sui / MoveStdlib / Bridge / SuiSystem are implicitly imported —
  no manual dep declaration needed

## Section ordering

Every file must use `// === <Name> ===` delimiters in this order:

1. Imports (auto-grouped by prettier)
2. `// === Errors ===`
3. `// === Constants ===`
4. `// === Structs ===`
5. `// === Events ===` — placed **after** Structs when both are present in the
   same module; in a dedicated events module, this is the only struct-family
   section and Structs is omitted
6. `// === Method Exports ===` (if any) — `public use fun ...` receiver-syntax
   aliases exposed by this module
7. `// === Init ===` (if an `init` function is present — place it first)
8. `// === Public Functions ===`
9. `// === View helpers ===`
10. `// === Admin Functions ===` (if any)
11. `// === Package Functions ===` (if any)
12. `// === Private Functions ===`
13. `// === Test-Only Helpers ===`

Within any section, feature-oriented sub-grouping comments are allowed and must
be preserved:

```move
// === Constructors ===
// === Hot Path ===
// === Scheduling / delay management ===
```

These are intentional organisation aids — do **not** remove them.

Common ordering violations to watch for:

- Constants section appearing before Errors
- View helpers appearing after Private Functions
- Witness structs placed in `// === Init ===` instead of `// === Structs ===`
- `// === Test only helpers ===` (wrong capitalisation — must be
  `// === Test-Only Helpers ===`)

## Imports

- Don't write `use pkg::mod::{Self};` on its own line when other members of
  `pkg::mod` are imported elsewhere — merge into a single grouped import:
  `use pkg::mod::{Self, OtherMember};`. A lone `use pkg::mod;` (without `{}`) is
  fine when only the module itself is needed.

## Structs

- Declare abilities in order: `key`, `copy`, `drop`, `store`

## Functions

- Use `public` OR `entry` — never combine as `public entry`
- Write composable functions that return values (for PTB usage); mint/create
  functions should return the object, not transfer it internally
- Parameter order: **self (receiver object) first → capability second → other
  objects → primitives/utilities → Clock → TxContext last**. The capability
  always sits at position 2 (even with multiple object params) so method-call
  syntax `self.fn(&cap, other_obj, ...)` keeps the cap visible at the call site.

  ```move
  // good — self, cap, rest
  public fun set_name(account: &mut Account, _: &AdminCap, new_name: String) { ... }
  // call: account.set_name(&cap, new_name)

  // good — self, cap, other object, primitives, Clock, ctx
  public fun authorize_transfer(
      pool: &mut Pool,
      cap: &AdminCap,
      account: &Account,
      amount: u64,
      clock: &Clock,
      ctx: &mut TxContext,
  ) { ... }
  // call: pool.authorize_transfer(&cap, &account, amount, &clock, ctx)

  // bad — reversed associativity, reads backwards at the call site
  public fun update(_: &AdminCap, account: &mut Account, new_name: String) { ... }
  // call: cap.update(&mut account, new_name)
  ```

- Keep functions pure — avoid `transfer::transfer` inside core logic; return
  objects instead
- Accept payment by value — `fun pay(payment: Coin<SUI>)`, not
  `&mut Coin<SUI>` plus an `amount` — so the caller hands over exactly what they
  intend; a `&mut Coin` lets the callee draw an unbounded amount.
- Use `public(package)` or private visibility liberally — only expose the stable
  external API as `public`. A `public` signature is permanent across package
  upgrades (see [`ARCHITECTURE.md`](./ARCHITECTURE.md#upgrade-safety)).

## Idiomatic Move 2024

### Receiver syntax

Prefer `obj.fn(arg1, arg2)` over `module::fn(obj, arg1, arg2)` whenever the
function's first parameter is the object (by value, `&`, or `&mut`). Apply this
to all functions **and** tests.

Examples of required rewrites:

- `balance::join(&mut bal, b)` → `bal.join(b)`
- `table::add(&mut t, key, val)` → `t.add(key, val)`
- `object::delete(id)` → `id.delete()`
- `tx_context::sender(ctx)` → `ctx.sender()`
- `coin::split(&mut c, amount, ctx)` → `c.split(amount, ctx)`
- `option::is_none(&opt)` → `opt.is_none()`
- `string::length(&s)` → `s.length()`
- `vector::length(&v)` → `v.length()`

**Cases that CANNOT use receiver syntax — keep the module-qualified form:**

- `event::emit(e)` — generic function with no native method binding; always
  write `event::emit(e)`
- `transfer::transfer(obj, recipient)` / `transfer::public_transfer(...)` /
  `transfer::share_object(obj)` / `transfer::freeze_object(obj)` — Sui transfer
  builtins have no method aliases by default; keep module-qualified
- `object::id(&obj)` / `object::id_address(&obj)` — no method alias is
  registered for these generic `key` functions; keep as `object::id(&obj)`
- `dynamic_field::add/borrow/borrow_mut/remove` and
  `dynamic_object_field::*` — no method alias is registered on `UID`; keep
  module-qualified (e.g. `dof::add(&mut uid, key, val)`)
- Constructor / factory free functions where no instance exists yet (e.g.
  `MyStruct::new(...)`)
- Any free function whose first parameter is a primitive (`u8`..`u256`, `bool`,
  `address`) — `public use fun fn as u64.method` is rejected by the compiler when
  the type is from a different package (stdlib). There is no correct workaround
  short of the function being defined in stdlib itself. Do NOT add non-public
  `use fun` workarounds in test modules as a substitute.
- Cross-module calls where the type's defining module does not expose the
  function and no `use fun` alias is in scope

### Other idioms

- String: `b"hello".to_string()` not `std::string::utf8(...)`
- Struct field shorthand: `MyStruct { id, caps, balance_manager }` not
  `balance_manager: balance_manager`
- Vectors: `vector[...]` literal, `.length()` method, `&x[&key]` indexing
- Option macros: `opt.do!(|v| ...)`, `opt.destroy_or!(default)`,
  `opt.destroy_or!(abort EFoo)`
- Loop macros: `n.do!(|_| ...)`, `vector::tabulate!(n, |i| i)`,
  `vec.do_ref!(|e| ...)`, `vec.destroy!(|e| ...)`, `.fold!()`, `.filter!()`
- Struct unpacking: `let MyStruct { id, .. } = value;`

## Collections & object size

- Objects max 250 KB — transactions abort if exceeded
- Use `vector` / `VecSet` / `VecMap` only for bounded collections ≤ 1000 items
- Use `Table` / `Bag` / `ObjectBag` / `ObjectTable` / `LinkedTable` for large or
  unbounded collections
- Never put ever-growing vectors inside objects

## Testing

- New code must meet the coverage gate defined in
  [`CONTRIBUTING.md`](./CONTRIBUTING.md#code-quality-standards)
  (`sui move test --coverage`).
- Test cases belong in `tests/`. In-module test code should be limited to
  `#[test_only]` helpers (compiled only in test mode) and `#[test]` functions
  that exercise private items unreachable from `tests/`. Place all `#[test_only]`
  and `#[test]` items under the `// === Test-Only Helpers ===` section (item 13).
- Combine attributes: `#[test, expected_failure(abort_code = EMyError)]` —
  **always reference the error constant by name**, never by numeric literal.
  `abort_code = 5` is brittle: renumbering the error const breaks the test
  silently.
- Prefer pinning exact values: `assert_eq!(result, exact)` over bound-only
  assertions (`assert!(r >= lo && r <= hi)`). For genuine property tests, use
  Sui's `#[random_test]` attribute.
- Prefer `assert!(cond)` over `assert!(cond, 0)` — Move 2024 auto-assigns abort
  codes when omitted; a literal `0` is meaningless boilerplate.
- No cleanup in expected-failure tests — just `abort` at the failure boundary.
- In `_tests` modules: no `test_` prefix on function names; use descriptive names.
- Use `tx_context::dummy()` for simple tests instead of TestScenario overhead.
- Use `assert_eq!` (from `std::unit_test`) not `assert!` with abort codes (abort
  codes collide with app errors). Import with `use std::unit_test::assert_eq;`.
- Use `use std::unit_test::destroy` as the black hole instead of
  `destroy_for_testing()` (note: `sui::test_utils::destroy` is deprecated — the
  current Sui compiler emits `E04037` and points to `std::unit_test::destroy`).

## Lint suppression

- **Do not add `#[allow(lint(...))]` attributes.** Every lint warning must be
  resolved by fixing the underlying code, not by silencing it.
- If a lint warning cannot be addressed, stop and escalate — do not suppress.
- An existing `#[allow(lint(...))]` is itself a violation: remove the attribute
  and fix the code it was hiding. If the fix is non-trivial, surface it.
- `#[allow(...)]` for non-lint diagnostics (e.g. `unused_const`, `unused_use`) is
  similarly disallowed — fix or remove the offending item.

## Documentation

- `///` for doc comments (renders in IDEs), `//` for inline technical notes
- No JavaDoc-style `/** */`
- Document struct fields, complex params, and return values
- Use section headings `#### Parameters`, `#### Returns`, and `#### Aborts` when
  relevant; use `-` for list items (not `*`)
- Document public functions with at least `Parameters` and `Returns`; include an
  `Aborts` section whenever a function can abort
- Keep terminology consistent with the implementation (e.g. avoid documenting
  impossible paths)

  ```move
  /// Compute something.
  ///
  /// #### Parameters
  /// - `value`: Input value.
  /// - `rounding_mode`: Rounding strategy.
  ///
  /// #### Returns
  /// - Rounded output value.
  ///
  /// #### Aborts
  /// - Aborts if `value` is zero.
  ```
