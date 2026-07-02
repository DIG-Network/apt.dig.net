// axe.test.mjs — WCAG 2.2 AA accessibility gate for the apt.dig.net landing page.
//
// CLAUDE.md §6.6 mandates a CONCRETE automated accessibility tier — not a linter
// alone. This loads the REAL site/index.html in a headless Chromium (so
// color-contrast and computed-style rules actually run — jsdom cannot do those)
// and asserts axe-core reports ZERO WCAG 2.0/2.1/2.2 A + AA violations.
//
// Run:  npm ci && npx playwright install --with-deps chromium && npm test
// Exit: 0 = no violations; 1 = one or more violations (details printed).

import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, resolve } from "node:path";
import { chromium } from "playwright";
import { AxeBuilder } from "@axe-core/playwright";

const HERE = dirname(fileURLToPath(import.meta.url));
// tests/a11y -> repo root -> site/index.html
const INDEX = resolve(HERE, "..", "..", "site", "index.html");
const url = pathToFileURL(INDEX).href;

// WCAG 2.2 AA = the 2.0/2.1/2.2 A + AA success-criterion tags axe maps rules to.
const WCAG_TAGS = [
  "wcag2a",
  "wcag2aa",
  "wcag21a",
  "wcag21aa",
  "wcag22aa",
];

function fail(msg) {
  console.error(`FAIL - ${msg}`);
  process.exitCode = 1;
}

const browser = await chromium.launch();
try {
  // @axe-core/playwright requires a page created from an explicit browser
  // context (not the shortcut browser.newPage()).
  const context = await browser.newContext();
  const page = await context.newPage();
  const resp = await page.goto(url, { waitUntil: "load" });
  if (!resp || !resp.ok()) {
    // file:// responses have a null/!ok status in some builds; only fail on a
    // genuine load error, not the file-scheme quirk.
    if (resp && resp.status() >= 400) {
      fail(`could not load ${url} (status ${resp.status()})`);
    }
  }

  const results = await new AxeBuilder({ page }).withTags(WCAG_TAGS).analyze();

  const violations = results.violations;
  if (violations.length === 0) {
    console.log(
      `ok   - axe: 0 WCAG 2.2 AA violations on site/index.html ` +
        `(${results.passes.length} checks passed)`
    );
  } else {
    fail(`axe: ${violations.length} WCAG 2.2 AA violation(s) on site/index.html`);
    for (const v of violations) {
      console.error(`\n  [${v.impact ?? "n/a"}] ${v.id}: ${v.help}`);
      console.error(`    ${v.helpUrl}`);
      for (const node of v.nodes) {
        console.error(`      target: ${JSON.stringify(node.target)}`);
        if (node.failureSummary) {
          console.error(
            "        " + node.failureSummary.replace(/\n/g, "\n        ")
          );
        }
      }
    }
  }
} finally {
  await browser.close();
}

if (process.exitCode && process.exitCode !== 0) {
  process.exit(process.exitCode);
}
console.log("\nall accessibility assertions passed");
