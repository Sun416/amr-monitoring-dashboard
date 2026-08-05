'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { sql, getDatabaseConfig } = require('./db');

const workspaceRoot = path.resolve(__dirname, '..', '..');
const refreshFiles = [
  '67_refresh_non_snapshot_dws_for_web.sql',
  '83_load_dws_robot_task_hourly.sql',
  '82_load_task_analytics_reference_and_leaderboards.sql'
];

let activeRefresh = null;

function splitSqlBatches(sqlText) {
  return sqlText
    .split(/^\s*GO\s*(?:--.*)?$/gim)
    .map((batch) => batch.trim())
    .filter(Boolean);
}

async function runControlledSqlFile(pool, relativePath) {
  const sqlPath = path.resolve(workspaceRoot, relativePath);
  if (path.relative(workspaceRoot, sqlPath).startsWith('..')) {
    throw new Error(`Refresh script is outside the workspace: ${relativePath}`);
  }

  const sqlText = await fs.readFile(sqlPath, 'utf8');
  let affectedRows = 0;
  for (const batch of splitSqlBatches(sqlText)) {
    const result = await pool.request().query(batch);
    affectedRows += result.rowsAffected.reduce((total, count) => total + Number(count || 0), 0);
  }
  return { file: relativePath, affectedRows };
}

async function executeDwsRefresh() {
  if (activeRefresh) {
    const error = new Error('A DWS refresh is already running. Wait for it to finish before starting another one.');
    error.code = 'DWS_REFRESH_IN_PROGRESS';
    error.statusCode = 409;
    throw error;
  }

  activeRefresh = (async () => {
    const startedAt = Date.now();
    const config = getDatabaseConfig({ requestTimeoutMs: 900000 });
    const pool = await new sql.ConnectionPool(config).connect();
    try {
      const completed = [];
      for (const file of refreshFiles) {
        completed.push(await runControlledSqlFile(pool, file));
      }
      return {
        status: 'SUCCESS',
        elapsedSeconds: Math.round((Date.now() - startedAt) / 1000),
        completed
      };
    } finally {
      await pool.close();
    }
  })();

  try {
    return await activeRefresh;
  } finally {
    activeRefresh = null;
  }
}

module.exports = { executeDwsRefresh };
