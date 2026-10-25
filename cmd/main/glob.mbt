// `--csv` glob expansion: the pattern matcher (`*`, and nothing else), the
// pattern stem that names a multi-file table, and the per-file stem used when a
// file is named explicitly.

///|
/// Expand one --csv glob pattern into sorted file paths. Only a single
/// `*` (matching any run within one directory level) is supported;
/// directories are skipped.
fn expand_glob(pattern : String) -> Array[String] raise {
  let mut slash = -1
  for i, ch in pattern {
    if ch == '/' {
      slash = i
    }
  }
  let dir = if slash >= 0 { pattern[:slash + 1].to_owned() } else { "" }
  let pat = pattern[slash + 1:].to_owned()
  let entries = @fs.read_dir(if dir == "" { "." } else { dir }) catch {
    _ => raise cli_fail("cannot read directory at \{dir}")
  }
  let hits : Array[String] = []
  for name in entries {
    if glob_match(pat, name) && @fs.is_file(dir + name) {
      hits.push(dir + name)
    }
  }
  hits.sort()
  hits
}

///|
/// Classic single-star glob match: `*` spans any run of characters,
/// everything else compares literally.
fn glob_match(pattern : String, name : String) -> Bool {
  let ps : Array[Char] = []
  for ch in pattern {
    ps.push(ch)
  }
  let ns : Array[Char] = []
  for ch in name {
    ns.push(ch)
  }
  let mut pi = 0
  let mut ni = 0
  let mut star = -1
  let mut mark = 0
  while ni < ns.length() {
    if pi < ps.length() && (ps[pi] == '*' || ps[pi] == ns[ni]) {
      if ps[pi] == '*' {
        star = pi
        mark = ni
        pi += 1
      } else {
        pi += 1
        ni += 1
      }
    } else if star >= 0 {
      pi = star + 1
      mark += 1
      ni = mark
    } else {
      return false
    }
  }
  while pi < ps.length() && ps[pi] == '*' {
    pi += 1
  }
  pi == ps.length()
}

///|
/// Table name for a multi-file glob pattern: the basename with `*`
/// removed ("parts/part-*.csv" scans into table "part-.csv"? no —
/// into "part-", keeping the suffix strip of table_stem).
fn pattern_stem(pattern : String) -> String {
  let mut start = 0
  for i, ch in pattern {
    if ch == '/' {
      start = i + 1
    }
  }
  let base = pattern[start:].to_owned()
  let mut stem = ""
  for ch in base {
    if ch != '*' {
      stem = stem + ch.to_string()
    }
  }
  for suffix in [".csv", ".parquet"] {
    if stem.has_suffix(suffix) {
      stem = stem[:stem.length() - suffix.length()].to_owned()
    }
  }
  // "part-*.csv" -> "part": the star leaves a separator behind that
  // would force quoting in every query
  let mut end = stem.length()
  while end > 0 {
    let last = stem[end - 1]
    if last == '-' || last == '_' || last == '.' {
      end -= 1
    } else {
      break
    }
  }
  stem[:end].to_owned()
}

///|
/// File stem: strip directories and a trailing ".csv" or ".parquet".
fn table_stem(path : String) -> String {
  let mut start = 0
  for i, ch in path {
    if ch == '/' {
      start = i + 1
    }
  }
  let base = path[start:].to_owned()
  for suffix in [".csv", ".parquet"] {
    if base.length() > suffix.length() && base.has_suffix(suffix) {
      return base[:base.length() - suffix.length()].to_owned()
    }
  }
  base
}

///|
test {
  assert_true(usage().contains("moonlake"))
  assert_eq(table_stem("lineitem.csv"), "lineitem")
  assert_eq(table_stem("/tmp/data/lineitem.csv"), "lineitem")
  assert_eq(table_stem("plain.tsv"), "plain.tsv")
  // single-star glob matching
  assert_true(glob_match("part-*.csv", "part-001.csv"))
  assert_true(glob_match("*.csv", "anything.csv"))
  assert_true(glob_match("a*b.csv", "aXxYb.csv"))
  assert_false(glob_match("part-*.csv", "part-001.tsv"))
  assert_false(glob_match("part-*.csv", "xpart-001.csv"))
  assert_false(glob_match("a*b.csv", "abcsv"))
  // pattern stem: star removed, suffix stripped, separator trimmed
  assert_eq(pattern_stem("parts/part-*.csv"), "part")
  // a bare "*.csv" keeps no name: build_groups rejects it rather than register
  // every file under table ""
  assert_eq(pattern_stem("*.csv"), "")
  assert_eq(pattern_stem("data-*.csv"), "data") // trailing separator trimmed
}
