# OpenZeppelin Contracts for Sui

[![Lint and Test](https://github.com/OpenZeppelin/contracts-sui/actions/workflows/test.yml/badge.svg)](https://github.com/OpenZeppelin/contracts-sui/actions/workflows/test.yml)
[![Coverage Status](https://codecov.io/gh/OpenZeppelin/contracts-sui/graph/badge.svg)](https://codecov.io/gh/OpenZeppelin/contracts-sui)
[![License](https://img.shields.io/github/license/OpenZeppelin/contracts-sui)](https://github.com/OpenZeppelin/contracts-sui/blob/main/LICENSE)

> [!Warning]
> This is experimental software and is provided on an "as is" and "as available"
> basis. We do not give any warranties and will not be liable for any losses
> incurred through any use of this code base.

**OpenZeppelin Contracts for Sui** is a collection of secure smart contract
libraries written in Move for the [Sui blockchain](https://sui.io/). Our goal
is to bring Web3 standards under the OpenZeppelin quality by providing a set of
high-quality, battle-tested contracts that can be used to build decentralized
applications on the Sui network.

## Usage

Sui smart contracts are written in Move leveraging the Sui Move framework.

### Install Sui:

Follow the installation guide in the [Sui documentation](https://docs.sui.io/guides/developer/getting-started/sui-install).

**Required version**: Sui CLI [1.59.1](https://github.com/MystenLabs/sui/releases/tag/mainnet-v1.59.1).

## Docs

Documentation is available inline in the source code. You can generate the
documentation locally using:

```bash
# Generate and view documentation for a specific package
sui move build --doc --path <module>
```

## Notes

We strive to maintain consistency with other OpenZeppelin libraries as much as
possible, following the same conventions and patterns. However, this Sui library
does not have a 1-to-1 mapping with other OpenZeppelin contracts. Due to
differences in the Sui architecture and Move language capabilities, certain
features and implementations may differ from their counterparts in other
ecosystems.

## Security

> [!Warning]
> This library has not been audited yet. Use at your own risk.

For security concerns, please refer to our [Security Policy](./SECURITY.md).

Smart contracts are an evolving technology and carry a high level of technical
risk and uncertainty. Although OpenZeppelin is well known for its security
audits, using OpenZeppelin Contracts for Sui is not a substitute for a security
audit.

## Contribute

We welcome contributions from the community!

If you are looking for a good place to start, find a good first issue
[here](https://github.com/OpenZeppelin/contracts-sui/issues?q=is%3Aissue%20state%3Aopen%20label%3A%22good%20first%20issue%22).

You can open an issue for a
[bug report](https://github.com/OpenZeppelin/contracts-sui/issues/new?template=bug_report.yml),
or [feature request](https://github.com/OpenZeppelin/contracts-sui/issues/new?template=feature_request.yml).

You can find more details in our [Contributing](./CONTRIBUTING.md) guide, and
please read our [Code of Conduct](./CODE_OF_CONDUCT.md).

## License

OpenZeppelin Contracts for Sui is released under the [MIT License](./LICENSE).
