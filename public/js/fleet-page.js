'use strict';

function renderConnectionError(error) {
  elements.connectionStatus.textContent = error.code === 'DATABASE_NOT_CONFIGURED'
    ? 'Database not configured. Complete amr-monitoring-web/.env first.'
    : 'Database connection or query failed.';
  elements.freshnessDot.className = 'status-dot error';
}

function renderDashboard(data) {
  const summary = data.summary || {};
  const robots = data.robots || [];
  populateRobotProfileSelector(robots);
  const attentionRobots = robots.filter(hasOperationalAlert);
  const lowBatteryRobots = robots.filter(isLowBattery);
  const noSignalRobots = robots.filter(isNoSignal);
  const rssiMeasurementIssueRobots = robots.filter(hasRssiMeasurementIssue);
  const deviceAlarmRobots = robots.filter(hasAlarm);
  const staleDataRobots = robots.filter(isRobotDataStale);
  const taskTotals = (data.jobTrend || []).reduce((totals, row) => ({
    completed: totals.completed + asNumber(row.completed_status_count),
    failed: totals.failed + asNumber(row.failed_status_count)
  }), { completed: 0, failed: 0 });
  const finishedTaskCount = taskTotals.completed + taskTotals.failed;
  const taskSuccessRate = finishedTaskCount > 0
    ? (taskTotals.completed / finishedTaskCount) * 100
    : null;
  const latestLoad = summary.latest_dws_load_time ? new Date(summary.latest_dws_load_time) : null;
  const latestSourceEvent = summary.source_anchor_time
    ? new Date(summary.source_anchor_time)
    : (summary.latest_source_event_time ? new Date(summary.latest_source_event_time) : null);
  const sourceAgeMinutes = latestSourceEvent && !Number.isNaN(latestSourceEvent.getTime())
    ? (Date.now() - latestSourceEvent.getTime()) / 60000
    : Number.POSITIVE_INFINITY;
  const loadAgeMinutes = latestLoad && !Number.isNaN(latestLoad.getTime())
    ? (Date.now() - latestLoad.getTime()) / 60000
    : Number.POSITIVE_INFINITY;

  renderAnalysis(data.analysis, data.analysisReadiness, robots);
  renderRunningWifiAnalysis(data.wifiRunningAnalysis || {});

  if (sourceAgeMinutes <= data.staleMinutes) {
    elements.connectionStatus.textContent = 'DWS non-snapshot data is current';
    elements.freshnessDot.className = 'status-dot ok';
  } else if (loadAgeMinutes <= data.staleMinutes) {
    elements.connectionStatus.textContent = `DWS loaded · Source data exceeds ${formatNumber(data.staleMinutes)} min`;
    elements.freshnessDot.className = 'status-dot stale';
  } else {
    elements.connectionStatus.textContent = `DWS refresh timeout · ${Number.isFinite(loadAgeMinutes) ? formatNumber(loadAgeMinutes) : '--'} min old`;
    elements.freshnessDot.className = 'status-dot stale';
  }
  elements.sourceFreshness.textContent = formatDateTime(summary.latest_source_event_time);
  elements.sourceLag.textContent = summary.source_anchor_lag_minutes == null
    ? '--'
    : `${formatNumber(Math.max(0, asNumber(summary.source_anchor_lag_minutes)))} min`;
  elements.dwsFreshness.textContent = formatDateTime(summary.latest_dws_load_time);
  elements.wifiFreshness.textContent = formatDateTime(summary.wifi_anchor_time);

  if (elements.metricTotal) {
    elements.metricTotal.textContent = `${formatNumber(summary.total_robot_count)} / ${formatNumber(summary.commissioned_robot_count)}`;
    elements.metricTotalScope.textContent = `Enabled / commissioned · ${formatNumber(summary.dws_known_robot_count)} found in non-snapshot DWS`;
    elements.metricOnline.textContent = formatNumber(summary.current_data_robot_count);
    elements.metricOffline.textContent = `Within ${formatNumber(data.staleMinutes)} min · ${formatNumber(summary.timed_out_robot_count)} timed out · ${formatNumber(summary.missing_data_robot_count)} missing`;
    elements.metricJobs.textContent = '--';
    elements.metricJobScope.textContent = 'Current task ID is not provided by DWS daily aggregates';
    elements.metricTaskSuccess.textContent = taskSuccessRate == null ? '--' : formatPercent(taskSuccessRate, 1);
    elements.metricTaskSuccessScope.textContent = `Queue outcomes · ${formatNumber(taskTotals.completed)} completed / ${formatNumber(taskTotals.failed)} unsuccessful`;
    elements.metricBattery.textContent = summary.avg_battery_soc == null ? '--' : `${formatNumber(summary.avg_battery_soc, 1)}%`;
    elements.metricLowBattery.textContent = `≤20%: ${formatNumber(summary.low_battery_robot_count)} · ${robotIdSummary(robots, isLowBattery, { prefix: 'IDs', limit: 3 })}`;
    elements.metricRssi.textContent = summary.avg_current_rssi == null ? '--' : `${formatNumber(summary.avg_current_rssi, 1)} dBm`;
    elements.metricWifiCoverage.textContent = `DWS current within ${formatNumber(data.staleMinutes)} min: ${formatNumber(summary.wifi_current_robot_count)} / ${formatNumber(summary.active_robot_count)}`;
    elements.metricZeroSignal.textContent = '--';
    elements.metricZeroSignalScope.textContent = 'Not measurable: DWS hourly WiFi does not retain AP or scan evidence';
    elements.metricAlarms.textContent = formatNumber(attentionRobots.length);
    elements.metricAlarmScope.textContent = `${formatNumber(staleDataRobots.length)} delayed · ${formatNumber(lowBatteryRobots.length)} low battery · ${formatNumber(noSignalRobots.length)} no signal · ${formatNumber(rssiMeasurementIssueRobots.length)} RSSI measurement issues · ${formatNumber(deviceAlarmRobots.length)} device errors`;
  }
  elements.operationsOnlineValue.textContent = `${formatNumber(summary.current_data_robot_count)} robots`;
  elements.operationsOfflineValue.textContent = `${formatNumber(summary.timed_out_robot_count)} robots`;
  elements.operationsOfflineIds.textContent = robotIdSummary(robots, (robot) => normalizedOnlineStatus(robot.online_status) !== 'online');
  elements.operationsActiveValue.textContent = 'Not available';
  elements.operationsActiveIds.textContent = 'DWS daily aggregates do not contain current task IDs';
  elements.taskSuccessValue.textContent = taskSuccessRate == null ? '--' : formatPercent(taskSuccessRate, 1);
  elements.taskFailureValue.textContent = formatNumber(taskTotals.failed);
  elements.taskFailureSummary.textContent = taskFailureSummary(data.taskFailureOutcomes || []);
  elements.taskActiveValue.textContent = 'Not available';
  elements.taskActiveIds.textContent = 'Use historical DWS task totals only';
  elements.energyAverageValue.textContent = summary.avg_battery_soc == null ? '--' : `${formatNumber(summary.avg_battery_soc, 1)}%`;
  elements.energyLowBatteryValue.textContent = `${formatNumber(summary.low_battery_robot_count)} robots`;
  elements.energyLowBatteryIds.textContent = robotIdSummary(robots, isLowBattery);
  elements.alarmRobotValue.textContent = `${formatNumber(attentionRobots.length)} robots`;
  elements.alarmRobotIds.textContent = robotIdSummary(robots, hasOperationalAlert);
  elements.alarmLowBatteryValue.textContent = `${formatNumber(lowBatteryRobots.length)} robots`;
  elements.alarmLowBatteryIds.textContent = robotIdSummary(robots, isLowBattery);
  elements.alarmNoSignalValue.textContent = `${formatNumber(noSignalRobots.length)} robots`;
  elements.alarmNoSignalIds.textContent = robotIdSummary(robots, isNoSignal);
  elements.alarmRssiIssueValue.textContent = `${formatNumber(rssiMeasurementIssueRobots.length)} robots`;
  elements.alarmRssiIssueIds.textContent = robotIdSummary(robots, hasRssiMeasurementIssue);
  elements.analysisWindowLabel.textContent = `${robotTypeLabel()} · ${analysisWindowLabelText()}`;
  elements.batteryTrendAnchor.textContent = summary.battery_trend_anchor_time
    ? `Through ${formatShortTime(summary.battery_trend_anchor_time)}`
    : '%';

  renderDistribution(elements.statusDistribution, data.statusDistribution, 'status_name');
  renderDistribution(elements.modeDistribution, data.modeDistribution, 'mode_name', 12);
  renderTasks(robots);
  renderTaskFailureOutcomes(data.taskFailureOutcomes || []);
  renderAlerts(robots);
  renderMap(robots);
  renderRobotVitals(robots);
  renderLowBatteryRisk(robots);
  renderLineChart(elements.batteryChart, data.batteryTrend, {
    valueKey: 'avg_battery_soc', labelKey: 'stat_hour', color: '#2563eb', suffix: '%', fixedRange: [0, 100]
  });
  renderLineChart(elements.jobChart, data.jobTrend, {
    valueKey: 'job_count', labelKey: 'stat_date', color: '#059669', suffix: '', nonNegative: true
  });
  renderLineChart(elements.alarmChart, data.statusTrend, {
    valueKey: 'error_sample_count', labelKey: 'stat_hour', color: '#dc2626', suffix: '', nonNegative: true
  });
  renderLineChart(elements.queueChart, data.queueTrend, {
    valueKey: 'queue_count', labelKey: 'stat_date', color: '#d97706', suffix: '', nonNegative: true
  });
  renderBatches(data.recentBatches || []);
  if (state.currentView === 'robot-profile') loadRobotProfile();
}

function textNode(tagName, className, value) {
  const element = document.createElement(tagName);
  if (className) element.className = className;
  element.textContent = value;
  return element;
}

function renderAnalysisBarChart(host, rows, options = {}) {
  if (!host) return;
  host.replaceChildren();

  const validRows = rows.filter((row) => Number.isFinite(Number(row.value)));
  if (!validRows.length) {
    host.classList.add('empty-state');
    host.textContent = options.emptyText || 'No supported data is available for this chart.';
    return;
  }

  host.classList.remove('empty-state');
  const observedMaximum = Math.max(...validRows.map((row) => Math.max(0, Number(row.value))));
  const scaleMaximum = Math.max(
    1,
    Number(options.maxValue) || 0,
    Number(options.referenceValue) || 0,
    observedMaximum
  );
  const valueFormatter = options.valueFormatter || ((value) => formatNumber(value, 1));

  validRows.forEach((row) => {
    const numericValue = Math.max(0, Number(row.value));
    const wrapper = document.createElement('div');
    wrapper.className = 'analysis-bar-row';
    wrapper.dataset.tone = row.tone || options.tone || 'blue';

    const label = document.createElement('div');
    label.className = 'analysis-bar-label';
    const title = textNode('strong', '', row.label || '--');
    title.title = row.fullLabel || row.label || '';
    label.append(title);
    if (row.detail) label.append(textNode('small', '', row.detail));

    const track = document.createElement('div');
    track.className = 'analysis-bar-track';
    const fill = document.createElement('span');
    fill.className = 'analysis-bar-fill';
    fill.style.width = `${Math.min(100, (numericValue / scaleMaximum) * 100)}%`;
    track.append(fill);

    if (Number.isFinite(Number(options.referenceValue))) {
      const reference = document.createElement('span');
      reference.className = 'analysis-bar-reference';
      reference.style.left = `${Math.min(100, (Number(options.referenceValue) / scaleMaximum) * 100)}%`;
      reference.title = options.referenceLabel || `Reference: ${valueFormatter(options.referenceValue)}`;
      track.append(reference);
    }

    wrapper.append(label, track, textNode('span', 'analysis-bar-value', valueFormatter(numericValue)));
    host.append(wrapper);
  });

  if (options.note) host.append(textNode('div', 'analysis-chart-note', options.note));
}

function diagnosisChartLabel(diagnostic) {
  const rules = diagnostic.ruleIds || [];
  if (rules.includes('DWS_REFRESH_TIMEOUT')) return 'DWS refresh timeout';
  if (rules.includes('DWS_SOURCE_LAG')) return 'DWS source-to-load lag';
  if (rules.includes('DWS_SOURCE_TIMEOUT')) return 'Source data timeout';
  if (rules.includes('DWS_STATUS_MISSING')) return 'DWS status data missing';
  if (rules.includes('SOURCE_TELEMETRY_ALL_TOPICS_STOPPED')) return 'Upstream telemetry stopped';
  if (rules.includes('BATTERY_LOW_NOT_CHARGING')) return 'Low battery, not charging';
  if (rules.includes('WIFI_SIGNAL_CONFIRMED_LOST')) return 'Confirmed WiFi signal loss';
  if (rules.includes('DEVICE_ERROR_REPORTED')) return 'Device-reported error';
  return diagnostic.phenomenon || rules[0] || 'Operational review';
}

function workloadTone(classification) {
  if (classification === 'CONCENTRATED') return 'warning';
  if (classification === 'OBSERVED_IDLE_OR_INELIGIBLE') return 'blue';
  if (classification === 'BALANCED') return 'healthy';
  return 'muted';
}

function groupedDiagnostics(diagnostics = []) {
  const groups = new Map();
  diagnostics.forEach((diagnostic) => {
    const key = `${diagnostic.diagnosis || ''}|${(diagnostic.ruleIds || []).join('|')}`;
    const group = groups.get(key) || {
      representative: diagnostic,
      robots: [],
      diagnostics: [],
      severity: diagnostic.severity
    };
    group.robots.push(diagnostic.robotId);
    group.diagnostics.push(diagnostic);
    groups.set(key, group);
  });

  const severityRank = { CRITICAL: 3, WARNING: 2, WATCH: 1, INFO: 0 };
  return [...groups.values()].sort((a, b) => {
    const severityDifference = (severityRank[b.severity] || 0) - (severityRank[a.severity] || 0);
    return severityDifference || b.robots.length - a.robots.length;
  });
}

function renderFleetDonut(host, segments, total) {
  host.replaceChildren();
  host.classList.remove('empty-state');

  const size = 190;
  const center = size / 2;
  const radius = 66;
  const circumference = 2 * Math.PI * radius;
  const svg = svgElement('svg', {
    viewBox: `0 0 ${size} ${size}`,
    role: 'img',
    'aria-label': `Telemetry freshness for ${formatNumber(total)} robots`
  });
  svg.append(svgElement('circle', {
    cx: center,
    cy: center,
    r: radius,
    class: 'fleet-donut-track'
  }));

  let offset = 0;
  segments.forEach((segment) => {
    const fraction = total > 0 ? segment.value / total : 0;
    const arc = svgElement('circle', {
      cx: center,
      cy: center,
      r: radius,
      class: 'fleet-donut-segment',
      stroke: segment.color,
      'stroke-dasharray': `${fraction * circumference} ${circumference}`,
      'stroke-dashoffset': `${-offset * circumference}`
    });
    const title = svgElement('title');
    title.textContent = `${segment.label}: ${formatNumber(segment.value)} robots`;
    arc.append(title);
    svg.append(arc);
    offset += fraction;
  });

  const totalText = svgElement('text', {
    x: center,
    y: center - 2,
    class: 'fleet-donut-total',
    'text-anchor': 'middle'
  });
  totalText.textContent = formatNumber(total);
  const labelText = svgElement('text', {
    x: center,
    y: center + 20,
    class: 'fleet-donut-label',
    'text-anchor': 'middle'
  });
  labelText.textContent = 'ROBOTS';
  svg.append(totalText, labelText);

  const legend = document.createElement('div');
  legend.className = 'fleet-donut-legend';
  segments.forEach((segment) => {
    const item = document.createElement('div');
    const swatch = document.createElement('span');
    swatch.style.backgroundColor = segment.color;
    item.append(swatch, textNode('b', '', segment.label), textNode('strong', '', formatNumber(segment.value)));
    legend.append(item);
  });
  host.append(svg, legend);
}

function renderFleetStatusOverview(analysis, robots = [], emptyMessage = 'No robots match the selected scope') {
  if (!elements.fleetStatusDonut || !elements.fleetRobotGrid) return;

  const statusCounts = { current: 0, delayed: 0, missing: 0 };
  robots.forEach((robot) => {
    const freshnessStatus = String(robot.data_freshness_status || '').trim().toUpperCase();
    if (freshnessStatus === 'MISSING' || !freshnessStatus) statusCounts.missing += 1;
    else if (freshnessStatus !== 'CURRENT') statusCounts.delayed += 1;
    else statusCounts.current += 1;
  });

  renderFleetDonut(elements.fleetStatusDonut, [
    { label: 'Current', value: statusCounts.current, color: '#2563eb' },
    { label: 'Timed out', value: statusCounts.delayed, color: '#d97706' },
    { label: 'Missing', value: statusCounts.missing, color: '#98a2b3' }
  ], robots.length);

  const diagnosticsByRobot = new Map(
    (analysis?.priorityDiagnostics || []).map((diagnostic) => [String(diagnostic.masterRobotId), diagnostic])
  );
  elements.fleetRobotGrid.replaceChildren();
  if (!robots.length) {
    elements.fleetRobotGrid.classList.add('empty-state');
    elements.fleetRobotGrid.textContent = emptyMessage;
    return;
  }
  elements.fleetRobotGrid.classList.remove('empty-state');

  [...robots]
    .sort((a, b) => robotIdentifier(a).localeCompare(robotIdentifier(b), 'en'))
    .forEach((robot) => {
      const diagnostic = diagnosticsByRobot.get(String(robot.master_robot_id));
      const freshnessStatus = String(robot.data_freshness_status || '').trim().toUpperCase();
      const freshness = freshnessStatus === 'CURRENT'
        ? 'current'
        : freshnessStatus === 'MISSING' || !freshnessStatus
          ? 'missing'
          : 'delayed';
      const freshnessLabel = {
        CURRENT: 'DWS current',
        DWS_REFRESH_TIMEOUT: 'DWS refresh timeout',
        DWS_SOURCE_LAG: 'DWS source lag',
        SOURCE_TIMEOUT: 'Source timeout',
        MISSING: 'DWS data missing'
      }[freshnessStatus] || 'DWS data missing';
      const tile = document.createElement('button');
      tile.type = 'button';
      tile.className = 'fleet-robot-tile';
      tile.dataset.tone = freshness;
      tile.title = `${robotIdentifier(robot)} · ${freshnessLabel} · latest event ${formatDataAge(robot.status_event_time)}${diagnostic ? ` · ${diagnosisChartLabel(diagnostic)}` : ''}`;
      tile.setAttribute('aria-label', tile.title);

      const identity = document.createElement('span');
      identity.append(textNode('i', 'fleet-status-dot', ''), textNode('strong', '', robotIdentifier(robot)));
      tile.append(identity, textNode('small', '', freshnessLabel));
      tile.addEventListener('click', () => selectRobotProfile(String(robot.master_robot_id)));
      elements.fleetRobotGrid.append(tile);
    });
}

function renderPriorityRepair(analysis) {
  if (!elements.priorityRepairSummary) return;
  const groups = groupedDiagnostics(analysis?.priorityDiagnostics || []);
  elements.priorityRepairSummary.replaceChildren();

  if (!groups.length) {
    elements.priorityRepairSummary.className = 'priority-repair-summary empty-state';
    elements.priorityRepairSummary.textContent = 'No current transparent-rule diagnosis requires maintenance.';
    return;
  }

  const group = groups[0];
  const diagnostic = group.representative;
  elements.priorityRepairSummary.className = 'priority-repair-summary';

  const heading = document.createElement('div');
  heading.className = 'repair-focus-heading';
  const titleGroup = document.createElement('div');
  titleGroup.append(
    textNode('span', 'repair-count', `${formatNumber(group.robots.length)} robots affected`),
    textNode('h4', '', diagnosisChartLabel(diagnostic))
  );
  const confidence = textNode(
    'span',
    `confidence-pill confidence-${String(diagnostic.confidence || '').toLowerCase()}`,
    `${diagnostic.confidence || '--'} evidence`
  );
  heading.append(titleGroup, confidence);

  const affected = document.createElement('div');
  affected.className = 'repair-robot-list';
  group.robots.slice(0, 8).forEach((robotId) => affected.append(textNode('span', '', robotId)));
  if (group.robots.length > 8) affected.append(textNode('span', '', `+${group.robots.length - 8}`));

  const actionList = document.createElement('ol');
  actionList.className = 'repair-action-list';
  (diagnostic.recommendedActions || []).slice(0, 3).forEach((action) => actionList.append(textNode('li', '', action)));

  const footer = document.createElement('div');
  footer.className = 'repair-rule-footer';
  footer.append(
    textNode('span', '', `Rule: ${(diagnostic.ruleIds || []).join(', ') || '--'}`),
    textNode('span', '', 'Physical confirmation is still required')
  );
  elements.priorityRepairSummary.append(heading, affected, actionList, footer);
}

function renderAnalysisVisuals(analysis) {
  const diagnostics = analysis.priorityDiagnostics || [];
  const workload = analysis.workload || {};
  const operational = analysis.operationalMetrics || {};

  const diagnosisRows = groupedDiagnostics(diagnostics)
    .map((group) => ({
      label: diagnosisChartLabel(group.representative),
      fullLabel: group.representative.diagnosis,
      detail: `${group.robots.slice(0, 3).join(', ')}${group.robots.length > 3 ? ` +${group.robots.length - 3}` : ''}`,
      value: group.robots.length,
      tone: group.severity === 'CRITICAL' ? 'critical' : 'warning'
    }));
  renderAnalysisBarChart(elements.diagnosisCauseChart, diagnosisRows, {
    valueFormatter: (value) => `${formatNumber(value)} robot${value === 1 ? '' : 's'}`,
    note: 'Counts use each robot’s strongest current transparent-rule diagnosis; they are not independent alarm-event totals.'
  });

  const workloadRows = workload.perRobot || [];
  const topActive = workloadRows
    .filter((row) => asNumber(row.assignedTaskCount) > 0)
    .sort((a, b) => asNumber(b.assignedTaskCount) - asNumber(a.assignedTaskCount))
    .slice(0, 6);
  const visibleExceptions = workloadRows.filter((row) => [
    'OBSERVED_IDLE_OR_INELIGIBLE',
    'CURRENT_ERROR_NO_TASK',
    'CURRENTLY_CHARGING_NO_TASK'
  ].includes(row.classification));
  const workloadSelection = new Map();
  [...topActive, ...visibleExceptions].forEach((row) => workloadSelection.set(String(row.masterRobotId), row));
  renderAnalysisBarChart(
    elements.workloadDistributionChart,
    [...workloadSelection.values()].map((row) => ({
      label: row.robotId,
      detail: String(row.classification || '').replaceAll('_', ' ').toLowerCase(),
      value: asNumber(row.assignedTaskCount),
      tone: workloadTone(row.classification)
    })),
    {
      valueFormatter: (value) => `${formatNumber(value)} tasks`,
      note: 'Shows the six highest-volume robots plus currently observable zero-task exceptions. The full fleet classification remains available below.'
    }
  );

  const timingRows = (operational.taskTiming?.perRobot || [])
    .filter((row) => asNumber(row.durationReferenceCount) > 0)
    .map((row) => ({
      label: row.robot_code || String(row.master_robot_id),
      detail: `${formatNumber(row.onTimeCount)} / ${formatNumber(row.durationReferenceCount)} referenced`,
      value: (asNumber(row.onTimeCount) / asNumber(row.durationReferenceCount)) * 100,
      tone: ((asNumber(row.onTimeCount) / asNumber(row.durationReferenceCount)) * 100) >= 90 ? 'healthy' : 'warning'
    }))
    .sort((a, b) => b.value - a.value);
  renderAnalysisBarChart(elements.onTimeRateChart, timingRows, {
    maxValue: 100,
    referenceValue: 90,
    referenceLabel: 'Target reference: 90%',
    valueFormatter: (value) => formatPercent(value, 1),
    note: 'The configured duration-limit unit is still treated as an explicit assumption.'
  });

  const queueRows = (operational.queueWait?.perRobot || [])
    .map((row) => ({
      label: row.robot_code || String(row.master_robot_id),
      detail: `${formatNumber(row.linkedQueueCount)} linked tasks`,
      value: asNumber(row.avgQueueWaitSeconds),
      tone: asNumber(row.avgQueueWaitSeconds) > 300 ? 'warning' : 'blue'
    }))
    .sort((a, b) => b.value - a.value);
  renderAnalysisBarChart(elements.queueWaitAnalysisChart, queueRows, {
    referenceValue: 300,
    referenceLabel: 'Review reference: 300 seconds',
    valueFormatter: (value) => formatSeconds(value),
    note: 'Wait is derived from AMR_Queue.enqueued_at to the linked TA_AMR.start_time.'
  });

  const batteryRows = (operational.batteryAbove60?.perRobot || [])
    .map((row) => ({
      label: row.robot_code || String(row.master_robot_id),
      detail: `${formatPercent(row.windowCoveragePercent, 0)} telemetry coverage`,
      value: asNumber(row.above60TimeSharePercent),
      tone: asNumber(row.windowCoveragePercent) >= 80 ? 'violet' : 'muted'
    }))
    .sort((a, b) => b.value - a.value);
  renderAnalysisBarChart(elements.batteryCoverageAnalysisChart, batteryRows, {
    maxValue: 100,
    valueFormatter: (value) => formatPercent(value, 1),
    note: 'Intervals longer than five minutes are excluded; muted bars have less than 80% window coverage.'
  });
}

/*
  Project-scope helpers for the Analysis Center.

  The dashboard is loaded fleet-wide, but the Analysis Center may be scoped to
  a project or task. Robot membership comes from the project analytics robot
  breakdown, which resolves display names through dbo.MA_AMR. An optional
  robot display selection can narrow those derived members without becoming a
  backend project query condition. Telemetry diagnostics are then filtered to
  exactly those master robot IDs.
*/
function projectScopeRobotNames() {
  const rows = state.projectAnalytics?.robots || [];
  const derivedNames = rows.map((row) => String(row.robot_name || '').trim()).filter(Boolean);
  if (!state.selectedProjectRobotCodes.length) return new Set(derivedNames);
  const selected = new Set(state.selectedProjectRobotCodes);
  return new Set(derivedNames.filter((name) => selected.has(name)));
}

function projectScopeActiveAny() {
  return state.selectedProjectIds.length > 0
    || state.selectedJobIds.length > 0
    || state.selectedProjectRobotCodes.length > 0;
}

function scopedAnalysisRobots(robots = []) {
  if (!projectScopeActiveAny()) return robots;
  const projectScope = state.selectedProjectIds.length > 0 || state.selectedJobIds.length > 0;
  let filtered = robots;
  if (projectScope) {
    const names = projectScopeRobotNames();
    if (!names.size) return [];
    filtered = filtered.filter((robot) => (
      names.has(String(robot.robot_code || '').trim())
      || names.has(String(robot.robot_name || '').trim())
    ));
  }
  return filtered;
}

function scopedAnalysisDiagnostics(analysis, robots = []) {
  if (!analysis || !projectScopeActiveAny()) return analysis;
  const masterIds = new Set(
    scopedAnalysisRobots(robots)
      .map((robot) => String(robot.master_robot_id))
      .filter((id) => id !== '' && id !== 'undefined' && id !== 'null')
  );
  if (!masterIds.size) return { ...analysis, priorityDiagnostics: [] };
  return {
    ...analysis,
    priorityDiagnostics: (analysis.priorityDiagnostics || []).filter((diagnostic) => (
      masterIds.has(String(diagnostic.masterRobotId))
    ))
  };
}

function renderAnalysis(analysis, readiness = {}, robots = []) {
  if (!analysis) {
    elements.analysisHeadline.textContent = 'Analysis is unavailable';
    elements.analysisSummary.textContent = 'The monitoring data loaded, but the transparent rule result is missing.';
    elements.analysisVerdict.dataset.severity = 'WARNING';
    return;
  }

  const scopedRobots = scopedAnalysisRobots(robots);
  const scopedAnalysis = scopedAnalysisDiagnostics(analysis, robots);
  const assessment = scopedAnalysis.fleetAssessment || {};
  const diagnostics = scopedAnalysis.priorityDiagnostics || [];
  const quality = scopedAnalysis.dataQuality || {};
  const gaps = scopedAnalysis.measurementGaps || [];
  const unavailableGapCount = gaps.filter((gap) => gap.status === 'NOT_MEASURABLE').length;
  const diagnosticGroups = groupedDiagnostics(diagnostics);
  const topDiagnosticGroup = diagnosticGroups[0];
  const reviewedRobotCount = new Set(diagnostics.map((diagnostic) => String(diagnostic.masterRobotId))).size;
  const projectScopeActive = projectScopeActiveAny();

  elements.analysisVerdict.dataset.severity = assessment.severity || 'INFO';
  elements.analysisHeadline.textContent = reviewedRobotCount
    ? `${formatNumber(reviewedRobotCount)} robots need rule review`
    : 'No current transparent-rule alert';
  elements.analysisSummary.textContent = topDiagnosticGroup
    ? `Top cause: ${diagnosisChartLabel(topDiagnosticGroup.representative)} · ${formatNumber(topDiagnosticGroup.robots.length)} robots`
    : projectScopeActive
      ? 'No rule-backed maintenance action is required from the selected project scope.'
      : 'No rule-backed maintenance action is required from the current evidence.';
  elements.analysisSummary.title = assessment.summary || '';
  elements.analysisConfidence.textContent = `Evidence coverage: ${assessment.confidence || '--'}`;
  elements.analysisRuleVersion.textContent = `Transparent rules: ${analysis.ruleVersion || '--'}`;
  elements.analysisRobotCount.textContent = formatNumber(reviewedRobotCount);
  elements.analysisCoverage.textContent = formatPercent(quality.statusCoveragePercent, 1);
  elements.analysisCoverageDetail.textContent = `${formatNumber(quality.statusCoverageRobotCount)} / ${formatNumber(quality.totalRobotCount)} robots have status-history samples`;
  elements.analysisGapCount.textContent = formatNumber(unavailableGapCount);
  if (elements.fleetScopeLabel) {
    elements.fleetScopeLabel.textContent = projectScopeActive ? 'PROJECT SCOPE' : 'ALL ROBOTS';
  }
  renderFleetStatusOverview(
    scopedAnalysis,
    scopedRobots,
    projectScopeActive ? 'No robots in the selected project scope' : 'Waiting for robot status'
  );
  renderPriorityRepair(scopedAnalysis);
}

/*
  Re-aggregate per-robot-target rows into fleet-shaped target rows for a subset
  of robots. Sample counts are summed and the average RSSI is weighted by valid
  sample count, so a multi-robot selection reads the same way as byTarget does.
*/

function filteredRobots() {
  const query = String(elements.robotSearch.value || '').trim().toLowerCase();
  return (state.dashboard?.robots || []).filter((robot) => {
    if (!query) return true;
    return [
      robot.robot_code,
      robot.robot_name,
      robot.master_robot_id,
      robot.robot_serial_number,
      robot.current_status,
      robot.current_mode,
      robot.current_mode_id,
      robot.station_code,
      robot.target_station_code,
      robot.job_id,
      robot.current_wifi_ap,
      robot.error_code,
      robot.error_message
    ].some((value) => String(value || '').toLowerCase().includes(query));
  });
}

function renderRobotVitals(robots) {
  elements.robotVitalsBody.replaceChildren();
  const visibleRobots = robots === state.dashboard?.robots ? filteredRobots() : robots;
  if (!visibleRobots.length) {
    const row = elements.robotVitalsBody.insertRow();
    const cell = row.insertCell();
    cell.colSpan = 10;
    cell.className = 'empty-cell';
    cell.textContent = elements.robotSearch.value ? 'No robots match the search' : 'No robot operating details are available';
    return;
  }

  const sorted = [...visibleRobots].sort((a, b) => {
    const freshness = Number(Boolean(b.wifi_is_current)) - Number(Boolean(a.wifi_is_current));
    if (freshness !== 0) return freshness;
    return String(a.robot_name || a.robot_code || '').localeCompare(String(b.robot_name || b.robot_code || ''), 'en');
  });

  sorted.forEach((robot) => {
    const row = elements.robotVitalsBody.insertRow();
    if (robot.robot_code === state.selectedRobotCode) row.classList.add('selected');
    row.addEventListener('click', () => selectRobot(robot.robot_code));

    const robotCell = row.insertCell();
    robotCell.className = 'robot-name';
    const robotName = document.createElement('strong');
    robotName.textContent = robot.robot_name || robot.robot_code || '--';
    const robotId = document.createElement('small');
    robotId.textContent = `Master ID ${robot.master_robot_id ?? '--'}`;
    robotCell.append(robotName, robotId);

    const statusCell = row.insertCell();
    statusCell.className = 'status-detail';
    const status = document.createElement('span');
    status.className = `status-pill ${robotVisualState(robot)}`;
    status.textContent = String(robot.data_freshness_status || 'MISSING').replaceAll('_', ' ');
    statusCell.append(status);
    const freshnessDetail = document.createElement('small');
    freshnessDetail.textContent = `DWS load ${formatDataAge(robot.status_dws_load_time || robot.dws_load_time)}`;
    statusCell.append(freshnessDetail);

    const batteryCell = row.insertCell();
    batteryCell.className = batteryClass(robot.battery_soc);
    const batteryValue = document.createElement('strong');
    batteryValue.textContent = robot.battery_soc == null ? '--' : `${formatNumber(robot.battery_soc, 1)}%`;
    const batteryDetail = document.createElement('small');
    const voltage = robot.battery_voltage == null ? '--' : `${formatNumber(robot.battery_voltage, 2)}V`;
    const current = robot.battery_current == null ? '--' : `${formatNumber(robot.battery_current, 2)}A`;
    batteryDetail.textContent = robot.battery_freshness_status === 'CURRENT'
      ? `${voltage} · ${current} · hourly average`
      : `Suppressed · ${String(robot.battery_freshness_status || 'MISSING').replaceAll('_', ' ')}`;
    batteryCell.append(batteryValue, batteryDetail);

    const taskCell = row.insertCell();
    taskCell.className = 'task-detail';
    const taskValue = document.createElement('strong');
    taskValue.textContent = 'Not available';
    const taskDetail = document.createElement('small');
    taskDetail.textContent = 'Current task is not stored in DWS daily aggregates';
    taskCell.append(taskValue, taskDetail);

    const modeCell = row.insertCell();
    modeCell.className = 'mode-detail';
    const modeId = document.createElement('strong');
    modeId.textContent = 'Not available';
    const modeDetail = document.createElement('small');
    modeDetail.textContent = 'Current mode is not stored in DWS hourly aggregates';
    modeCell.append(modeId, modeDetail);

    const rssiCell = row.insertCell();
    rssiCell.className = wifiFreshnessClass(robot);
    if (hasRssiMeasurementIssue(robot)) rssiCell.classList.add('rssi-measurement-issue');
    rssiCell.textContent = robot.current_rssi == null ? '--' : `${formatNumber(robot.current_rssi)} dBm`;
    const quality = document.createElement('small');
    quality.textContent = robot.wifi_freshness_status === 'CURRENT'
      ? 'Latest DWS hourly average'
      : `Suppressed · ${String(robot.wifi_freshness_status || 'MISSING').replaceAll('_', ' ')}`;
    rssiCell.append(quality);

    const zeroCell = row.insertCell();
    zeroCell.className = zeroSignalClass(robot.zero_signal_rate);
    zeroCell.textContent = '--';
    const zeroCount = document.createElement('small');
    zeroCount.textContent = 'Not measurable from DWS hourly data';
    zeroCell.append(zeroCount);

    const apCell = row.insertCell();
    apCell.textContent = 'Not available';
    const riskAp = document.createElement('small');
    riskAp.textContent = 'AP identity is not stored in DWS hourly data';
    apCell.append(riskAp);

    row.insertCell().textContent = robotPoiSummary(robot);

    const timeCell = row.insertCell();
    timeCell.className = dataTimeClass(robot.status_dws_load_time || robot.dws_load_time);
    timeCell.textContent = formatDateTime(robot.status_dws_load_time || robot.dws_load_time);
    const freshness = document.createElement('small');
    freshness.textContent = `Status event ${formatDateTime(robot.status_event_time)}`;
    timeCell.append(freshness);
  });
}

function renderLowBatteryRisk(robots) {
  elements.lowBatteryRiskBody.replaceChildren();
  const lowBatteryRobots = robots
    .filter(isLowBattery)
    .sort((a, b) => asNumber(a.battery_soc, 101) - asNumber(b.battery_soc, 101)
      || robotIdentifier(a).localeCompare(robotIdentifier(b), 'en'));

  if (!lowBatteryRobots.length) {
    const row = elements.lowBatteryRiskBody.insertRow();
    const cell = row.insertCell();
    cell.colSpan = 6;
    cell.className = 'empty-cell';
    const currentBatteryCount = robots.filter((robot) => robot.battery_freshness_status === 'CURRENT').length;
    cell.textContent = currentBatteryCount
      ? 'No freshness-gated DWS hourly battery average is at or below 20%'
      : `Battery values are suppressed because no robot currently passes the ${formatNumber(state.dashboard?.staleMinutes || 30)}-minute DWS freshness gate`;
    return;
  }

  lowBatteryRobots.forEach((robot) => {
    const row = elements.lowBatteryRiskBody.insertRow();
    row.addEventListener('click', () => selectRobot(robot.robot_code));
    const idCell = row.insertCell();
    idCell.className = 'robot-name';
    const code = document.createElement('strong');
    code.textContent = robotIdentifier(robot);
    const masterId = document.createElement('small');
    masterId.textContent = `Master ID ${robot.master_robot_id ?? '--'}`;
    idCell.append(code, masterId);

    const batteryCell = row.insertCell();
    batteryCell.className = 'battery-low';
    batteryCell.textContent = `${formatNumber(robot.battery_soc, 1)}%`;
    row.insertCell().textContent = robot.current_status || robot.online_status || '--';
    row.insertCell().textContent = robot.charging_status || '--';
    row.insertCell().textContent = robotPoiSummary(robot);
    row.insertCell().textContent = formatDateTime(robot.battery_event_time || robot.source_event_time);
  });
}

function renderTasks(robots) {
  elements.taskTableBody.replaceChildren();
  const row = elements.taskTableBody.insertRow();
  const cell = row.insertCell();
  cell.colSpan = 4;
  cell.className = 'empty-cell';
  cell.textContent = 'Current task state is not stored in non-snapshot DWS tables. Use the DWS daily task trend and workload analysis above.';
}

function renderTaskFailureOutcomes(rows) {
  const groups = new Map();
  rows.forEach((item) => {
    const outcome = String(item.failure_outcome || 'UNKNOWN').trim().toUpperCase();
    const group = groups.get(outcome) || { outcome, count: 0, robots: new Set(), latestTime: null };
    group.count += asNumber(item.failure_count);
    if (item.robot_code) group.robots.add(String(item.robot_code));
    if (item.latest_failure_time && (!group.latestTime || new Date(item.latest_failure_time) > new Date(group.latestTime))) {
      group.latestTime = item.latest_failure_time;
    }
    groups.set(outcome, group);
  });

  const outcomes = [...groups.values()]
    .sort((a, b) => b.count - a.count || a.outcome.localeCompare(b.outcome, 'en'));
  elements.taskFailureBody.replaceChildren();

  if (!outcomes.length) {
    const row = elements.taskFailureBody.insertRow();
    const cell = row.insertCell();
    cell.colSpan = 5;
    cell.className = 'empty-cell';
    cell.textContent = 'No unsuccessful queue outcomes are available in this time range';
    return;
  }

  outcomes.forEach((group) => {
    const row = elements.taskFailureBody.insertRow();
    const outcomeCell = row.insertCell();
    const outcome = document.createElement('span');
    outcome.className = 'status-pill alarm';
    outcome.textContent = group.outcome;
    outcomeCell.append(outcome);
    row.insertCell().textContent = formatNumber(group.count);
    row.insertCell().textContent = formatNumber(group.robots.size);
    row.insertCell().textContent = [...group.robots].sort((a, b) => a.localeCompare(b, 'en')).join(', ') || '--';
    row.insertCell().textContent = formatDateTime(group.latestTime);
  });
}

function renderAlerts(robots) {
  const groupedReasons = new Map();
  robots.forEach((robot) => {
    robotAlertCauses(robot).forEach((cause) => {
      const key = `${cause.code}\u0000${cause.reason}`;
      const group = groupedReasons.get(key) || { ...cause, robots: [], latestTime: null };
      group.robots.push(robotIdentifier(robot));
      if (cause.dataTime && (!group.latestTime || new Date(cause.dataTime) > new Date(group.latestTime))) {
        group.latestTime = cause.dataTime;
      }
      groupedReasons.set(key, group);
    });
  });
  const reasons = [...groupedReasons.values()]
    .sort((a, b) => b.robots.length - a.robots.length || a.reason.localeCompare(b.reason, 'en'));

  elements.alertBadge.textContent = formatNumber(reasons.length);
  elements.alertList.replaceChildren();
  if (!reasons.length) {
    elements.alertList.className = 'alert-list empty-state';
    elements.alertList.textContent = 'No delayed-telemetry, low-battery, no-signal or device-reported causes are present';
    return;
  }

  elements.alertList.className = 'alert-list';
  reasons.forEach((group) => {
    const item = document.createElement('button');
    item.type = 'button';
    item.className = `alert-item cause-${group.type}`;
    item.addEventListener('click', () => selectRobot(group.robots[0]));

    const text = document.createElement('span');
    text.className = 'alert-text';
    const title = document.createElement('strong');
    title.textContent = `${group.code} · ${group.reason}`;
    const detail = document.createElement('span');
    detail.textContent = `Affected robot IDs: ${group.robots.join(', ')}`;
    text.append(title, detail);

    const meta = document.createElement('span');
    meta.className = 'alert-meta';
    const count = document.createElement('strong');
    count.textContent = `${formatNumber(group.robots.length)} robots`;
    const time = document.createElement('span');
    time.textContent = formatShortTime(group.latestTime);
    meta.append(count, time);
    item.append(text, meta);
    elements.alertList.append(item);
  });
}

function syncMapSelect(robots) {
  const mapCounts = new Map();
  robots
    .filter((robot) => hasCoordinate(robot.position_x) && hasCoordinate(robot.position_y))
    .forEach((robot) => {
      const code = normalizedMapCode(robot);
      mapCounts.set(code, (mapCounts.get(code) || 0) + 1);
    });

  const mapEntries = [...mapCounts.entries()].sort((a, b) => {
    if (b[1] !== a[1]) return b[1] - a[1];
    return mapLabel(a[0]).localeCompare(mapLabel(b[0]), 'en');
  });

  if (!mapEntries.some(([code]) => code === state.selectedMapCode)) {
    state.selectedMapCode = mapEntries[0]?.[0] || null;
  }

  elements.mapSelect.replaceChildren();
  if (!mapEntries.length) {
    const option = document.createElement('option');
    option.value = '';
    option.textContent = 'No coordinate data';
    elements.mapSelect.append(option);
    elements.mapSelect.disabled = true;
    return mapEntries;
  }

  mapEntries.forEach(([code, count]) => {
    const option = document.createElement('option');
    option.value = code;
    option.textContent = `${mapLabel(code)} (${formatNumber(count)})`;
    option.selected = code === state.selectedMapCode;
    elements.mapSelect.append(option);
  });
  elements.mapSelect.disabled = false;
  return mapEntries;
}

function renderMap(robots) {
  elements.robotMapLayer.replaceChildren();
  const coordinateRobots = robots.filter((robot) => hasCoordinate(robot.position_x) && hasCoordinate(robot.position_y));
  const mapEntries = syncMapSelect(robots);
  const mapped = coordinateRobots.filter((robot) => normalizedMapCode(robot) === state.selectedMapCode);
  elements.mappedRobotCount.textContent = formatNumber(mapped.length);
  elements.mapCodeCount.textContent = formatNumber(mapEntries.length);
  elements.mapEmpty.style.display = mapped.length ? 'none' : 'block';
  if (!mapped.length) return;

  const xs = mapped.map((robot) => Number(robot.position_x));
  const ys = mapped.map((robot) => Number(robot.position_y));
  const minX = Math.min(...xs); const maxX = Math.max(...xs);
  const minY = Math.min(...ys); const maxY = Math.max(...ys);
  const scaleX = (value) => maxX === minX ? 500 : 95 + ((value - minX) / (maxX - minX)) * 810;
  const scaleY = (value) => maxY === minY ? 300 : 505 - ((value - minY) / (maxY - minY)) * 410;

  mapped.forEach((robot) => {
    const group = svgElement('g', { class: 'robot-marker', tabindex: '0', role: 'button' });
    const x = scaleX(Number(robot.position_x));
    const y = scaleY(Number(robot.position_y));
    const visualState = robotVisualState(robot);
    const color = visualState === 'alarm' ? '#dc2626' : visualState === 'online' ? '#059669' : '#2563eb';
    const selected = robot.robot_code === state.selectedRobotCode;

    const pulse = svgElement('circle', { cx: x, cy: y, r: selected ? 17 : 12, fill: 'none', stroke: color, 'stroke-opacity': selected ? 0.8 : 0.28, 'stroke-width': 2 });
    const dot = svgElement('circle', { cx: x, cy: y, r: selected ? 7 : 5, fill: color, class: 'robot-dot' });
    const label = svgElement('text', { x: x + 10, y: y - 9, class: 'robot-label' });
    label.textContent = robot.robot_code || 'Unknown robot';
    const title = svgElement('title');
    title.textContent = `${robot.robot_code || 'Unknown robot'} | ${robot.current_status || 'Status not reported'} | Mode ${robot.current_mode_id || '--'} ${robot.current_mode || '--'} | Battery ${robot.battery_soc ?? '--'}%`;

    const handler = () => selectRobot(robot.robot_code);
    group.addEventListener('click', handler);
    group.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') handler(); });
    group.append(title, pulse, dot, label);
    elements.robotMapLayer.append(group);
  });
}

function selectRobot(robotCode) {
  state.selectedRobotCode = robotCode || null;
  elements.selectedRobot.textContent = robotCode || '--';
  const robot = (state.dashboard?.robots || []).find((item) => item.robot_code === robotCode);
  if (robot && hasCoordinate(robot.position_x) && hasCoordinate(robot.position_y)) {
    state.selectedMapCode = normalizedMapCode(robot);
  }
  renderMap(state.dashboard?.robots || []);
  renderRobotVitals(state.dashboard?.robots || []);
}

function renderLineChart(host, rows = [], options) {
  host.replaceChildren();
  const points = rows
    .map((row) => {
      const rawValue = row[options.valueKey];
      return {
        label: row[options.labelKey],
        value: rawValue === null || rawValue === undefined || rawValue === ''
          ? null
          : Number(rawValue)
      };
    })
    .filter((point) => point.value !== null && Number.isFinite(point.value));

  if (!points.length) {
    const empty = document.createElement('div');
    empty.className = 'chart-empty';
    empty.textContent = 'No trend data is available for this time range';
    host.append(empty);
    return;
  }

  if (points.length < 4) {
    const sparse = document.createElement('div');
    sparse.className = 'chart-sparse';
    points.forEach((point) => {
      const row = document.createElement('div');
      row.className = 'chart-sparse-row';
      const label = document.createElement('span');
      label.textContent = formatShortTime(point.label);
      const value = document.createElement('strong');
      value.textContent = `${formatNumber(point.value, 2)}${options.suffix}`;
      row.append(label, value);
      sparse.append(row);
    });
    host.append(sparse);
    return;
  }

  const width = 420; const height = 155;
  const margin = { left: 40, right: 12, top: 10, bottom: 28 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  const rawMin = Math.min(...points.map((point) => point.value));
  const rawMax = Math.max(...points.map((point) => point.value));
  const padding = (rawMax - rawMin || Math.abs(rawMax) || 1) * 0.1;
  let min;
  let max;
  if (options.fixedRange) {
    [min, max] = options.fixedRange;
  } else if (options.nonNegative && rawMax === 0) {
    min = 0;
    max = 1;
  } else {
    min = rawMin - padding;
    max = rawMax + padding;
    if (options.nonNegative) min = Math.max(0, min);
  }
  const x = (index) => margin.left + (index / Math.max(points.length - 1, 1)) * plotWidth;
  const y = (value) => margin.top + (1 - (value - min) / (max - min || 1)) * plotHeight;

  const svg = svgElement('svg', { viewBox: `0 0 ${width} ${height}`, role: 'img', 'aria-label': 'Time trend chart' });

  [0, 0.5, 1].forEach((ratio) => {
    const lineY = margin.top + ratio * plotHeight;
    svg.append(svgElement('line', { x1: margin.left, y1: lineY, x2: width - margin.right, y2: lineY, class: 'chart-grid-line' }));
    const label = svgElement('text', { x: margin.left - 6, y: lineY + 3, 'text-anchor': 'end', class: 'chart-axis-label' });
    label.textContent = formatNumber(max - ratio * (max - min), Math.abs(max - min) < 10 ? 1 : 0);
    svg.append(label);
  });

  const pathData = points.map((point, index) => `${index === 0 ? 'M' : 'L'} ${x(index)} ${y(point.value)}`).join(' ');
  const linePath = svgElement('path', { d: pathData, class: 'chart-line' });
  linePath.style.stroke = options.color;
  svg.append(linePath);

  const pointInterval = Math.max(1, Math.ceil(points.length / 24));
  points.forEach((point, index) => {
    if (index % pointInterval !== 0 && index !== points.length - 1) return;
    const circle = svgElement('circle', { cx: x(index), cy: y(point.value), r: 2.5, stroke: options.color, class: 'chart-point' });
    circle.style.stroke = options.color;
    const title = svgElement('title');
    title.textContent = `${formatShortTime(point.label)}: ${formatNumber(point.value, 2)}${options.suffix}`;
    circle.append(title);
    svg.append(circle);
  });

  const firstLabel = svgElement('text', { x: margin.left, y: height - 7, class: 'chart-axis-label' });
  firstLabel.textContent = formatShortTime(points[0].label);
  const lastLabel = svgElement('text', { x: width - margin.right, y: height - 7, 'text-anchor': 'end', class: 'chart-axis-label' });
  lastLabel.textContent = formatShortTime(points[points.length - 1].label);
  svg.append(firstLabel, lastLabel);
  host.append(svg);

  const summary = document.createElement('div');
  summary.className = 'chart-summary';
  const current = document.createElement('span');
  const currentStrong = document.createElement('strong');
  currentStrong.textContent = `${formatNumber(points[points.length - 1].value, 2)}${options.suffix}`;
  current.append('Latest ', currentStrong);
  const range = document.createElement('span');
  const rangeStrong = document.createElement('strong');
  rangeStrong.textContent = `${formatNumber(rawMin, 2)} – ${formatNumber(rawMax, 2)}`;
  range.append('Range ', rangeStrong);
  summary.append(current, range);
  host.append(summary);
}

function renderBatches(batches) {
  elements.batchTableBody.replaceChildren();
  if (!batches.length) {
    const row = elements.batchTableBody.insertRow();
    const cell = row.insertCell();
    cell.colSpan = 5;
    cell.className = 'empty-cell';
    cell.textContent = 'No DWS load batches are available';
    return;
  }

  batches.forEach((batch) => {
    const row = elements.batchTableBody.insertRow();
    row.insertCell().textContent = batch.batch_id;
    row.insertCell().textContent = formatDateTime(batch.batch_start_time);
    row.insertCell().textContent = formatDateTime(batch.batch_end_time);
    const status = row.insertCell();
    status.textContent = batch.batch_status || '--';
    status.className = `batch-${String(batch.batch_status || '').toLowerCase()}`;
    row.insertCell().textContent = batch.error_message || '--';
  });
}
