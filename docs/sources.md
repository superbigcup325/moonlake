# CSV and Parquet

What the two data sources accept, how values are read, and what each target's
filesystem can do. The Parquet work is in-house (`sources/parquet`), scoped on
purpose rather than "whatever the files in the wild use".

## Registering tables

A table is a lazily scanned source: the schema is available at once and a query
decodes only the columns it projects, in 2048-row batches.

## CSV

Column types are inferred: int32 → int64 → float64 for integers that outgrow
their type, bool — `true`/`false` in any letter case, so a pandas export's
`True`/`False` is a bool and not a string —, date, string.

- out-of-range values widen, never wrap
- a ragged row is refused by row number (a short row would otherwise read its
  neighbour's cells)
- a repeated header name is renamed the way DuckDB's `read_csv` does (`a`,
  `a_1`, …) so both columns stay reachable
- the `NaN` / `inf` / `-Infinity` spellings read as float64 instead of turning
  the column into strings

### Ranged scans

Registration reads a 64 KB prefix (header plus the inference sample) and a scan
reads one 4 MB range at a time, indexing, materializing and dropping each range,
so the per-cell offset table is one range rather than the file. `count(*)` over a
302 MB CSV: 1063 MB → 35 MB of peak RSS, 1.36 s → 0.64 s, and `write --csv` on
the same input 1063 MB → 35 MB with byte-identical output.

## Parquet reading

Scope: flat schemas, v1 data pages, PLAIN, dictionary, the DELTA family and
BYTE_STREAM_SPLIT page encodings (the last five through colenc), RLE boolean
values, `UNCOMPRESSED` and `SNAPPY`.

Refused with a pointed error rather than guessed at: nested fields, INT96
timestamps, v2 pages, DECIMAL, UINT_32/UINT_64 and the other codecs. A decimal
byte array read as text, or a UINT taken as signed, would be a wrong answer
rather than a refusal.

On native targets a scan reads the 8-byte trailer and the footer, then one
column chunk per projected column per row group, so peak memory is a couple of
row groups' columns rather than the file: `count(*)` over a 287 MB archive,
295 MB → 12 MB of peak RSS. `scan_bytes` and the wasm-gc/js builds keep their
whole-input behaviour behind the same signatures.

## Parquet writing

The scope is the reader's, and the writer speaks the format rather than merely
the encoding: `write_bytes` / `write_file` emit one row group per batch with v1
pages, PLAIN values, `STRING`/`DATE` annotations, and per-column-chunk
statistics (`min_value`/`max_value`/`null_count`), so moonlake's own output is
prunable by its own reader. `--snappy` (library: `write_bytes_with`) stores pages
compressed, and `moonlake write --csv in.csv --out out.parquet` is the CLI path
(its argument and failure behaviour are in [cli.md](cli.md)).

Every column is written OPTIONAL with RLE definition levels (about one bit per
value on disk, and what pyarrow does by default): that is what lets the input
stream through one batch at a time instead of being materialized, since a
REQUIRED schema would have to be decided before the first page is written.

On native targets the file path streams: pages go straight to a file handle and
a temporary name is renamed over the target, so peak memory no longer grows with
the output (326 MB → 101 MB writing a 75 MB file from Parquet input) and a failed
write leaves the previous file intact. wasm-gc/js keep the whole-file write their
hosts require, behind the same `write_file_with` signature.

`harness/check_writer_interop.py` reads the result with pyarrow and DuckDB and
reads a DuckDB-written file back.

## The wasm-gc/js limit

wasm-gc/js scans read whole files, because their filesystem module has no ranged
read (native scans read byte ranges, and the writer streams on native).
[ROADMAP.md](ROADMAP.md) says what closing that would take, and lists the rest of
the directions that are on hold with the evidence each one waits for.
