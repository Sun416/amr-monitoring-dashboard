'use strict';

const path = require('node:path');
const express = require('express');
const { loadDashboard, loadTaskAnalytics, loadProjectAnalytics, loadRobotProfile, checkDatabase } = require('./src/dashboard-service');
const { closePool, DatabaseConfigurationError, parseInteger } = require('./src/db');

try {
  if (typeof process.loadEnvFile === 'function') process.loadEnvFile(path.join(__dirname, '.env'));
} catch (error) {
  if (error.code !== 'ENOENT') console.warn('[environment]', error.message);
}

const app = express();
const host = String(process.env.WEB_HOST_OVERRIDE || process.env.WEB_HOST || '127.0.0.1').trim();
const port = parseInteger(process.env.WEB_PORT_OVERRIDE || process.env.WEB_PORT, 3080, 1, 65535);
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
      days: request.query.days,
      robotType: request.query.robotType,
      wifiStart: request.query.wifiStart,
      wifiEnd: request.query.wifiEnd
    });
    response.json(dashboard);
  } catch (error) {
    next(error);
  }
});

app.get('/api/task-analytics', async (request, response, next) => {
  try {
    const taskAnalytics = await loadTaskAnalytics({
      taskStart: request.query.start,
      taskEnd: request.query.end,
      robotCodes: request.query.robots || request.query.robot
    });
    response.json(taskAnalytics);
  } catch (error) {
    next(error);
  }
});

app.get('/api/project-analytics', async (request, response, next) => {
  try {
    if (request.query.robots !== undefined || request.query.robot !== undefined) {
      const error = new Error('Robot is a derived result in Project Analytics. Filter by project and task, then use the returned robot breakdown.');
      error.code = 'ROBOT_SCOPE_NOT_SUPPORTED';
      error.statusCode = 400;
      throw error;
    }
    const projectAnalytics = await loadProjectAnalytics({
      start: request.query.start,
      end: request.query.end,
      projectId: request.query.projectId,
      jobId: request.query.jobId,
      projectIds: request.query.projects,
      jobIds: request.query.jobs
    });
    response.json(projectAnalytics);
  } catch (error) {
    next(error);
  }
});

app.get('/api/robot/:robotId', async (request, response, next) => {
  try {
    const profile = await loadRobotProfile({
      robotId: request.params.robotId,
      hours: request.query.hours,
      days: request.query.days
    });
    response.json(profile);
  } catch (error) {
    next(error);
  }
});

app.post('/api/sync/current', async (request, response, next) => {
  response.status(410).json({
    code: 'SNAPSHOT_SYNC_DISABLED',
    message: 'Current-snapshot synchronization is disabled. The dashboard reads non-snapshot DWS aggregates and applies a 30-minute freshness gate.'
  });
});

app.post('/api/sync/dws', (request, response) => {
  response.status(410).json({
    code: 'DWS_SYNC_EXTERNALIZED',
    message: 'DWS synchronization is owned by the amr-data-warehouse operational workflow and cannot be triggered from the read-only dashboard.'
  });
});

app.use(express.static(publicDirectory, { index: 'index.html' }));

app.get('/{*splat}', (request, response) => {
  response.sendFile(path.join(publicDirectory, 'index.html'));
});

app.use((error, request, response, next) => {
  if (response.headersSent) return next(error);

  const notConfigured = error instanceof DatabaseConfigurationError || error.code === 'DATABASE_NOT_CONFIGURED';
  const status = notConfigured ? 503 : (error.statusCode || 500);
  console.error(`[${request.method} ${request.path}]`, error.message);

  response.status(status).json({
    code: notConfigured ? 'DATABASE_NOT_CONFIGURED' : (error.code || 'DATABASE_REQUEST_FAILED'),
    message: notConfigured
      ? error.message
      : (error.statusCode ? error.message : 'Database request failed. Check the SQL Server connection, object permissions and server logs.')
  });
});

const server = app.listen(port, host, () => {
  console.log(`[AMR Monitor] http://${host}:${port}`);
  console.log('[AMR Monitor] Current data source: non-snapshot DWS aggregates with freshness gating.');
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
