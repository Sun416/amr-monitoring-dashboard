'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { normalizeWifiAnalysisWindow } = require('../src/dashboard-service');

test('uses the top-level duration when no exact WiFi window is selected', () => {
  assert.deepEqual(normalizeWifiAnalysisWindow(null, null, 24), {
    isCustom: false,
    start: null,
    end: null,
    hours: 24
  });
});

test('preserves database-local exact WiFi timestamps without timezone conversion', () => {
  assert.deepEqual(
    normalizeWifiAnalysisWindow('2026-07-30T08:15:00', '2026-07-31T08:15:00', 24),
    {
      isCustom: true,
      start: '2026-07-30T08:15:00.000',
      end: '2026-07-31T08:15:00.000',
      hours: 24
    }
  );
});

test('rejects incomplete, backwards, invalid, and over-30-day exact WiFi windows', () => {
  assert.throws(
    () => normalizeWifiAnalysisWindow('2026-07-30T08:15', null, 24),
    { code: 'INVALID_WIFI_ANALYSIS_WINDOW' }
  );
  assert.throws(
    () => normalizeWifiAnalysisWindow('2026-07-31T08:15', '2026-07-30T08:15', 24),
    { code: 'INVALID_WIFI_ANALYSIS_WINDOW' }
  );
  assert.throws(
    () => normalizeWifiAnalysisWindow('2026-02-30T08:15', '2026-03-01T08:15', 24),
    { code: 'INVALID_WIFI_ANALYSIS_WINDOW' }
  );
  assert.throws(
    () => normalizeWifiAnalysisWindow('2026-06-01T00:00', '2026-07-02T00:00', 24),
    { code: 'INVALID_WIFI_ANALYSIS_WINDOW' }
  );
});
