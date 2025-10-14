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
alias run_ptb='python3 ../../../../scripts/run_ptb.py'
```

### Step 1 – Publish and record identifiers

```bash
sui client publish --with-unpublished-dependencies

export PACKAGE_ID=0x...          # package containing ownable + gift_box_v2
export OWNER_CAP_ID=0x...        # OwnerCap<GIFT_BOX_V2>
export OWNER_ADDRESS=$(sui client active-address)  # deploying account
```

### Step 2 – Prospective owner submits a request

```bash
sui client addresses             # optional: view saved addresses
export NEW_OWNER_ADDRESS=0xPROSPECTIVE_OWNER
sui client switch --address $NEW_OWNER_ADDRESS

run_ptb ptbs/01_request_ownership.ptb -- --preview
run_ptb ptbs/01_request_ownership.ptb

export OWNERSHIP_REQUEST_ID=0xREQUEST_ID   # capture from output
```

### Step 3 – Current owner rejects the request (demo of the negative path)

```bash
sui client switch --address $OWNER_ADDRESS
# ensure OWNERSHIP_REQUEST_ID targets the request you want to reject

run_ptb ptbs/02_reject_request.ptb -- --preview
run_ptb ptbs/02_reject_request.ptb

sui client object $OWNERSHIP_REQUEST_ID    # should report that the object no longer exists
unset OWNERSHIP_REQUEST_ID
```

### Step 4 – Prospective owner requests again

```bash
sui client switch --address $NEW_OWNER_ADDRESS

run_ptb ptbs/01_request_ownership.ptb -- --preview
run_ptb ptbs/01_request_ownership.ptb

export OWNERSHIP_REQUEST_ID=0xNEW_REQUEST_ID
```

### Step 5 – Current owner approves the request

```bash
sui client switch --address $OWNER_ADDRESS
# confirm OWNERSHIP_REQUEST_ID is set to the fresh request ID

run_ptb ptbs/03_transfer_requested_ownership.ptb -- --preview
run_ptb ptbs/03_transfer_requested_ownership.ptb
# OwnerCap now belongs to $NEW_OWNER_ADDRESS
```

### Step 6 – New owner sends a gift

```bash
sui client switch --address $NEW_OWNER_ADDRESS
export NOTE_TEXT="'Welcome to two-step ownership!'"
export RECIPIENT_ADDRESS=0xGIFT_RECIPIENT

run_ptb ptbs/04_send_gift.ptb -- --preview
run_ptb ptbs/04_send_gift.ptb
```

Record the gift object ID printed in the transaction output for verification.

### Step 7 – Inspect on-chain state

```bash
sui client object $OWNER_CAP_ID
sui client object 0x<NEW_GIFT_OBJECT_ID_FROM_OUTPUT>
```
