## Example Overview

### Gift Box V1 — Immediate Transfer

`gift_box_v1` showcases `OwnerCap` from `openzeppelin_access::ownable` configured with the immediate-transfer policy. During initialization, `init` mints the capability and finalizes ownership so the deployer controls the module. Because transfers are instantaneous, the current owner can hand off control in a single transaction via `ownable::transfer_ownership`. Double-check the recipient address—once transferred, the previous owner permanently loses access to the restricted entry points.

---

## PTB Quickstart (Gift Box V1)

Need to set up localnet or fund accounts? Follow the [examples quickstart](../../../EXAMPLES.md#quickstart-localnet-setup) first. These steps assume:

- You are in `contracts/access/examples/gift_box_v1`.
- You run PTBs with `../../../../scripts/run_ptb.py`.
- Every environment variable that represents an address or object ID includes the `0x` prefix.

Optional helper alias (run once per shell session):

```bash
cd contracts/access/examples/gift_box_v1

alias run_ptb='python3 ../../../../scripts/run_ptb.py'
```

### Step 1 – Publish and record identifiers

```bash
# publish openzeppelin_access::ownable alongside the example
sui client publish --with-unpublished-dependencies

export PACKAGE_ID=0x...          # package containing ownable + gift_box_v1
export OWNER_CAP_ID=0x...        # OwnerCap<GIFT_BOX_V1>
export OWNER_ADDRESS=$(sui client active-address)  # deploying account
```

### Step 2 – Transfer ownership

Ensure `PACKAGE_ID`, `OWNER_CAP_ID`, and `OWNER_ADDRESS` remain exported.

1. Discover candidate addresses:
   ```bash
   sui client addresses
   ```
2. Choose the new owner and switch back to the current owner:
   ```bash
   export NEW_OWNER_ADDRESS=0xRECIPIENT
   sui client switch --address $OWNER_ADDRESS
   ```
   > If the deploying account lacks gas coins, request them from the faucet before continuing.
3. Execute the transfer (preview, then run):
   ```bash
   run_ptb ptbs/01_transfer_ownership.ptb -- --preview
   run_ptb ptbs/01_transfer_ownership.ptb
   ```
4. Verify the transaction output shows `OwnershipTransferred` with `$NEW_OWNER_ADDRESS`.

### Step 3 – Send a gift from the new owner

1. Switch to the new owner:
   ```bash
   sui client switch --address $NEW_OWNER_ADDRESS
   ```
2. Provide the gift details:
   ```bash
   export NOTE_TEXT="'Congrats from the new ownership'"
   export RECIPIENT_ADDRESS=0xGIFT_RECIPIENT
   ```
3. Mint and transfer the gift:
   ```bash
   run_ptb ptbs/02_send_gift.ptb -- --preview
   run_ptb ptbs/02_send_gift.ptb
   ```
4. Capture the gift object ID from the transaction output for the next step.

### Step 4 – Inspect on-chain state

```bash
sui client object $OWNER_CAP_ID
sui client object 0x<NEW_GIFT_OBJECT_ID_FROM_OUTPUT>
```
