// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "superbigcup325/moonlake"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/superbigcup325/moonlake"

license = "Apache-2.0"

keywords = [ "sql", "olap", "query-engine", "csv", "parquet", "columnar" ]

description = "Embeddable analytical query engine for MoonBit: run SQL over CSV/Parquet files, native and WebAssembly from one codebase."

import {
  "moonbit-community/sqlparser@0.5.1",
  "moonbit-community/NyaCSV@0.3.3",
}
