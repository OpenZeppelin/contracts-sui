## Access Examples

Hands-on walkthroughs for the `openzeppelin_access` package live here. Each subdirectory contains a Move module plus PTB scripts that illustrate a specific ownership pattern.

> **Important:** These short tutorials focus on pedagogy. They are not meant for use in production.

### Getting Ready

- Bring up a local network and fund test accounts using the [examples quickstart](../../EXAMPLES.md#quickstart-localnet-setup).
- Reuse the shared PTB helper at `../../../../scripts/run_ptb.py` to avoid repeating boilerplate.

### Example Catalog

| Directory | Scenario | Highlights | Quickstart |
|-----------|----------|------------|------------|
| [`gift_box_v1/`](gift_box_v1/) | Immediate ownership transfer | `OwnerCap` moves in a single call via `transfer_ownership`. | See `gift_box_v1/README.md` |
| [`gift_box_v2/`](gift_box_v2/) | Two-step ownership transfer | Request/approve flow using `OwnershipRequestCap`. | See `gift_box_v2/README.md` |
