# Why `destroy_empty` is permissionless instead of witness-gated

**TL;DR:** if tearing down a `VestingWallet` required the curve witness `S`, a curve-agnostic wrapper could never destroy a wallet it holds — because it doesn't have, and can't fabricate, `S`.

## The reasoning

- A witness `S` can only be minted inside its own curve module. Any code outside that module — including a generic wrapper that just *holds* `VestingWallet<S, P, C>` without knowing the curve — has no way to produce one.
- So if `destroy_empty` took `_w: S`, the only caller that could ever destroy the wallet is the curve module itself. A wrapper that owns the wallet would be stuck: it can move it, but never tear it down and reclaim the storage rebate. That breaks curve-agnostic composability, which is the whole point of letting wrappers hold these.

## The fix (#404): split the authority via a hot-potato receipt

- `destroy_empty` takes **no witness** → permissionless. Any holder (incl. a wrapper) can drain-and-destroy the wallet and get back a `DestroyReceipt<S, P>`.
- `consume_receipt` is **witness-gated** (`_w: S`) → only the declaring curve can unwrap the receipt.
- The receipt is a hot potato, so it *must* be consumed in the same PTB. That drags the curve into the teardown transaction regardless of who initiated it, and lets the curve run teardown logic and **veto by aborting** (which reverts the whole PTB, including the destruction).
- This mirrors the existing `VestedAmount` split: one half callable without the witness, the curve gates the other. Same authority model, consistent across the API.

**Net:** wrappers get to destroy, the curve keeps its veto. Witness-gating the destroy directly would have given the curve veto power but at the cost of making curve-agnostic teardown impossible.
