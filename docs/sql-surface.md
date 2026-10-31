# SQL surface

What the engine accepts, what each form means, and what it refuses. Semantics
follow DuckDB and PostgreSQL where the three engines could differ, and the
differences are stated rather than left to be discovered.

## Statements

- `SELECT` (including `*`) / `FROM` (multi-table) / `WHERE` / `GROUP BY` /
  `HAVING` / `ORDER BY` / `LIMIT`
- `INNER` / `LEFT` / `RIGHT` / `FULL` / `CROSS` joins, `UNION [ALL]` /
  `INTERSECT` / `EXCEPT` (INTERSECT binds tighter; ALL keeps multisets) — hash
  join, join order chosen greedily by connectivity, LEFT keeps written order
- `GROUP BY 1` ordinals resolve to select items
- `WITH name AS (SELECT ...)` — non-recursive CTEs, statement level; a name is
  its own qualifier, later CTEs may reference earlier ones
- derived tables (`FROM (SELECT ...) AS t`), with optional column alias lists
  (`AS t (a, b)`)

## Expressions

- arithmetic, comparison, `CASE WHEN`, `IN`, `NOT IN`, `BETWEEN`,
  `NOT BETWEEN`, `LIKE`, `NOT LIKE`, `IS [NOT] NULL`, `NULL` as a
  comparison/arithmetic operand, `EXTRACT(year/month/day)`, `DATE` literals,
  `date +/- INTERVAL n day/month/year` (calendar-aware, day-of-month clamping),
  `CAST`, string functions (`substring` — both argument styles, `length`,
  `upper`, `lower`, variadic `concat`), `abs`, `round`, three-valued NULL logic
  throughout
- `round` and `cast(<double> AS int/int64)` round half away from zero, as DuckDB
  and PostgreSQL do (`round(-2.5)` is -3, `cast(2.5 AS int)` is 3; C, SQLite and
  MySQL truncate instead), and a float → integer cast that does not fit raises
  instead of saturating
- `concat(a, b, ...)` takes one or more arguments, casts the non-string ones,
  and skips NULL arguments (`concat('a', NULL, 'b')` is `'ab'`), while the `||`
  operator takes two strings and propagates NULL
- division is DuckDB-style: `/` is always DOUBLE (`x/0` is ±inf, `0/0` is nan)
  and `%` follows fmod (`x % 0` is NULL)
- integer literals widen int32 → int64 → float64 to stay exact; int32/int64
  `+`/`-`/`*` raise on overflow rather than wrap (the same refusal `sum()`
  makes), since a wrapped value is a wrong number a query never asked for
- identifiers: the DATE-part keywords `year`/`month`/`day`/`date` double as bare
  column/table/alias names; double-quoted identifiers (`"left"`, with `""`
  escape) reach every other reserved word

## Aggregates

- `sum` / `avg` / `min` / `max` / `count` / `count(*)` / `count(DISTINCT)` /
  `stddev` (+samp/pop) / `variance` (+samp/pop) / `median` / `string_agg`
  (literal separator); aggregates over int64 that overflow raise instead of
  wrapping
- approximate aggregates, both explicit and never substituted for the exact
  form: `approx_count_distinct(expr)` estimates the distinct non-NULL count with
  a HyperLogLog at precision 14 (about 0.81% standard error, 16 KiB of register
  payload per dense sketch, plus object overhead) and `approx_quantile(expr, q)`
  estimates a quantile with a t-digest at compression 100 (`q` a constant in
  [0, 1], checked at bind time; NaN and infinity input is a SQL error).
  [sketches.md](sketches.md) records the types, NULL and value-equivalence
  rules, and the measured state cost

## Window functions

In the select list: `row_number()`, `rank()`, `dense_rank()` and every aggregate
as `agg(expr) OVER (PARTITION BY ... ORDER BY ...)` (NULLS FIRST/LAST per key).
Aggregates use the standard default frame — RANGE UNBOUNDED PRECEDING TO CURRENT
ROW (a running aggregate whose peers share the value); without ORDER BY the frame
is the whole partition.

Refused with pointed errors: explicit frame clauses (`ROWS`/`RANGE` BETWEEN ...),
window functions in WHERE/ORDER BY/HAVING/GROUP BY (order by the output alias
instead), and windows inside correlated subqueries.

## Subqueries

Correlated `EXISTS` / `NOT EXISTS` / `IN` / `NOT IN` and correlated scalar
aggregate subqueries, anywhere an expression may appear — a WHERE conjunct, a
select item, inside `AND` / `OR` / `NOT` / `CASE` — nested to the depth TPC-H
asks.

The correlation is general, not just equality: an `inner.col = outer.col` pair is
still joined by hash key, a purely inner conjunct stays in the inner filter, and
everything else (`<`, `>`, `<>`, `BETWEEN`, an `OR`, a conjunct on the outer
columns alone) becomes a keyless semi/anti join for `EXISTS` / `IN`, or — for a
scalar subquery and for `EXISTS` / `IN` used as a value — a theta aggregate
computed once per distinct combination of the outer values it reads and joined
back on a row key, so a repeated outer row cannot multiply the inner matches.

A `GROUP BY` inside the EXISTS is dropped (it cannot change whether a matching
row exists) and a `HAVING` is kept when the grouping is the correlation keys
themselves, refused with its reason when it is the user's own grouping; `IN` /
`NOT IN` keep SQL's three-valued logic as values too (`NULL` probe or a `NULL` in
the set yields `NULL`).

What is still refused, each with a pointer to rewrite it as a join:

- a derived table in the subquery's FROM
- `DISTINCT` / `LIMIT` / `OFFSET` / a set operation inside it
- a grouping or `HAVING` that is not the correlation keys
- a correlated subquery in a position the rewriter does not reach — the select
  list of a `GROUP BY` query (its value would have to appear in the `GROUP BY`),
  a `HAVING` clause, or a `JOIN ON` clause
- a reference to a table two levels out, refused by the binder
  (`unknown table or alias <name> in FROM`): it has no named message yet

## Scalar functions

`coalesce` / `nullif` / `greatest` / `least`, `date_trunc(unit, date)`,
`date_diff(unit, start, end)`. `SELECT` works without FROM and a bare `NULL`
select item reads as INTEGER.

## Pushdown

Single-table predicates from WHERE/ON are applied as build/probe filters at each
hash join; equalities become hash keys even when implied by disjunctions. At
joins that preserve a side (`LEFT`/`RIGHT`/`FULL`), WHERE predicates — spanning
ones included — stay post-join so NULL-extended rows still meet them.

## Out of scope

Writes (`INSERT`/`UPDATE`/`CREATE TABLE`/DDL beyond CTEs), persistence,
transactions, indexes, explicit window frame clauses (the default frame is
supported), cost-based optimization, multi-statement scripts.

Larger-than-memory execution (`--memory`, spill) is in [cli.md](cli.md).
