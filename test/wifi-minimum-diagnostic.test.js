'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { buildWifiMinimumDiagnostics } = require('../src/wifi-minimum-diagnostic');

function worstSample(overrides = {}) {
  return {
    scope_type: 'ALL',
    scope_robot_code: null,
    scope_poi_target: null,
    minimum_robot_code: 'AMB-01',
    minimum_poi_target: 'LM122',
    minimum_event_time: '2026-07-30T08:15:00.000Z',
    minimum_rssi: -69,
    ...overrides
  };
}

function diagnose({ byTarget, byRobot, byRobotTarget } = {}) {
  return buildWifiMinimumDiagnostics({
    byTarget: byTarget || [{
      poi_target: 'LM122',
      robot_count: 1,
      valid_signal_sample_count: 12,
      average_valid_rssi: -69
    }],
    byRobot: byRobot || [{
      robot_code: 'AMB-01',
      target_count: 1,
      valid_signal_sample_count: 12,
      average_valid_rssi: -69,
      minimum_valid_rssi: -69,
      maximum_valid_rssi: -55
    }],
    byRobotTarget: byRobotTarget || [{
      robot_code: 'AMB-01',
      poi_target: 'LM122',
      valid_signal_sample_count: 12
    }],
    worstSamples: [worstSample()]
  })[0];
}

test('fixed RSSI values are diagnosed as a data-quality risk before physical WiFi causes', () => {
  const result = diagnose({
    byRobot: [{
      robot_code: 'AMB-01',
      target_count: 5,
      valid_signal_sample_count: 80,
      average_valid_rssi: -69,
      minimum_valid_rssi: -69,
      maximum_valid_rssi: -69
    }]
  });

  assert.equal(result.rule_id, 'WIFI_RSSI_VALUE_STUCK');
  assert.equal(result.confidence, 'HIGH');
  assert.equal(result.cause_status, 'DATA_QUALITY_RISK');
  assert.match(result.cause, /cannot confirm a sudden on-site signal drop/);
});

test('multiple robots with a weak point average indicate a point coverage risk', () => {
  const result = diagnose({
    byTarget: [{
      poi_target: 'LM122',
      robot_count: 3,
      valid_signal_sample_count: 60,
      average_valid_rssi: -70
    }]
  });

  assert.equal(result.rule_id, 'WIFI_POINT_COVERAGE_RISK');
  assert.equal(result.confidence, 'MEDIUM');
  assert.match(result.cause, /risk of AP coverage/);
});

test('one robot weak across multiple targets indicates a robot-side risk', () => {
  const result = diagnose({
    byRobot: [{
      robot_code: 'AMB-01',
      target_count: 5,
      valid_signal_sample_count: 80,
      average_valid_rssi: -70,
      minimum_valid_rssi: -78,
      maximum_valid_rssi: -55
    }]
  });

  assert.equal(result.rule_id, 'WIFI_ROBOT_SIDE_RISK');
  assert.equal(result.confidence, 'MEDIUM');
  assert.match(result.cause, /antenna, feeder cable, WiFi adapter/);
});

test('a single low observation remains unresolved when corroborating evidence is absent', () => {
  const result = diagnose();

  assert.equal(result.rule_id, 'WIFI_MINIMUM_CAUSE_UNRESOLVED');
  assert.equal(result.confidence, 'LOW');
  assert.equal(result.robot_code, 'AMB-01');
  assert.equal(result.poi_target, 'LM122');
  assert.equal(result.minimum_rssi, -69);
  assert.equal(result.actions.length, 3);
});
