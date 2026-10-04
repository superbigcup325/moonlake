# Randomized differential fuzz: moonlake vs duckdb over randomly
# generated WHERE/ON predicate trees on multi-join schemas (INNER and
# LEFT). Pushdown, residual placement, OR-implied keys and NULL
# semantics are exercised by construction; duckdb is the referee.
#
# Usage: uv run --with duckdb python harness/fuzz_pushdown.py [N] [seed]
#
# The synthetic schema (generated once per seed, written to a temp dir):
#   a(id, k1, k2, v, s, d, f)   b(id, k1, w, s, d)   c(id, k2, u, s)
# with nullable join keys, strings, dates and floats. Join graph:
#   a.k1 = b.k1, b.k2 = c.k2 (b the hub), random INNER/LEFT per edge.

import pathlib
import random
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
BIN = REPO / "_build/native/debug/build/cmd/main/main.exe"

CMP_OPS = ["=", "<>", "<", "<=", ">", ">="]


def gen_data(rng: random.Random, out: pathlib.Path) -> None:
    n = {"a": 3000, "b": 2000, "c": 1500}
    for t, cnt in n.items():
        rows = ["id,k1,k2,v,w,u,s,d,f"]
        for i in range(cnt):
            k1 = rng.choice([str(rng.randint(0, 40)), ""]) if t in ("a", "b") else ""
            k2 = rng.choice([str(rng.randint(0, 40)), ""]) if t in ("a", "b", "c") else ""
            v = str(rng.randint(-100, 100)) if t == "a" else ""
            w = str(rng.randint(-50, 50)) if t in ("a", "b") else ""
            u = str(rng.randint(0, 30)) if t == "c" else ""
            s = rng.choice(["alpha", "beta", "gamma", "", "delta"]) if t != "c" else rng.choice(["alpha", "beta", ""])
            d = f"2024-{rng.randint(1, 12):02d}-{rng.randint(1, 28):02d}" if t == "a" else ""
            f = f"{rng.uniform(-10, 10):.4f}" if t == "a" else ""
            rows.append(",".join(x for x in [i and str(i) or "0", k1, k2, v, w, u, s, d, f]))
        (out / f"{t}.csv").write_text("\n".join(rows) + "\n")


def table_cols(t: str) -> list[str]:
    return {
        "a": ["a.k1", "a.k2", "a.v", "a.s", "a.d", "a.f"],
        "b": ["b.k1", "b.k2", "b.w", "b.s"],
        "c": ["c.k2", "c.u", "c.s"],
    }[t]


def gen_predicate(rng: random.Random, tables: list[str]) -> str:
    """One random conjunct referencing only the given tables."""
    t = rng.choice(tables)
    cols = table_cols(t)
    col = rng.choice(cols)
    kind = rng.random()
    is_str = col.endswith(".s")
    is_date = col.endswith(".d")
    is_float = col.endswith(".f")
    if kind < 0.45 and not (is_str or is_date):
        if is_float:
            return f"{col} {rng.choice(CMP_OPS)} {rng.uniform(-60, 60):.2f}"
        op = rng.choice(CMP_OPS)
        return f"{col} {op} {rng.randint(-60, 60)}"
    if kind < 0.55 and col.endswith(".s"):
        op = rng.choice(["=", "<>"])
        return f"{col} {op} '{rng.choice(['alpha', 'beta', 'gamma'])}'"
    if kind < 0.65 and not (is_str or is_date):
        vals = ", ".join(str(rng.randint(-40, 40)) for _ in range(rng.randint(2, 4)))
        return f"{col} IN ({vals})"
    if kind < 0.75 and not (is_str or is_date):
        return f"{col} BETWEEN {rng.randint(-50, 0)} AND {rng.randint(0, 50)}"
    if kind < 0.85:
        return f"{col} IS {'NOT ' if rng.random() < 0.5 else ''}NULL"
    if kind < 0.93 and col.endswith(".s"):
        return f"{col} LIKE '{rng.choice(['a%', '%a%', '%e', 'beta'])}'"
    if is_date:
        return f"{col} {rng.choice(['<', '>', '<=', '>='])} date '2024-{rng.randint(1, 12):02d}-15'"
    # spanning conjuncts across two present tables: WHERE-form
    # equalities are the discriminating shape for placement at LEFT
    # joins (as a hash key, NULL-extended rows escape them)
    if len(tables) >= 2 and rng.random() < 0.5:
        t2 = rng.choice([x for x in tables if x != t])
        kcols_t = [c for c in table_cols(t) if ".k" in c]
        kcols_t2 = [c for c in table_cols(t2) if ".k" in c]
        if kcols_t and kcols_t2 and rng.random() < 0.6:
            return f"{rng.choice(kcols_t)} = {rng.choice(kcols_t2)}"
        c1 = rng.choice([c for c in table_cols(t) if ".k" not in c and ".s" not in c and ".d" not in c])
        c2 = rng.choice([c for c in table_cols(t2) if ".k" not in c and ".s" not in c and ".d" not in c])
        if c1 and c2:
            return f"{c1} {rng.choice(['<', '>='])} {c2}"
    if is_str:
        return f"{col} {rng.choice(['=', '<>'])} '{rng.choice(['alpha', 'beta', 'gamma'])}'"
    if is_date:
        return f"{col} {rng.choice(['<', '>'])} date '2024-{rng.randint(1, 12):02d}-15'"
    op = rng.choice(CMP_OPS)
    return f"{col} {op} {rng.randint(-60, 60)}"


def gen_query(rng: random.Random) -> str:
    left_kind = rng.choice(["INNER", "LEFT"])
    right_kind = rng.choice(["INNER", "LEFT"])
    join_b = f"a {left_kind} JOIN b ON a.k1 = b.k1"
    join_c = f" {right_kind} JOIN c ON b.k2 = c.k2"
    tables = ["a", "b"] + (["c"] if right_kind == "INNER" or rng.random() < 0.7 else [])
    conjuncts = []
    for _ in range(rng.randint(2, 5)):
        conjuncts.append(gen_predicate(rng, tables))
    # sometimes an OR with an implied join key (the Q19 shape)
    if rng.random() < 0.25:
        side = rng.choice(["a.v", "b.w"])
        th1, th2 = rng.randint(-30, 30), rng.randint(-30, 30)
        conjuncts.append(
            f"(({side} > {th1} AND a.k1 = b.k1 AND a.k1 < 20) OR ({side} < {th2} AND a.k1 = b.k1))"
        )
    where = " AND ".join(c for c in conjuncts if c)
    proj = rng.choice(["count(*)", "sum(a.v)", "sum(b.w)", "max(a.f)", "count(DISTINCT a.s)"])
    return f"SELECT {proj} AS out FROM {join_b}{join_c} WHERE {where}"


def run_engine(binary: pathlib.Path, data: pathlib.Path, sql: str) -> tuple[int, str]:
    cmd = [str(binary), "exec"]
    for t in ["a", "b", "c"]:
        cmd += ["--csv", str(data / f"{t}.csv")]
    cmd.append(sql)
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    return proc.returncode, (proc.stdout.strip() or proc.stderr.strip())


def run_duckdb(data: pathlib.Path, sql: str) -> str:
    import duckdb

    con = duckdb.connect()
    for t in ["a", "b", "c"]:
        con.execute(
            f"CREATE TABLE {t} AS SELECT * FROM read_csv_auto('{data / (t + '.csv')}', NULLSTR='')"
        )
    cur = con.execute(sql)
    rows = cur.fetchall()
    if not rows:
        return "empty"
    return repr(rows[0][0])


def main() -> int:
    total = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 20261005
    rng = random.Random(seed)
    data = pathlib.Path(tempfile.mkdtemp(prefix="fuzz_pd_"))
    gen_data(rng, data)
    failures = 0
    errors = 0
    for i in range(total):
        sql = gen_query(rng)
        code, out = run_engine(BIN, data, sql)
        want = run_duckdb(data, sql)
        if code != 0:
            # a clean bind/parse rejection is recorded, not a wrong answer
            if "sql error" in out:
                errors += 1
                print(f"[{i}] ENGINE ERROR: {out[:120]}\n  {sql}")
                failures += 1
                continue
            print(f"[{i}] CRASH: {out[:200]}\n  {sql}")
            failures += 1
            continue
        got = out.splitlines()[-1] if out else ""
        # numeric cells compare with the harness 1e-9 tolerance; here the
        # aggregates are integers or float sums — compare loosely then tight
        if not cells_match(got, want):
            failures += 1
            print(f"[{i}] MISMATCH moonlake={got!r} duckdb={want!r}\n  {sql}")
    print(f"done: {total} queries, {failures} failures, {errors} engine rejections")
    return 1 if failures else 0


def cells_match(got: str, want: str) -> bool:
    # moonlake prints SQL NULL as "null"; duckdb comes back as None
    if got in ("", "null") and want in ("None", ""):
        return True
    if got == want:
        return True
    try:
        g, w = float(got), float(want)
    except ValueError:
        return False
    if g != g and w != w:  # both NaN
        return True
    denom = max(abs(w), 1e-300)
    return abs(g - w) / denom <= 1e-9


if __name__ == "__main__":
    sys.exit(main())
