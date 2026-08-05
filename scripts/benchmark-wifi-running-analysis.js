'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { performance } = require('node:perf_hooks');
const { sql, getPool, closePool, parseInteger } = require('../src/db');
const { buildWifiMinimumDiagnostics } = require('../src/wifi-minimum-diagnostic');

try {
  if (typeof process.loadEnvFile === 'function') {
    process.loadEnvFile(path.join(__dirname, '..', '.env'));
  }
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
}

async function main() {
  const hours = parseInteger(process.argv[2], 24, 1, 720);
  const queryText = await fs.readFile(
    path.join(__dirname, '..', 'src', 'wifi-running-analysis-query.sql'),
    'utf8'
  );
  const pool = await getPool();
  const request = pool.request();
  request.multiple = true;
  request.input('hours', sql.Int, hours);
  request.input('freshness_timeout_minutes', sql.Int, 30);
  request.input('robot_type', sql.NVarChar(10), 'ALL');

  const startedAt = performance.now();
  const result = await request.query(queryText);
  const durationMs = performance.now() - startedAt;
  const recordsets = result.recordsets || [];
  const minimumDiagnostics = buildWifiMinimumDiagnostics({
    byTarget: recordsets[2] || [],
    byRobot: recordsets[3] || [],
    byRobotTarget: recordsets[4] || [],
    worstSamples: recordsets[5] || []
  });

  process.stdout.write(`${JSON.stringify({
    requestedHours: hours,
    durationMs: Number(durationMs.toFixed(1)),
    summary: recordsets[0]?.[0] || {},
    rowCounts: recordsets.map((rows) => rows.length),
    overallMinimumDiagnostic: minimumDiagnostics.find((item) => item.scope_type === 'ALL') || null
  }, null, 2)}\n`);
}

main()
  .then(closePool)
  .catch(async (error) => {
    console.error(error);
    await closePool();
    process.exitCode = 1;
  });
