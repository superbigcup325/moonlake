#!/usr/bin/env node
// Playground file-upload acceptance: drives the real page in headless
// Chromium and reports one PASS/FAIL line per scenario.
//
// Dev-only (not part of the package). Playwright is not a project dependency;
// point PLAYWRIGHT_MODULE at an install, or have it resolvable by require.
//
//   moon build --target wasm-gc playground
//   mkdir -p /tmp/site && cp playground/index.html /tmp/site/ \
//     && cp _build/wasm-gc/debug/build/playground/playground.wasm /tmp/site/
//   python3 -m http.server 8971 --directory /tmp/site &
//   node harness/playground_accept.cjs http://127.0.0.1:8971/index.html
//
// The suite uploads the SF0.01 fixtures (harness/gen_tpch.py) and covers:
//   - CSV upload and a grouped aggregate
//   - Parquet upload with DATE columns (--datecols) and DATE rendering
//   - two error paths: unknown column / syntax error
//   - a cross-file JOIN (one table per upload, so it must be refused by name)
//   - a same-file self-join (the engine does support joins)
//   - one uncaught-JS-error check across the whole run
//
// Environment:
//   PLAYWRIGHT_MODULE=/path/to/node_modules/playwright
//   CHROME_PATH=/path/to/chrome      (default: a cached playwright chromium)
//   MOONLAKE_DATA=/path/to/sf001     (default: harness/data/sf001)

const path = require("path");
const fs = require("fs");

function loadPlaywright() {
  const tried = [];
  const candidates = [
    process.env.PLAYWRIGHT_MODULE,
    "playwright",
    path.join(process.env.HOME || "", ".cache", "playwright-node", "playwright"),
  ].filter(Boolean);
  for (const c of candidates) {
    tried.push(c);
    try {
      return require(c);
    } catch (_) {
      /* next */
    }
  }
  throw new Error(`playwright not found; tried:\n  ${tried.join("\n  ")}`);
}

const chromium = loadPlaywright().chromium;
const chromeCandidates = [
  process.env.CHROME_PATH,
  path.join(process.env.HOME || "", ".cache", "ms-playwright", "chromium-1243", "chrome-linux64", "chrome"),
  path.join(process.env.HOME || "", ".cache", "ms-playwright", "chromium-1234", "chrome-linux64", "chrome"),
].filter(Boolean);
const chrome = chromeCandidates.find((p) => fs.existsSync(p));

let url = process.argv[2] && !process.argv[2].startsWith("--")
  ? process.argv[2]
  : "http://127.0.0.1:8971/index.html";
const root = path.resolve(__dirname, "..");
const data = process.env.MOONLAKE_DATA
  ? path.resolve(process.env.MOONLAKE_DATA)
  : path.join(root, "harness", "data", "sf001");

let page;
const results = [];
const pageErrors = [];

function check(name, ok, detail) {
  results.push({ name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? ` — ${detail}` : ""}`);
}

async function waitReady() {
  await page.waitForFunction(
    () => document.querySelector("#status").textContent.startsWith("engine "),
    null,
    { timeout: 30000 },
  );
  return (await page.textContent("#status")).trim();
}

async function loadFile(file, datecols) {
  const name = path.basename(file);
  if (datecols !== undefined) await page.fill("#datecols", datecols);
  const before = await page.textContent("#loaded");
  await page.setInputFiles("#file", file);
  // the parquet path reads asynchronously: wait for *this* file's name, not
  // just for the Run button (which the previous file already enabled)
  await page.waitForFunction(
    ([want, prev]) => {
      const loaded = document.querySelector("#loaded").textContent;
      return !document.querySelector("#run").disabled && loaded.includes(want) && loaded !== prev;
    },
    [name, before],
    { timeout: 120000 },
  );
  return (await page.textContent("#loaded")).trim();
}

async function runSql(sql) {
  await page.fill("#sql", sql);
  await page.click("#run");
  // The handler runs synchronously: once click() resolves, status/err/out are
  // final. (Polling for a status *change* is not enough — two consecutive
  // failing queries both end on "failed".)
  await page.waitForTimeout(50);
  const status = (await page.textContent("#status")).trim();
  const err = (await page.textContent("#err")).trim();
  const rows = await page.$$eval("#out table tbody tr", (trs) =>
    trs.map((tr) => [...tr.children].map((td) => td.textContent)),
  );
  return { status, err, rows };
}

function defaultQuery() {
  return [
    "SELECT l_returnflag, count(*) AS n, sum(l_extendedprice) AS total",
    "FROM lineitem",
    "WHERE l_shipdate <= date '1998-09-02'",
    "GROUP BY l_returnflag",
    "ORDER BY l_returnflag",
  ].join("\n");
}

async function main() {
  const browser = await chromium.launch({
    executablePath: chrome,
    args: ["--no-sandbox", "--disable-dev-shm-usage"],
  });
  page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  page.on("pageerror", (e) => pageErrors.push(`pageerror: ${e.message}`));
  page.on("console", (m) => {
    if (m.type() === "error") pageErrors.push(`console.error: ${m.text()}`);
  });

  console.log(`url   ${url}`);
  await page.goto(url, { waitUntil: "load" });
  const engine = await waitReady();
  console.log(`engine  ${engine}`);
  check("wasm loads and reports an engine version", /^engine \d+\.\d+\.\d+ loaded/.test(engine), engine);

  // 1. CSV upload
  const csvName = await loadFile(path.join(data, "lineitem.csv"));
  check("CSV upload is accepted and enables Run", /lineitem\.csv/.test(csvName), csvName);
  const csv = await runSql(defaultQuery());
  const csvFlags = csv.rows.map((r) => r[0]);
  check(
    "CSV: default aggregate returns 3 groups (A,N,R)",
    csv.rows.length === 3 && csvFlags.join(",") === "A,N,R" && /3 rows in/.test(csv.status),
    `${csv.status}; groups ${csvFlags.join(",")}`,
  );

  // 2. Parquet with DATE columns
  const pqName = await loadFile(
    path.join(data, "lineitem.parquet"),
    "l_shipdate,l_commitdate,l_receiptdate",
  );
  check("Parquet upload is accepted and enables Run", /lineitem\.parquet/.test(pqName), pqName);
  const pq = await runSql(defaultQuery());
  check(
    "Parquet DATE: default date-filtered aggregate returns 3 groups",
    pq.rows.length === 3 && pq.rows.map((r) => r[0]).join(",") === "A,N,R",
    `${pq.status}; groups ${pq.rows.map((r) => r[0]).join(",")}`,
  );
  check(
    "CSV and Parquet agree cell-for-cell on the same query",
    JSON.stringify(csv.rows) === JSON.stringify(pq.rows),
    JSON.stringify(pq.rows).slice(0, 160),
  );
  const dates = await runSql("SELECT min(l_shipdate) AS lo, max(l_shipdate) AS hi FROM lineitem");
  const lo = dates.rows[0] && dates.rows[0][0];
  const hi = dates.rows[0] && dates.rows[0][1];
  check(
    "Parquet DATE: min/max render as calendar dates, not epoch ints",
    /^\d{4}-\d{2}-\d{2}$/.test(lo || "") && /^\d{4}-\d{2}-\d{2}$/.test(hi || ""),
    `lo=${lo} hi=${hi}`,
  );

  // 3. Broken SQL
  const bad = await runSql("SELECT nonexistent_column FROM lineitem");
  check(
    "error SQL: message surfaces, status failed, no table",
    bad.err.length > 0 && bad.status === "failed" && bad.rows.length === 0,
    `${bad.status}; err=${bad.err.slice(0, 120)}`,
  );
  const syntax = await runSql("SELECT FROM WHERE");
  check("error SQL: syntax error surfaces", syntax.err.length > 0 && syntax.status === "failed", syntax.err.slice(0, 120));

  // 4. Cross-file JOIN (the page holds one table, so this must fail loudly)
  const join = await runSql(
    "SELECT count(*) FROM lineitem l JOIN orders o ON l.l_orderkey = o.o_orderkey",
  );
  check(
    "cross-file JOIN: refused with a pointed error naming the missing table",
    join.status === "failed" && /orders/.test(join.err) && join.rows.length === 0,
    `${join.status}; err=${join.err.slice(0, 200)}`,
  );

  // 5. Same-file self-join still works (the engine is not the limit)
  const selfJoin = await runSql(
    "SELECT count(*) AS n FROM lineitem a JOIN lineitem b ON a.l_orderkey = b.l_orderkey WHERE a.l_linenumber = 1 AND b.l_linenumber = 2",
  );
  check(
    "same-file JOIN executes (engine supports joins over the uploaded table)",
    /rows in/.test(selfJoin.status) && selfJoin.err === "",
    `${selfJoin.status}; n=${selfJoin.rows[0] && selfJoin.rows[0][0]}`,
  );

  // 6. CSV after Parquet, to prove the two paths do not poison each other
  await loadFile(path.join(data, "lineitem.csv"));
  const again = await runSql("SELECT count(*) AS n FROM lineitem");
  check(
    "CSV reload after Parquet still scans",
    again.err === "" && again.rows.length === 1,
    `${again.status}; n=${again.rows[0] && again.rows[0][0]}`,
  );

  check("no uncaught JS errors on the page", pageErrors.length === 0, pageErrors.join(" | "));

  const shotIdx = process.argv.indexOf("--shot");
  if (shotIdx > 0 && process.argv[shotIdx + 1]) {
    fs.mkdirSync(process.argv[shotIdx + 1], { recursive: true });
    await page.screenshot({ path: path.join(process.argv[shotIdx + 1], "playground-accept.png"), fullPage: true });
    console.log(`shot  ${path.join(process.argv[shotIdx + 1], "playground-accept.png")}`);
  }

  await browser.close();
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  process.exit(failed.length ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(2);
});
