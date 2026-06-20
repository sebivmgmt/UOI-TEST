#!/usr/bin/env node
/**
 * DEV-only Supabase Management API SQL runner.
 *
 * Usage:
 *   SUPABASE_ACCESS_TOKEN=... node scripts/run-score-v22-sql.mjs path/to/file.sql
 *   SUPABASE_ACCESS_TOKEN=... node scripts/run-score-v22-sql.mjs --read-only path/to/file.sql
 *
 * Optional:
 *   SUPABASE_PROJECT_REF=colkilearqxuyldzjutw
 *
 * The script refuses every project except the approved DEV ref and explicitly
 * refuses the LIVE ref.
 */

import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const DEV_REF = "colkilearqxuyldzjutw";
const LIVE_REF = "clxfsghyasjmfoxmhpxv";

function fail(message) {
  console.error(`\nERROR: ${message}\n`);
  process.exit(1);
}

const args = process.argv.slice(2);
const readOnly = args[0] === "--read-only";
const sqlPath = readOnly ? args[1] : args[0];
if (!sqlPath || args.length !== (readOnly ? 2 : 1)) {
  fail("Usage: run-score-v22-sql.mjs [--read-only] <sql-file>");
}

const projectRef = process.env.SUPABASE_PROJECT_REF || DEV_REF;
if (projectRef === LIVE_REF) {
  fail("LIVE project is forbidden for the Score v2.2 rollout.");
}
if (projectRef !== DEV_REF) {
  fail(`Refusing unknown project ref: ${projectRef}`);
}

const accessToken = process.env.SUPABASE_ACCESS_TOKEN;
if (!accessToken) {
  fail("SUPABASE_ACCESS_TOKEN is required.");
}

const resolvedPath = path.resolve(sqlPath);
const sql = await fs.readFile(resolvedPath, "utf8");
if (!sql.trim()) {
  fail(`SQL file is empty: ${resolvedPath}`);
}

const endpoint =
  `https://api.supabase.com/v1/projects/${projectRef}/database/query`;

console.log(`DEV project: ${projectRef}`);
console.log(`SQL file:    ${resolvedPath}`);
console.log(`SHA-256:     ${await sha256(sql)}`);
console.log(`Read only:   ${readOnly}`);

const response = await fetch(endpoint, {
  method: "POST",
  headers: {
    Authorization: `Bearer ${accessToken}`,
    "Content-Type": "application/json",
  },
  body: JSON.stringify({ query: sql, read_only: readOnly }),
});

const bodyText = await response.text();
let body;
try {
  body = JSON.parse(bodyText);
} catch {
  body = bodyText;
}

if (!response.ok) {
  console.error(body);
  fail(`Management API returned HTTP ${response.status}.`);
}

console.dir(body, { depth: null, colors: true, maxArrayLength: null });

async function sha256(value) {
  const { createHash } = await import("node:crypto");
  return createHash("sha256").update(value).digest("hex");
}
