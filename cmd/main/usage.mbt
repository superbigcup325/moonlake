// The three usage texts, kept apart from the commands so that editing the
// wording never touches control flow.

///|
fn write_usage() -> String {
  (
    #|write needs an input and an output: moonlake write --csv <file> --out <file.parquet> [options]
    #|
    #|  --csv <file>          register a CSV file (repeatable)
    #|  --parquet <file>      register a Parquet file (repeatable)
    #|  --date-col <c>        declare an unannotated Parquet INT32 column as DATE
    #|  --out <file>          where to write the Parquet file (required)
    #|  --table <name>        which registered table to write (default: the only one)
    #|  --snappy              compress pages with Snappy instead of storing them raw
  )
}

///|
fn exec_usage() -> String {
  (
    #|usage: moonlake exec (--csv <file> | --parquet <file> | --date-col <c>)+ <sql | --file <q.sql>>
    #|
    #|CSV: first row is the header, types inferred. Parquet: DATE columns
    #|are declared with --date-col (epoch-day int32). File stems become
    #|table names; pass one --csv/--parquet per joined table. A --csv
    #|argument may carry one `*`: the matches scan into one table
    #|named by the pattern. The SQL is
    #|one quoted argument, or a file with --file (handy to skip shell
    #|quoting; a trailing semicolon is fine).
    #|Examples:
    #|  moonlake exec --csv lineitem.csv \
    #|    "SELECT sum(x) AS s FROM lineitem WHERE x > 1"
    #|  moonlake exec --csv lineitem.csv --file q6.sql
  )
}

///|
fn usage() -> String {
  (
    #|moonlake - embeddable analytical query engine for MoonBit
    #|
    #|Usage: moonlake [options] [command]
    #|
    #|Commands:
    #|  exec (--csv <file> | --parquet <file> | --date-col <c])+ <sql>
    #|      Run a SELECT over CSV/Parquet files (one flag per table)
    #|  write (--csv <file> | --parquet <file> | --date-col <c])+ --out <file>
    #|      Write one registered table back out as Parquet
    #|      --table <name>   pick the table (default: the only one)
    #|      --snappy         compress pages with Snappy
    #|
    #|    exec options:
    #|      --date-col <c>        declare a Parquet column as DATE (epoch-day)
    #|      --explain             print the physical plan instead of running
    #|      --analyze             run it: plan plus actual rows per stage
    #|      --json                emit the result as one JSON array line
    #|      --memory <n>[K|M|G]   budget for the blocking ORDER BY; beyond
    #|                            it runs spill to disk (external sort)
    #|      --spill-dir <dir>     parent of this query's run files (default:
    #|                            TMPDIR); each query gets its own subdirectory
    #|
    #|Options:
    #|  --version   Print version and exit
    #|  --help      Print this help and exit
    #|
    #|The engine is under active development.
  )
}
