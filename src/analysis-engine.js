'use strict';

const RULE_VERSION = '2026.07.7';

const SEVERITY_RANK = {
  CRITICAL: 4,
  WARNING: 3,
  WATCH: 2,
  HEALTHY: 1,
  INFO: 0
};

function number(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function hasValue(value) {
  return value !== null && value !== undefined && String(value).trim() !== '';
}

function minutesBetween(earlier, later) {
  if (!earlier || !later) return Number.POSITIVE_INFINITY;
  const start = new Date(earlier);
  const end = new Date(later);
  if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) return Number.POSITIVE_INFINITY;
  return Math.max(0, (end.getTime() - start.getTime()) / 60000);
}

function timestampSpreadMinutes(values) {
  const timestamps = values
    .map((value) => new Date(value).getTime())
    .filter((value) => Number.isFinite(value));
  if (timestamps.length !== values.length) return Number.POSITIVE_INFINITY;
  return (Math.max(...timestamps) - Math.min(...timestamps)) / 60000;
}

function isTruthy(value) {
  return value === true || value === 1 || value === '1';
}

function isDeviceError(robot) {
  const code = String(robot.error_code || '').trim().toUpperCase();
  const message = String(robot.error_message || '').trim().toUpperCase();
  /*
      Legacy operational data mapped robot_emer_status into error_code.
      Live source evidence shows both 0 and 1 on normally reporting robots, so a
      bare 0/1 value is an emergency-state flag, not a validated fault code.
      A nonempty error message or a non-boolean code is required for diagnosis.
  */
  return !['', '-', '0', '1', 'NULL', 'UNDEFINED', 'NONE', 'FALSE', 'TRUE', 'OK', 'NORMAL'].includes(code)
    || !['', '-', 'NULL', 'UNDEFINED', 'NONE'].includes(message);
}

function isCharging(robot) {
  const value = String(robot.charging_status || '').trim().toUpperCase();
  const mode = String(robot.current_mode || '').trim().toUpperCase();
  return ['C', 'CHARGING', 'TRUE', '1', 'ON'].includes(value) || mode.includes('CHARGE');
}

function robotName(robot) {
  return String(robot.robot_code || robot.robot_name || `Master ${robot.master_robot_id}`);
}

function makeDiagnostic(robot, input) {
  return {
    robotId: robotName(robot),
    masterRobotId: robot.master_robot_id,
    robotType: robot.robot_type || 'OTHER',
    phenomenon: input.phenomenon,
    diagnosis: input.diagnosis,
    confidence: input.confidence,
    severity: input.severity,
    evidence: input.evidence,
    recommendedActions: input.recommendedActions,
    alternativeCauses: input.alternativeCauses || [],
    ruleIds: input.ruleIds || []
  };
}

function diagnoseRobot(robot, context) {
  const now = context.databaseCurrentTime;
  const staleMinutes = context.staleMinutes;
  const statusTime = robot.status_event_time || robot.source_event_time;
  const statusAge = minutesBetween(statusTime, now);
  const wifiAge = minutesBetween(robot.latest_wifi_time, now);
  const batteryAge = minutesBetween(robot.battery_event_time, now);
  const statusStale = statusAge > staleMinutes;
  const wifiFresh = wifiAge <= staleMinutes;
  const wifiZero = hasValue(robot.current_rssi) && number(robot.current_rssi) === 0;
  const wifiGood = wifiFresh && hasValue(robot.current_rssi) && number(robot.current_rssi) < 0;
  const rawWifiZero = hasValue(robot.raw_current_rssi) && number(robot.raw_current_rssi) === 0;
  const wifiSampleCount = number(robot.wifi_sample_count);
  const unusableRssiSampleCount = number(robot.unusable_rssi_sample_count);
  const unusableRssiRate = wifiSampleCount > 0
    ? 100 * unusableRssiSampleCount / wifiSampleCount
    : 0;
  const currentAccessPoint = String(robot.current_wifi_ap || '').trim();
  const hasAssociationEvidence = (
    currentAccessPoint !== ''
    && currentAccessPoint !== '-'
  ) || number(robot.current_wifi_count) > 0;
  const rssiMeasurementUnavailable = wifiFresh
    && rawWifiZero
    && !hasValue(robot.current_rssi)
    && hasAssociationEvidence
    && wifiSampleCount >= 100
    && unusableRssiRate >= 95;
  const lowBattery = hasValue(robot.battery_soc) && number(robot.battery_soc) >= 0 && number(robot.battery_soc) <= 20;
  const batteryFresh = batteryAge <= Math.max(staleMinutes, 15);
  const explicitError = isDeviceError(robot);
  const offline = String(robot.online_status || '').trim().toUpperCase() !== 'ONLINE';
  const disconnected = offline || statusStale;
  const freshnessStatus = String(robot.data_freshness_status || robot.status_freshness_status || '').trim().toUpperCase();
  const statusRefreshAge = hasValue(robot.status_refresh_age_minutes)
    ? number(robot.status_refresh_age_minutes)
    : minutesBetween(robot.status_dws_load_time || robot.dws_load_time, now);
  const statusPipelineLag = hasValue(robot.status_pipeline_lag_minutes)
    ? number(robot.status_pipeline_lag_minutes)
    : minutesBetween(statusTime, robot.status_dws_load_time || robot.dws_load_time);

  if (freshnessStatus === 'DWS_REFRESH_TIMEOUT') {
    return makeDiagnostic(robot, {
      phenomenon: 'DWS data refresh timeout',
      diagnosis: `The non-snapshot DWS status aggregate has not refreshed within the ${staleMinutes}-minute production threshold. Last-known robot values are intentionally suppressed; this proves a DWS serving-layer freshness failure, not that the robot is offline.`,
      confidence: 'HIGH',
      severity: 'CRITICAL',
      evidence: [
        `Latest DWS status load: ${robot.status_dws_load_time || robot.dws_load_time || 'not available'}.`,
        `DWS refresh age: ${Number.isFinite(statusRefreshAge) ? statusRefreshAge.toFixed(1) : 'unknown'} minutes; threshold: ${staleMinutes} minutes.`,
        `Latest status event retained in DWS: ${statusTime || 'not available'}.`,
        'Current status, battery, position and task values are not taken from the operational snapshot.'
      ],
      recommendedActions: [
        'Inspect the latest DWS.etl_batch and DWS.etl_load_log rows to locate the failed or missing status/battery/WiFi aggregation step.',
        `Restore the authorized DWS incremental refresh schedule and verify that each target table receives a new successful load within ${staleMinutes} minutes.`,
        'After DWS refresh recovers, re-run the freshness gate before investigating individual robot power, WiFi or publisher causes.'
      ],
      alternativeCauses: [
        'Scheduled DWS refresh is not running.',
        'A DWD-to-DWS aggregation step failed or is blocked.',
        'SQL Server Agent permission or scheduling remains unavailable.'
      ],
      ruleIds: ['DWS_REFRESH_TIMEOUT']
    });
  }

  if (freshnessStatus === 'DWS_SOURCE_LAG') {
    return makeDiagnostic(robot, {
      phenomenon: 'DWS source-to-load lag exceeded',
      diagnosis: `The DWS table was refreshed, but the newest source event retained by the aggregate is more than ${staleMinutes} minutes behind its DWS load time. This identifies a delayed warehouse input or aggregation watermark; it does not identify robot power or WiFi as the cause.`,
      confidence: 'HIGH',
      severity: 'WARNING',
      evidence: [
        `Latest status event retained in DWS: ${statusTime || 'not available'}.`,
        `Latest DWS status load: ${robot.status_dws_load_time || robot.dws_load_time || 'not available'}.`,
        `Event-to-load lag: ${Number.isFinite(statusPipelineLag) ? statusPipelineLag.toFixed(1) : 'unknown'} minutes; threshold: ${staleMinutes} minutes.`
      ],
      recommendedActions: [
        'Compare the DWD status watermark with the DWS status-hourly source_max_fact_id.',
        'Inspect late or failed DWD-to-DWS batches and clear blocking before retrying the bounded incremental load.',
        'Only investigate the individual robot after a current DWS batch still shows its source event timing out.'
      ],
      alternativeCauses: [
        'DWD incremental watermark is behind.',
        'DWS hourly aggregation skipped or partially loaded the recent window.',
        'The upstream source stopped before the current DWS load.'
      ],
      ruleIds: ['DWS_SOURCE_LAG']
    });
  }

  if (freshnessStatus === 'SOURCE_TIMEOUT') {
    return makeDiagnostic(robot, {
      phenomenon: 'Source data timeout in DWS',
      diagnosis: `The DWS aggregate refreshed within ${staleMinutes} minutes, but this robot has no status event within the same threshold. The timeout is upstream of DWS; available evidence cannot distinguish robot power loss, network loss or a stopped telemetry publisher.`,
      confidence: 'MEDIUM',
      severity: 'WARNING',
      evidence: [
        `Latest status event retained in DWS: ${statusTime || 'not available'}.`,
        `Status data age: ${Number.isFinite(statusAge) ? statusAge.toFixed(1) : 'unknown'} minutes; threshold: ${staleMinutes} minutes.`,
        `Latest DWS status load: ${robot.status_dws_load_time || robot.dws_load_time || 'not available'}.`
      ],
      recommendedActions: [
        'Confirm the robot is powered and check its local display.',
        'Check WiFi-controller association and the robot telemetry publisher/collector logs.',
        `Confirm recovery only after a new source event reaches the non-snapshot DWS aggregate within ${staleMinutes} minutes.`
      ],
      alternativeCauses: [
        'Robot power loss',
        'Robot network loss',
        'Robot-side telemetry publisher stopped',
        'Central collector stopped or excluded this robot'
      ],
      ruleIds: ['DWS_SOURCE_TIMEOUT']
    });
  }

  if (freshnessStatus === 'MISSING') {
    return makeDiagnostic(robot, {
      phenomenon: 'DWS status data missing',
      diagnosis: 'No non-snapshot DWS status aggregate can be matched to this enabled robot. Current operating values are unavailable and no cause can be assigned until the identity mapping or load gap is resolved.',
      confidence: 'HIGH',
      severity: 'WARNING',
      evidence: [
        `Master robot ID: ${robot.master_robot_id}.`,
        `Robot code: ${robotName(robot)}.`,
        'No matching DWS status event/load timestamp is available.'
      ],
      recommendedActions: [
        'Check whether DWS uses the MA_AMR name or numeric ID for this robot_code.',
        'Verify DWD contains status facts for the same MA_AMR.id.',
        'Repair the mapping or bounded load, then re-run the freshness gate.'
      ],
      alternativeCauses: ['Robot has never reported status data', 'DWS identity mapping mismatch', 'DWS row was not loaded'],
      ruleIds: ['DWS_STATUS_MISSING']
    });
  }

  if (disconnected && wifiFresh && wifiZero) {
    return makeDiagnostic(robot, {
      phenomenon: 'Disconnected / status data delayed',
      diagnosis: 'Wireless signal loss is the most likely immediate cause.',
      confidence: 'HIGH',
      severity: 'CRITICAL',
      evidence: [
        `Status data age: ${Number.isFinite(statusAge) ? statusAge.toFixed(1) : 'unknown'} minutes (rule threshold ${staleMinutes} minutes).`,
        `WiFi sample is current but its RSSI is 0 (${Number.isFinite(wifiAge) ? wifiAge.toFixed(1) : 'unknown'} minutes old).`,
        robot.current_wifi_ap ? `Last access point: ${robot.current_wifi_ap}.` : 'The zero-signal sample has no access point attribution.'
      ],
      recommendedActions: [
        'Inspect the robot antenna, WiFi module and power connection.',
        'Check coverage and roaming around the robot’s last known position.',
        'After signal recovery, verify that status timestamps resume before returning the robot to production.'
      ],
      alternativeCauses: lowBattery ? ['Low battery may also have contributed to the disconnect.'] : [],
      ruleIds: ['DISCONNECT_WIFI_ZERO']
    });
  }

  if (disconnected && lowBattery && batteryFresh && !isCharging(robot)) {
    return makeDiagnostic(robot, {
      phenomenon: 'Disconnected / status data delayed',
      diagnosis: 'Low battery without a current charging indication is the strongest available cause.',
      confidence: wifiGood ? 'MEDIUM' : 'HIGH',
      severity: 'CRITICAL',
      evidence: [
        `Battery is ${number(robot.battery_soc).toFixed(1)}% and the battery sample is ${batteryAge.toFixed(1)} minutes old.`,
        'No current charging state was detected.',
        wifiGood ? `WiFi is still reporting ${number(robot.current_rssi)} dBm, which weakens the WiFi-loss hypothesis.` : 'There is no current valid WiFi signal that can exclude network loss.'
      ],
      recommendedActions: [
        'Move the robot to a charger or inspect automatic charging contact and alignment.',
        'Check battery voltage/current and compare charge acceptance with a healthy robot.',
        'Confirm status telemetry returns after the battery recovers.'
      ],
      alternativeCauses: ['WiFi or the telemetry service may also be unavailable if their samples are stale.'],
      ruleIds: ['DISCONNECT_LOW_BATTERY']
    });
  }

  if (disconnected && wifiGood) {
    return makeDiagnostic(robot, {
      phenomenon: 'Disconnected / status data delayed',
      diagnosis: 'The robot still reports valid WiFi; the status collection or telemetry path is more likely delayed than radio coverage.',
      confidence: 'MEDIUM',
      severity: 'WARNING',
      evidence: [
        `Status data is ${Number.isFinite(statusAge) ? statusAge.toFixed(1) : 'unknown'} minutes old.`,
        `WiFi is ${wifiAge.toFixed(1)} minutes old with RSSI ${number(robot.current_rssi)} dBm.`,
        'Fresh WiFi and stale status are from different source paths, so WiFi availability does not prove the robot application is healthy.'
      ],
      recommendedActions: [
        'Check the robot status publisher/service and its process logs.',
        'Verify the status ingestion job and non-snapshot DWS load timestamps.',
        'Do not replace the antenna unless packet loss or roaming evidence also points to radio failure.'
      ],
      alternativeCauses: explicitError ? ['A last-known device error is also present and should be inspected.'] : [],
      ruleIds: ['DISCONNECT_WIFI_HEALTHY_STATUS_STALE']
    });
  }

  const allSourceStreamsStale = statusStale
    && wifiAge > staleMinutes
    && batteryAge > Math.max(staleMinutes, 15);
  const sourceStopSpreadMinutes = timestampSpreadMinutes([
    statusTime,
    robot.latest_wifi_time,
    robot.battery_event_time
  ]);

  if (disconnected && allSourceStreamsStale && sourceStopSpreadMinutes <= 2) {
    const latestSourceStopTime = [statusTime, robot.latest_wifi_time, robot.battery_event_time]
      .map((value) => new Date(value))
      .sort((a, b) => b.getTime() - a.getTime())[0]
      .toISOString();
    return makeDiagnostic(robot, {
      phenomenon: 'All robot telemetry streams stopped together',
      diagnosis: 'Status, WiFi and battery source telemetry stopped within the same two-minute interval. The failure is upstream of the Web/DWS serving layer, but current evidence cannot distinguish robot power loss, robot network loss or a stopped publisher/collector.',
      confidence: 'MEDIUM',
      severity: 'WARNING',
      evidence: [
        `Last status sample: ${statusTime}.`,
        `Last WiFi sample: ${robot.latest_wifi_time}.`,
        `Last battery sample: ${robot.battery_event_time}.`,
        `The three source timestamps stopped ${sourceStopSpreadMinutes.toFixed(1)} minutes apart; latest stop time ${latestSourceStopTime}.`
      ],
      recommendedActions: [
        'Check the robot power indicator and local display; if both are off, inspect battery isolation, contactors and emergency stop.',
        'If the robot is powered, verify its association and last-seen time in the WiFi controller/AP instead of relying on ICMP ping.',
        'If network association is current, inspect or restart the robot-side telemetry publisher and the central collector for this robot.',
        'Confirm recovery only after new rows resume in status, WiFi and battery source tables.'
      ],
      alternativeCauses: [
        'Robot power loss',
        'Robot WiFi association or routing loss',
        'Robot-side telemetry publisher stopped',
        'Central collector stopped or excluded this robot'
      ],
      ruleIds: ['SOURCE_TELEMETRY_ALL_TOPICS_STOPPED']
    });
  }

  if (disconnected) {
    const evidence = [
      `Status data is ${Number.isFinite(statusAge) ? statusAge.toFixed(1) : 'unavailable'} minutes old.`,
      Number.isFinite(wifiAge)
        ? `WiFi data is also ${wifiAge.toFixed(1)} minutes old.`
        : 'No WiFi timestamp is available.',
      lowBattery
        ? `Last-known battery is ${number(robot.battery_soc).toFixed(1)}%, but its freshness is insufficient to prove causation.`
        : 'No current low-battery evidence is available.'
    ];
    return makeDiagnostic(robot, {
      phenomenon: 'Disconnected / status data delayed',
      diagnosis: 'The cause is unresolved because the status and network evidence are both missing or stale.',
      confidence: 'LOW',
      severity: 'WARNING',
      evidence,
      recommendedActions: [
        'Check physical power and the robot display first.',
        'Then check WiFi association, the telemetry process and upstream ingestion in that order.',
        'Record the confirmed cause so the rule can be tightened with future evidence.'
      ],
      alternativeCauses: ['Power loss', 'WiFi loss', 'robot application stopped', 'telemetry ingestion delay'],
      ruleIds: ['DISCONNECT_EVIDENCE_STALE']
    });
  }

  if (explicitError) {
    return makeDiagnostic(robot, {
      phenomenon: 'Device-reported error',
      diagnosis: hasValue(robot.error_message) ? String(robot.error_message).trim() : `Device error code ${robot.error_code}`,
      confidence: 'HIGH',
      severity: 'CRITICAL',
      evidence: [
        `Error code: ${robot.error_code || 'not supplied'}.`,
        `Error message: ${robot.error_message || 'not supplied'}.`,
        `Status source time: ${statusTime || 'not supplied'}.`
      ],
      recommendedActions: [
        'Follow the manufacturer procedure for the reported code/message.',
        'Clear the fault only after checking the affected sensor, actuator or emergency circuit.',
        'Confirm the error remains cleared in a new status sample.'
      ],
      ruleIds: ['DEVICE_ERROR_EXPLICIT']
    });
  }

  if (lowBattery) {
    return makeDiagnostic(robot, {
      phenomenon: 'Low battery risk',
      diagnosis: isCharging(robot)
        ? 'Battery is low, but a charging state is currently reported.'
        : 'Battery is low and no charging state is currently reported.',
      confidence: batteryFresh ? 'HIGH' : 'MEDIUM',
      severity: isCharging(robot) ? 'WATCH' : 'WARNING',
      evidence: [
        `Battery is ${number(robot.battery_soc).toFixed(1)}%.`,
        `Battery sample age: ${Number.isFinite(batteryAge) ? batteryAge.toFixed(1) : 'unknown'} minutes.`,
        `Charging state: ${robot.charging_status || robot.current_mode || 'not reported'}.`
      ],
      recommendedActions: isCharging(robot)
        ? ['Monitor charge current and confirm state-of-charge rises.', 'Inspect contacts if the level remains flat.']
        : ['Send the robot to charge.', 'Inspect charger availability, alignment and charging contacts.'],
      ruleIds: ['LOW_BATTERY_CURRENT']
    });
  }

  if (rssiMeasurementUnavailable) {
    return makeDiagnostic(robot, {
      phenomenon: 'WiFi signal measurement unavailable',
      diagnosis: 'The robot is still publishing WiFi association/scan evidence, but its RSSI measurement remains the unusable sentinel value 0. Signal quality analysis is blocked until the robot-side collector reports a valid negative RSSI.',
      confidence: 'HIGH',
      severity: 'WARNING',
      evidence: [
        `The latest WiFi sample is ${Number.isFinite(wifiAge) ? wifiAge.toFixed(1) : 'unknown'} minutes old, so this is not a stale-data artifact.`,
        `Raw RSSI is 0 and WiFi quality is ${hasValue(robot.current_wifi_quality) ? number(robot.current_wifi_quality) : 'not reported'}.`,
        `${unusableRssiSampleCount} of ${wifiSampleCount} samples (${unusableRssiRate.toFixed(1)}%) in the selected WiFi window have unusable RSSI.`,
        currentAccessPoint && currentAccessPoint !== '-'
          ? `Association evidence remains present at access point ${currentAccessPoint}; ${number(robot.current_wifi_count)} networks were reported in the latest scan.`
          : `${number(robot.current_wifi_count)} networks were reported in the latest scan.`
      ],
      recommendedActions: [
        'Inspect the robot-side WiFi telemetry collector and confirm that it reads RSSI from the active adapter rather than returning the sentinel value 0.',
        'Compare the WiFi driver, adapter selection, service account permissions and collector configuration with a robot that reports valid negative RSSI.',
        'Verify recovery only when new source rows contain negative wifi_signal_level values; do not infer signal quality from the AP address alone.'
      ],
      alternativeCauses: [
        'The WiFi adapter or driver does not expose RSSI to the collector.',
        'The collector is querying the wrong adapter or unsupported API.',
        'A source-field conversion or robot-side sampling defect is replacing unavailable RSSI with 0.'
      ],
      ruleIds: ['WIFI_RSSI_MEASUREMENT_UNAVAILABLE']
    });
  }

  return null;
}

function median(values) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function analyzeWorkload(workloadRows, robots) {
  const robotById = new Map(robots.map((robot) => [String(robot.master_robot_id), robot]));
  const rows = workloadRows.map((row) => ({
    ...row,
    assignedTaskCount: number(row.assigned_task_count),
    completedTaskCount: number(row.completed_task_count),
    unsuccessfulTaskCount: number(row.unsuccessful_task_count)
  }));
  const types = [...new Set(rows.map((row) => row.robot_type))];
  const groups = types.map((type) => {
    const typeRows = rows.filter((row) => row.robot_type === type);
    const total = typeRows.reduce((sum, row) => sum + row.assignedTaskCount, 0);
    const top = [...typeRows].sort((a, b) => b.assignedTaskCount - a.assignedTaskCount)[0];
    const nonzero = typeRows.filter((row) => row.assignedTaskCount > 0).map((row) => row.assignedTaskCount);
    const zeroTaskRows = typeRows.filter((row) => row.assignedTaskCount === 0);
    const currentOnlineZeroTaskRows = zeroTaskRows.filter((row) => {
      const robot = robotById.get(String(row.master_robot_id)) || {};
      return String(robot.online_status || '').toUpperCase() === 'ONLINE'
        && isTruthy(robot.current_task_supported);
    });
    const chargingZeroTaskRows = currentOnlineZeroTaskRows.filter((row) => (
      isCharging(robotById.get(String(row.master_robot_id)) || {})
    ));
    const currentlyObservableIdleRows = currentOnlineZeroTaskRows.filter((row) => {
      const robot = robotById.get(String(row.master_robot_id)) || {};
      return !isCharging(robot) && !isDeviceError(robot) && !robot.is_active_job;
    });
    const telemetryUnavailableZeroTaskCount = zeroTaskRows.length - currentOnlineZeroTaskRows.length;
    return {
      robotType: type,
      robotCount: typeRows.length,
      totalAssignedTasks: total,
      zeroTaskRobotCount: zeroTaskRows.length,
      currentOnlineZeroTaskRobotCount: currentOnlineZeroTaskRows.length,
      telemetryUnavailableZeroTaskRobotCount: telemetryUnavailableZeroTaskCount,
      chargingZeroTaskRobotCount: chargingZeroTaskRows.length,
      currentlyObservableIdleRobotCount: currentlyObservableIdleRows.length,
      topRobotId: top?.robot_code || null,
      topRobotTaskCount: top?.assignedTaskCount || 0,
      topRobotSharePercent: total > 0 ? Number(((top.assignedTaskCount / total) * 100).toFixed(1)) : 0,
      medianActiveRobotTasks: median(nonzero),
      driverSummary: zeroTaskRows.length === 0
        ? 'Every robot has at least one assignment in the selected window.'
        : `${telemetryUnavailableZeroTaskCount} zero-task peers have no current telemetry; ${currentlyObservableIdleRows.length} are currently online, not charging and have no active job.`
    };
  });

  const perRobot = rows.map((row) => {
    const group = groups.find((item) => item.robotType === row.robot_type);
    const robot = robotById.get(String(row.master_robot_id)) || {};
    let classification = 'BALANCED';
    let explanation = 'Task volume is within the observed range for this robot type.';
    let nextCheck = 'Continue monitoring over a comparable production window.';

    if (group.totalAssignedTasks === 0) {
      classification = 'NO_DATA';
      explanation = 'No task assignment was recorded for this robot type in the selected window.';
      nextCheck = 'Verify job-history coverage and whether this robot type is expected to receive production tasks.';
    } else if (row.assignedTaskCount === 0) {
      classification = 'OBSERVED_IDLE_OR_INELIGIBLE';
      if (String(robot.online_status || '').toUpperCase() !== 'ONLINE' || !isTruthy(robot.current_task_supported)) {
        classification = 'TELEMETRY_UNAVAILABLE';
        explanation = String(robot.online_status || '').toUpperCase() !== 'ONLINE'
          ? 'No tasks were assigned, but current DWS evidence is delayed; the dashboard cannot prove that this robot was idle or dispatch-eligible.'
          : 'No tasks were assigned, but the non-snapshot DWS tables do not contain current task or eligibility state; idle status cannot be proven.';
        nextCheck = String(robot.online_status || '').toUpperCase() !== 'ONLINE'
          ? 'Restore DWS freshness first. Then compare dispatch eligibility during the same production window.'
          : 'Use dispatch candidate/eligibility audit data from the assignment time; do not infer idle from a zero task total.';
      } else if (isCharging(robot)) {
        classification = 'CURRENTLY_CHARGING_NO_TASK';
        explanation = 'No tasks were assigned, and the current freshness-gated data indicates charging.';
        nextCheck = 'Verify historical charge intervals overlap the task window before attributing zero assignments to charging.';
      } else if (isDeviceError(robot)) {
        classification = 'CURRENT_ERROR_NO_TASK';
        explanation = 'No tasks were assigned, and a device error is currently reported.';
        nextCheck = 'Resolve the device error, then confirm candidate-pool re-entry in dispatch audit logs.';
      } else {
        explanation = `No tasks were assigned although the robot is currently online with no active job (${robot.current_mode || robot.current_status || 'mode unavailable'}).`;
        nextCheck = 'Inspect dispatch eligibility, task/robot capability mapping, priority, zone and candidate-score/rejection logs for the same task window.';
      }
    } else if (
      group.totalAssignedTasks > 0
      && group.topRobotId === row.robot_code
      && group.topRobotSharePercent >= 60
      && group.robotCount >= 3
    ) {
      classification = 'CONCENTRATED';
      explanation = `This robot received ${group.topRobotSharePercent.toFixed(1)}% of ${row.robot_type} assignments.`;
      nextCheck = 'Compare candidate eligibility, location, priority and dispatch score against underused peers.';
    }

    return {
      robotId: row.robot_code,
      masterRobotId: row.master_robot_id,
      robotType: row.robot_type,
      assignedTaskCount: row.assignedTaskCount,
      completedTaskCount: row.completedTaskCount,
      unsuccessfulTaskCount: row.unsuccessfulTaskCount,
      classification,
      explanation,
      nextCheck
    };
  });

  const concentrated = groups.filter((group) => group.topRobotSharePercent >= 60 && group.robotCount >= 3 && group.totalAssignedTasks > 0);
  const totalZero = groups.reduce((sum, group) => sum + group.zeroTaskRobotCount, 0);
  const unavailableZero = groups.reduce((sum, group) => sum + group.telemetryUnavailableZeroTaskRobotCount, 0);
  const observableIdle = groups.reduce((sum, group) => sum + group.currentlyObservableIdleRobotCount, 0);
  const causeStatus = concentrated.length
    ? (observableIdle > 0 ? 'PARTIALLY_EXPLAINED' : (unavailableZero > 0 ? 'CAPACITY_EVIDENCE_LIMITED' : 'UNRESOLVED'))
    : 'NO_SEVERE_CONCENTRATION';
  return {
    severity: concentrated.length ? 'WARNING' : (totalZero ? 'WATCH' : 'HEALTHY'),
    title: concentrated.length ? 'Task assignment is materially concentrated.' : 'No severe assignment concentration was detected.',
    summary: concentrated.length
      ? concentrated.map((group) => `${group.robotType}: ${group.topRobotId} holds ${group.topRobotSharePercent.toFixed(1)}% of assignments; ${group.zeroTaskRobotCount} robots received none. ${group.driverSummary}`).join(' ')
      : `${totalZero} robots received no tasks in the selected window.`,
    causeStatus,
    causeExplanation: concentrated.length
      ? `${unavailableZero} zero-task peers lack current telemetry, so unavailable fleet capacity is a supported contributor. ${observableIdle} zero-task peers are currently observable and idle, so their eligibility and dispatch score require audit. Current state does not prove historical eligibility; optimality still requires candidate, priority, zone and score/rejection logs from the assignment time.`
      : 'The distribution is verified. Optimality still requires candidate, priority, zone and score/rejection logs from the assignment time.',
    groups,
    perRobot
  };
}

function summarizeOperationalMetrics(taskTimingRows, queueWaitRows, batteryAbove60Rows, routeSegmentRows) {
  const taskRows = taskTimingRows.map((row) => ({
    ...row,
    taskExecutionCount: number(row.task_execution_count),
    durationCompleteCount: number(row.duration_complete_count),
    durationReferenceCount: number(row.duration_reference_count),
    onTimeCount: number(row.on_time_count),
    avgActualDurationSeconds: number(row.avg_actual_duration_seconds),
    maxActualDurationSeconds: number(row.max_actual_duration_seconds),
    over1HourDurationCount: number(row.over_1_hour_duration_count)
  }));
  const taskDurationCompleteCount = taskRows.reduce((sum, row) => sum + row.durationCompleteCount, 0);
  const taskDurationReferenceCount = taskRows.reduce((sum, row) => sum + row.durationReferenceCount, 0);
  const onTimeCount = taskRows.reduce((sum, row) => sum + row.onTimeCount, 0);
  const weightedTaskDurationSeconds = taskRows.reduce(
    (sum, row) => sum + (row.avgActualDurationSeconds * row.durationCompleteCount),
    0
  );

  const queueRows = queueWaitRows.map((row) => ({
    ...row,
    linkedQueueCount: number(row.linked_queue_count),
    avgQueueWaitSeconds: number(row.avg_queue_wait_seconds),
    maxQueueWaitSeconds: number(row.max_queue_wait_seconds),
    over5MinuteQueueCount: number(row.over_5_minute_queue_count)
  }));
  const linkedQueueCount = queueRows.reduce((sum, row) => sum + row.linkedQueueCount, 0);
  const weightedQueueWaitSeconds = queueRows.reduce(
    (sum, row) => sum + (row.avgQueueWaitSeconds * row.linkedQueueCount),
    0
  );

  const batteryRows = batteryAbove60Rows.map((row) => ({
    ...row,
    observedSeconds: number(row.observed_seconds),
    above60Seconds: number(row.above_60_seconds),
    above60TimeSharePercent: number(row.above_60_time_share_percent),
    windowCoveragePercent: number(row.window_coverage_percent)
  }));
  const reliableBatteryRows = batteryRows.filter((row) => row.windowCoveragePercent >= 80);
  const routeRows = routeSegmentRows.map((row) => ({
    ...row,
    completedSegmentCount: number(row.completed_segment_count),
    avgSegmentDurationSeconds: number(row.avg_segment_duration_seconds),
    maxSegmentDurationSeconds: number(row.max_segment_duration_seconds)
  }));
  const loadingPattern = /(LOAD|UNLOAD|PICK|DROP|上料|下料|取料|放料)/i;

  return {
    taskTiming: {
      taskExecutionCount: taskRows.reduce((sum, row) => sum + row.taskExecutionCount, 0),
      durationCompleteCount: taskDurationCompleteCount,
      durationReferenceCount: taskDurationReferenceCount,
      durationReferenceRobotCount: taskRows.filter((row) => row.durationReferenceCount > 0).length,
      onTimeCount,
      onTimeRatePercent: taskDurationReferenceCount
        ? Number(((onTimeCount / taskDurationReferenceCount) * 100).toFixed(2))
        : null,
      avgActualDurationSeconds: taskDurationCompleteCount
        ? Number((weightedTaskDurationSeconds / taskDurationCompleteCount).toFixed(2))
        : null,
      maxActualDurationSeconds: taskRows.reduce((max, row) => Math.max(max, row.maxActualDurationSeconds), 0),
      over1HourDurationCount: taskRows.reduce((sum, row) => sum + row.over1HourDurationCount, 0),
      targetPercent: 90,
      referenceDefinition: 'AMR_Subjob_Analyze.limit, interpreted as milliseconds',
      perRobot: taskRows
    },
    queueWait: {
      linkedQueueCount,
      avgQueueWaitSeconds: linkedQueueCount
        ? Number((weightedQueueWaitSeconds / linkedQueueCount).toFixed(2))
        : null,
      maxQueueWaitSeconds: queueRows.reduce((max, row) => Math.max(max, row.maxQueueWaitSeconds), 0),
      over5MinuteQueueCount: queueRows.reduce((sum, row) => sum + row.over5MinuteQueueCount, 0),
      derivation: 'AMR_Queue.enqueued_at to linked TA_AMR.start_time',
      perRobot: queueRows
    },
    batteryAbove60: {
      measuredRobotCount: batteryRows.length,
      reliableCoverageRobotCount: reliableBatteryRows.length,
      minimumReliableCoveragePercent: 80,
      perRobot: batteryRows
    },
    routeSegments: {
      completedSegmentCount: routeRows.reduce((sum, row) => sum + row.completedSegmentCount, 0),
      segmentDefinitionCount: new Set(routeRows.map((row) => `${row.subjob_type_name || ''}|${row.subjob_name || ''}`)).size,
      loadingOrUnloadingSegmentCount: routeRows
        .filter((row) => loadingPattern.test(`${row.subjob_type_name || ''} ${row.subjob_name || ''}`))
        .reduce((sum, row) => sum + row.completedSegmentCount, 0),
      perSegment: routeRows
    }
  };
}

function buildMeasurementGaps(readiness, operationalMetrics) {
  const queueRows = number(readiness.queue_row_count);
  const queueDurationRows = number(readiness.queue_duration_row_count);
  const subjobRows = number(readiness.subjob_row_count);
  const dispatchAssignments = number(readiness.dispatch_assignment_row_count);
  const dispatchAuditFields = number(readiness.dispatch_audit_field_count);
  const dispatchAuditRows = number(readiness.dispatch_audit_row_count);
  const operationEventRows = number(readiness.operation_event_row_count);
  const operationEventAttributedRows = number(readiness.operation_event_robot_attributed_count);
  const auditWatermarkSources = number(readiness.audit_watermark_source_count);
  const auditCurrentSources = number(readiness.audit_sources_current_count);
  const incidentRows = number(readiness.incident_row_count);
  const incidentEvidenceRows = number(readiness.incident_evidence_row_count);
  const taskTiming = operationalMetrics.taskTiming;
  const queueWait = operationalMetrics.queueWait;
  const batteryAbove60 = operationalMetrics.batteryAbove60;
  const routeSegments = operationalMetrics.routeSegments;
  return [
    {
      metric: 'On-time rate vs. estimated task duration',
      status: taskTiming.durationReferenceCount > 0 ? 'SUPPORTED_WITH_ASSUMPTION' : 'NOT_MEASURABLE',
      reason: taskTiming.durationReferenceCount > 0
        ? `${taskTiming.onTimeCount} of ${taskTiming.durationReferenceCount} referenced executions were within the configured limit (${taskTiming.onTimeRatePercent?.toFixed(2)}%; target 90%). The reference covers ${taskTiming.durationReferenceRobotCount} robot(s), so this is not a full-fleet rate. The limit unit is inferred as milliseconds and still requires owner confirmation.`
        : 'No completed task execution can currently be matched to a positive duration limit.',
      requiredData: 'Confirm AMR_Subjob_Analyze.limit semantics/unit; retain TA_AMR start_time and end_time'
    },
    {
      metric: 'Task execution duration',
      status: taskTiming.durationCompleteCount > 0 ? 'SUPPORTED' : 'NOT_MEASURABLE',
      reason: taskTiming.durationCompleteCount > 0
        ? `${taskTiming.durationCompleteCount} executions have duration; fleet average ${taskTiming.avgActualDurationSeconds?.toFixed(1)} seconds and observed maximum ${taskTiming.maxActualDurationSeconds.toFixed(0)} seconds. ${taskTiming.over1HourDurationCount} executions exceed one hour and require stale-close/long-operation review before using the mean as a normal baseline.`
        : 'No valid task start/end pair is available.',
      requiredData: 'TA_AMR start_time, end_time, job_id, subjob_id and robot ID'
    },
    {
      metric: 'Queue waiting time',
      status: queueWait.linkedQueueCount > 0 ? 'SUPPORTED_WITH_DERIVATION' : 'NOT_MEASURABLE',
      reason: queueWait.linkedQueueCount > 0
        ? `${queueWait.linkedQueueCount} queue records link to task start; average wait ${queueWait.avgQueueWaitSeconds?.toFixed(1)} seconds, maximum ${queueWait.maxQueueWaitSeconds.toFixed(0)} seconds, and ${queueWait.over5MinuteQueueCount} exceed 5 minutes. DWD duration is empty (${queueDurationRows}/${queueRows}); wait is derived from enqueue to task start.`
        : queueRows > 0
          ? `${queueRows} queue rows exist, but no valid link to a later task start was found.`
        : 'No queue evidence is available in the selected source window.',
      requiredData: 'Preserve AMR_Queue.id/enqueued_at and TA_AMR.queue_id/start_time; add explicit dispatch_time for separation of queue and dispatch latency'
    },
    {
      metric: 'Route congestion and loading/unloading delay',
      status: routeSegments.completedSegmentCount > 0 ? 'PARTIAL' : 'NOT_MEASURABLE',
      reason: routeSegments.completedSegmentCount > 0
        ? `${routeSegments.completedSegmentCount} completed TA_AMR subjob executions across ${routeSegments.segmentDefinitionCount} named segment definitions have duration. ${routeSegments.loadingOrUnloadingSegmentCount} are explicitly labeled as loading/unloading. Movement duration is measurable, but congestion and station dwell are not attributable without route occupancy and arrival/load/departure events.`
        : subjobRows > 0
          ? 'Subjob definitions exist, but no completed segment execution for the active robot scope is available.'
        : 'No subjob/route-segment evidence is currently available.',
      requiredData: 'route segment, station arrival/departure, loading start/end, unloading start/end'
    },
    {
      metric: 'Battery above 60% time share',
      status: batteryAbove60.measuredRobotCount > 0 ? 'SUPPORTED_WITH_COVERAGE' : 'NOT_MEASURABLE',
      reason: batteryAbove60.measuredRobotCount > 0
        ? `${batteryAbove60.measuredRobotCount} robots have time-weighted results; ${batteryAbove60.reliableCoverageRobotCount} cover at least ${batteryAbove60.minimumReliableCoveragePercent}% of the selected window. Intervals over five minutes are excluded so telemetry gaps are not counted as battery time.`
        : 'No valid consecutive battery intervals are available in the selected window.',
      requiredData: 'Consecutive battery samples plus coverage percent; keep gaps excluded from the denominator'
    },
    {
      metric: 'Dispatch optimality',
      status: dispatchAuditFields >= 7 && dispatchAuditRows > 0
        ? 'SUPPORTED'
        : (dispatchAssignments > 0 ? 'PARTIAL' : 'NOT_MEASURABLE'),
      reason: dispatchAuditFields >= 7 && dispatchAuditRows > 0
        ? `${dispatchAuditRows} candidate decision rows are available with the seven required audit fields.`
        : dispatchAssignments > 0
          ? `${dispatchAssignments} project-to-robot assignment rows and queue priorities exist, but the candidate audit contract currently has ${dispatchAuditRows} rows and ${dispatchAuditFields}/7 required fields. Outcomes are explainable only as a proxy, not as proof of optimal assignment.`
        : 'Task counts show allocation outcomes but not which robots were eligible or why one was selected.',
      requiredData: 'candidate robots, eligibility result, score, rejection reason, priority, capability and zone'
    },
    {
      metric: 'Unified event and incident audit trail',
      status: operationEventRows > 0
        ? (incidentRows > 0 && incidentEvidenceRows > 0 ? 'SUPPORTED' : 'PARTIAL')
        : 'NOT_MEASURABLE',
      reason: operationEventRows > 0
        ? `${operationEventRows} source-traceable operation events are retained; ${operationEventAttributedRows} are linked to a recorded robot and ${auditCurrentSources}/${auditWatermarkSources} incremental sources are at the current ODS watermark. Incident records: ${incidentRows}; persisted incident evidence rows: ${incidentEvidenceRows}. Operation history is auditable, but diagnostic confirmation is not yet persisted until the maintenance workflow writes incidents and evidence.`
        : 'The unified audit contract exists, but no source operation event has been loaded.',
      requiredData: 'Write each rule result and its source evidence into the incident tables; add maintenance confirmation, confirmed cause and resolution actions'
    },
    {
      metric: 'Task cumulative mileage',
      status: 'NOT_MEASURABLE',
      reason: 'Task records contain start map/zone and coordinates but no end coordinate, route distance or robot odometer delta linked to the task.',
      requiredData: 'task_id with start/end odometer, or route segment distance with task linkage'
    }
  ];
}

function buildAnalysis({
  summary = {},
  robots = [],
  workloadRows = [],
  statusCoverageRows = [],
  readiness = {},
  taskTimingRows = [],
  queueWaitRows = [],
  batteryAbove60Rows = [],
  routeSegmentRows = [],
  staleMinutes = 30,
  window = {}
}) {
  const databaseCurrentTime = readiness.database_current_time || summary.database_current_time || new Date().toISOString();
  const diagnostics = robots
    .map((robot) => diagnoseRobot(robot, { databaseCurrentTime, staleMinutes }))
    .filter(Boolean)
    .sort((a, b) => (SEVERITY_RANK[b.severity] || 0) - (SEVERITY_RANK[a.severity] || 0)
      || a.robotId.localeCompare(b.robotId, 'en'));
  const workload = analyzeWorkload(workloadRows, robots);
  const coveredRobotCount = statusCoverageRows.filter((row) => number(row.status_sample_count) > 0).length;
  const totalRobotCount = robots.length;
  const operationalMetrics = summarizeOperationalMetrics(taskTimingRows, queueWaitRows, batteryAbove60Rows, routeSegmentRows);
  const measurementGaps = buildMeasurementGaps(readiness, operationalMetrics);
  const eventAudit = {
    operationEventCount: number(readiness.operation_event_row_count),
    robotAttributedEventCount: number(readiness.operation_event_robot_attributed_count),
    latestEventTime: readiness.operation_event_latest_time || null,
    sourceCount: number(readiness.audit_watermark_source_count),
    currentSourceCount: number(readiness.audit_sources_current_count),
    incidentCount: number(readiness.incident_row_count),
    incidentEvidenceCount: number(readiness.incident_evidence_row_count)
  };
  const criticalCount = diagnostics.filter((item) => item.severity === 'CRITICAL').length;
  const rssiMeasurementUnavailableDiagnostics = diagnostics.filter((item) => (
    item.ruleIds.includes('WIFI_RSSI_MEASUREMENT_UNAVAILABLE')
  ));
  const unresolvedDisconnectCount = diagnostics.filter((item) => (
    item.ruleIds.includes('DISCONNECT_EVIDENCE_STALE')
    || item.ruleIds.includes('SOURCE_TELEMETRY_ALL_TOPICS_STOPPED')
  )).length;
  const severity = criticalCount ? 'CRITICAL' : diagnostics.length || workload.severity === 'WARNING' ? 'WARNING' : 'HEALTHY';

  return {
    method: 'TRANSPARENT_RULES',
    ruleVersion: RULE_VERSION,
    generatedAt: new Date().toISOString(),
    window,
    fleetAssessment: {
      severity,
      headline: criticalCount
        ? criticalCount === 1
          ? '1 robot has a high-priority, evidence-backed maintenance signal.'
          : `${criticalCount} robots have high-priority, evidence-backed maintenance signals.`
        : diagnostics.length
          ? `${diagnostics.length} robots require review; no high-confidence critical cause was detected.`
          : 'No current robot-level maintenance signal was detected by the available rules.',
      summary: `${workload.title} ${workload.causeExplanation}`,
      confidence: unresolvedDisconnectCount > 0 || coveredRobotCount < totalRobotCount ? 'LIMITED' : 'SUPPORTED',
      verifiedFacts: [
        `${diagnostics.length} robots triggered at least one transparent diagnostic rule.`,
        `${coveredRobotCount} of ${totalRobotCount} robots have status-history samples in the selected window.`,
        workload.summary,
        `${eventAudit.operationEventCount} source-traceable operation events are retained in the unified audit trail.`
      ],
      limitations: [
        `${measurementGaps.filter((gap) => gap.status === 'NOT_MEASURABLE').length} requested analyses are not yet measurable from current fields.`,
        'A rule identifies the most likely explanation supported by current evidence; it does not replace physical confirmation.'
      ]
    },
    priorityDiagnostics: diagnostics,
    workload,
    operationalMetrics,
    eventAudit,
    dataQuality: {
      severity: coveredRobotCount === totalRobotCount && rssiMeasurementUnavailableDiagnostics.length === 0
        ? 'HEALTHY'
        : 'WARNING',
      statusCoverageRobotCount: coveredRobotCount,
      totalRobotCount,
      statusCoveragePercent: totalRobotCount ? Number(((coveredRobotCount / totalRobotCount) * 100).toFixed(1)) : 0,
      rssiMeasurementUnavailableRobotCount: rssiMeasurementUnavailableDiagnostics.length,
      rssiMeasurementUnavailableRobotIds: rssiMeasurementUnavailableDiagnostics.map((item) => item.robotId),
      statusHistoryAnchorTime: readiness.status_history_anchor_time || null,
      queueHistoryAnchorTime: readiness.queue_history_anchor_time || null
    },
    measurementGaps
  };
}

module.exports = {
  RULE_VERSION,
  analyzeWorkload,
  buildAnalysis,
  diagnoseRobot
};
