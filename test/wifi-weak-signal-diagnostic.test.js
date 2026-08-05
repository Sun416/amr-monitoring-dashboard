'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { buildWifiWeakSignalDiagnostics } = require('../src/wifi-weak-signal-diagnostic');

function build(rows = {}) {
  return buildWifiWeakSignalDiagnostics({
    byRobot: rows.byRobot || [],
    byTarget: rows.byTarget || []
  });
}

test('fixed weak RSSI is a data-quality risk before physical root-cause claims', () => {
  const [diagnostic] = build({
    byRobot: [{
      robot_code: 'AMB-02',
      target_count: 3,
      valid_signal_sample_count: 50,
      weak_signal_sample_count: 50,
      weak_signal_rate: 100,
      weak_target_count: 3,
      minimum_valid_rssi: -68,
      maximum_valid_rssi: -68
    }]
  });

  assert.equal(diagnostic.rule_id, 'WIFI_WEAK_SIGNAL_FIXED_VALUE');
  assert.equal(diagnostic.confidence, 'HIGH');
  assert.equal(diagnostic.cause_status, 'DATA_QUALITY_RISK');
  assert.match(diagnostic.cause, /does not by itself prove an on-site RF deterioration/);
});

test('weak observations across multiple target destinations raise a robot-side candidate', () => {
  const [diagnostic] = build({
    byRobot: [{
      robot_code: 'AMB-02',
      target_count: 4,
      valid_signal_sample_count: 80,
      weak_signal_sample_count: 24,
      weak_signal_rate: 30,
      weak_target_count: 2,
      minimum_valid_rssi: -76,
      maximum_valid_rssi: -52
    }]
  });

  assert.equal(diagnostic.rule_id, 'WIFI_WEAK_SIGNAL_MULTI_TARGET_ROBOT_RISK');
  assert.equal(diagnostic.confidence, 'MEDIUM');
  assert.match(diagnostic.cause, /antenna, feeder, WiFi adapter/);
});

test('weak observations associated with one target across robots remain location indicators, not proof of position', () => {
  const [diagnostic] = build({
    byTarget: [{
      poi_target: 'LM122',
      valid_signal_sample_count: 60,
      weak_signal_sample_count: 30,
      weak_signal_rate: 50,
      weak_robot_count: 3,
      average_valid_rssi: -68
    }]
  });

  assert.equal(diagnostic.rule_id, 'WIFI_WEAK_SIGNAL_MULTI_ROBOT_TARGET_RISK');
  assert.equal(diagnostic.confidence, 'MEDIUM');
  assert.match(diagnostic.cause, /task destination rather than a measured position/);
});

test('no weak samples produce no diagnostic', () => {
  assert.deepEqual(build({
    byRobot: [{ robot_code: 'AMB-01', weak_signal_sample_count: 0 }],
    byTarget: [{ poi_target: 'LM100', weak_signal_sample_count: 0 }]
  }), []);
});
