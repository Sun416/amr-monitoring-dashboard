'use strict';

const state = {
  dashboard: null,
  robotProfile: null,
  selectedRobotId: null,
  profileRequestId: 0,
  selectedRobotCode: null,
  selectedMapCode: null,
  loading: false,
  currentView: 'overview',
  window: { key: 'd1', label: 'Last 1 day', hours: 24, days: 1 }
};

const VIEW_META = {
  overview: { eyebrow: '01 · OVERVIEW', title: 'Overview', description: 'Review fleet health first, then open a focused analysis view.' },
  operations: { eyebrow: '02 · OPERATIONS', title: 'Operating Status', description: 'Review status, mode and robot position.' },
  tasks: { eyebrow: '03 · TASKS', title: 'Task Analytics', description: 'Review task performance, queues and the current task snapshot.' },
  energy: { eyebrow: '04 · ENERGY', title: 'Energy Analytics', description: 'Identify exact robot IDs at low-battery risk and review the trend.' },
  network: { eyebrow: '05 · NETWORK', title: 'Network Quality', description: 'Review RSSI, zero-signal rate and access-point risk.' },
  alarms: { eyebrow: '06 · ALERTS', title: 'Robot Alert Causes', description: 'See delayed telemetry, low battery, signal loss and device-reported errors by robot ID.' },
  robots: { eyebrow: '07 · ROBOT DETAILS', title: 'Robot Details', description: 'Search robot-level operating data in one place.' },
  'robot-profile': { eyebrow: '08 · ROBOT PROFILE', title: 'Robot Profile', description: 'Select one Robot ID and review its complete current and historical status.' },
  'data-quality': { eyebrow: '09 · DATA QUALITY', title: 'Data Quality', description: 'Review data freshness, lag and DWS load batches.' }
};

const elements = Object.fromEntries(
  [
    'sidebar', 'sidebarOverlay', 'sidebarToggle', 'viewEyebrow', 'viewTitle', 'viewDescription',
    'currentDate', 'currentTime', 'freshnessDot', 'connectionStatus', 'sourceFreshness', 'sourceLag', 'dwsFreshness', 'wifiFreshness',
    'rangeSelect', 'analysisWindowLabel', 'refreshButton', 'syncButton', 'exportAllButton', 'metricTotal', 'metricTotalScope', 'metricOnline',
    'metricOffline', 'metricJobs', 'metricJobScope', 'metricBattery', 'metricLowBattery', 'metricRssi', 'metricWifiCoverage',
    'metricZeroSignal', 'metricZeroSignalScope', 'metricAlarms', 'metricAlarmScope', 'metricTaskSuccess', 'metricTaskSuccessScope',
    'operationsOnlineValue', 'operationsOfflineValue', 'operationsOfflineIds', 'operationsActiveValue', 'operationsActiveIds',
    'taskSuccessValue', 'taskFailureValue', 'taskFailureSummary', 'taskActiveValue', 'taskActiveIds', 'energyAverageValue', 'energyLowBatteryValue', 'energyLowBatteryIds',
    'networkRssiValue', 'networkZeroValue', 'networkCoverageValue', 'networkStaleIds', 'alarmRobotValue', 'alarmRobotIds',
    'alarmLowBatteryValue', 'alarmLowBatteryIds', 'alarmNoSignalValue', 'alarmNoSignalIds',
    'statusDistribution', 'modeDistribution', 'robotSearch', 'taskTableBody', 'taskFailureBody', 'lowBatteryRiskBody',
    'alertList', 'alertBadge', 'robotMapLayer', 'mapEmpty', 'mapSelect', 'mappedRobotCount', 'mapCodeCount',
    'selectedRobot', 'robotVitalsBody', 'wifiRiskBody', 'wifiWindowLabel', 'batteryChart', 'wifiChart',
    'jobChart', 'alarmChart', 'queueChart', 'batteryTrendAnchor', 'batchTableBody',
    'profileRobotSelect', 'profileRobotSubtitle', 'profileAlertBanner', 'profileStatusValue', 'profileStatusDetail',
    'profileBatteryValue', 'profileBatteryDetail', 'profileTaskValue', 'profileTaskDetail', 'profileWifiValue',
    'profileWifiDetail', 'profilePositionValue', 'profilePositionDetail', 'profileDataTimeValue', 'profileDataTimeDetail',
    'profileBatteryChart', 'profileWifiChart', 'profileStatusChart', 'profileJobChart', 'profileSourceTimesBody',
    'profileTaskBreakdownBody', 'toast'
  ].map((id) => [id, document.getElementById(id)])
);

const SVG_NS = 'http://www.w3.org/2000/svg';

function closeSidebar() {
  elements.sidebar.classList.remove('open');
  elements.sidebarOverlay.classList.remove('open');
  elements.sidebarToggle.setAttribute('aria-expanded', 'false');
}

function activateView(view, { updateHash = true } = {}) {
  const meta = VIEW_META[view];
  const target = document.querySelector(`[data-view-panel="${view}"]`);
  if (!meta || !target) return;

  state.currentView = view;
  document.querySelectorAll('[data-view-panel]').forEach((panel) => panel.classList.toggle('active', panel === target));
  document.querySelectorAll('[data-view]').forEach((button) => {
    const active = button.dataset.view === view;
    button.classList.toggle('active', active);
    if (active) button.setAttribute('aria-current', 'page');
    else button.removeAttribute('aria-current');
  });
  elements.viewEyebrow.textContent = meta.eyebrow;
  elements.viewTitle.textContent = meta.title;
  elements.viewDescription.textContent = meta.description;
  document.title = `${meta.title} · AMR Operations Analytics`;
  if (updateHash) history.replaceState(null, '', `#${view}`);
  closeSidebar();
  window.scrollTo({ top: 0, behavior: 'smooth' });
  if (view === 'robot-profile' && state.dashboard) loadRobotProfile();
}

function svgElement(name, attributes = {}) {
  const node = document.createElementNS(SVG_NS, name);
  Object.entries(attributes).forEach(([key, value]) => node.setAttribute(key, String(value)));
  return node;
}

function asNumber(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function formatNumber(value, maximumFractionDigits = 0) {
  if (value === null || value === undefined || value === '') return '--';
  return new Intl.NumberFormat('en-US', { maximumFractionDigits }).format(asNumber(value));
}

function formatPercent(value, maximumFractionDigits = 1) {
  if (value === null || value === undefined || value === '') return '--';
  return `${formatNumber(value, maximumFractionDigits)}%`;
}

function formatDateTime(value) {
  if (!value) return '--';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  return new Intl.DateTimeFormat('en-GB', {
    month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false
  }).format(date);
}

function formatShortTime(value) {
  if (!value) return '--';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value).slice(0, 10);
  return new Intl.DateTimeFormat('en-GB', {
    month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false
  }).format(date);
}

function dataTimeClass(value) {
  if (!value) return 'data-stale';
  const dataTime = new Date(value);
  const referenceTime = new Date(state.dashboard?.summary?.database_current_time || state.dashboard?.generatedAt || Date.now());
  if (Number.isNaN(dataTime.getTime()) || Number.isNaN(referenceTime.getTime())) return 'data-stale';
  const staleMinutes = asNumber(state.dashboard?.staleMinutes, 5);
  return referenceTime.getTime() - dataTime.getTime() <= staleMinutes * 60 * 1000
    ? 'data-current'
    : 'data-stale';
}

function dataAgeMinutes(value) {
  if (!value) return Number.POSITIVE_INFINITY;
  const dataTime = new Date(value);
  const referenceTime = new Date(state.dashboard?.summary?.database_current_time || state.dashboard?.generatedAt || Date.now());
  if (Number.isNaN(dataTime.getTime()) || Number.isNaN(referenceTime.getTime())) return Number.POSITIVE_INFINITY;
  return Math.max(0, (referenceTime.getTime() - dataTime.getTime()) / 60000);
}

function formatDataAge(value) {
  const minutes = dataAgeMinutes(value);
  if (!Number.isFinite(minutes)) return 'No timestamp available';
  if (minutes >= 1440) return `${formatNumber(minutes / 1440, 1)} days old`;
  if (minutes >= 60) return `${formatNumber(minutes / 60, 1)} hours old`;
  return `${formatNumber(minutes)} minutes old`;
}

function isRobotDataStale(robot) {
  return dataAgeMinutes(robot?.latest_data_time) > asNumber(state.dashboard?.staleMinutes, 5);
}

function updateClock() {
  const now = new Date();
  elements.currentDate.textContent = new Intl.DateTimeFormat('en-GB', {
    year: 'numeric', month: '2-digit', day: '2-digit', weekday: 'short'
  }).format(now);
  elements.currentTime.textContent = new Intl.DateTimeFormat('en-GB', {
    hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false
  }).format(now);
}

function normalizedOnlineStatus(value) {
  const status = String(value || '').trim().toUpperCase();
  if (['ONLINE', 'ON', 'TRUE', '1', 'ACTIVE'].includes(status)) return 'online';
  if (['OFFLINE', 'OFF', 'FALSE', '0', 'INACTIVE'].includes(status)) return 'offline';
  return 'unknown';
}

function hasAlarm(robot) {
  const message = String(robot.error_message || '').trim().toUpperCase();
  const code = String(robot.error_code || '').trim().toUpperCase();
  return !['', '-', 'NULL', 'UNDEFINED', 'NONE'].includes(message)
    || !['', '-', '0', 'NULL', 'UNDEFINED', 'NONE', 'FALSE', 'OK', 'NORMAL'].includes(code);
}

function hasActiveJob(robot) {
  if (robot && Object.prototype.hasOwnProperty.call(robot, 'is_active_job')) {
    return robot.is_active_job === true || robot.is_active_job === 1 || robot.is_active_job === '1';
  }
  const job = String(robot.job_id || '').trim().toUpperCase();
  return !['', '-', '0', 'NULL', 'UNDEFINED', 'IDLE'].includes(job);
}

function hasCoordinate(value) {
  return value !== null && value !== undefined && value !== '' && Number.isFinite(Number(value));
}

function isLowBattery(robot) {
  const battery = Number(robot?.battery_soc);
  return Number.isFinite(battery) && battery >= 0 && battery <= 20;
}

function isNoSignal(robot) {
  const value = robot?.current_rssi;
  return value !== null && value !== undefined && value !== '' && Number(value) === 0;
}

function robotAlertCauses(robot) {
  const causes = [];
  if (isRobotDataStale(robot)) {
    causes.push({
      code: 'DATA_STALE',
      reason: robot.latest_data_time
        ? `Telemetry has not updated within ${formatNumber(state.dashboard?.staleMinutes || 5)} minutes`
        : 'No telemetry timestamp is available',
      type: 'data-stale',
      dataTime: robot.latest_data_time
    });
  }
  if (hasAlarm(robot)) {
    causes.push({
      code: String(robot.error_code || 'DEVICE_ERROR').trim(),
      reason: String(robot.error_message || '').trim()
        || `Device emergency status reported (code ${String(robot.error_code).trim()})`,
      type: 'device-error',
      dataTime: robot.status_event_time || robot.source_event_time
    });
  }
  if (isLowBattery(robot)) {
    causes.push({
      code: 'LOW_BATTERY',
      reason: 'Low battery (battery at or below 20%)',
      type: 'low-battery',
      dataTime: robot.battery_event_time || robot.source_event_time
    });
  }
  if (isNoSignal(robot)) {
    causes.push({
      code: 'NO_SIGNAL',
      reason: 'No signal in the latest known WiFi sample (RSSI = 0)',
      type: 'no-signal',
      dataTime: robot.latest_wifi_time
    });
  }
  return causes;
}

function hasOperationalAlert(robot) {
  return robotAlertCauses(robot).length > 0;
}

function taskFailureSummary(rows = []) {
  const totals = new Map();
  rows.forEach((row) => {
    const outcome = String(row.failure_outcome || 'UNKNOWN').trim().toUpperCase();
    totals.set(outcome, (totals.get(outcome) || 0) + asNumber(row.failure_count));
  });
  if (!totals.size) return 'No unsuccessful queue outcomes';
  return [...totals.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0], 'en'))
    .map(([outcome, count]) => `${outcome}: ${formatNumber(count)}`)
    .join(' · ');
}

function robotIdentifier(robot) {
  return robot?.robot_code || robot?.robot_name || (robot?.master_robot_id == null ? 'Unknown robot' : `Master ${robot.master_robot_id}`);
}

function robotIdSummary(robots, predicate, { prefix = 'IDs', limit = 6 } = {}) {
  const ids = robots.filter(predicate).map(robotIdentifier);
  if (!ids.length) return `${prefix}: None`;
  const visible = ids.slice(0, limit).join(', ');
  return `${prefix}: ${visible}${ids.length > limit ? ` +${ids.length - limit}` : ''}`;
}

function normalizedMapCode(robot) {
  const mapCode = String(robot?.map_code || '').trim();
  return mapCode || '__NO_MAP__';
}

function mapLabel(mapCode) {
  return mapCode === '__NO_MAP__' ? 'Unassigned map' : mapCode;
}

function robotPoiSummary(robot) {
  const currentPoi = String(robot?.station_code || '').trim();
  const targetPoi = String(robot?.target_station_code || '').trim();

  if (currentPoi && targetPoi && currentPoi !== targetPoi) return `${currentPoi} → ${targetPoi}`;
  if (currentPoi) return currentPoi;
  if (targetPoi) return `Target ${targetPoi}`;
  return String(robot?.map_code || '').trim() || '--';
}

function selectedWindow() {
  const option = elements.rangeSelect.selectedOptions[0];
  return {
    key: option?.value || 'd1',
    label: option?.textContent?.trim() || 'Last 1 day',
    hours: asNumber(option?.dataset.hours, 24),
    days: asNumber(option?.dataset.days, 1)
  };
}

function robotVisualState(robot) {
  if (hasOperationalAlert(robot)) return 'alarm';
  return normalizedOnlineStatus(robot.online_status);
}

function batteryClass(value) {
  const battery = asNumber(value, -1);
  if (battery < 0) return '';
  if (battery <= 20) return 'battery-low';
  if (battery <= 50) return 'battery-mid';
  return 'battery-ok';
}

function showToast(message, type = 'info') {
  elements.toast.textContent = message;
  elements.toast.className = `toast show ${type === 'error' ? 'error' : ''}`;
  window.clearTimeout(showToast.timer);
  showToast.timer = window.setTimeout(() => { elements.toast.className = 'toast'; }, 4200);
}

function setBusy(isBusy, message) {
  state.loading = isBusy;
  elements.refreshButton.disabled = isBusy;
  elements.syncButton.disabled = isBusy;
  if (message) elements.connectionStatus.textContent = message;
}

async function requestJson(url, options) {
  const response = await fetch(url, options);
  let payload = {};
  try { payload = await response.json(); } catch { payload = {}; }
  if (!response.ok) {
    const error = new Error(payload.message || `Request failed (${response.status})`);
    error.code = payload.code;
    throw error;
  }
  return payload;
}

async function loadDashboard({ announce = false } = {}) {
  if (state.loading) return;
  setBusy(true, 'Loading DWS and WiFi analytics data...');

  try {
    state.window = selectedWindow();
    const params = new URLSearchParams({
      hours: state.window.hours,
      days: state.window.days
    });
    state.dashboard = await requestJson(`/api/dashboard?${params}`);
    renderDashboard(state.dashboard);
    if (announce) showToast(`Refreshed: ${state.window.label}`);
  } catch (error) {
    renderConnectionError(error);
    showToast(error.message, 'error');
  } finally {
    setBusy(false);
  }
}

function populateRobotProfileSelector(robots) {
  const sorted = [...robots].sort((a, b) => robotIdentifier(a).localeCompare(robotIdentifier(b), 'en'));
  const availableIds = new Set(sorted.map((robot) => String(robot.master_robot_id)));
  if (!state.selectedRobotId || !availableIds.has(String(state.selectedRobotId))) {
    state.selectedRobotId = sorted[0]?.master_robot_id == null ? null : String(sorted[0].master_robot_id);
  }

  elements.profileRobotSelect.replaceChildren();
  if (!sorted.length) {
    const option = document.createElement('option');
    option.value = '';
    option.textContent = 'No enabled robots';
    elements.profileRobotSelect.append(option);
    elements.profileRobotSelect.disabled = true;
    return;
  }

  sorted.forEach((robot) => {
    const option = document.createElement('option');
    option.value = String(robot.master_robot_id);
    option.textContent = `${robotIdentifier(robot)} · Master ID ${robot.master_robot_id}`;
    option.selected = option.value === String(state.selectedRobotId);
    elements.profileRobotSelect.append(option);
  });
  elements.profileRobotSelect.disabled = false;
}

async function loadRobotProfile() {
  if (!state.dashboard || !state.selectedRobotId) return;
  const requestId = ++state.profileRequestId;
  elements.profileRobotSelect.disabled = true;
  elements.profileAlertBanner.dataset.tone = 'neutral';
  elements.profileAlertBanner.querySelector('strong').textContent = 'Loading the selected robot profile...';

  try {
    const params = new URLSearchParams({ hours: state.window.hours, days: state.window.days });
    const profile = await requestJson(`/api/robot/${encodeURIComponent(state.selectedRobotId)}?${params}`);
    if (requestId !== state.profileRequestId) return;
    state.robotProfile = profile;
    renderRobotProfile(profile);
  } catch (error) {
    if (requestId !== state.profileRequestId) return;
    state.robotProfile = null;
    elements.profileAlertBanner.dataset.tone = 'critical';
    elements.profileAlertBanner.querySelector('strong').textContent = error.message;
    showToast(error.message, 'error');
  } finally {
    if (requestId === state.profileRequestId) {
      elements.profileRobotSelect.disabled = false;
    }
  }
}

async function syncCurrentSnapshot() {
  if (state.loading) return;
  setBusy(true, 'Synchronizing the current robot status...');

  try {
    await requestJson('/api/sync/current', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
    setBusy(false);
    showToast('Current status synchronized. Reloading the dashboard...');
    await loadDashboard();
  } catch (error) {
    renderConnectionError(error);
    showToast(error.message, 'error');
    setBusy(false);
  }
}

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

  if (sourceAgeMinutes <= data.staleMinutes) {
    elements.connectionStatus.textContent = 'DWS connected · Status data is current';
    elements.freshnessDot.className = 'status-dot ok';
  } else if (loadAgeMinutes <= data.staleMinutes) {
    elements.connectionStatus.textContent = 'DWS snapshot current · Upstream status data is delayed';
    elements.freshnessDot.className = 'status-dot stale';
  } else {
    elements.connectionStatus.textContent = 'DWS available · Status data and snapshot are delayed';
    elements.freshnessDot.className = 'status-dot stale';
  }
  elements.sourceFreshness.textContent = formatDateTime(summary.source_anchor_time || summary.latest_source_event_time);
  elements.sourceLag.textContent = summary.source_anchor_lag_minutes == null
    ? '--'
    : `${formatNumber(Math.max(0, asNumber(summary.source_anchor_lag_minutes)))} min`;
  elements.dwsFreshness.textContent = formatDateTime(summary.latest_dws_load_time);
  elements.wifiFreshness.textContent = formatDateTime(summary.wifi_anchor_time);

  elements.metricTotal.textContent = `${formatNumber(summary.total_robot_count)} / ${formatNumber(summary.commissioned_robot_count)}`;
  elements.metricTotalScope.textContent = `Enabled / commissioned · ${formatNumber(summary.snapshot_robot_count)} matched snapshots`;
  elements.metricOnline.textContent = formatNumber(summary.online_robot_count);
  elements.metricOffline.textContent = `Reported within ${formatNumber(data.onlineAnchorMinutes)} min · ${formatNumber(summary.offline_robot_count)} timed out · ${formatNumber(summary.missing_snapshot_robot_count)} missing snapshots`;
  elements.metricJobs.textContent = formatNumber(summary.active_job_robot_count);
  elements.metricJobScope.textContent = `Reported within ${formatNumber(data.onlineAnchorMinutes)} min · Working / Running`;
  elements.metricTaskSuccess.textContent = taskSuccessRate == null ? '--' : formatPercent(taskSuccessRate, 1);
  elements.metricTaskSuccessScope.textContent = `Queue outcomes · ${formatNumber(taskTotals.completed)} completed / ${formatNumber(taskTotals.failed)} unsuccessful`;
  elements.metricBattery.textContent = summary.avg_battery_soc == null ? '--' : `${formatNumber(summary.avg_battery_soc, 1)}%`;
  elements.metricLowBattery.textContent = `≤20%: ${formatNumber(summary.low_battery_robot_count)} · ${robotIdSummary(robots, isLowBattery, { prefix: 'IDs', limit: 3 })}`;
  elements.metricRssi.textContent = summary.avg_current_rssi == null ? '--' : `${formatNumber(summary.avg_current_rssi, 1)} dBm`;
  elements.metricWifiCoverage.textContent = `Reported in last 5 min: ${formatNumber(summary.wifi_current_robot_count)} / ${formatNumber(summary.active_robot_count)}`;
  elements.metricZeroSignal.textContent = formatPercent(summary.zero_signal_rate, 2);
  elements.metricZeroSignalScope.textContent = `Last ${formatNumber(summary.wifi_window_hours)} hours · ${formatNumber(summary.zero_signal_sample_count)} / ${formatNumber(summary.wifi_sample_count)} samples`;
  elements.metricAlarms.textContent = formatNumber(attentionRobots.length);
  elements.metricAlarmScope.textContent = `${formatNumber(staleDataRobots.length)} delayed · ${formatNumber(lowBatteryRobots.length)} low battery · ${formatNumber(noSignalRobots.length)} no signal · ${formatNumber(deviceAlarmRobots.length)} device errors`;
  elements.operationsOnlineValue.textContent = `${formatNumber(summary.online_robot_count)} robots`;
  elements.operationsOfflineValue.textContent = `${formatNumber(summary.offline_robot_count)} robots`;
  elements.operationsOfflineIds.textContent = robotIdSummary(robots, (robot) => normalizedOnlineStatus(robot.online_status) !== 'online');
  elements.operationsActiveValue.textContent = `${formatNumber(summary.active_job_robot_count)} robots`;
  elements.operationsActiveIds.textContent = robotIdSummary(robots, hasActiveJob);
  elements.taskSuccessValue.textContent = taskSuccessRate == null ? '--' : formatPercent(taskSuccessRate, 1);
  elements.taskFailureValue.textContent = formatNumber(taskTotals.failed);
  elements.taskFailureSummary.textContent = taskFailureSummary(data.taskFailureOutcomes || []);
  elements.taskActiveValue.textContent = `${formatNumber(summary.active_job_robot_count)} robots`;
  elements.taskActiveIds.textContent = robotIdSummary(robots, hasActiveJob);
  elements.energyAverageValue.textContent = summary.avg_battery_soc == null ? '--' : `${formatNumber(summary.avg_battery_soc, 1)}%`;
  elements.energyLowBatteryValue.textContent = `${formatNumber(summary.low_battery_robot_count)} robots`;
  elements.energyLowBatteryIds.textContent = robotIdSummary(robots, isLowBattery);
  elements.networkRssiValue.textContent = summary.avg_current_rssi == null ? '--' : `${formatNumber(summary.avg_current_rssi, 1)} dBm`;
  elements.networkZeroValue.textContent = formatPercent(summary.zero_signal_rate, 2);
  elements.networkCoverageValue.textContent = `${formatNumber(summary.wifi_current_robot_count)} / ${formatNumber(summary.active_robot_count)} robots`;
  elements.networkStaleIds.textContent = robotIdSummary(robots, (robot) => !robot.wifi_is_current, { prefix: 'Not current' });
  elements.alarmRobotValue.textContent = `${formatNumber(attentionRobots.length)} robots`;
  elements.alarmRobotIds.textContent = robotIdSummary(robots, hasOperationalAlert);
  elements.alarmLowBatteryValue.textContent = `${formatNumber(lowBatteryRobots.length)} robots`;
  elements.alarmLowBatteryIds.textContent = robotIdSummary(robots, isLowBattery);
  elements.alarmNoSignalValue.textContent = `${formatNumber(noSignalRobots.length)} robots`;
  elements.alarmNoSignalIds.textContent = robotIdSummary(robots, isNoSignal);
  elements.wifiWindowLabel.textContent = `Last ${formatNumber(summary.wifi_window_hours)} hours`;
  elements.analysisWindowLabel.textContent = state.window.label;
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
  renderWifiRisk(data.wifiAccessPointRisk || []);
  renderLineChart(elements.batteryChart, data.batteryTrend, {
    valueKey: 'avg_battery_soc', labelKey: 'stat_hour', color: '#2563eb', suffix: '%', fixedRange: [0, 100]
  });
  renderLineChart(elements.wifiChart, data.wifiTrend, {
    valueKey: 'avg_rssi', labelKey: 'stat_hour', color: '#7c3aed', suffix: ' dBm'
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

function renderRobotProfile(profile) {
  const current = (state.dashboard?.robots || []).find(
    (robot) => String(robot.master_robot_id) === String(profile.robot.master_robot_id)
  );
  if (!current) {
    elements.profileAlertBanner.dataset.tone = 'critical';
    elements.profileAlertBanner.querySelector('strong').textContent = 'The selected robot is not present in the current dashboard snapshot.';
    return;
  }

  const robotId = robotIdentifier(current);
  const causes = robotAlertCauses(current);
  elements.profileRobotSelect.value = String(current.master_robot_id);
  elements.profileRobotSubtitle.textContent = `Master ID ${current.master_robot_id} · ${state.window.label} · ${profile.robot.robot_serial_number || 'Serial number not reported'}`;
  elements.profileAlertBanner.dataset.tone = causes.length ? 'critical' : 'healthy';
  elements.profileAlertBanner.querySelector('span').textContent = causes.length ? 'Alert Cause' : 'Current Health';
  elements.profileAlertBanner.querySelector('strong').textContent = causes.length
    ? causes.map((cause) => `${cause.code}: ${cause.reason}`).join(' · ')
    : 'No current alert causes were detected for this robot.';

  elements.profileStatusValue.textContent = current.current_status || 'Not reported';
  elements.profileStatusDetail.textContent = `${current.online_status || 'UNKNOWN'} · Mode ${current.current_mode_id || '--'} ${current.current_mode || '--'}`;
  elements.profileBatteryValue.textContent = current.battery_soc == null ? '--' : `${formatNumber(current.battery_soc, 1)}%`;
  elements.profileBatteryValue.className = batteryClass(current.battery_soc);
  elements.profileBatteryDetail.textContent = `${current.charging_status || 'Charging state not reported'} · ${formatNumber(current.battery_voltage, 2)}V · ${formatNumber(current.battery_current, 2)}A`;
  elements.profileTaskValue.textContent = hasActiveJob(current) ? (current.job_id || 'Active job') : 'No active job';
  elements.profileTaskDetail.textContent = `${current.job_status || 'Status not reported'} · Target ${current.target_station_code || '--'}`;
  elements.profileWifiValue.textContent = current.current_rssi == null ? '--' : `${formatNumber(current.current_rssi)} dBm`;
  elements.profileWifiDetail.textContent = `${current.current_wifi_ap || 'Access point not reported'} · Quality ${formatNumber(current.current_wifi_quality)}`;
  elements.profilePositionValue.textContent = robotPoiSummary(current);
  elements.profilePositionDetail.textContent = `${current.map_code || 'Map not reported'} · X ${formatNumber(current.position_x, 2)} · Y ${formatNumber(current.position_y, 2)}`;
  elements.profileDataTimeValue.textContent = formatDateTime(current.latest_data_time);
  elements.profileDataTimeValue.className = dataTimeClass(current.latest_data_time);
  elements.profileDataTimeDetail.textContent = formatDataAge(current.latest_data_time);

  renderLineChart(elements.profileBatteryChart, profile.batteryTrend, {
    valueKey: 'avg_battery_soc', labelKey: 'stat_hour', color: '#2563eb', suffix: '%', fixedRange: [0, 100]
  });
  renderLineChart(elements.profileWifiChart, profile.wifiTrend, {
    valueKey: 'avg_rssi', labelKey: 'stat_hour', color: '#7c3aed', suffix: ' dBm'
  });
  renderLineChart(elements.profileStatusChart, profile.statusTrend, {
    valueKey: 'error_sample_count', labelKey: 'stat_hour', color: '#dc2626', suffix: '', nonNegative: true
  });
  renderLineChart(elements.profileJobChart, profile.jobTrend, {
    valueKey: 'job_count', labelKey: 'stat_date', color: '#059669', suffix: '', nonNegative: true
  });

  const sourceTimes = [
    ['Status', current.status_event_time || current.source_event_time],
    ['Battery', current.battery_event_time],
    ['WiFi', current.latest_wifi_time],
    ['Current task', current.job_event_time],
    ['DWS snapshot load', current.dws_load_time]
  ];
  elements.profileSourceTimesBody.replaceChildren();
  sourceTimes.forEach(([source, time]) => {
    const row = elements.profileSourceTimesBody.insertRow();
    row.insertCell().textContent = source;
    const timeCell = row.insertCell();
    timeCell.textContent = formatDateTime(time);
    if (source !== 'DWS snapshot load') timeCell.className = dataTimeClass(time);
  });

  elements.profileTaskBreakdownBody.replaceChildren();
  if (!profile.taskBreakdown.length) {
    const row = elements.profileTaskBreakdownBody.insertRow();
    const cell = row.insertCell();
    cell.colSpan = 6;
    cell.className = 'empty-cell';
    cell.textContent = 'No task history is available for this robot in the selected time range';
  } else {
    profile.taskBreakdown.forEach((item) => {
      const row = elements.profileTaskBreakdownBody.insertRow();
      row.insertCell().textContent = item.job_type_code;
      row.insertCell().textContent = `${item.robot_mode_id} · ${item.robot_mode_detail}`;
      row.insertCell().textContent = formatNumber(item.job_count);
      row.insertCell().textContent = formatNumber(item.completed_status_count);
      row.insertCell().textContent = formatNumber(item.failed_status_count);
      row.insertCell().textContent = formatDateTime(item.latest_job_time);
    });
  }
}

function renderDistribution(host, rows = [], nameKey, limit = 8) {
  host.replaceChildren();
  if (!rows.length) {
    host.className = host.id === 'modeDistribution' ? 'mini-bars empty-state' : 'distribution-list empty-state';
    host.textContent = 'No distribution data is available';
    return;
  }

  host.classList.remove('empty-state');
  const max = Math.max(...rows.map((row) => asNumber(row.robot_count)), 1);
  rows.slice(0, limit).forEach((row) => {
    const wrapper = document.createElement('div');
    wrapper.className = 'distribution-row';

    const name = document.createElement('span');
    name.className = 'distribution-name';
    name.textContent = row[nameKey] || 'Unknown';

    const track = document.createElement('span');
    track.className = 'bar-track';
    const fill = document.createElement('span');
    fill.className = 'bar-fill';
    fill.style.width = `${Math.max(2, (asNumber(row.robot_count) / max) * 100)}%`;
    track.append(fill);

    const count = document.createElement('strong');
    count.className = 'distribution-count';
    count.textContent = formatNumber(row.robot_count);
    wrapper.append(name, track, count);
    host.append(wrapper);
  });
}

function wifiFreshnessClass(robot) {
  return robot.wifi_is_current ? 'wifi-current' : 'wifi-stale';
}

function zeroSignalClass(value) {
  const rate = asNumber(value, -1);
  if (rate < 0) return '';
  if (rate >= 20) return 'zero-high';
  if (rate >= 5) return 'zero-mid';
  return 'zero-low';
}

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
    status.textContent = robot.has_current_snapshot
      ? (robot.current_status || 'Status not reported')
      : 'No operating snapshot';
    statusCell.append(status);
    if (robot.has_current_snapshot && !String(robot.current_status || '').trim()) {
      const masterState = document.createElement('small');
      masterState.textContent = `Master status: ${robot.master_status || '--'}`;
      statusCell.append(masterState);
    }

    const batteryCell = row.insertCell();
    batteryCell.className = batteryClass(robot.battery_soc);
    const batteryValue = document.createElement('strong');
    batteryValue.textContent = robot.battery_soc == null ? '--' : `${formatNumber(robot.battery_soc, 1)}%`;
    const batteryDetail = document.createElement('small');
    const voltage = robot.battery_voltage == null ? '--' : `${formatNumber(robot.battery_voltage, 2)}V`;
    const current = robot.battery_current == null ? '--' : `${formatNumber(robot.battery_current, 2)}A`;
    batteryDetail.textContent = `${voltage} · ${current} · ${robot.charging_status || 'Charging status --'}`;
    batteryCell.append(batteryValue, batteryDetail);

    const taskCell = row.insertCell();
    taskCell.className = 'task-detail';
    const taskValue = document.createElement('strong');
    taskValue.textContent = hasActiveJob(robot) ? robot.job_id : 'No active job';
    const taskDetail = document.createElement('small');
    taskDetail.textContent = robot.job_id
      ? `Latest record: ${robot.job_id} · ${robot.job_status || 'Status --'}`
      : `Task status: ${robot.job_status || '--'}`;
    taskCell.append(taskValue, taskDetail);

    const modeCell = row.insertCell();
    modeCell.className = 'mode-detail';
    const modeId = document.createElement('strong');
    modeId.textContent = `Mode ${robot.current_mode_id || '--'}`;
    const modeDetail = document.createElement('small');
    modeDetail.textContent = robot.current_mode || robot.source_current_mode || 'Mode dictionary not matched';
    modeCell.append(modeId, modeDetail);

    const rssiCell = row.insertCell();
    rssiCell.className = wifiFreshnessClass(robot);
    rssiCell.textContent = robot.current_rssi == null ? '--' : `${formatNumber(robot.current_rssi)} dBm`;
    const quality = document.createElement('small');
    quality.textContent = robot.current_wifi_quality == null ? 'Quality --' : `Quality ${formatNumber(robot.current_wifi_quality)}`;
    rssiCell.append(quality);

    const zeroCell = row.insertCell();
    zeroCell.className = zeroSignalClass(robot.zero_signal_rate);
    zeroCell.textContent = formatPercent(robot.zero_signal_rate, 2);
    const zeroCount = document.createElement('small');
    zeroCount.textContent = `${formatNumber(robot.zero_signal_sample_count)} / ${formatNumber(robot.wifi_sample_count)} samples`;
    zeroCell.append(zeroCount);

    const apCell = row.insertCell();
    apCell.textContent = robot.current_wifi_ap || '--';
    const riskAp = document.createElement('small');
    riskAp.textContent = robot.highest_zero_signal_ap ? `Most zero signals: ${robot.highest_zero_signal_ap}` : 'No attributable zero-signal access point';
    apCell.append(riskAp);

    row.insertCell().textContent = robotPoiSummary(robot);

    const timeCell = row.insertCell();
    timeCell.className = dataTimeClass(robot.latest_data_time);
    timeCell.textContent = formatDateTime(robot.latest_data_time);
    const freshness = document.createElement('small');
    freshness.textContent = 'Latest of status, battery and WiFi';
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
    cell.textContent = 'No robots are currently at or below the 20% low-battery threshold';
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

function renderWifiRisk(rows) {
  elements.wifiRiskBody.replaceChildren();
  if (!rows.length) {
    const row = elements.wifiRiskBody.insertRow();
    const cell = row.insertCell();
    cell.colSpan = 7;
    cell.className = 'empty-cell';
    cell.textContent = 'No access points meet the minimum sample threshold in this range';
    return;
  }

  rows.forEach((item) => {
    const row = elements.wifiRiskBody.insertRow();
    row.insertCell().textContent = item.wifi_ap || '--';

    const riskCell = row.insertCell();
    const risk = document.createElement('span');
    const level = String(item.risk_level || 'STABLE').toLowerCase();
    risk.className = `risk-pill ${level === 'critical' ? 'critical' : level === 'warning' ? 'warning' : ''}`;
    risk.textContent = level === 'critical' ? 'Critical' : level === 'warning' ? 'Warning' : 'Stable';
    riskCell.append(risk);

    const zeroCell = row.insertCell();
    zeroCell.className = zeroSignalClass(item.zero_signal_rate);
    zeroCell.textContent = formatPercent(item.zero_signal_rate, 2);
    row.insertCell().textContent = `${formatNumber(item.zero_signal_sample_count)} / ${formatNumber(item.wifi_sample_count)}`;
    row.insertCell().textContent = formatNumber(item.affected_robot_count);
    row.insertCell().textContent = item.avg_valid_rssi == null ? '--' : `${formatNumber(item.avg_valid_rssi, 1)} dBm`;
    row.insertCell().textContent = formatDateTime(item.last_sample_time);
  });
}

function renderTasks(robots) {
  const tasks = [...robots]
    .sort((a, b) => {
      const activeOrder = Number(hasActiveJob(b)) - Number(hasActiveJob(a));
      if (activeOrder !== 0) return activeOrder;
      const onlineOrder = Number(normalizedOnlineStatus(b.online_status) === 'online')
        - Number(normalizedOnlineStatus(a.online_status) === 'online');
      if (onlineOrder !== 0) return onlineOrder;
      return String(a.robot_name || a.robot_code || '').localeCompare(String(b.robot_name || b.robot_code || ''), 'en');
    })
    .slice(0, 50);
  elements.taskTableBody.replaceChildren();
  if (!tasks.length) {
    const row = elements.taskTableBody.insertRow();
    const cell = row.insertCell();
    cell.colSpan = 4;
    cell.className = 'empty-cell';
    cell.textContent = 'No robot task snapshot is available';
    return;
  }

  tasks.forEach((robot) => {
    const row = elements.taskTableBody.insertRow();
    row.addEventListener('click', () => selectRobot(robot.robot_code));
    row.insertCell().textContent = robot.robot_code || '--';
    const taskCell = row.insertCell();
    taskCell.className = 'task-detail';
    const taskName = document.createElement('strong');
    taskName.textContent = hasActiveJob(robot) ? (robot.job_id || '--') : 'No active job';
    const taskRoute = document.createElement('small');
    taskRoute.textContent = `POI: ${robotPoiSummary(robot)}`;
    taskCell.append(taskName, taskRoute);
    const statusCell = row.insertCell();
    statusCell.textContent = robot.job_status || '--';
    statusCell.className = hasActiveJob(robot) ? 'wifi-current' : 'wifi-stale';
    const modeCell = row.insertCell();
    modeCell.className = 'task-mode';
    const modeId = document.createElement('strong');
    modeId.textContent = `ID ${robot.current_mode_id || '--'}`;
    const modeDetail = document.createElement('small');
    modeDetail.textContent = robot.current_mode || '--';
    modeCell.append(modeId, modeDetail);
  });
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

function buildExportRows(dataset) {
  const data = state.dashboard || {};
  const summary = data.summary || {};
  const robots = data.robots || [];
  const profile = state.robotProfile || {};
  const selectedProfileRobot = robots.find(
    (robot) => String(robot.master_robot_id) === String(state.selectedRobotId)
  );

  switch (dataset) {
    case 'overview': {
      const totals = (data.jobTrend || []).reduce((result, row) => ({
        completed: result.completed + asNumber(row.completed_status_count),
        failed: result.failed + asNumber(row.failed_status_count)
      }), { completed: 0, failed: 0 });
      const finished = totals.completed + totals.failed;
      return [{
        Analysis_Window: state.window.label,
        Dashboard_Generated_At: data.generatedAt,
        Status_Data_Time: summary.source_anchor_time || summary.latest_source_event_time,
        DWS_Refresh_Time: summary.latest_dws_load_time,
        Enabled_Robots: summary.total_robot_count,
        Commissioned_Robots: summary.commissioned_robot_count,
        Online_Robots: summary.online_robot_count,
        Offline_Robots: summary.offline_robot_count,
        Offline_Robot_IDs: robots.filter((robot) => normalizedOnlineStatus(robot.online_status) !== 'online').map(robotIdentifier).join(', '),
        Active_Job_Robots: summary.active_job_robot_count,
        Active_Job_Robot_IDs: robots.filter(hasActiveJob).map(robotIdentifier).join(', '),
        Completed_Task_States: totals.completed,
        Failed_Task_States: totals.failed,
        Task_Success_Rate_Percent: finished > 0 ? Number(((totals.completed / finished) * 100).toFixed(2)) : null,
        Average_Battery_Percent: summary.avg_battery_soc,
        Low_Battery_Robots: summary.low_battery_robot_count,
        Low_Battery_Robot_IDs: robots.filter(isLowBattery).map(robotIdentifier).join(', '),
        Current_Average_RSSI: summary.avg_current_rssi,
        Zero_Signal_Sample_Rate_Percent: summary.zero_signal_rate,
        Alert_Robots: robots.filter(hasOperationalAlert).length,
        Alert_Robot_IDs: robots.filter(hasOperationalAlert).map(robotIdentifier).join(', '),
        No_Signal_Robot_IDs: robots.filter(isNoSignal).map(robotIdentifier).join(', '),
        Device_Error_Robot_IDs: robots.filter(hasAlarm).map(robotIdentifier).join(', ')
      }];
    }
    case 'status-distribution':
      return (data.statusDistribution || []).map((row) => ({ Status: row.status_name, Robot_Count: row.robot_count }));
    case 'mode-distribution':
      return (data.modeDistribution || []).map((row) => ({ Mode: row.mode_name, Robot_Count: row.robot_count }));
    case 'low-battery-risk':
      return robots.filter(isLowBattery).map((robot) => ({
        Robot_ID: robotIdentifier(robot),
        Master_Data_ID: robot.master_robot_id,
        Battery_Percent: robot.battery_soc,
        Battery_Voltage_V: robot.battery_voltage,
        Battery_Current_A: robot.battery_current,
        Operating_Status: robot.current_status,
        Online_Status: robot.online_status,
        Charging_Status: robot.charging_status,
        Current_Position: robot.station_code,
        Target_Position: robot.target_station_code,
        Battery_Data_Time: robot.battery_event_time || robot.source_event_time
      }));
    case 'battery-trend':
      return (data.batteryTrend || []).map((row) => ({
        Statistical_Hour: row.stat_hour,
        Sample_Count: row.sample_count,
        Average_Battery_Percent: row.avg_battery_soc,
        Minimum_Battery_Percent: row.min_battery_soc,
        Maximum_Battery_Percent: row.max_battery_soc,
        Charging_Sample_Count: row.charging_sample_count
      }));
    case 'wifi-trend':
      return (data.wifiTrend || []).map((row) => ({
        Statistical_Hour: row.stat_hour,
        Sample_Count: row.sample_count,
        Average_RSSI: row.avg_rssi,
        Minimum_RSSI: row.min_rssi,
        Maximum_RSSI: row.max_rssi,
        Zero_Signal_Sample_Count: row.zero_signal_sample_count,
        Zero_Signal_Rate_Percent: row.zero_signal_rate,
        Weak_Signal_Sample_Count: row.weak_signal_sample_count
      }));
    case 'job-trend':
      return (data.jobTrend || []).map((row) => {
        const completed = asNumber(row.completed_status_count);
        const failed = asNumber(row.failed_status_count);
        return {
          Statistical_Date: row.stat_date,
          Job_Record_Count: row.job_count,
          Distinct_Job_Count: row.distinct_job_count,
          Completed_Status_Count: row.completed_status_count,
          Failed_Status_Count: row.failed_status_count,
          Success_Rate_Percent: completed + failed > 0 ? Number(((completed / (completed + failed)) * 100).toFixed(2)) : null
        };
      });
    case 'alarm-trend':
      return (data.statusTrend || []).map((row) => ({
        Statistical_Hour: row.stat_hour,
        Status_Sample_Count: row.sample_count,
        Online_Sample_Count: row.online_sample_count,
        Error_Sample_Count: row.error_sample_count,
        Average_Speed_Meters_Per_Second: row.avg_speed_mps,
        Maximum_Speed_Meters_Per_Second: row.max_speed_mps
      }));
    case 'queue-trend':
      return (data.queueTrend || []).map((row) => ({
        Statistical_Date: row.stat_date,
        Queue_Record_Count: row.queue_count,
        Distinct_Queue_Count: row.distinct_queue_count,
        Completed_Status_Count: row.completed_status_count,
        Failed_Status_Count: row.failed_status_count,
        Average_Duration_Seconds: row.avg_duration_seconds
      }));
    case 'task-failure-outcomes':
      return (data.taskFailureOutcomes || []).map((row) => ({
        Recorded_Outcome: row.failure_outcome,
        Robot_ID: row.robot_code,
        Source_Robot_Reference: row.source_robot_reference,
        Failed_Task_Count: row.failure_count,
        Latest_Failure_Time: row.latest_failure_time,
        Root_Cause: 'Not captured by the source queue table'
      }));
    case 'alerts':
      return robots.flatMap((robot) => robotAlertCauses(robot).map((cause) => ({
        Robot_ID: robotIdentifier(robot),
        Alert_Code: cause.code,
        Alert_Cause: cause.reason,
        Cause_Type: cause.type,
        Current_Status: robot.current_status,
        Current_Job: robot.job_id,
        Current_Position: robotPoiSummary(robot),
        Battery_Percent: robot.battery_soc,
        Current_RSSI: robot.current_rssi,
        Cause_Data_Time: cause.dataTime
      })));
    case 'robot-profile':
      return selectedProfileRobot ? [{
        Analysis_Window: state.window.label,
        Robot_ID: robotIdentifier(selectedProfileRobot),
        Master_Data_ID: selectedProfileRobot.master_robot_id,
        Serial_Number: selectedProfileRobot.robot_serial_number,
        Current_Status: selectedProfileRobot.current_status,
        Online_Status: selectedProfileRobot.online_status,
        Battery_Percent: selectedProfileRobot.battery_soc,
        Voltage_V: selectedProfileRobot.battery_voltage,
        Current_A: selectedProfileRobot.battery_current,
        Charging_Status: selectedProfileRobot.charging_status,
        Current_Job: selectedProfileRobot.job_id,
        Job_Status: selectedProfileRobot.job_status,
        Operating_Mode_ID: selectedProfileRobot.current_mode_id,
        Operating_Mode: selectedProfileRobot.current_mode,
        Current_RSSI: selectedProfileRobot.current_rssi,
        WiFi_Quality: selectedProfileRobot.current_wifi_quality,
        Access_Point: selectedProfileRobot.current_wifi_ap,
        Map: selectedProfileRobot.map_code,
        Current_Position: selectedProfileRobot.station_code,
        Target_Position: selectedProfileRobot.target_station_code,
        Alert_Causes: robotAlertCauses(selectedProfileRobot).map((cause) => `${cause.code}: ${cause.reason}`).join('; '),
        Latest_Data_Time: selectedProfileRobot.latest_data_time,
        Status_Data_Time: selectedProfileRobot.status_event_time || selectedProfileRobot.source_event_time,
        Battery_Data_Time: selectedProfileRobot.battery_event_time,
        WiFi_Data_Time: selectedProfileRobot.latest_wifi_time,
        Task_Data_Time: selectedProfileRobot.job_event_time,
        DWS_Load_Time: selectedProfileRobot.dws_load_time
      }] : [];
    case 'profile-battery':
      return (profile.batteryTrend || []).map((row) => ({
        Robot_ID: robotIdentifier(selectedProfileRobot),
        Statistical_Hour: row.stat_hour,
        Sample_Count: row.sample_count,
        Average_Battery_Percent: row.avg_battery_soc,
        Minimum_Battery_Percent: row.min_battery_soc,
        Maximum_Battery_Percent: row.max_battery_soc,
        Charging_Sample_Count: row.charging_sample_count
      }));
    case 'profile-wifi':
      return (profile.wifiTrend || []).map((row) => ({
        Robot_ID: robotIdentifier(selectedProfileRobot),
        Statistical_Hour: row.stat_hour,
        Sample_Count: row.sample_count,
        Average_RSSI: row.avg_rssi,
        Minimum_RSSI: row.min_rssi,
        Maximum_RSSI: row.max_rssi,
        Zero_Signal_Sample_Count: row.zero_signal_sample_count,
        Zero_Signal_Rate_Percent: row.zero_signal_rate,
        Weak_Signal_Sample_Count: row.weak_signal_sample_count
      }));
    case 'profile-status':
      return (profile.statusTrend || []).map((row) => ({
        Robot_ID: robotIdentifier(selectedProfileRobot),
        Statistical_Hour: row.stat_hour,
        Status_Sample_Count: row.sample_count,
        Online_Sample_Count: row.online_sample_count,
        Error_Sample_Count: row.error_sample_count,
        Average_Speed_Meters_Per_Second: row.avg_speed_mps,
        Maximum_Speed_Meters_Per_Second: row.max_speed_mps
      }));
    case 'profile-jobs':
      return (profile.jobTrend || []).map((row) => ({
        Robot_ID: robotIdentifier(selectedProfileRobot),
        Statistical_Date: row.stat_date,
        Job_Record_Count: row.job_count,
        Distinct_Job_Count: row.distinct_job_count,
        Completed_Status_Count: row.completed_status_count,
        Failed_Status_Count: row.failed_status_count
      }));
    case 'profile-task-breakdown':
      return (profile.taskBreakdown || []).map((row) => ({
        Robot_ID: robotIdentifier(selectedProfileRobot),
        Task_Type: row.job_type_code,
        Operating_Mode_ID: row.robot_mode_id,
        Operating_Mode: row.robot_mode_detail,
        Task_Count: row.job_count,
        Completed_Status_Count: row.completed_status_count,
        Failed_Status_Count: row.failed_status_count,
        Latest_Task_Time: row.latest_job_time,
        Failure_Root_Cause: 'Not captured by the source job history table'
      }));
    case 'tasks':
      return robots.map((robot) => ({
        Robot_ID: robotIdentifier(robot),
        Job_ID: robot.job_id,
        Subjob_ID: robot.subjob_id,
        Job_Status: robot.job_status,
        Has_Active_Job: hasActiveJob(robot) ? 1 : 0,
        Operating_Mode_ID: robot.current_mode_id,
        Operating_Mode: robot.current_mode,
        Current_Position: robot.station_code,
        Target_Position: robot.target_station_code,
        Job_Data_Time: robot.job_event_time
      }));
    case 'robots':
      return filteredRobots().map((robot) => ({
        Robot_ID: robotIdentifier(robot),
        Master_Data_ID: robot.master_robot_id,
        Serial_Number: robot.robot_serial_number,
        Current_Status: robot.current_status,
        Online_Status: robot.online_status,
        Battery_Percent: robot.battery_soc,
        Voltage_V: robot.battery_voltage,
        Current_A: robot.battery_current,
        Charging_Status: robot.charging_status,
        Current_Job: robot.job_id,
        Job_Status: robot.job_status,
        Operating_Mode_ID: robot.current_mode_id,
        Operating_Mode: robot.current_mode,
        Current_RSSI: robot.current_rssi,
        WiFi_Quality: robot.current_wifi_quality,
        Zero_Signal_Rate_Percent: robot.zero_signal_rate,
        Current_Access_Point: robot.current_wifi_ap,
        Map: robot.map_code,
        Current_Position: robot.station_code,
        Target_Position: robot.target_station_code,
        Alarm_Code: robot.error_code,
        Alarm_Reason: robot.error_message,
        Derived_Alert_Causes: robotAlertCauses(robot).map((cause) => cause.reason).join('; '),
        Latest_Data_Time: robot.latest_data_time,
        Status_Data_Time: robot.status_event_time || robot.source_event_time,
        Battery_Data_Time: robot.battery_event_time,
        WiFi_Data_Time: robot.latest_wifi_time
      }));
    case 'map':
      return robots
        .filter((robot) => hasCoordinate(robot.position_x) && hasCoordinate(robot.position_y))
        .filter((robot) => normalizedMapCode(robot) === state.selectedMapCode)
        .map((robot) => ({
          Map: mapLabel(normalizedMapCode(robot)),
          Robot_ID: robotIdentifier(robot),
          X_Coordinate: robot.position_x,
          Y_Coordinate: robot.position_y,
          Heading: robot.position_theta,
          Current_Status: robot.current_status,
          Online_Status: robot.online_status,
          Alarm_Reason: robot.error_message,
          Current_Position: robot.station_code,
          Target_Position: robot.target_station_code,
          Data_Time: robot.source_event_time
        }));
    case 'wifi-risk':
      return (data.wifiAccessPointRisk || []).map((row) => ({
        Wireless_Access_Point: row.wifi_ap,
        Risk_Level: row.risk_level,
        Sample_Count: row.wifi_sample_count,
        Zero_Signal_Sample_Count: row.zero_signal_sample_count,
        Zero_Signal_Rate_Percent: row.zero_signal_rate,
        Weak_Signal_Sample_Count: row.weak_signal_sample_count,
        Weak_Signal_Rate_Percent: row.weak_signal_rate,
        Affected_Robot_Count: row.affected_robot_count,
        Average_RSSI: row.avg_valid_rssi,
        Latest_Sample_Time: row.last_sample_time
      }));
    case 'batches':
      return (data.recentBatches || []).map((row) => ({
        Batch_ID: row.batch_id,
        Start_Time: row.batch_start_time,
        End_Time: row.batch_end_time,
        Status: row.batch_status,
        Error_Message: row.error_message
      }));
    default:
      return [];
  }
}

function csvCell(value) {
  if (value === null || value === undefined) return '';
  const text = String(value);
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

function downloadBlob(content, mimeType, filename) {
  const blob = new Blob([content], { type: mimeType });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.append(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 0);
}

function exportDataset(dataset) {
  if (!state.dashboard) {
    showToast('Data has not loaded yet, so the export is unavailable', 'error');
    return;
  }
  const rows = buildExportRows(dataset);
  if (!rows.length) {
    showToast('There is no downloadable data in the current filter range', 'error');
    return;
  }
  const columns = [...new Set(rows.flatMap((row) => Object.keys(row)))];
  const lines = [columns.map(csvCell).join(',')];
  rows.forEach((row) => lines.push(columns.map((column) => csvCell(row[column])).join(',')));
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  downloadBlob(`\uFEFF${lines.join('\r\n')}`, 'text/csv;charset=utf-8', `amr-${dataset}-${state.window.key}-${stamp}.csv`);
  showToast(`Downloaded: ${rows.length} rows`);
}

function exportAllData() {
  if (!state.dashboard) {
    showToast('Data has not loaded yet, so the export is unavailable', 'error');
    return;
  }
  const payload = {
    exportedAt: new Date().toISOString(),
    selectedWindow: state.window,
    sourceNote: 'IOT2020 DWS dashboard response; WiFi detail window is capped at 24 hours.',
    dashboard: state.dashboard
  };
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  downloadBlob(JSON.stringify(payload, null, 2), 'application/json;charset=utf-8', `amr-dashboard-all-${state.window.key}-${stamp}.json`);
  showToast('Downloaded all current dashboard data');
}

elements.refreshButton.addEventListener('click', () => loadDashboard({ announce: true }));
elements.syncButton.addEventListener('click', syncCurrentSnapshot);
elements.exportAllButton.addEventListener('click', exportAllData);
elements.robotSearch.addEventListener('input', () => renderRobotVitals(state.dashboard?.robots || []));
function selectRobotProfile(robotId) {
  state.selectedRobotId = robotId || null;
  state.robotProfile = null;
  elements.profileRobotSelect.value = robotId || '';
  activateView('robot-profile');
}
elements.profileRobotSelect.addEventListener('change', () => selectRobotProfile(elements.profileRobotSelect.value));
elements.mapSelect.addEventListener('change', () => {
  state.selectedMapCode = elements.mapSelect.value || null;
  renderMap(state.dashboard?.robots || []);
});
elements.rangeSelect.addEventListener('change', () => loadDashboard({ announce: true }));
document.querySelectorAll('[data-export]').forEach((button) => {
  button.addEventListener('click', () => exportDataset(button.dataset.export));
});
document.querySelectorAll('[data-view]').forEach((button) => {
  button.addEventListener('click', () => activateView(button.dataset.view));
});
document.querySelectorAll('[data-go-view]').forEach((button) => {
  button.addEventListener('click', () => activateView(button.dataset.goView));
});
elements.sidebarToggle.addEventListener('click', () => {
  const open = !elements.sidebar.classList.contains('open');
  elements.sidebar.classList.toggle('open', open);
  elements.sidebarOverlay.classList.toggle('open', open);
  elements.sidebarToggle.setAttribute('aria-expanded', String(open));
});
elements.sidebarOverlay.addEventListener('click', closeSidebar);
window.addEventListener('keydown', (event) => { if (event.key === 'Escape') closeSidebar(); });
window.addEventListener('hashchange', () => {
  const view = location.hash.slice(1);
  if (VIEW_META[view]) activateView(view, { updateHash: false });
});

updateClock();
window.setInterval(updateClock, 1000);
const initialView = location.hash.slice(1);
activateView(VIEW_META[initialView] ? initialView : 'overview', { updateHash: false });
loadDashboard();
