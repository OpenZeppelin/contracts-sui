## Example Overview

### Gift Box V2 — Two-Step Ownership

`gift_box_v2` secures a simple gifting module with `OwnerCap` from `openzeppelin_access::ownable`, configured for the two-step transfer policy. During `init`, the module mints the capability, switches it to the two-step policy, and finalizes ownership so the deployer initially controls all privileged entry points.

Ownership only moves when both parties take action:

1. The prospective owner calls `ownable::request_ownership`, creating an `OwnershipRequestCap` that is delivered to the current owner.
2. The current owner either finalizes the transfer with `ownable::transfer_requested_ownership` or cancels it with `ownable::reject_ownership_request`.

This handshake ensures the capability never moves without explicit approval, preventing accidental loss of administrative access.

> **Important:** Anyone can request ownership, but only the current owner can approve or reject the request. Review every request carefully before acting on it.

---

## PTB Quickstart (Gift Box V2)

Need a local environment or funded accounts first? Follow the [examples quickstart](../../../EXAMPLES.md#quickstart-localnet-setup). The walkthrough below assumes:

- Your shell is at `contracts/access/examples/gift_box_v2`.
- You run PTBs with the shared helper `../../../../scripts/run_ptb.py`.
- Each referenced environment variable has been exported with a leading `0x` where required.

For convenience, set an alias once per terminal session:

```bash
cd contracts/access/examples/gift_box_v2

alias run_ptb='python3 ../../../../scripts/run_ptb.py'
```

### Step 1 – Publish and record identifiers

```bash
# publish openzeppelin_access::ownable in the same package for testing purposes
sui client publish --with-unpublished-dependencies

export PACKAGE_ID=0x...          # package containing ownable + gift_box_v2
export OWNER_CAP_ID=0x...        # OwnerCap<GIFT_BOX_V2>
export OWNER_ADDRESS=$(sui client active-address)  # deploying account
```

### Step 2 – Prospective owner submits a request

1. List available addresses:
   ```bash
   sui client addresses
   ```
2. Export and switch to the prospective owner:
   ```bash
   export NEW_OWNER_ADDRESS=0xPROSPECTIVE_OWNER
   sui client switch --address $NEW_OWNER_ADDRESS
   ```
3. Submit the request (preview, then execute):
   ```bash
   run_ptb ptbs/01_request_ownership.ptb -- --preview
   run_ptb ptbs/01_request_ownership.ptb
   ```
4. Capture the request ID for later steps:
   ```bash
   export OWNERSHIP_REQUEST_ID=0xREQUEST_ID
   ```

### Step 3 – Current owner rejects the request (demo of the negative path)

1. Return to the current owner:
   ```bash
   sui client switch --address $OWNER_ADDRESS
   ```
2. Reject the pending request:
   ```bash
   run_ptb ptbs/02_reject_request.ptb -- --preview
   run_ptb ptbs/02_reject_request.ptb
   ```
3. Confirm the request was deleted, then clear the variable:
   ```bash
   sui client object $OWNERSHIP_REQUEST_ID
   unset OWNERSHIP_REQUEST_ID
   ```

### Step 4 – Prospective owner requests again

1. Switch back to the prospective owner:
   ```bash
   sui client switch --address $NEW_OWNER_ADDRESS
   ```
2. Create a fresh request:
   ```bash
   run_ptb ptbs/01_request_ownership.ptb -- --preview
   run_ptb ptbs/01_request_ownership.ptb
   ```
3. Export the new request ID:
   ```bash
   export OWNERSHIP_REQUEST_ID=0xNEW_REQUEST_ID
   ```

### Step 5 – Current owner approves the request

1. Switch to the current owner:
   ```bash
   sui client switch --address $OWNER_ADDRESS
   ```
2. Approve the request:
   ```bash
   run_ptb ptbs/03_transfer_requested_ownership.ptb -- --preview
   run_ptb ptbs/03_transfer_requested_ownership.ptb
   ```
   OwnerCap now belongs to `$NEW_OWNER_ADDRESS`.

### Step 6 – New owner sends a gift

1. Switch (or stay) on the new owner:
   ```bash
   sui client switch --address $NEW_OWNER_ADDRESS
   ```
2. Set the gift parameters:
   ```bash
   export NOTE_TEXT="'Welcome to two-step ownership!'"
   export RECIPIENT_ADDRESS=0xGIFT_RECIPIENT
   ```
3. Send the gift:
   ```bash
   run_ptb ptbs/04_send_gift.ptb -- --preview
   run_ptb ptbs/04_send_gift.ptb
   ```

Record the gift object ID printed in the transaction output for verification.

### Step 7 – Inspect on-chain state

```bash
sui client object $OWNER_CAP_ID
sui client object 0x<NEW_GIFT_OBJECT_ID_FROM_OUTPUT>
```
