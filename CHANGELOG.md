# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- MoonBit module skeleton (`superbigcup325/moonlake`): library package and CLI entry point (`cmd/main`)
- CLI `--version` / `--help` output
- Engine facade with version metadata and blackbox tests
- GitHub Actions CI: format check, `moon check`, tests across native / wasm-gc / js targets
- Apache-2.0 license
- W1: `types` (columnar vectors, scalars with three-valued NULL logic, epoch-day dates), `catalog`, CSV scan with type inference, engine subset parser/binder/executor, CLI `exec --csv`, TPC-H cross-validation harness (duckdb goldens, Q6 end to end)
- W2: GROUP BY hash aggregation with the v1 aggregate set (sum / avg / count / count(*) / count(distinct) / min / max), HAVING, ORDER BY (NULLS LAST) and LIMIT
- W2: CASE WHEN, LIKE and IN expressions; TRUE/FALSE literals
- W2: multi-table FROM with hash joins — comma lists, `JOIN ... ON`, `LEFT [OUTER] JOIN`, `CROSS JOIN`; WHERE/ON conjunct classification into build/probe filters, hash keys and per-pair residuals
- W2: Parquet scan adapter (`sources/parquet`) over mizchi/parquet with declared DATE columns; CLI `--parquet` / `--date-col`
- W2: TPC-H goldens for Q1 / Q3 / Q14 plus the parquet chain (q6p), `harness/check_all.sh`, and a CI job regenerating data + goldens via duckdb and cross-validating every query
