'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { getPool, closePool } = require('../src/db');

try {
  if (typeof process.loadEnvFile === 'function') {
    process.loadEnvFile(path.join(__dirname, '..', '.env'));
  }
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
}

const workspaceRoot = path.resolve(__dirname, '..', '..');

function resolveSqlPath(argument) {
  if (!argument) {
    throw new Error('Usage: node scripts/run-sql-file.js <workspace-relative-sql-file>');
  }

  const resolved = path.resolve(workspaceRoot, argument);
  const relative = path.relative(workspaceRoot, resolved);
  if (relative.startsWith('..') || path.isAbsolute(relative) || path.extname(resolved).toLowerCase() !== '.sql') {
    throw new Error('SQL file must be a .sql file inside the workspace.');
  }
  return resolved;
}

async function main() {
  const sqlPath = resolveSqlPath(process.argv[2]);
  const sqlText = await fs.readFile(sqlPath, 'utf8');
  const pool = await getPool();
  const request = pool.request();
  request.multiple = true;
  const result = await request.query(sqlText);

  process.stdout.write(`${JSON.stringify({
    file: path.relative(workspaceRoot, sqlPath),
    rowsAffected: result.rowsAffected,
    recordsets: result.recordsets
  }, null, 2)}\n`);
}

main()
  .then(closePool)
  .catch(async (error) => {
    console.error(error);
    await closePool();
    process.exitCode = 1;
  });
