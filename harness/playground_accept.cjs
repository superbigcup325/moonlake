#!/usr/bin/env node
// Playground acceptance: drives the real page in headless Chromium and reports
// one PASS/FAIL line per scenario.
//
// Dev-only (not part of the package). Playwright is not a project dependency;
// point PLAYWRIGHT_MODULE at an install, or have it resolvable by require.
// CI installs it in the `playground` job.
//
//   moon build --target wasm-gc playground
//   mkdir -p /tmp/site && cp playground/index.html /tmp/site/ \
//     && cp _build/wasm-gc/debug/build/playground/playground.wasm /tmp/site/
//   python3 -m http.server 8971 --directory /tmp/site &
//   node harness/playground_accept.cjs http://127.0.0.1:8971/index.html
//
// What it covers: the session model (several files registered at once, listed
// with their schema, dropped again), a cross-file JOIN that now actually runs,
// the plan panel, CSV and Parquet agreeing cell for cell, two error paths, and
// one uncaught-JS-error check across the whole run.
//
// Environment:
//   PLAYWRIGHT_MODULE=/path/to/node_modules/playwright
//   CHROME_PATH=/path/to/chrome      (default: a cached playwright chromium)
//   MOONLAKE_DATA=/path/to/sf001     (default: harness/data/sf001)
//   MOONLAKE_EXPECT_VERSION=0.4.0 (default: version in this checkout's moon.mod)

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
const manifestVersion = fs.readFileSync(path.join(root, "moon.mod"), "utf8")
  .match(/^version\s*=\s*"([^"]+)"/m);
if (!manifestVersion) throw new Error("moon.mod has no version to verify");
const expectedVersion = process.env.MOONLAKE_EXPECT_VERSION || manifestVersion[1];
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

async function waitForEngine() {
  await page.waitForFunction(
    () => /^\d+\.\d+\.\d+/.test(document.body.dataset.engine || ""),
    null,
    { timeout: 60000 },
  );
}

async function waitForStatus(prefix) {
  await page.waitForFunction(
    (p) => document.querySelector("#status").textContent.startsWith(p),
    prefix,
    { timeout: 60000 },
  );
}

async function statusText() {
  return page.textContent("#status");
}

// Upload one or more files through the real <input type=file multiple>.
async function upload(files) {
  await page.setInputFiles("#file", files);
  await page.waitForTimeout(300); // the handler is async
}

function csvFile(name, body) {
  return { name, mimeType: "text/csv", buffer: Buffer.from(body, "utf8") };
}

async function runSQL(sql) {
  await page.fill("#sql", sql);
  await page.click("#run");
  await page.waitForTimeout(30);
}

async function rowTexts() {
  return page.$$eval("#out table tbody tr", (rows) =>
    rows.map((r) => [...r.querySelectorAll("td")].map((c) => c.textContent)),
  );
}

async function tableNames() {
  return page.$$eval("#tables .t", (rows) => rows.map((r) => r.dataset.table));
}

(async () => {
  const browser = await chromium.launch(chrome ? { executablePath: chrome } : {});
  const ctx = await browser.newContext();
  page = await ctx.newPage();
  page.on("pageerror", (e) => pageErrors.push(`pageerror: ${e.message}`));
  page.on("console", (m) => {
    if (m.type() === "error") pageErrors.push(`console.error: ${m.text()}`);
  });

  await page.goto(url, { waitUntil: "load" });

  // 1. the wasm loads and reports its version
  await waitForEngine();
  const version = await page.evaluate(() => document.body.dataset.engine);
  check("wasm loads and reports the expected engine version", version === expectedVersion,
    `${version} (expected ${expectedVersion})`);

  // 2. two CSV files uploaded at once become two tables with their schema
  await upload([
    csvFile("t1.csv", "id,k\n1,10\n2,10\n3,20\n"),
    csvFile("t2.csv", "id,k\n1,10\n2,20\n4,30\n"),
  ]);
  let tables = await tableNames();
  check("two files register as two tables", tables.join(",") === "t1,t2", tables.join(","));
  const schema = await page.textContent('#tables .t[data-table="t1"] .cols');
  check("the table list shows the schema", schema.includes("id:int32") && schema.includes("k:int32"), schema);

  // 3. a cross-file JOIN now runs (this used to be refused by design)
  await runSQL("SELECT count(*) AS n FROM t1 JOIN t2 ON t1.k = t2.k");
  let rows = await rowTexts();
  // t1.k = 10,10,20 against t2.k = 10,20,30: three matching pairs
  check("a cross-file JOIN runs", rows.length === 1 && rows[0][0] === "3", JSON.stringify(rows));

  // 4. the plan panel shows the physical plan with scan row counts
  await page.fill("#sql", "SELECT count(*) AS n FROM t1 WHERE k = 10");
  await page.click("#planbtn");
  await page.waitForTimeout(100);
  const plan = await page.textContent("#planout");
  const planVisible = await page.isVisible("#planout");
  check(
    "the plan panel shows the plan",
    planVisible && plan.includes("scan t1") && /rows: (\?|\d+)/.test(plan),
    (plan.split("\n")[0] || "").slice(0, 60),
  );

  // 5. re-uploading the same name is refused instead of replacing silently
  await upload([csvFile("t1.csv", "x\n1\n")]);
  const dupErr = await page.textContent("#err");
  check("a duplicate table name is refused", dupErr.includes("already registered"), dupErr.slice(0, 60));

  // 6. dropping a table removes it, and a query over it fails by name
  await page.click('#tables .t[data-table="t2"] button');
  await page.waitForTimeout(50);
  tables = await tableNames();
  await runSQL("SELECT count(*) AS n FROM t2");
  const dropErr = await page.textContent("#err");
  check(
    "a dropped table is gone and named in the error",
    tables.join(",") === "t1" && dropErr.includes("unknown table"),
    `${tables.join(",")} | ${dropErr.slice(0, 40)}`,
  );

  // 7. clear empties the session and disables Run
  await page.click("#clear");
  await page.waitForTimeout(50);
  tables = await tableNames();
  const runDisabled = await page.isDisabled("#run");
  check("clear empties the session", tables.length === 0 && runDisabled, `${tables.length} tables`);

  // 8. the SF0.01 fixtures: CSV and Parquet, uploaded together, agree
  const csv = fs.readFileSync(path.join(data, "lineitem.csv"));
  const pq = fs.readFileSync(path.join(data, "lineitem.parquet"));
  await page.fill("#datecols", "l_shipdate");
  await upload([
    { name: "csvrows.csv", mimeType: "text/csv", buffer: csv },
    { name: "pqrows.parquet", mimeType: "application/octet-stream", buffer: pq },
  ]);
  await waitForStatus("2 tables");
  await runSQL(
    "SELECT count(*) AS n, min(l_shipdate) AS lo, max(l_shipdate) AS hi FROM csvrows",
  );
  const csvRows = await rowTexts();
  await runSQL(
    "SELECT count(*) AS n, min(l_shipdate) AS lo, max(l_shipdate) AS hi FROM pqrows",
  );
  const pqRows = await rowTexts();
  check(
    "CSV and Parquet agree cell for cell",
    JSON.stringify(csvRows) === JSON.stringify(pqRows) && csvRows.length === 1,
    `${JSON.stringify(csvRows)} vs ${JSON.stringify(pqRows)}`,
  );
  check(
    "DATE renders as a calendar date",
    /^\d{4}-\d{2}-\d{2}$/.test(csvRows[0][1]) && /^\d{4}-\d{2}-\d{2}$/.test(csvRows[0][2]),
    csvRows[0].join(","),
  );

  // 8b. a non-finite double reaches the table as text and does not break the
  // page's JSON.parse (bare Infinity/NaN used to make the whole line invalid)
  await runSQL(
    "SELECT l_quantity / 0 AS pi, (l_quantity - 10) / (l_quantity - 10) AS nan FROM csvrows WHERE l_quantity = 10 LIMIT 1",
  );
  const special = await rowTexts();
  check(
    "non-finite doubles render without breaking the page",
    special.length === 1 && special[0].join(",") === "Infinity,NaN" &&
      (await statusText()).startsWith("1 rows"),
    `${JSON.stringify(special)} | ${await statusText()}`,
  );

  // 9. a JOIN across the two uploaded copies (the point of the session)
  await runSQL(
    "SELECT count(*) AS n FROM csvrows JOIN pqrows ON csvrows.l_orderkey = pqrows.l_orderkey",
  );
  rows = await rowTexts();
  check("a JOIN across the two uploaded copies runs", rows.length === 1, JSON.stringify(rows));

  // 10. error paths surface and mark the run failed
  await runSQL("SELECT nope FROM csvrows");
  let err = await page.textContent("#err");
  check("an unknown column surfaces", err.includes("unknown column"), err.slice(0, 50));
  check("a failed query says so", (await statusText()) === "failed", await statusText());
  await runSQL("SELECT FROM");
  err = await page.textContent("#err");
  check("a syntax error surfaces", err.length > 0, err.slice(0, 50));

  // 11. nothing threw outside the page's own error handling
  check("no uncaught JS error", pageErrors.length === 0, pageErrors.join(" | "));

  await browser.close();

  const failed = results.filter((r) => !r.ok);
  console.log(
    `\n${results.length - failed.length}/${results.length} checks passed` +
      (failed.length ? `; ${failed.length} failed` : ""),
  );
  process.exit(failed.length ? 1 : 0);
})().catch(async (e) => {
  console.error(`FAIL  harness crashed: ${e && e.stack ? e.stack : e}`);
  try {
    if (page) await page.screenshot({ path: "playground-failure.png" });
  } catch (_) {
    /* best effort */
  }
  process.exit(1);
});
