'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { analyzeWorkload, buildAnalysis, diagnoseRobot } = require('../src/analysis-engine');

const now = '2026-07-28T10:00:00.000Z';

function robot(overrides = {}) {
  return {
    master_robot_id: 1,
    robot_code: 'AMR_01',
    robot_type: 'AMR',
    online_status: 'OFFLINE',
    status_event_time: '2026-07-28T09:40:00.000Z',
    battery_event_time: '2026-07-28T09:59:00.000Z',
    latest_wifi_time: '2026-07-28T09:59:00.000Z',
    battery_soc: 80,
    current_rssi: -55,
    charging_status: null,
    ...overrides
  };
}

test('fresh valid WiFi with stale status points to telemetry path, not WiFi loss', () => {
  const result = diagnoseRobot(robot(), { databaseCurrentTime: now, staleMinutes: 5 });
  assert.equal(result.confidence, 'MEDIUM');
  assert.deepEqual(result.ruleIds, ['DISCONNECT_WIFI_HEALTHY_STATUS_STALE']);
  assert.match(result.diagnosis, /telemetry path/i);
});

test('current RSSI zero is a high-confidence disconnect signal', () => {
  const result = diagnoseRobot(robot({ current_rssi: 0 }), { databaseCurrentTime: now, staleMinutes: 5 });
  assert.equal(result.confidence, 'HIGH');
  assert.deepEqual(result.ruleIds, ['DISCONNECT_WIFI_ZERO']);
});

test('fresh online robot with RSSI zero is not diagnosed as disconnected', () => {
  const result = diagnoseRobot(robot({
    online_status: 'ONLINE',
    status_event_time: '2026-07-28T09:59:00.000Z',
    current_rssi: 0,
    error_code: '1'
  }), { databaseCurrentTime: now, staleMinutes: 5 });
  assert.equal(result, null);
});

test('persistent unusable RSSI with current AP evidence raises a telemetry-quality diagnosis', () => {
  const result = diagnoseRobot(robot({
    online_status: 'ONLINE',
    status_event_time: '2026-07-28T09:59:00.000Z',
    current_rssi: null,
    raw_current_rssi: 0,
    current_wifi_quality: 0,
    current_wifi_ap: 'A4:88:73:9F:13:47',
    current_wifi_count: 5,
    wifi_sample_count: 28795,
    unusable_rssi_sample_count: 28795
  }), { databaseCurrentTime: now, staleMinutes: 5 });

  assert.equal(result.confidence, 'HIGH');
  assert.equal(result.severity, 'WARNING');
  assert.deepEqual(result.ruleIds, ['WIFI_RSSI_MEASUREMENT_UNAVAILABLE']);
  assert.match(result.diagnosis, /signal quality analysis is blocked/i);
});

test('boolean emergency-state values are not treated as device fault codes', () => {
  const result = diagnoseRobot(robot({
    online_status: 'ONLINE',
    status_event_time: '2026-07-28T09:59:00.000Z',
    error_code: '1',
    error_message: null
  }), { databaseCurrentTime: now, staleMinutes: 5 });
  assert.equal(result, null);
});

test('fresh low battery without charging outranks unresolved network evidence', () => {
  const result = diagnoseRobot(robot({
    battery_soc: 8,
    current_rssi: null,
    latest_wifi_time: null
  }), { databaseCurrentTime: now, staleMinutes: 5 });
  assert.deepEqual(result.ruleIds, ['DISCONNECT_LOW_BATTERY']);
  assert.match(result.diagnosis, /Low battery/i);
});

test('three stale source streams stopping together identify an upstream telemetry stop', () => {
  const result = diagnoseRobot(robot({
    status_event_time: '2026-07-28T08:00:00.000Z',
    latest_wifi_time: '2026-07-28T08:00:20.000Z',
    battery_event_time: '2026-07-28T08:00:40.000Z',
    current_rssi: null
  }), { databaseCurrentTime: now, staleMinutes: 5 });
  assert.equal(result.confidence, 'MEDIUM');
  assert.equal(result.severity, 'WARNING');
  assert.deepEqual(result.ruleIds, ['SOURCE_TELEMETRY_ALL_TOPICS_STOPPED']);
  assert.match(result.diagnosis, /upstream of the Web\/DWS serving layer/i);
  assert.equal(result.evidence.length, 4);
  assert.equal(result.recommendedActions.length, 4);
});

test('stale DWS refresh suppresses robot conclusions and raises a DWS timeout', () => {
  const result = diagnoseRobot(robot({
    data_freshness_status: 'DWS_REFRESH_TIMEOUT',
    status_dws_load_time: '2026-07-28T09:40:00.000Z',
    status_refresh_age_minutes: 20,
    current_status: null,
    battery_soc: null,
    current_rssi: null
  }), { databaseCurrentTime: now, staleMinutes: 30 });

  assert.equal(result.confidence, 'HIGH');
  assert.equal(result.severity, 'CRITICAL');
  assert.deepEqual(result.ruleIds, ['DWS_REFRESH_TIMEOUT']);
  assert.match(result.diagnosis, /serving-layer freshness failure/i);
  assert.match(result.diagnosis, /30-minute production threshold/i);
  assert.match(result.recommendedActions[1], /within 30 minutes/i);
  assert.doesNotMatch(result.diagnosis, /robot is offline$/i);
});

test('current DWS load with old source event raises an upstream source timeout', () => {
  const result = diagnoseRobot(robot({
    data_freshness_status: 'SOURCE_TIMEOUT',
    status_dws_load_time: '2026-07-28T09:59:00.000Z',
    status_event_time: '2026-07-28T09:30:00.000Z',
    current_status: null,
    battery_soc: null,
    current_rssi: null
  }), { databaseCurrentTime: now, staleMinutes: 10 });

  assert.equal(result.confidence, 'MEDIUM');
  assert.deepEqual(result.ruleIds, ['DWS_SOURCE_TIMEOUT']);
  assert.match(result.diagnosis, /upstream of DWS/i);
});

test('DWS event-to-load lag is reported without guessing power or WiFi cause', () => {
  const result = diagnoseRobot(robot({
    data_freshness_status: 'DWS_SOURCE_LAG',
    status_event_time: '2026-07-28T09:20:00.000Z',
    status_dws_load_time: '2026-07-28T09:59:00.000Z',
    status_pipeline_lag_minutes: 39,
    current_status: null,
    battery_soc: null,
    current_rssi: null
  }), { databaseCurrentTime: now, staleMinutes: 10 });

  assert.equal(result.confidence, 'HIGH');
  assert.deepEqual(result.ruleIds, ['DWS_SOURCE_LAG']);
  assert.match(result.diagnosis, /aggregation watermark/i);
  assert.doesNotMatch(result.diagnosis, /power loss|WiFi loss/i);
});

test('workload concentration is calculated within robot type', () => {
  const result = analyzeWorkload([
    { master_robot_id: 1, robot_code: 'AMR_01', robot_type: 'AMR', assigned_task_count: 90 },
    { master_robot_id: 2, robot_code: 'AMR_02', robot_type: 'AMR', assigned_task_count: 10 },
    { master_robot_id: 3, robot_code: 'AMR_03', robot_type: 'AMR', assigned_task_count: 0 }
  ], [
    robot(),
    robot({ master_robot_id: 2, robot_code: 'AMR_02' }),
    robot({ master_robot_id: 3, robot_code: 'AMR_03' })
  ]);
  assert.equal(result.severity, 'WARNING');
  assert.equal(result.groups[0].topRobotSharePercent, 90);
  assert.equal(result.groups[0].zeroTaskRobotCount, 1);
  assert.equal(result.groups[0].telemetryUnavailableZeroTaskRobotCount, 1);
  assert.equal(result.causeStatus, 'CAPACITY_EVIDENCE_LIMITED');
});

test('workload analysis separates unavailable peers from currently observable idle peers', () => {
  const result = analyzeWorkload([
    { master_robot_id: 1, robot_code: 'AMR_01', robot_type: 'AMR', assigned_task_count: 100 },
    { master_robot_id: 2, robot_code: 'AMR_02', robot_type: 'AMR', assigned_task_count: 0 },
    { master_robot_id: 3, robot_code: 'AMR_03', robot_type: 'AMR', assigned_task_count: 0 }
  ], [
    robot({ online_status: 'ONLINE', status_event_time: '2026-07-28T09:59:00.000Z', current_task_supported: true }),
    robot({ master_robot_id: 2, robot_code: 'AMR_02', online_status: 'ONLINE', status_event_time: '2026-07-28T09:59:00.000Z', current_task_supported: true, is_active_job: false, current_mode: 'START_MOTOR' }),
    robot({ master_robot_id: 3, robot_code: 'AMR_03', online_status: 'OFFLINE' })
  ]);
  assert.equal(result.groups[0].telemetryUnavailableZeroTaskRobotCount, 1);
  assert.equal(result.groups[0].currentlyObservableIdleRobotCount, 1);
  assert.equal(result.causeStatus, 'PARTIALLY_EXPLAINED');
  assert.equal(result.perRobot.find((row) => row.robotId === 'AMR_02').classification, 'OBSERVED_IDLE_OR_INELIGIBLE');
  assert.equal(result.perRobot.find((row) => row.robotId === 'AMR_03').classification, 'TELEMETRY_UNAVAILABLE');
});

test('analysis exposes unsupported metrics instead of inventing values', () => {
  const result = buildAnalysis({
    summary: { database_current_time: now },
    robots: [robot()],
    workloadRows: [],
    statusCoverageRows: [],
    readiness: { queue_row_count: 10, queue_duration_row_count: 0, subjob_row_count: 0 },
    staleMinutes: 5,
    window: { hours: 24, days: 1 }
  });
  const onTime = result.measurementGaps.find((gap) => gap.metric.startsWith('On-time'));
  const queue = result.measurementGaps.find((gap) => gap.metric === 'Queue waiting time');
  assert.equal(onTime.status, 'NOT_MEASURABLE');
  assert.equal(queue.status, 'NOT_MEASURABLE');
});

test('analysis exposes supported task, derived queue and coverage-aware battery metrics', () => {
  const result = buildAnalysis({
    summary: { database_current_time: now },
    robots: [robot()],
    workloadRows: [],
    statusCoverageRows: [],
    readiness: {
      queue_row_count: 10,
      queue_duration_row_count: 0,
      subjob_row_count: 0,
      dispatch_assignment_row_count: 2,
      dispatch_audit_field_count: 7,
      dispatch_audit_row_count: 0,
      operation_event_row_count: 15437,
      operation_event_robot_attributed_count: 15390,
      audit_watermark_source_count: 3,
      audit_sources_current_count: 3,
      incident_row_count: 0,
      incident_evidence_row_count: 0
    },
    taskTimingRows: [{
      master_robot_id: 1,
      robot_code: 'AMR_01',
      task_execution_count: 10,
      duration_complete_count: 10,
      duration_reference_count: 10,
      on_time_count: 9,
      avg_actual_duration_seconds: 30,
      max_actual_duration_seconds: 60
    }],
    queueWaitRows: [{
      master_robot_id: 1,
      robot_code: 'AMR_01',
      linked_queue_count: 10,
      avg_queue_wait_seconds: 20,
      max_queue_wait_seconds: 100,
      over_5_minute_queue_count: 0
    }],
    batteryAbove60Rows: [{
      master_robot_id: 1,
      robot_code: 'AMR_01',
      observed_seconds: 86400,
      above_60_seconds: 43200,
      above_60_time_share_percent: 50,
      window_coverage_percent: 100
    }],
    staleMinutes: 5,
    window: { hours: 24, days: 1 }
  });
  assert.equal(result.operationalMetrics.taskTiming.onTimeRatePercent, 90);
  assert.equal(result.operationalMetrics.queueWait.avgQueueWaitSeconds, 20);
  assert.equal(result.operationalMetrics.batteryAbove60.reliableCoverageRobotCount, 1);
  assert.equal(result.measurementGaps.find((gap) => gap.metric.startsWith('On-time')).status, 'SUPPORTED_WITH_ASSUMPTION');
  assert.equal(result.measurementGaps.find((gap) => gap.metric === 'Queue waiting time').status, 'SUPPORTED_WITH_DERIVATION');
  assert.equal(result.measurementGaps.find((gap) => gap.metric === 'Dispatch optimality').status, 'PARTIAL');
  assert.equal(result.measurementGaps.find((gap) => gap.metric === 'Unified event and incident audit trail').status, 'PARTIAL');
  assert.equal(result.eventAudit.operationEventCount, 15437);
});
