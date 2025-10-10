## Example overview:

### **Gift Box V1**

This package demonstrates a gift box module protected by `OwnerCap` from `openzeppelin_access::ownable` using the immediate-transfer policy. During deployment, `init` mints the capability and finalizes ownership so the publisher controls the module. Because the policy is immediate, the current owner can hand off control in a single transaction via `ownable::transfer_ownership`, without any acknowledgement from the recipient. Be sure the new owner address is correct and can store the capability—once the transfer succeeds, the previous owner permanently loses access to the restricted entry points.

### PTB quickstart (Gift Box V1)

If you still need a local environment and funded accounts, follow the [examples quickstart](../../EXAMPLES.md#quickstart-localnet-setup) first.

Use the two programmable transaction block helpers under `./ptbs/`—`01_transfer_ownership.ptb` and `02_send_gift.ptb`—to move the owner capability and send a gift via the immediate-transfer policy. Publishing should be done with the Sui CLI directly. The commands below assume your shell is in `contracts/access/examples/gift_box_v1`, that you invoke the shared helper `../../../../scripts/run_ptb.py`, and that you set the environment variables noted in each step before running the scripts (no edits to the PTB files are required).

1. **Publish the example package (CLI command)**
   - From `contracts/access/examples/gift_box_v1`, run:
     ```bash
     cd examples/gift_box_v1/

     # publish openzeppelin_access::ownable in the same package for testing purposes
     sui client publish --with-unpublished-dependencies
     ```
   - Record the published package ID and the resulting `OwnerCap<GIFT_BOX_V1>` object ID from the transaction output.
   - Export the package/object identifiers for the follow-up PTBs (include the `0x` prefix in each value):
     ```bash
     export PACKAGE_ID=0x...          # package container
     export OWNER_CAP_ID=0x...        # object ID of the OwnerCap<GIFT_BOX_V1>
     export OWNER_ADDRESS=$(sui client active-address)  # original deployer/owner account
     ```

2. **Set up helper alias (optional)**
   - For shorter commands in the following steps, you can set up an alias:
     ```bash
     alias run_ptb='python3 ../../../../scripts/run_ptb.py'
     ```
   - The remaining steps will use this alias in place of the full Python command.

3. **Transfer ownership immediately**
   - Ensure the environment variables `PACKAGE_ID` and `OWNER_CAP_ID` are still set to the values recorded in the previous step.
   - Export the recipient of the ownership capability:
     ```bash
     export NEW_OWNER_ADDRESS=0xRECIPIENT
     ```
   - Make sure the CLI is using the original owner account before executing the PTB:
     ```bash
     sui client switch --address $OWNER_ADDRESS
     ```
     > You may need to set up this account and request gas tokens from the faucet if you haven't done so before.
   - Run a preview first, then the real transfer (as the current owner):
     ```bash
     run_ptb ptbs/01_transfer_ownership.ptb -- --preview
     run_ptb ptbs/01_transfer_ownership.ptb
     ```
   - Confirm the `OwnershipTransferred` event references the new owner by checking the given output.

4. **Send a gift from the new owner**
   - Reuse the exported `PACKAGE_ID` and `OWNER_CAP_ID` values gathered earlier.
   - Export the message text and gift recipient:
     ```bash
     export NOTE_TEXT="'Congrats from the new ownership'"
     export RECIPIENT_ADDRESS=0xGIFT_RECIPIENT
     ```
   - Switch the CLI to the new owner before sending the gift:
     ```bash
     sui client switch --address $NEW_OWNER_ADDRESS
     ```
   - Execute from the new owner account:
     ```bash
     run_ptb ptbs/02_send_gift.ptb -- --preview
     run_ptb ptbs/02_send_gift.ptb
     ```
   - Record the new gift object ID printed in the transaction results so you can inspect it in the final step.

5. **Verify results**
   - Check the capability and gift objects:
     ```bash
     sui client object $OWNER_CAP_ID
     sui client object 0x<NEW_GIFT_OBJECT_ID_FROM_OUTPUT>
     ```
