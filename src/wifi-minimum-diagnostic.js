'use strict';

const WIFI_WEAK_RSSI_THRESHOLD = -67;
const WIFI_MINIMUM_RULE_VERSION = '2026.07.30';

function numberValue(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function countValue(value) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : 0;
}

function scopeKey(scopeType, robotCode, poiTarget) {
  return [
    String(scopeType || 'ALL'),
    String(robotCode || ''),
    String(poiTarget || '')
  ].join('|');
}

function buildWifiMinimumDiagnostics({
  byTarget = [],
  byRobot = [],
  byRobotTarget = [],
  worstSamples = []
} = {}) {
  const targetByName = new Map(byTarget.map((row) => [String(row.poi_target), row]));
  const robotByCode = new Map(byRobot.map((row) => [String(row.robot_code), row]));
  const robotTargetByKey = new Map(
    byRobotTarget.map((row) => [
      `${String(row.robot_code)}|${String(row.poi_target)}`,
      row
    ])
  );

  return worstSamples.map((sample) => {
    const robotCode = String(sample.minimum_robot_code || '');
    const poiTarget = String(sample.minimum_poi_target || '');
    const target = targetByName.get(poiTarget) || {};
    const robot = robotByCode.get(robotCode) || {};
    const robotTarget = robotTargetByKey.get(`${robotCode}|${poiTarget}`) || {};
    const robotValidCount = countValue(robot.valid_signal_sample_count);
    const robotTargetValidCount = countValue(robotTarget.valid_signal_sample_count);
    const targetValidCount = countValue(target.valid_signal_sample_count);
    const targetRobotCount = countValue(target.robot_count);
    const robotTargetCount = countValue(robot.target_count);
    const robotMinimum = numberValue(robot.minimum_valid_rssi);
    const robotMaximum = numberValue(robot.maximum_valid_rssi);
    const robotAverage = numberValue(robot.average_valid_rssi);
    const targetAverage = numberValue(target.average_valid_rssi);
    const valueIsFixed = (
      robotValidCount >= 10
      && robotMinimum !== null
      && robotMaximum !== null
      && robotMinimum === robotMaximum
    );
    const multipleRobotsWeakAtTarget = (
      targetValidCount >= 20
      && targetRobotCount >= 2
      && targetAverage !== null
      && targetAverage <= WIFI_WEAK_RSSI_THRESHOLD
    );
    const oneRobotWeakAcrossTargets = (
      robotValidCount >= 20
      && robotTargetCount >= 2
      && robotAverage !== null
      && robotAverage <= WIFI_WEAK_RSSI_THRESHOLD
    );

    let ruleId;
    let confidence;
    let causeStatus;
    let cause;
    let evidence;
    let actions;

    if (valueIsFixed) {
      ruleId = 'WIFI_RSSI_VALUE_STUCK';
      confidence = 'HIGH';
      causeStatus = 'DATA_QUALITY_RISK';
      cause = `${robotCode} has the same minimum and maximum value of ${robotMinimum} dBm across ${robotValidCount} valid samples in the current window. This more likely reflects a long-term fixed RSSI publishing value and cannot confirm a sudden on-site signal drop.`;
      evidence = [
        `${robotCode}: ${robotValidCount} valid samples`,
        `Minimum = maximum = ${robotMinimum} dBm`,
        `${robotTargetCount} related target POIs`
      ];
      actions = [
        `First verify that ${robotCode}'s WiFi RSSI publishing process continues to refresh and that ODS raw values change over time.`,
        `Near ${poiTarget}, compare the robot operating-system and wireless-controller logs. If external readings change while ODS is fixed, repair the collection or publishing path.`,
        'After confirming that RSSI changes normally, retest before replacing an AP, antenna, or WiFi adapter.'
      ];
    } else if (multipleRobotsWeakAtTarget) {
      ruleId = 'WIFI_POINT_COVERAGE_RISK';
      confidence = 'MEDIUM';
      causeStatus = 'LIKELY_POINT_RISK';
      cause = `${poiTarget} is covered by ${targetRobotCount} robots and ${targetValidCount} valid samples, with an average of ${targetAverage} dBm. Weak signal at the same target POI across multiple robots supports a risk of AP coverage, obstruction, interference, or roaming handover in this area, but AP logs and on-site measurements are still required.`;
      evidence = [
        `${poiTarget}: ${targetRobotCount} robots covered`,
        `Target-POI average: ${targetAverage} dBm`,
        `${targetValidCount} valid target-POI samples`
      ];
      actions = [
        `At the minimum-value time, inspect AP association, roaming, retry, and channel-utilization logs near ${poiTarget}.`,
        `Schedule a retest at ${poiTarget} with another robot. If both are weak, inspect AP placement, transmit power, channel selection, and obstruction.`,
        `Retest the same route after adjustments and confirm that the target-POI average is above ${WIFI_WEAK_RSSI_THRESHOLD} dBm.`
      ];
    } else if (oneRobotWeakAcrossTargets) {
      ruleId = 'WIFI_ROBOT_SIDE_RISK';
      confidence = 'MEDIUM';
      causeStatus = 'LIKELY_ROBOT_RISK';
      cause = `${robotCode} averages ${robotAverage} dBm across ${robotTargetCount} target POIs and ${robotValidCount} valid samples. Consistently weak signal across POIs for one robot supports a risk in the antenna, feeder cable, WiFi adapter, or terminal roaming configuration, but hardware inspection has not confirmed it.`;
      evidence = [
        `${robotCode}: ${robotTargetCount} target POIs covered`,
        `Robot average: ${robotAverage} dBm`,
        `${robotTargetValidCount} samples at the current minimum target POI`
      ];
      actions = [
        `Retest ${poiTarget} with another robot. If only ${robotCode} is weak, move to robot-side checks.`,
        `Inspect ${robotCode}'s antenna connection, feeder cable, WiFi adapter, and roaming configuration, then compare wireless-controller records.`,
        'After repair, retest multiple target POIs; close this risk only after cross-POI averages recover.'
      ];
    } else {
      ruleId = 'WIFI_MINIMUM_CAUSE_UNRESOLVED';
      confidence = 'LOW';
      causeStatus = 'UNRESOLVED';
      cause = `The current evidence confirms only that ${robotCode} produced the minimum RSSI in this window. The available samples cannot distinguish a brief fluctuation, target-POI coverage issue, or robot-side issue.`;
      evidence = [
        `${poiTarget}: ${targetRobotCount} robots covered`,
        `${targetValidCount} valid target-POI samples`,
        `${robotCode}: ${robotValidCount} valid samples`
      ];
      actions = [
        `Schedule a retest at ${poiTarget} with ${robotCode} and another robot to compare one robot across POIs and multiple robots at one POI.`,
        'At the minimum-value time, inspect robot and wireless-controller logs for roaming, retries, disconnects, and channel utilization.',
        'Do not directly replace the AP, antenna, or WiFi adapter before repeat evidence is available.'
      ];
    }

    return {
      scope_type: String(sample.scope_type || 'ALL'),
      scope_robot_code: sample.scope_robot_code || null,
      scope_poi_target: sample.scope_poi_target || null,
      scope_key: scopeKey(sample.scope_type, sample.scope_robot_code, sample.scope_poi_target),
      robot_code: robotCode,
      poi_target: poiTarget,
      event_time: sample.minimum_event_time || null,
      minimum_rssi: numberValue(sample.minimum_rssi),
      rule_id: ruleId,
      rule_version: WIFI_MINIMUM_RULE_VERSION,
      confidence,
      cause_status: causeStatus,
      cause,
      evidence,
      actions
    };
  });
}

module.exports = {
  WIFI_WEAK_RSSI_THRESHOLD,
  WIFI_MINIMUM_RULE_VERSION,
  buildWifiMinimumDiagnostics,
  scopeKey
};
