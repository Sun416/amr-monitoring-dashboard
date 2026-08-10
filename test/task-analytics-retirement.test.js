'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..');
const indexHtml = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');
const bootstrap = fs.readFileSync(path.join(root, 'public', 'js', 'app-bootstrap.js'), 'utf8');
const core = fs.readFileSync(path.join(root, 'public', 'js', 'app-core.js'), 'utf8');
const server = fs.readFileSync(path.join(root, 'server.js'), 'utf8');
const service = fs.readFileSync(path.join(root, 'src', 'dashboard-service.js'), 'utf8');

test('retires the standalone Task Analytics navigation and page', () => {
  assert.equal(indexHtml.includes('data-view="tasks"'), false);
  assert.equal(indexHtml.includes('data-view-panel="tasks"'), false);
  assert.equal(core.includes("tasks: { eyebrow:"), false);
});

test('loads task state coverage only from the Data Quality view', () => {
  assert.match(indexHtml, /id="dataQualityTaskStateScope"/);
  assert.match(indexHtml, /id="dataQualityTaskStateExceptionPanel"/);
  assert.match(core, /view === 'data-quality'.*loadTaskStateQuality\(\)/);
  assert.equal(bootstrap.includes('loadTaskAnalytics('), false);
  assert.equal(bootstrap.includes('taskApplyWindow'), false);
});

test('retains the task analytics API and DWS service for on-demand state evidence', () => {
  assert.match(server, /app\.get\('\/api\/task-analytics'/);
  assert.match(service, /async function loadTaskAnalytics/);
  assert.match(service, /stateExceptionDetails/);
});
