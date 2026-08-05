'use strict';

const { WIFI_WEAK_RSSI_THRESHOLD } = require('./wifi-minimum-diagnostic');

const WIFI_WEAK_SIGNAL_RULE_VERSION = '2026.08.03';

function numberValue(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : 0;
}

function percentage(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function fixedWeakValue(row) {
  const validCount = numberValue(row.valid_signal_sample_count);
  const minimum = Number(row.minimum_valid_rssi);
  const maximum = Number(row.maximum_valid_rssi);
  return validCount >= 10
    && Number.isFinite(minimum)
    && minimum <= WIFI_WEAK_RSSI_THRESHOLD
    && minimum === maximum;
}

function robotDiagnostic(row) {
  const robotCode = String(row.robot_code || 'Unknown robot');
  const weakCount = numberValue(row.weak_signal_sample_count);
  const validCount = numberValue(row.valid_signal_sample_count);
  const weakRate = percentage(row.weak_signal_rate);
  const weakTargetCount = numberValue(row.weak_target_count);

  if (fixedWeakValue(row)) {
    return {
      scope_type: 'ROBOT',
      scope_robot_code: robotCode,
      scope_poi_target: null,
      rule_id: 'WIFI_WEAK_SIGNAL_FIXED_VALUE',
      rule_version: WIFI_WEAK_SIGNAL_RULE_VERSION,
      confidence: 'HIGH',
      cause_status: 'DATA_QUALITY_RISK',
      priority: 3,
      weak_signal_sample_count: weakCount,
      weak_signal_rate: weakRate,
      cause: `${robotCode} reported one fixed weak RSSI value across ${validCount} valid Running-task samples. This can indicate a stuck RSSI publishing value; it does not by itself prove an on-site RF deterioration.`,
      evidence: [
        `${weakCount} weak samples out of ${validCount} valid samples (${weakRate == null ? '--' : `${weakRate}%`})`,
        `Minimum RSSI = maximum RSSI = ${row.minimum_valid_rssi} dBm`,
        `${numberValue(row.target_count)} related target POIs`
      ],
      actions: [
        `Verify ${robotCode}'s raw WiFi telemetry changes over time and compare it with an on-robot diagnostic reading.`,
        'If the raw reading changes while the ODS value remains fixed, repair the collection or publishing path before changing RF hardware.',
        'After telemetry is validated, repeat the Running-task route before replacing an AP, antenna, cable, or WiFi adapter.'
      ]
    };
  }

  if (weakTargetCount >= 2 && weakCount >= 10) {
    return {
      scope_type: 'ROBOT',
      scope_robot_code: robotCode,
      scope_poi_target: null,
      rule_id: 'WIFI_WEAK_SIGNAL_MULTI_TARGET_ROBOT_RISK',
      rule_version: WIFI_WEAK_SIGNAL_RULE_VERSION,
      confidence: 'MEDIUM',
      cause_status: 'LIKELY_ROBOT_RISK',
      priority: 2,
      weak_signal_sample_count: weakCount,
      weak_signal_rate: weakRate,
      cause: `${robotCode} produced weak observations at ${weakTargetCount} task destinations. This supports a robot-side antenna, feeder, WiFi adapter, or roaming-configuration risk, but needs a cross-robot retest before hardware replacement.`,
      evidence: [
        `${weakCount} weak samples out of ${validCount} valid samples (${weakRate == null ? '--' : `${weakRate}%`})`,
        `${weakTargetCount} target POIs with at least one weak sample`,
        `Observed RSSI range: ${row.minimum_valid_rssi} to ${row.maximum_valid_rssi} dBm`
      ],
      actions: [
        `Run the same task destinations with ${robotCode} and one comparison robot.`,
        `Inspect ${robotCode}'s antenna connection, feeder cable, WiFi adapter, and roaming configuration.`,
        'Compare wireless-controller association, retry, and roaming records at the weak-signal times.'
      ]
    };
  }

  return {
    scope_type: 'ROBOT',
    scope_robot_code: robotCode,
    scope_poi_target: null,
    rule_id: 'WIFI_WEAK_SIGNAL_CAUSE_UNRESOLVED',
    rule_version: WIFI_WEAK_SIGNAL_RULE_VERSION,
    confidence: 'LOW',
    cause_status: 'UNRESOLVED',
    priority: 1,
    weak_signal_sample_count: weakCount,
    weak_signal_rate: weakRate,
    cause: `${robotCode} has weak Running-task WiFi observations, but the current evidence does not separate a local coverage issue, a robot-side issue, or a temporary fluctuation.`,
    evidence: [
      `${weakCount} weak samples out of ${validCount} valid samples (${weakRate == null ? '--' : `${weakRate}%`})`,
      `${weakTargetCount} target POIs with at least one weak sample`,
      `Observed RSSI range: ${row.minimum_valid_rssi} to ${row.maximum_valid_rssi} dBm`
    ],
    actions: [
      `Retest the same task destination with ${robotCode} and another robot.`,
      'At the weak-signal time, inspect wireless-controller and robot logs for AP association, roaming, retries, and channel utilization.',
      'Do not directly attribute the observation to an AP or a robot component before comparison evidence is available.'
    ]
  };
}

function targetDiagnostic(row) {
  const poiTarget = String(row.poi_target || 'Unknown target');
  const weakCount = numberValue(row.weak_signal_sample_count);
  const validCount = numberValue(row.valid_signal_sample_count);
  const weakRate = percentage(row.weak_signal_rate);
  const weakRobotCount = numberValue(row.weak_robot_count);

  if (weakRobotCount >= 2 && weakCount >= 10) {
    return {
      scope_type: 'TARGET',
      scope_robot_code: null,
      scope_poi_target: poiTarget,
      rule_id: 'WIFI_WEAK_SIGNAL_MULTI_ROBOT_TARGET_RISK',
      rule_version: WIFI_WEAK_SIGNAL_RULE_VERSION,
      confidence: 'MEDIUM',
      cause_status: 'LIKELY_POINT_RISK',
      priority: 2,
      weak_signal_sample_count: weakCount,
      weak_signal_rate: weakRate,
      cause: `${poiTarget} is associated with weak observations from ${weakRobotCount} robots. Because poi_target is a task destination rather than a measured position, this is a route/area risk indicator—not proof that the weak sample occurred at that exact point.`,
      evidence: [
        `${weakCount} weak samples out of ${validCount} valid samples (${weakRate == null ? '--' : `${weakRate}%`})`,
        `${weakRobotCount} robots with weak observations for this target`,
        `Target average RSSI: ${row.average_valid_rssi} dBm`
      ],
      actions: [
        `Inspect AP association, roaming, retry, and channel-utilization logs around the weak-signal times for routes serving ${poiTarget}.`,
        `Retest the route associated with ${poiTarget} using at least two robots.`,
        'If weak readings repeat across robots, inspect AP placement, channel plan, transmit power, obstruction, and interference.'
      ]
    };
  }

  return null;
}

function buildWifiWeakSignalDiagnostics({ byRobot = [], byTarget = [] } = {}) {
  const robotDiagnostics = byRobot
    .filter((row) => numberValue(row.weak_signal_sample_count) > 0)
    .map(robotDiagnostic);
  const targetDiagnostics = byTarget
    .filter((row) => numberValue(row.weak_signal_sample_count) > 0)
    .map(targetDiagnostic)
    .filter(Boolean);

  return [...robotDiagnostics, ...targetDiagnostics]
    .sort((left, right) => (
      right.priority - left.priority
      || numberValue(right.weak_signal_rate) - numberValue(left.weak_signal_rate)
      || numberValue(right.weak_signal_sample_count) - numberValue(left.weak_signal_sample_count)
      || String(left.scope_robot_code || left.scope_poi_target).localeCompare(String(right.scope_robot_code || right.scope_poi_target), 'en')
    ));
}

module.exports = {
  WIFI_WEAK_SIGNAL_RULE_VERSION,
  buildWifiWeakSignalDiagnostics
};
