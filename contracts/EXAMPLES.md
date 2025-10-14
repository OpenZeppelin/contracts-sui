# Examples

Every package ships with runnable demos—Move modules paired with PTB scripts—that show how to stitch OpenZeppelin primitives into full flows. This page helps you prep your environment and discover what’s available.

---

## Layout Overview

| Path pattern | What you’ll find |
|--------------|------------------|
| `examples/*` | Move modules showcasing the package feature. |
| `examples/**/ptbs/` | Programmable transaction blocks that drive the example from the CLI. |
| [`scripts/run_ptb.py`](../scripts/run_ptb.py) | Shared helper to run PTBs with env-var substitution. |

Each example README explains the scenario and walks through the PTBs step by step.

---

## Localnet Quickstart

Run through this checklist once per session before executing any PTB scripts:

1. **Install or verify Sui CLI**
   ```bash
   sui --version
   ```
   If the command fails, follow the [official installation guide](https://docs.sui.io/guides/developer/getting-started/sui-install).

2. **Start a local network with faucet**
   ```bash
   RUST_LOG='off,sui_node=info' \
   sui start --with-faucet --force-regenesis
   ```
   Keep this terminal running; it hosts the validator, RPC endpoint, and faucet.

3. **Initial CLI setup (first run only)**
   ```bash
   sui client
   ```
   Suggested answers:
   - Connect to Sui Full node server? → `y`
   - Server URL → `http://127.0.0.1:9000`
   - Environment alias → `localnet`
   - Key scheme → `0` (ed25519)

4. **Switch to the localnet environment**
   ```bash
   sui client switch --env localnet
   sui client active-address
   ```
   Create or import a keypair if prompted.

5. **Fund every test account you plan to use**
   ```bash
   sui client faucet --address 0xYOUR_ADDRESS
   ```
   Repeat for senders, recipients, and any other signer in your walkthrough.

6. **Sanity-check connectivity**
   ```bash
   sui client gas
   sui client committee
   ```
   Successful responses confirm the CLI can reach the local fullnode and your accounts have gas coins.

7. **Open the example workspace**
   ```bash
   cd contracts/access/examples
   ```

> **Tip:** Set an alias once per shell session to run PTBs easily:  
> `alias run_ptb='python3 ../../../../scripts/run_ptb.py'`

---

## Ready to Explore?

Navigate into an example folder (e.g., [`gift_box_v1/`](access/examples/gift_box_v1/)) and follow its README for a guided PTB session. When you add new examples, drop them under `examples/` and link their quickstart in the corresponding package README so the catalog stays up to date.
