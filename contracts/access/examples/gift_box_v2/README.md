## Example overview

### Gift Box V2 (Two-Step Ownership Transfer)

This module demonstrates securing a gift box with `OwnerCap` under the two-step ownership transfer policy provided by `openzeppelin_access::ownable`. During initialization, `init` mints the capability, switches it to the two-step policy, and finalizes ownership so the publisher controls the module.

Under this policy, ownership only changes hands after both participants act:

1. The prospective owner calls `ownable::request_ownership` to mint an `OwnershipRequestCap` and passes it to the current owner.
2. The current owner completes the handoff by calling `ownable::transfer_requested_ownership`, or rejects the request through `ownable::reject_ownership_request`.

This handshake prevents the capability from moving to an unintended address without explicit consent, reducing the risk of losing access to privilege-restricted entry points.

> **Important:** Anyone can create a request, but only the current owner can approve it. Always verify ownership requests before approving them.

### PTB quickstart (Gift Box V2)

If you still need a local environment and funded accounts, follow the [examples quickstart](../../../EXAMPLES.md#quickstart-localnet-setup) first.

Use the programmable transaction block helpers under `./ptbs/`—`01_request_ownership.ptb`, `02_reject_request.ptb`, `03_transfer_requested_ownership.ptb`, and `04_send_gift.ptb`—to exercise the full two-step flow. Publishing should be done with the Sui CLI directly. The commands below assume your shell is in `contracts/access/examples/gift_box_v2`, that you invoke the shared helper `../../../../scripts/run_ptb.py` (optionally via an alias), and that you set the environment variables noted in each step before running the scripts (no edits to the PTB files are required).

1. **Publish the example package (CLI command)**
   - From `contracts/access/examples/gift_box_v2`, run:
     ```bash
     # publish openzeppelin_access::ownable in the same package for testing purposes
     sui client publish --with-unpublished-dependencies
     ```
   - Record the published package ID and the resulting `OwnerCap<GIFT_BOX_V2>` object ID from the transaction output.
   - Export the package/object identifiers for the follow-up PTBs (include the `0x` prefix in each value):
     ```bash
     export PACKAGE_ID=0x...          # package container (contains both ownable and gift_box_v2)
     export OWNER_CAP_ID=0x...        # object ID of the OwnerCap<GIFT_BOX_V2>
     export OWNER_ADDRESS=$(sui client active-address)  # original deployer/owner account
     ```

2. **Set up helper alias (optional)**
   - For shorter commands in the following steps, you can set up an alias:
     ```bash
     alias run_ptb='python3 ../../../../scripts/run_ptb.py'
     ```
   - The remaining steps will use this alias in place of the full Python command.

3. **Submit an ownership request (prospective owner)**
   - List available addresses and choose one to be the new owner:
     ```bash
     sui client addresses
     ```
   - Choose the account that should receive ownership and export its address:
     ```bash
     export NEW_OWNER_ADDRESS=0xPROSPECTIVE_OWNER
     ```
   - Switch the CLI to that account:
     ```bash
     sui client switch --address $NEW_OWNER_ADDRESS
     ```
   - Ensure `OWNER_ADDRESS` remains set to the current owner and run a preview, then the real request:
     ```bash
     run_ptb ptbs/01_request_ownership.ptb -- --preview
     run_ptb ptbs/01_request_ownership.ptb
     ```
   - Capture the `OwnershipRequestCap` object ID printed in the transaction output and export it for later steps:
     ```bash
     export OWNERSHIP_REQUEST_ID=0xREQUEST_ID
     ```

4. **Reject the pending request (current owner)**
   - Switch back to the original owner account:
     ```bash
     sui client switch --address $OWNER_ADDRESS
     ```
   - Ensure `OWNERSHIP_REQUEST_ID` still points to the request you want to reject.
   - Run a preview, then the real rejection (this destroys the request object):
     ```bash
     run_ptb ptbs/02_reject_request.ptb -- --preview
     run_ptb ptbs/02_reject_request.ptb
     ```
   - Verify that the request object was deleted:
     ```bash
     sui client object $OWNERSHIP_REQUEST_ID
     ```
   - You should see an error indicating the object does not exist
   - After rejection, clear the exported `OWNERSHIP_REQUEST_ID` (the object no longer exists):
     ```bash
     unset OWNERSHIP_REQUEST_ID
     ```

5. **Submit a new ownership request (prospective owner)**
   - Switch to the prospective owner again:
     ```bash
     sui client switch --address $NEW_OWNER_ADDRESS
     ```
   - Repeat the request PTB to create a fresh `OwnershipRequestCap`:
     ```bash
     run_ptb ptbs/01_request_ownership.ptb -- --preview
     run_ptb ptbs/01_request_ownership.ptb
     ```
   - Export the new request ID for approval:
     ```bash
     export OWNERSHIP_REQUEST_ID=0xNEW_REQUEST_ID
     ```

6. **Approve the request and transfer ownership (current owner)**
   - Switch back to the original owner:
     ```bash
     sui client switch --address $OWNER_ADDRESS
     ```
   - Confirm that `OWNERSHIP_REQUEST_ID` is set to the newly created request ID.
   - Run the approval PTB to hand off the capability:
     ```bash
     run_ptb ptbs/03_transfer_requested_ownership.ptb -- --preview
     run_ptb ptbs/03_transfer_requested_ownership.ptb
     ```
   - After execution, the `OwnerCap` now belongs to `$NEW_OWNER_ADDRESS`. Keep `OWNER_CAP_ID` exported for the next step.

7. **Send a gift from the new owner**
   - Switch the CLI to the new owner (if not already):
     ```bash
     sui client switch --address $NEW_OWNER_ADDRESS
     ```
   - Export the message text and gift recipient:
     ```bash
     export NOTE_TEXT="'Welcome to two-step ownership!'"
     export RECIPIENT_ADDRESS=0xGIFT_RECIPIENT
     ```
   - Execute the gift PTB from the new owner account:
     ```bash
     run_ptb ptbs/04_send_gift.ptb -- --preview
     run_ptb ptbs/04_send_gift.ptb
     ```
   - Record the new gift object ID printed in the transaction results so you can inspect it in the final step.

8. **Verify results**
   - Check the capability and gift objects:
     ```bash
     sui client object $OWNER_CAP_ID
     sui client object 0x<NEW_GIFT_OBJECT_ID_FROM_OUTPUT>
     ```
