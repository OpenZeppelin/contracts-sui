# Math

Math primitives for Sui DeFi, implemented as pure functions (no on-chain storage).

## Packages

| Package | MVR slug | Move package | Docs | Highlights |
|---------|----------|--------------|------|-----------|
| [`core/`](core/) | [`@openzeppelin-move/integer-math`](https://www.moveregistry.com/package/@openzeppelin-move/integer-math) | `openzeppelin_math` | [docs](https://docs.openzeppelin.com/contracts-sui/1.x/math) | Overflow-safe unsigned integer arithmetic with configurable rounding. |
| [`fixed_point/`](fixed_point/) | [`@openzeppelin-move/fixed-point-math`](https://www.moveregistry.com/package/@openzeppelin-move/fixed-point-math) | `openzeppelin_fp_math` | [docs](https://docs.openzeppelin.com/contracts-sui/1.x/fixed-point) | Fixed-point decimal types (`UD30x9`, `SD29x9`) with 9 decimals; arithmetic and comparison ops, plus bitwise helpers on `UD30x9`. |
