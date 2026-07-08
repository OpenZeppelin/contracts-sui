# Math

Math primitives for Sui DeFi, implemented as pure functions (no on-chain storage).

**AI agents:** [`llms.txt`](https://raw.githubusercontent.com/OpenZeppelin/contracts-sui/main/llms.txt) is the discovery entry point for integrating this library into a downstream project.

## Packages

| Package | MVR | Move package | Docs | Highlights |
|---------|----------|--------------|------|-----------|
| [`core/`](core/) | [`@openzeppelin-move/integer-math`](https://www.moveregistry.com/package/@openzeppelin-move/integer-math) | `openzeppelin_math` | [docs](https://docs.openzeppelin.com/contracts-sui/1.x/math) | Overflow-safe unsigned integer arithmetic with configurable rounding, decimal scaling, and vector utilities. See [`core/examples/`](core/examples) for integration examples. |
| [`fixed_point/`](fixed_point/) | [`@openzeppelin-move/fixed-point-math`](https://www.moveregistry.com/package/@openzeppelin-move/fixed-point-math) | `openzeppelin_fp_math` | [docs](https://docs.openzeppelin.com/contracts-sui/1.x/fixed-point) | Fixed-point decimal types (`UD30x9`, `SD29x9`) with 9 decimals: arithmetic, rounding, comparison, conversions/casts, logarithms, and standard-normal Gaussian functions; plus bitwise helpers on `UD30x9`. See [`fixed_point/examples/`](fixed_point/examples) for integration examples. |
