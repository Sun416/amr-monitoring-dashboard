'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..');

function read(...segments) {
  return fs.readFileSync(path.join(root, ...segments), 'utf8');
}

const indexHtml = read('public', 'index.html');
const projectPage = read('public', 'js', 'project-page.js');
const server = read('server.js');
const service = read('src', 'dashboard-service.js');
const query = read('src', 'project-analytics-query.sql');

test('executive query scope is project and task while robot remains a derived display filter', () => {
  assert.match(indexHtml, /id="robotToggle"/);
  assert.match(indexHtml, /id="analysisRobotToggle"/);
  assert.match(indexHtml, /Project and task define the query\. Robot only narrows the derived display\./);
  assert.match(indexHtml, /Robots \(display\)/);
  assert.match(indexHtml, /Robots Carrying the Selected Work/);
});

test('project analytics never sends or parses a robot filter', () => {
  assert.equal(projectPage.includes("params.set('robots'"), false);
  assert.equal(service.includes('robot_codes_text_param'), false);
  assert.equal(query.includes('@selected_robots'), false);
  assert.equal(query.includes('@robot_codes_text'), false);
});

test('dashboard static files are not cached across a project-filter deployment', () => {
  assert.match(server, /response\.setHeader\('Cache-Control', 'no-store'\)/);
  assert.match(indexHtml, /project-page\.js\?v=20260810-task-page-removal-r1/);
});

test('project selection clears task selection before reloading the hierarchy', () => {
  assert.match(projectPage, /setProjectScope\(\{ projectIds: values, jobIds: \[\] \}\)/);
  assert.match(projectPage, /projectIds: \[\.\.\.next\],\s+jobIds: \[\]/);
});

test('robots are a derived breakdown with a robot-profile drilldown', () => {
  assert.match(service, /filters: \['project', 'task'\]/);
  assert.match(service, /derivedBreakdown: 'robot'/);
  assert.match(service, /drilldown: 'robot-profile'/);
  assert.match(projectPage, /selectRobotProfile\(robotId\)/);
  assert.match(projectPage, /setProjectRobotDisplayScope/);
  assert.match(projectPage, /projectDisplayRobotRows/);
  assert.match(projectPage, /idleCausesByRobot/);
});

test('derived Robot display scope is applied to every Project Analytics result', () => {
  assert.match(projectPage, /const robotRows = projectDisplayRobotRows\(allRobotRows\)/);
  assert.match(projectPage, /renderProjectRobots\(robotRows\)/);
  assert.match(projectPage, /projectDisplayIdleCauses\(data\.idleCausesByRobot \|\| \[\]\)/);
  assert.match(projectPage, /projectDisplayRobotRows\(data\.hourlyTrend \|\| \[\]\)/);
  assert.match(projectPage, /projectDisplayRobotRows\(data\.recentQueues \|\| \[\]\)/);
});

test('project API rejects the retired robot-first scope', () => {
  assert.match(server, /request\.query\.robots !== undefined/);
  assert.match(server, /ROBOT_SCOPE_NOT_SUPPORTED/);
  assert.match(server, /statusCode = 400/);
});
