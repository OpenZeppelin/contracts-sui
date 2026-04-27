# Math

Math primitives for Sui DeFi, implemented as pure functions (no on-chain storage).

## Packages

| Name | Path | Highlights |
|------|------|------------|
| `openzeppelin_math` | [`core/`](core/) | Overflow-safe unsigned integer arithmetic with configurable rounding. |
| `openzeppelin_fp_math` | [`fixed_point/`](fixed_point/) | Fixed-point decimal types (`UD30x9`, `SD29x9`) with 9 decimals; arithmetic and comparison ops, plus bitwise helpers on `UD30x9`. |
