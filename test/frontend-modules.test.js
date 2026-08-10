'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..');
const indexHtml = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');

const expectedModules = [
  'app-core.js',
  'task-page.js',
  'project-page.js',
  'robot-profile-page.js',
  'fleet-page.js',
  'wifi-page.js',
  'exports.js',
  'app-bootstrap.js'
];

test('loads the frontend modules in dependency order', () => {
  let previousIndex = -1;
  for (const moduleName of expectedModules) {
    const moduleIndex = indexHtml.indexOf(`/js/${moduleName}`);
    assert.ok(moduleIndex > previousIndex, `${moduleName} must load after its dependencies`);
    assert.ok(fs.existsSync(path.join(root, 'public', 'js', moduleName)), `${moduleName} must exist`);
    previousIndex = moduleIndex;
  }
});

test('does not load the retired monolithic app.js bundle', () => {
  assert.equal(indexHtml.includes('/app.js'), false);
  assert.equal(fs.existsSync(path.join(root, 'public', 'app.js')), false);
});
