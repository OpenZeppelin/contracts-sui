# Contracts Examples

Each package directory includes Move modules and companion PTB scripts that demonstrate how to compose OpenZeppelin primitives into end-to-end flows. Use these walkthroughs to see the patterns in action before integrating them into your own projects.

## What’s Included

- `examples/*`: Move modules demonstrating OpenZeppelin primitives and patterns.
- `examples/**/ptbs/`: Programmable transaction block (PTB) snippets that drive those modules from the CLI, showcasing common flows like package publish and functionality execution.

## Quickstart: Localnet Setup

Follow this checklist before running any PTB scripts. It prepares a local Sui network with a faucet so you can iterate safely.

1. **Install Sui (or verify it’s available)**
   ```bash
   sui --version
   ```
   If the command fails, install the binaries via the [official guide](https://docs.sui.io/guides/developer/getting-started/sui-install).

2. **Start the local network**
   ```bash
   RUST_LOG="off,sui_node=info" \
   sui start --with-faucet --force-regenesis
   ```
   Leave this terminal running; it hosts the validator, local RPC endpoint, and faucet.

3. **Configure sui client (first time only)**
   ```bash
   sui client
   ```
   The CLI will prompt you with questions - answer them as follows:
   - Connect to Sui Full node server? Enter `y`
   - Server URL: Enter `http://127.0.0.1:9000`
   - Environment alias: Enter `localnet`
   - Key scheme: Enter `0` for ed25519

4. **Switch the CLI to localnet**
   ```bash
   sui client switch --env localnet
   sui client active-address
   ```
   The CLI will prompt you to create/import keypairs if needed.

5. **Fund test accounts**
   ```bash
   sui client faucet --address 0xYOUR_ADDRESS
   ```
   Repeat for every signer that will send PTBs (owners, recipients, etc.).

6. **Verify connectivity**
   ```bash
   sui client gas
   ```
   Successful responses confirm the CLI can reach the local fullnode and that gas coins are available.
