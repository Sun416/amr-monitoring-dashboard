'use strict';

const sql = require('mssql');

let poolPromise = null;

class DatabaseConfigurationError extends Error {
  constructor(message) {
    super(message);
    this.name = 'DatabaseConfigurationError';
    this.code = 'DATABASE_NOT_CONFIGURED';
  }
}

function parseBoolean(value, defaultValue) {
  if (value === undefined || value === null || value === '') return defaultValue;
  return ['1', 'true', 'yes', 'on'].includes(String(value).toLowerCase());
}

function parseInteger(value, defaultValue, minimum, maximum) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed)) return defaultValue;
  return Math.min(maximum, Math.max(minimum, parsed));
}

function getDatabaseConfig({ requestTimeoutMs } = {}) {
  const server = String(process.env.DB_SERVER || '').trim();
  const database = String(process.env.DB_DATABASE || 'IOT2020').trim();
  const user = String(process.env.DB_USER || '').trim();
  const password = String(process.env.DB_PASSWORD || '');
  const instanceName = String(process.env.DB_INSTANCE || '').trim();

  if (!server || !database || !user || !password || password === 'replace_with_password') {
    throw new DatabaseConfigurationError(
      'Database connection is not configured. Copy .env.example to .env and set DB_SERVER, DB_USER and DB_PASSWORD.'
    );
  }

  const options = {
    encrypt: parseBoolean(process.env.DB_ENCRYPT, false),
    trustServerCertificate: parseBoolean(process.env.DB_TRUST_SERVER_CERTIFICATE, true),
    // IOT2020 stores local wall-clock DATETIME/DATETIME2 values without a UTC offset.
    // Reading them as UTC adds another +07:00 in the browser and makes batch times wrong.
    useUTC: parseBoolean(process.env.DB_USE_UTC, false),
    enableArithAbort: true
  };

  if (instanceName) options.instanceName = instanceName;

  const config = {
    server,
    database,
    user,
    password,
    options,
    connectionTimeout: parseInteger(process.env.DB_CONNECTION_TIMEOUT_MS, 15000, 1000, 120000),
    requestTimeout: parseInteger(
      requestTimeoutMs,
      parseInteger(process.env.DB_REQUEST_TIMEOUT_MS, 120000, 5000, 900000),
      5000,
      900000
    ),
    pool: {
      max: 8,
      min: 0,
      idleTimeoutMillis: 30000
    }
  };

  if (!instanceName) {
    config.port = parseInteger(process.env.DB_PORT, 1433, 1, 65535);
  }

  return config;
}

async function getPool() {
  if (!poolPromise) {
    const config = getDatabaseConfig();
    const pool = new sql.ConnectionPool(config);
    pool.on('error', (error) => {
      console.error('[database pool error]', error.message);
    });
    poolPromise = pool.connect().catch((error) => {
      poolPromise = null;
      throw error;
    });
  }

  return poolPromise;
}

async function closePool() {
  if (!poolPromise) return;
  try {
    const pool = await poolPromise;
    await pool.close();
  } finally {
    poolPromise = null;
  }
}

module.exports = {
  sql,
  getPool,
  getDatabaseConfig,
  closePool,
  DatabaseConfigurationError,
  parseInteger
};
