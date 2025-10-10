## Access Examples

This directory collects runnable snippets that demonstrate how to use OpenZeppelin access
control primitives on Sui packages.

> **Note**: These examples are for demonstration purposes only and not intended for production use. They showcase basic patterns
> but may lack important security considerations and optimizations needed in a production environment.

### Ownable

- [Gift Box V1](ownable/sources/gift_box_v1.move): immediate-transfer owner capability initialized by the package deployer.
- [Gift Box V2](ownable/sources/gift_box_v2.move): two-step ownership handoff requiring a request before transfer.
