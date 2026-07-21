'use strict';

const path = require('node:path');
const express = require('express');
const { loadDashboard, synchronizeCurrentSnapshot, checkDatabase } = require('./src/dashboard-service');
const { closePool, DatabaseConfigurationError, parseInteger } = require('./src/db');

try {
  if (typeof process.loadEnvFile === 'function') process.loadEnvFile(path.join(__dirname, '.env'));
} catch (error) {
  if (error.code !== 'ENOENT') console.warn('[environment]', error.message);
}

const app = express();
const host = String(process.env.WEB_HOST || '127.0.0.1').trim();
const port = parseInteger(process.env.WEB_PORT, 3080, 1, 65535);
const publicDirectory = path.join(__dirname, 'public');

app.disable('x-powered-by');
app.set('json replacer', (key, value) => typeof value === 'bigint' ? value.toString() : value);
app.use(express.json({ limit: '32kb' }));
app.use((request, response, next) => {
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('X-Frame-Options', 'DENY');
  response.setHeader('Referrer-Policy', 'no-referrer');
  response.setHeader('Cache-Control', request.path.startsWith('/api/') ? 'no-store' : 'no-cache');
  next();
});

app.get('/api/health', async (request, response, next) => {
  try {
    const database = await checkDatabase();
    response.json({ status: 'ok', database });
  } catch (error) {
    next(error);
  }
});

app.get('/api/dashboard', async (request, response, next) => {
  try {
    const dashboard = await loadDashboard({
      hours: request.query.hours,
      days: request.query.days
    });
    response.json(dashboard);
  } catch (error) {
    next(error);
  }
});

app.post('/api/sync/current', async (request, response, next) => {
  try {
    const result = await synchronizeCurrentSnapshot();
    response.json(result);
  } catch (error) {
    next(error);
  }
});

app.use(express.static(publicDirectory, { index: 'index.html' }));

app.get('/{*splat}', (request, response) => {
  response.sendFile(path.join(publicDirectory, 'index.html'));
});

app.use((error, request, response, next) => {
  if (response.headersSent) return next(error);

  const notConfigured = error instanceof DatabaseConfigurationError || error.code === 'DATABASE_NOT_CONFIGURED';
  const status = notConfigured ? 503 : 500;
  console.error(`[${request.method} ${request.path}]`, error.message);

  response.status(status).json({
    code: notConfigured ? 'DATABASE_NOT_CONFIGURED' : 'DATABASE_REQUEST_FAILED',
    message: notConfigured
      ? error.message
      : 'Database request failed. Check the SQL Server connection, object permissions and server logs.'
  });
});

const server = app.listen(port, host, () => {
  console.log(`[AMR Monitor] http://${host}:${port}`);
});

async function shutdown(signal) {
  console.log(`[AMR Monitor] ${signal}, shutting down...`);
  server.close(async () => {
    await closePool();
    process.exit(0);
  });
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
