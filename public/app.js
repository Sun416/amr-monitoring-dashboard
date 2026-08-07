'use strict';

const state = {
  dashboard: null,
  robotProfile: null,
  selectedRobotId: null,
  profileRequestId: 0,
  selectedRobotCode: null,
  selectedMapCode: null,
  selectedWifiPoi: 'ALL',
  selectedWifiRobot: 'ALL',
  /*
    Multi-select filters for the Running-task WiFi chart.
    Empty array means "all". The single-value selectedWifiRobot/selectedWifiPoi
    above stay in sync for the downstream renderers that expect one value:
    exactly one selection passes that value, zero or many pass 'ALL' and the
    renderers filter on these arrays instead.
  */
  selectedWifiRobots: [],
  selectedWifiPois: [],
  loading: false,
  currentView: 'overview',
  robotType: 'ALL',
  window: { key: 'd1', label: 'Last 24 hours', hours: 24, days: 1 },
  analysisWindow: { isCustom: false, start: null, end: null },
  taskAnalytics: null,
  taskRobots: [],
  taskTopLimit: 5,
  taskRequestId: 0,
  /*
    Project and task first. These scope every panel in the projects view;
    null means "no filter", so the view opens on the whole window.
  */
  projectAnalytics: null,
  selectedProjectIds: [],
  selectedJobIds: [],
  selectedRobotCodes: [],
  projectRequestId: 0
};

const VIEW_META = {
  projects: { eyebrow: '01 · PROJECT & TASK', title: 'Project and Task Analysis', description: 'Filter a project or task first, then review how it ran and which robots carried it.' },
  overview: { eyebrow: '02 · ANALYSIS CENTER', title: 'Analysis Center', description: 'Start with causes, supporting evidence and the next maintenance action.' },
  operations: { eyebrow: '03 · OPERATIONS', title: 'Operating Status', description: 'Review status, mode and robot position.' },
  tasks: { eyebrow: '04 · TASKS', title: 'Task Analytics', description: 'Review DWS utilization, idle causes, Calling Boxes, and assigned tasks.' },
  energy: { eyebrow: '05 · ENERGY', title: 'Energy Analytics', description: 'Identify exact robot IDs at low-battery risk and review the trend.' },
  network: { eyebrow: '06 · RUNNING WIFI', title: 'Running-Task WiFi Signal Analysis', description: 'Analyze signal trends, minimum-RSSI evidence, robot differences, and target-POI risks during Running tasks.' },
  alarms: { eyebrow: '07 · ALERTS', title: 'Robot Alert Causes', description: 'See operational faults and telemetry-quality issues by robot ID.' },
  robots: { eyebrow: '08 · ROBOT DETAILS', title: 'Robot Details', description: 'Search robot-level operating data in one place.' },
  'robot-profile': { eyebrow: '09 · ROBOT PROFILE', title: 'Robot Profile', description: 'Select one Robot ID and review its complete current and historical status.' },
  'data-quality': { eyebrow: '10 · DATA QUALITY', title: 'Data Quality', description: 'Review data freshness, lag and DWS load batches.' }
};

const elements = Object.fromEntries(
  [
    'sidebar', 'sidebarOverlay', 'sidebarToggle', 'viewEyebrow', 'viewTitle', 'viewDescription',
    'currentDate', 'currentTime', 'freshnessDot', 'connectionStatus', 'sourceFreshness', 'sourceLag', 'dwsFreshness', 'wifiFreshness',
    'analysisWindowLabel', 'windowClearButton', 'refreshButton', 'syncButton', 'exportAllButton', 'metricTotal', 'metricTotalScope', 'metricOnline',
    'metricOffline', 'metricJobs', 'metricJobScope', 'metricBattery', 'metricLowBattery', 'metricRssi', 'metricWifiCoverage',
    'metricZeroSignal', 'metricZeroSignalScope', 'metricAlarms', 'metricAlarmScope', 'metricTaskSuccess', 'metricTaskSuccessScope',
    'analysisVerdict', 'analysisHeadline', 'analysisSummary', 'analysisConfidence', 'analysisRuleVersion',
    'analysisRobotCount', 'analysisCoverage', 'analysisCoverageDetail', 'analysisGapCount', 'fleetScopeLabel', 'analysisWorkloadState',
    'analysisWorkloadDetail', 'analysisDiagnosticList', 'workloadCauseStatus', 'workloadAnchor',
    'workloadGroupSummary', 'workloadAnalysisBody', 'operationalAnalysisBody', 'measurementGapList',
    'fleetStatusDonut', 'fleetRobotGrid', 'priorityRepairSummary',
    'runningWifiFreshness', 'wifiStartTime', 'wifiEndTime', 'wifiApplyWindow',
    'wifiConclusion', 'wifiRobotToggle', 'wifiRobotToggleText', 'wifiRobotMenu',
    'wifiPoiToggle', 'wifiPoiToggleText', 'wifiPoiMenu', 'wifiRobotMulti', 'wifiPoiMulti',
    'runningWifiChartSubtitle', 'runningWifiTrendChart', 'runningWifiMinimumDiagnostic', 'runningWifiNarrative',
    'weakSignalRateSubtitle', 'weakSignalRateChart', 'weakSignalTimelineSubtitle', 'weakSignalTimelineChart',
    'wifiPointStrengthSubtitle', 'wifiPointStrengthChart',
    'diagnosisCauseChart', 'workloadDistributionChart', 'onTimeRateChart', 'queueWaitAnalysisChart', 'batteryCoverageAnalysisChart',
    'operationsOnlineValue', 'operationsOfflineValue', 'operationsOfflineIds', 'operationsActiveValue', 'operationsActiveIds',
    'taskSuccessValue', 'taskFailureValue', 'taskFailureSummary', 'taskActiveValue', 'taskActiveIds', 'energyAverageValue', 'energyLowBatteryValue', 'energyLowBatteryIds',
    'alarmRobotValue', 'alarmRobotIds',
    'alarmLowBatteryValue', 'alarmLowBatteryIds', 'alarmNoSignalValue', 'alarmNoSignalIds',
    'alarmRssiIssueValue', 'alarmRssiIssueIds',
    'statusDistribution', 'modeDistribution', 'robotSearch', 'taskTableBody', 'taskFailureBody', 'lowBatteryRiskBody',
    'taskRobotToggle', 'taskRobotMenu', 'taskTopLimitSelect', 'taskApplyWindow', 'taskDataScope',
    'taskUtilizationValue', 'taskUtilizationDetail', 'taskExecutionValue', 'taskExecutionDetail',
    'taskIdleValue', 'taskIdleDetail', 'taskDataExceptionValue', 'taskDataExceptionDetail',
    'taskStateExceptionPanel', 'taskStateExceptionSummary', 'taskStateExceptionBody',
    'taskUsageSubtitle', 'taskUsageChart', 'taskIdleTrendChart', 'taskIdleCauseChart',
    'taskCallingBoxTitle', 'taskCallingBoxList', 'taskAssignedTitle', 'taskAssignedList',
    'taskCallingBoxTrendChart', 'taskCallingBoxTrendSubtitle', 'taskAssignedTrendChart', 'taskAssignedTrendSubtitle',
    'analysisProjectToggle', 'analysisProjectToggleText', 'analysisProjectMenu',
    'analysisTaskToggle', 'analysisTaskToggleText', 'analysisTaskMenu',
    'analysisRobotToggle', 'analysisRobotToggleText', 'analysisRobotMenu', 'analysisClearFilter',
    'projectToggle', 'projectToggleText', 'projectMenu',
    'taskToggle', 'taskToggleText', 'taskMenu',
    'robotToggle', 'robotToggleText', 'robotMenu', 'projectClearFilter', 'projectDataScope',
    'projectQueueValue', 'projectQueueDetail', 'projectCompletionValue', 'projectCompletionDetail',
    'projectExecutionValue', 'projectExecutionDetail', 'projectRobotValue', 'projectRobotIds',
    'projectListBody', 'projectListChart', 'projectTaskTitle', 'projectTaskBody', 'projectTaskChart',
    'projectRobotTitle', 'projectRobotBody', 'projectRobotChart',
    'projectOutcomeChart', 'projectTrendSubtitle', 'projectTrendChart', 'projectRecordBody',
    'alertList', 'alertBadge', 'robotMapLayer', 'mapEmpty', 'mapSelect', 'mappedRobotCount', 'mapCodeCount',
    'selectedRobot', 'robotVitalsBody', 'batteryChart',
    'jobChart', 'alarmChart', 'queueChart', 'batteryTrendAnchor', 'batchTableBody',
    'profileRobotSelect', 'profileRobotSubtitle', 'profileAlertBanner', 'profileStatusValue', 'profileStatusDetail',
    'profileBatteryValue', 'profileBatteryDetail', 'profileTaskValue', 'profileTaskDetail', 'profileWifiValue',
    'profileWifiDetail', 'profilePositionValue', 'profilePositionDetail', 'profileDataTimeValue', 'profileDataTimeDetail',
    'profileBatteryChart', 'profileWifiChart', 'profileStatusChart', 'profileJobChart', 'profileSourceTimesBody',
    'profileTaskBreakdownBody', 'networkWifiAnalysisHost', 'runningWifiAnalysisSection', 'toast'
  ].map((id) => [id, document.getElementById(id)])
);

if (elements.networkWifiAnalysisHost && elements.runningWifiAnalysisSection) {
  elements.networkWifiAnalysisHost.append(elements.runningWifiAnalysisSection);
}

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
  document.title = `${meta.title} · Robot Operations Analytics`;
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

function formatExactDateTime(value) {
  if (!value) return '--';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  return new Intl.DateTimeFormat('en-GB', {
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false
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

function formatSeconds(value) {
  const seconds = asNumber(value);
  if (!Number.isFinite(seconds)) return '--';
  if (seconds >= 3600) return `${formatNumber(seconds / 3600, 1)} h`;
  if (seconds >= 120) return `${formatNumber(seconds / 60, 1)} min`;
  return `${formatNumber(seconds, 1)} s`;
}

function dataTimeClass(value) {
  if (!value) return 'data-stale';
  const dataTime = new Date(value);
  const referenceTime = new Date(state.dashboard?.summary?.database_current_time || state.dashboard?.generatedAt || Date.now());
  if (Number.isNaN(dataTime.getTime()) || Number.isNaN(referenceTime.getTime())) return 'data-stale';
  const staleMinutes = asNumber(state.dashboard?.staleMinutes, 30);
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
  const freshnessStatus = String(robot?.data_freshness_status || '').trim().toUpperCase();
  if (freshnessStatus) return freshnessStatus !== 'CURRENT';
  return dataAgeMinutes(robot?.latest_data_time) > asNumber(state.dashboard?.staleMinutes, 30);
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
    || !['', '-', '0', '1', 'NULL', 'UNDEFINED', 'NONE', 'FALSE', 'TRUE', 'OK', 'NORMAL'].includes(code);
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
  const statusTime = robot?.status_event_time || robot?.source_event_time;
  const statusStale = dataAgeMinutes(statusTime) > asNumber(state.dashboard?.staleMinutes, 30);
  return value !== null
    && value !== undefined
    && value !== ''
    && Number(value) === 0
    && (normalizedOnlineStatus(robot?.online_status) !== 'online' || statusStale);
}

function hasRssiMeasurementIssue(robot) {
  const sampleCount = asNumber(robot?.wifi_sample_count);
  const unusableCount = asNumber(robot?.unusable_rssi_sample_count);
  const unusableRate = sampleCount > 0 ? (100 * unusableCount / sampleCount) : 0;
  const accessPoint = String(robot?.current_wifi_ap || '').trim();
  const hasAssociationEvidence = (accessPoint !== '' && accessPoint !== '-')
    || asNumber(robot?.current_wifi_count) > 0;
  const wifiIsCurrent = robot?.wifi_is_current === true || asNumber(robot?.wifi_is_current) === 1;

  return wifiIsCurrent
    && robot?.raw_current_rssi !== null
    && robot?.raw_current_rssi !== undefined
    && Number(robot.raw_current_rssi) === 0
    && (robot?.current_rssi === null || robot?.current_rssi === undefined || robot?.current_rssi === '')
    && hasAssociationEvidence
    && sampleCount >= 100
    && unusableRate >= 95;
}

function robotAlertCauses(robot) {
  const causes = [];
  if (isRobotDataStale(robot)) {
    const freshnessStatus = String(robot.data_freshness_status || '').trim().toUpperCase();
    const freshnessReason = {
      DWS_REFRESH_TIMEOUT: `DWS refresh exceeded the ${formatNumber(state.dashboard?.staleMinutes || 30)}-minute threshold`,
      DWS_SOURCE_LAG: `Source-to-DWS load lag exceeded the ${formatNumber(state.dashboard?.staleMinutes || 30)}-minute threshold`,
      SOURCE_TIMEOUT: `No source event reached DWS within ${formatNumber(state.dashboard?.staleMinutes || 30)} minutes`,
      MISSING: 'No non-snapshot DWS status aggregate is available'
    }[freshnessStatus];
    causes.push({
      code: freshnessStatus || 'DATA_STALE',
      reason: freshnessReason || (robot.latest_data_time
        ? `DWS data has not updated within ${formatNumber(state.dashboard?.staleMinutes || 30)} minutes`
        : 'No DWS telemetry timestamp is available'),
      type: 'data-stale',
      dataTime: robot.status_dws_load_time || robot.dws_load_time || robot.latest_data_time
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
  if (hasRssiMeasurementIssue(robot)) {
    const sampleCount = asNumber(robot.wifi_sample_count);
    const unusableCount = asNumber(robot.unusable_rssi_sample_count);
    const unusableRate = sampleCount > 0 ? (100 * unusableCount / sampleCount) : 0;
    causes.push({
      code: 'RSSI_MEASUREMENT_UNAVAILABLE',
      reason: `WiFi association is present, but ${formatPercent(unusableRate, 1)} of recent RSSI samples are unusable`,
      type: 'data-quality',
      dataTime: robot.latest_wifi_time
    });
  }
  return causes;
}

function hasOperationalAlert(robot) {
  return robotAlertCauses(robot).length > 0;
}

function robotDiagnostic(robot) {
  return (state.dashboard?.analysis?.priorityDiagnostics || []).find(
    (diagnostic) => String(diagnostic.masterRobotId) === String(robot?.master_robot_id)
  ) || null;
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
  return { ...state.window };
}

function selectedAnalysisWindow() {
  if (!state.analysisWindow.isCustom) {
    return { isCustom: false, start: null, end: null, hours: 24 };
  }
  const start = new Date(String(state.analysisWindow.start).replace('T', ' '));
  const end = new Date(String(state.analysisWindow.end).replace('T', ' '));
  const durationHours = Number.isFinite(start.getTime()) && Number.isFinite(end.getTime())
    ? Math.ceil((end.getTime() - start.getTime()) / 3600000)
    : 24;
  return {
    isCustom: true,
    start: state.analysisWindow.start,
    end: state.analysisWindow.end,
    hours: Math.max(1, durationHours)
  };
}

function wifiRefreshLabel(wifiWindow) {
  if (!wifiWindow.isCustom) return 'Last 24 hours';
  const format = (value) => String(value || '').replace('T', ' ').slice(0, 16);
  return `Exact ${format(wifiWindow.start)} – ${format(wifiWindow.end)}`;
}

function analysisWindowLabelText() {
  return wifiRefreshLabel(selectedAnalysisWindow());
}

function selectedRobotType() {
  return 'ALL';
}

function robotTypeLabel(value = state.robotType) {
  return value === 'ALL' ? 'All Robots' : value;
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
  elements.wifiApplyWindow.disabled = isBusy;
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
  setBusy(true, 'Loading non-snapshot DWS analytics data...');

  try {
    state.window = selectedWindow();
    state.robotType = selectedRobotType();
    const analysisWindow = selectedAnalysisWindow();
    const params = new URLSearchParams({
      hours: analysisWindow.hours,
      days: state.window.days,
      robotType: state.robotType
    });
    if (analysisWindow.isCustom) {
      params.set('wifiStart', analysisWindow.start);
      params.set('wifiEnd', analysisWindow.end);
    }
    state.dashboard = await requestJson(`/api/dashboard?${params}`);
    renderDashboard(state.dashboard);
    if (announce) showToast(`Refreshed: ${robotTypeLabel()} · ${wifiRefreshLabel(analysisWindow)}`);
  } catch (error) {
    renderConnectionError(error);
    showToast(error.message, 'error');
  } finally {
    setBusy(false);
  }
}

function localInputDateTime(value) {
  if (!value) return '';
  const raw = String(value).trim().replace(' ', 'T');
  const wallClock = raw.match(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})(?::(\d{2}))?/);
  if (wallClock) return `${wallClock[1]}:${wallClock[2] || '00'}`;
  return raw.slice(0, 19);
}

function formatTaskLocalDateTime(value) {
  if (!value) return '--';
  const raw = String(value).trim().replace(' ', 'T');
  const wallClock = raw.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?/);
  if (!wallClock) return String(value);
  const [, year, month, day, hour, minute, second = '00'] = wallClock;
  return `${day}/${month}/${year}, ${hour}:${minute}:${second}`;
}

function taskWindowLabel(summary = {}) {
  const start = formatTaskLocalDateTime(summary.analysis_start);
  const end = formatTaskLocalDateTime(summary.analysis_end);
  const requestedStart = formatTaskLocalDateTime(summary.requested_start);
  const requestedEnd = formatTaskLocalDateTime(summary.requested_end);
  const effectiveWindow = `${start} to ${end}`;
  return requestedStart === start && requestedEnd === end
    ? effectiveWindow
    : `${effectiveWindow} (complete hours)`;
}

async function loadTaskAnalytics({ announce = false } = {}) {
  const requestId = ++state.taskRequestId;
  const analysisWindow = selectedAnalysisWindow();
  const start = analysisWindow.start || '';
  const end = analysisWindow.end || '';
  const params = new URLSearchParams();
  if (start || end) {
    if (!start || !end) {
      showToast('Choose both task analytics start and end times', 'error');
      return;
    }
    params.set('start', start);
    params.set('end', end);
  }
  if (state.taskRobots.length) params.set('robots', state.taskRobots.join(','));

  if (elements.taskApplyWindow) elements.taskApplyWindow.disabled = true;
  if (elements.taskDataScope) elements.taskDataScope.textContent = 'Loading DWS task analytics…';
  try {
    const data = await requestJson(`/api/task-analytics${params.toString() ? `?${params}` : ''}`);
    if (requestId !== state.taskRequestId) return;
    state.taskAnalytics = data;
    renderTaskAnalytics(data);
    if (announce) showToast(`Task Analytics updated: ${taskWindowLabel(data.summary)}`);
  } catch (error) {
    if (requestId !== state.taskRequestId) return;
    if (elements.taskDataScope) {
      elements.taskDataScope.dataset.tone = 'critical';
      elements.taskDataScope.textContent = error.message;
    }
    showToast(error.message, 'error');
  } finally {
    if (requestId === state.taskRequestId && elements.taskApplyWindow) elements.taskApplyWindow.disabled = false;
  }
}

function taskRobotSelectionLabel(rows = []) {
  if (!state.taskRobots.length) return `All robots (${rows.length})`;
  if (state.taskRobots.length === 1) return state.taskRobots[0];
  return `Selected ${state.taskRobots.length}`;
}

function updateTaskRobotPickerLabel(rows = []) {
  if (!elements.taskRobotToggle) return;
  elements.taskRobotToggle.textContent = taskRobotSelectionLabel(rows);
}

function populateTaskRobotSelector(rows) {
  if (!elements.taskRobotMenu) return;
  const availableCodes = rows.map((row) => String(row.robot_code || '').trim()).filter(Boolean);
  const availableSet = new Set(availableCodes);
  state.taskRobots = state.taskRobots.filter((code) => availableSet.has(code));
  elements.taskRobotMenu.replaceChildren();

  const actions = document.createElement('div');
  actions.className = 'task-robot-menu-actions';
  const selectAll = document.createElement('button');
  selectAll.type = 'button';
  selectAll.textContent = 'Select all';
  selectAll.addEventListener('click', () => {
    state.taskRobots = [...availableCodes];
    populateTaskRobotSelector(rows);
  });
  const clearAll = document.createElement('button');
  clearAll.type = 'button';
  clearAll.textContent = 'Clear all';
  clearAll.addEventListener('click', () => {
    state.taskRobots = [];
    populateTaskRobotSelector(rows);
  });
  actions.append(selectAll, clearAll);
  elements.taskRobotMenu.append(actions);

  availableCodes.forEach((robotCode) => {
    const label = document.createElement('label');
    label.className = 'task-robot-option';
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.value = robotCode;
    input.checked = state.taskRobots.includes(robotCode);
    input.addEventListener('change', () => {
      const selected = new Set(state.taskRobots);
      if (input.checked) selected.add(robotCode);
      else selected.delete(robotCode);
      state.taskRobots = availableCodes.filter((code) => selected.has(code));
      updateTaskRobotPickerLabel(rows);
    });
    const text = document.createElement('span');
    text.textContent = robotCode;
    label.append(input, text);
    elements.taskRobotMenu.append(label);
  });
  updateTaskRobotPickerLabel(rows);
}

function renderTaskRanking(host, rows, valueKey, secondary) {
  if (!host) return;
  host.replaceChildren();
  if (!rows.length) {
    host.classList.add('empty-state');
    host.textContent = 'No DWS records are available for the selected period and robot.';
    return;
  }
  host.classList.remove('empty-state');
  const maximum = Math.max(...rows.map((row) => asNumber(row[valueKey])), 1);
  rows.forEach((row, index) => {
    const item = document.createElement('div');
    item.className = 'task-ranking-item';
    const title = document.createElement('strong');
    title.textContent = `${index + 1}. ${row.calling_box_label || row.task_label || '--'}`;
    const detail = document.createElement('span');
    detail.textContent = secondary(row);
    const bar = document.createElement('i');
    bar.style.width = `${Math.max(4, (100 * asNumber(row[valueKey])) / maximum)}%`;
    const value = document.createElement('b');
    value.textContent = formatNumber(row[valueKey]);
    item.append(title, detail, bar, value);
    host.append(item);
  });
}

function renderTaskUsageTrend(host, rows = [], selectedRobots = []) {
  if (!host) return;
  host.replaceChildren();
  const scopedRows = rows.filter((row) => row.stat_hour && row.robot_code);
  if (!scopedRows.length) {
    const empty = document.createElement('div');
    empty.className = 'chart-empty';
    empty.textContent = 'No hourly task evidence is available for the selected period.';
    host.append(empty);
    return;
  }

  const hourLabels = [...new Set(scopedRows.map((row) => row.stat_hour))].sort();
  const uniqueRobots = [...new Set(scopedRows.map((row) => row.robot_code))].sort();
  const splitByRobot = selectedRobots.length > 0 && selectedRobots.length <= 6;
  const seriesMap = new Map();
  if (splitByRobot) {
    uniqueRobots.forEach((robotCode) => seriesMap.set(robotCode, new Map()));
    scopedRows.forEach((row) => seriesMap.get(row.robot_code)?.set(row.stat_hour, asNumber(row.executing_seconds) / 60));
  } else {
    const aggregate = new Map();
    scopedRows.forEach((row) => aggregate.set(row.stat_hour, (aggregate.get(row.stat_hour) || 0) + (asNumber(row.executing_seconds) / 60)));
    seriesMap.set(selectedRobots.length > 6 ? 'Selected fleet' : 'All robots', aggregate);
  }
  const series = [...seriesMap.entries()].map(([name, values], index) => ({ name, values, color: ['#2563eb', '#059669', '#d97706', '#7c3aed', '#db2777', '#0891b2'][index % 6] }));
  const allValues = series.flatMap((item) => hourLabels.map((label) => item.values.get(label) || 0));
  const max = Math.max(...allValues, 1);
  const width = 780; const height = 250;
  const margin = { left: 48, right: 18, top: 16, bottom: 34 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  const x = (index) => margin.left + (index / Math.max(hourLabels.length - 1, 1)) * plotWidth;
  const y = (value) => margin.top + (1 - value / max) * plotHeight;
  const svg = svgElement('svg', { viewBox: `0 0 ${width} ${height}`, role: 'img', 'aria-label': 'Hourly execution trend by robot, in minutes' });
  [0, .5, 1].forEach((ratio) => {
    const lineY = margin.top + ratio * plotHeight;
    svg.append(svgElement('line', { x1: margin.left, y1: lineY, x2: width - margin.right, y2: lineY, class: 'chart-grid-line' }));
    const axis = svgElement('text', { x: margin.left - 7, y: lineY + 4, 'text-anchor': 'end', class: 'chart-axis-label' });
    axis.textContent = `${formatNumber(max * (1 - ratio), 0)}m`;
    svg.append(axis);
  });
  series.forEach((item) => {
    const points = hourLabels.map((label, index) => ({ x: x(index), y: y(item.values.get(label) || 0) }));
    const line = svgElement('path', { d: buildMonotoneCurvePath(points), class: 'chart-line task-usage-line' });
    line.style.stroke = item.color;
    svg.append(line);
    hourLabels.forEach((label, index) => {
      if (index % Math.max(1, Math.ceil(hourLabels.length / 18)) !== 0 && index !== hourLabels.length - 1) return;
      const point = svgElement('circle', { cx: x(index), cy: y(item.values.get(label) || 0), r: 2.2, stroke: item.color, class: 'chart-point' });
      point.style.stroke = item.color;
      const title = svgElement('title');
      title.textContent = `${item.name} · ${formatShortTime(label)}: ${formatNumber(item.values.get(label) || 0, 1)} min`;
      point.append(title);
      svg.append(point);
    });
  });
  const xTickCount = Math.min(7, hourLabels.length);
  const xTickIndexes = [...new Set(Array.from({ length: xTickCount }, (_, index) => (
    Math.round((index * (hourLabels.length - 1)) / Math.max(xTickCount - 1, 1))
  )))];
  xTickIndexes.forEach((index) => {
    const tick = svgElement('text', {
      x: x(index),
      y: height - 8,
      'text-anchor': index === 0 ? 'start' : (index === hourLabels.length - 1 ? 'end' : 'middle'),
      class: 'chart-axis-label'
    });
    tick.textContent = formatShortTime(hourLabels[index]);
    svg.append(tick);
  });
  host.append(svg);
  const legend = document.createElement('div');
  legend.className = 'task-chart-legend';
  series.forEach((item) => {
    const legendItem = document.createElement('span');
    legendItem.innerHTML = `<i style="background:${item.color}"></i>${item.name}`;
    legend.append(legendItem);
  });
  host.append(legend);
}

/*
  Smooth cubic interpolation that remains monotone between adjacent hourly
  values. The curve passes through every observed point without inventing an
  overshoot between two zero-value hours.
*/
function buildMonotoneCurvePath(points = []) {
  if (!points.length) return '';
  if (points.length === 1) return `M ${points[0].x} ${points[0].y}`;

  const slopes = points.slice(0, -1).map((point, index) => {
    const nextPoint = points[index + 1];
    return (nextPoint.y - point.y) / (nextPoint.x - point.x);
  });
  const tangents = points.map((point, index) => {
    if (index === 0) return slopes[0];
    if (index === points.length - 1) return slopes[slopes.length - 1];
    return slopes[index - 1] * slopes[index] <= 0
      ? 0
      : (2 * slopes[index - 1] * slopes[index]) / (slopes[index - 1] + slopes[index]);
  });

  let path = `M ${points[0].x} ${points[0].y}`;
  for (let index = 0; index < points.length - 1; index += 1) {
    const point = points[index];
    const nextPoint = points[index + 1];
    const deltaX = (nextPoint.x - point.x) / 3;
    path += ` C ${point.x + deltaX} ${point.y + tangents[index] * deltaX}`;
    path += ` ${nextPoint.x - deltaX} ${nextPoint.y - tangents[index + 1] * deltaX}`;
    path += ` ${nextPoint.x} ${nextPoint.y}`;
  }
  return path;
}

/*
  Step-after path for hourly series. The value stays constant until the next
  hour, so the chart never suggests data exists between two hourly samples.
*/
function buildStepPath(points = []) {
  if (!points.length) return '';
  let path = `M ${points[0].x} ${points[0].y}`;
  for (let index = 1; index < points.length; index += 1) {
    path += ` H ${points[index].x} V ${points[index].y}`;
  }
  return path;
}

function renderTaskIdleTrend(host, rows = []) {
  if (!host) return;
  host.replaceChildren();
  const byHour = new Map();
  rows.forEach((row) => {
    if (!row.stat_hour) return;
    const idleMinutes = (asNumber(row.no_task_seconds) + asNumber(row.waiting_seconds) + asNumber(row.charging_seconds)) / 60;
    byHour.set(row.stat_hour, (byHour.get(row.stat_hour) || 0) + idleMinutes);
  });
  const points = [...byHour.entries()].sort(([left], [right]) => left.localeCompare(right)).map(([label, value]) => ({ label, value }));
  if (!points.length) {
    const empty = document.createElement('div');
    empty.className = 'chart-empty';
    empty.textContent = 'No hourly idle-time evidence is available for the selected period.';
    host.append(empty);
    return;
  }
  const width = 620; const height = 250;
  const margin = { left: 48, right: 18, top: 16, bottom: 34 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  const max = Math.max(...points.map((point) => point.value), 1);
  const step = plotWidth / Math.max(points.length, 1);
  const barWidth = Math.max(2, Math.min(18, step * .7));
  const y = (value) => margin.top + (1 - value / max) * plotHeight;
  const svg = svgElement('svg', { viewBox: `0 0 ${width} ${height}`, role: 'img', 'aria-label': 'Hourly idle time, in minutes' });
  [0, .5, 1].forEach((ratio) => {
    const lineY = margin.top + ratio * plotHeight;
    svg.append(svgElement('line', { x1: margin.left, y1: lineY, x2: width - margin.right, y2: lineY, class: 'chart-grid-line' }));
    const axis = svgElement('text', { x: margin.left - 7, y: lineY + 4, 'text-anchor': 'end', class: 'chart-axis-label' });
    axis.textContent = `${formatNumber(max * (1 - ratio), 0)}m`;
    svg.append(axis);
  });
  points.forEach((point, index) => {
    const x = margin.left + index * step + (step - barWidth) / 2;
    const rect = svgElement('rect', { x, y: y(point.value), width: barWidth, height: Math.max(1, margin.top + plotHeight - y(point.value)), rx: 2, fill: '#d97706' });
    const title = svgElement('title');
    title.textContent = `${formatShortTime(point.label)}: ${formatNumber(point.value, 1)} idle min`;
    rect.append(title);
    svg.append(rect);
  });
  const first = svgElement('text', { x: margin.left, y: height - 8, class: 'chart-axis-label' });
  first.textContent = formatShortTime(points[0].label);
  const last = svgElement('text', { x: width - margin.right, y: height - 8, 'text-anchor': 'end', class: 'chart-axis-label' });
  last.textContent = formatShortTime(points[points.length - 1].label);
  svg.append(first, last);
  host.append(svg);
}

function renderTaskIdleCauses(summary, host = elements.taskIdleCauseChart) {
  if (!host) return;
  const causes = [
    { label: 'No task', value: asNumber(summary.no_task_seconds), color: '#2563eb' },
    { label: 'Waiting', value: asNumber(summary.waiting_seconds), color: '#d97706' },
    { label: 'Charging', value: asNumber(summary.charging_seconds), color: '#059669' }
  ];
  const total = causes.reduce((sum, item) => sum + item.value, 0);
  host.replaceChildren();
  if (!total) {
    host.classList.add('empty-state');
    host.textContent = 'No confirmed idle-time evidence is available in this period.';
    return;
  }
  host.classList.remove('empty-state');
  let cursor = 0;
  const segments = causes.map((item) => {
    const end = cursor + (100 * item.value / total);
    const segment = `${item.color} ${cursor}% ${end}%`;
    cursor = end;
    return segment;
  });
  const donut = document.createElement('div');
  donut.className = 'task-idle-pie';
  donut.style.background = `conic-gradient(${segments.join(', ')})`;
  donut.setAttribute('role', 'img');
  donut.setAttribute('aria-label', `Observed idle time: ${formatSeconds(total)}`);
  const legend = document.createElement('div');
  legend.className = 'task-idle-legend';
  causes.forEach((item) => {
    const row = document.createElement('div');
    row.innerHTML = `<i style="background:${item.color}"></i><span>${item.label}</span><b>${formatSeconds(item.value)}</b>`;
    legend.append(row);
  });
  host.append(donut, legend);
}

function taskExceptionFinding(type) {
  const labels = {
    FULL_NO_BATTERY_OR_TASK_EVIDENCE: 'No battery or task evidence',
    FULL_TASK_EVENT_WITHOUT_BATTERY_EVIDENCE: 'Task evidence; battery state missing',
    FULL_STATE_COVERAGE_GAP_UNRESOLVED: 'State coverage unresolved',
    PARTIAL_STATE_COVERAGE_GAP: 'Partial state coverage gap'
  };
  return labels[type] || 'State coverage gap';
}

function renderTaskStateExceptionDetails(rows = [], totalAffectedRobotHours = 0) {
  const panel = elements.taskStateExceptionPanel;
  const body = elements.taskStateExceptionBody;
  const summary = elements.taskStateExceptionSummary;
  if (!panel || !body || !summary) return;

  panel.hidden = rows.length === 0;
  body.replaceChildren();
  if (!rows.length) return;

  summary.textContent = `Latest ${formatNumber(rows.length)} of ${formatNumber(totalAffectedRobotHours)} affected robot-hours`;
  rows.forEach((row) => {
    const tr = document.createElement('tr');
    const robot = document.createElement('td');
    robot.textContent = row.robot_code || '--';
    const hour = document.createElement('td');
    hour.textContent = formatTaskLocalDateTime(row.stat_hour);
    const finding = document.createElement('td');
    finding.textContent = `${taskExceptionFinding(row.exception_type)} (${formatSeconds(row.data_unavailable_seconds)})`;
    const evidence = document.createElement('td');
    evidence.textContent = `Battery ${formatNumber(row.battery_event_count)} / task ${formatNumber(row.task_event_count)}`;
    const priorBattery = document.createElement('td');
    priorBattery.textContent = formatTaskLocalDateTime(row.last_battery_event_time_before_hour);
    tr.append(robot, hour, finding, evidence, priorBattery);
    body.append(tr);
  });
}

function renderLegacyTaskAnalytics(data) {
  const summary = data.summary || {};
  const topLimit = state.taskTopLimit;
  const idleSeconds = asNumber(summary.no_task_seconds) + asNumber(summary.waiting_seconds) + asNumber(summary.charging_seconds);
  const totalSeconds = asNumber(summary.executing_seconds) + idleSeconds + asNumber(summary.data_unavailable_seconds);
  const unavailablePercent = totalSeconds > 0 ? (100 * asNumber(summary.data_unavailable_seconds) / totalSeconds) : 0;
  const assignedTaskCount = asNumber(summary.queue_assigned_task_count);
  const completedTaskCount = asNumber(summary.queue_completed_task_count);
  const noClosedTaskEvidence = !summary.latest_source_event_time
    && asNumber(summary.executing_seconds) === 0
    && asNumber(summary.task_started_count) === 0
    && asNumber(summary.task_completed_count) === 0;
  populateTaskRobotSelector(data.robots || []);
  if (elements.taskTopLimitSelect) elements.taskTopLimitSelect.value = String(topLimit);
  elements.taskDataScope.dataset.tone = asNumber(summary.data_unavailable_seconds) > 0 ? 'warning' : 'ok';
  elements.taskDataScope.textContent = `${taskWindowLabel(summary)} · ${formatNumber(summary.robot_count)} robots · TA_AMR + AMR_Queue via DWS · ${formatPercent(unavailablePercent)} coverage gap`;
  elements.taskOnlineValue.textContent = 'Not available';
  elements.taskOnlineDetail.textContent = 'Task activity is not online-state evidence';
  elements.taskCompletedValue.textContent = formatNumber(completedTaskCount);
  elements.taskCompletedDetail.textContent = `${formatNumber(assignedTaskCount)} assigned queues · terminal status completed`;
  elements.taskEfficiencyValue.textContent = 'Not defined';
  elements.taskEfficiencyDetail.textContent = 'No approved formula or full available-time denominator';
  elements.taskWifiDisconnectValue.textContent = 'Not available';
  elements.taskWifiDisconnectDetail.textContent = 'No WiFi disconnect event in Task DWS';
  elements.taskDistanceValue.textContent = 'Not available';
  elements.taskDistanceDetail.textContent = 'No route distance or odometer in the source tables';
  const selectedRobotLabel = taskRobotSelectionLabel(data.robots || []);
  elements.taskUsageSubtitle.textContent = noClosedTaskEvidence
    ? `${selectedRobotLabel} · no closed task-event evidence in this selected period`
    : `${selectedRobotLabel} · accepted queues ${formatNumber(summary.accepted_queue_count)} → task/subjob starts ${formatNumber(asNumber(summary.task_started_count) + asNumber(summary.subtask_started_count))} → top-level completions ${formatNumber(summary.task_completed_count)}`;
  if (noClosedTaskEvidence) {
    elements.taskUsageChart.replaceChildren();
    const empty = document.createElement('div');
    empty.className = 'chart-empty';
    empty.textContent = 'No closed task-event evidence is available for an execution trend in this period.';
    elements.taskUsageChart.append(empty);
  } else {
    renderTaskUsageTrend(elements.taskUsageChart, data.hourlyTrend || [], state.taskRobots);
  }
  renderTaskIdleTrend(elements.taskIdleTrendChart, data.hourlyTrend || []);
  renderTaskIdleCauses(summary);
  elements.taskCallingBoxTitle.textContent = `Top ${topLimit} Calling Boxes`;
  elements.taskAssignedTitle.textContent = `Top ${topLimit} Assigned Tasks`;
  renderTaskRanking(elements.taskCallingBoxList, (data.callingBoxes || []).slice(0, topLimit), 'calling_box_count', (row) => `${formatNumber(row.robot_count)} robots · latest ${formatTaskLocalDateTime(row.last_called_at)}`);
  renderTaskRanking(elements.taskAssignedList, (data.assignedTasks || []).slice(0, topLimit), 'assigned_task_count', (row) => `${formatNumber(row.completed_task_count)} completed · ${formatNumber(row.robot_count)} robots`);
  renderTaskVolumeCharts(data);
}

/*
  Hourly series chart for Calling Box and assigned-task counts.
  Deliberately mirrors renderTaskUsageTrend so the three Task Analytics trend
  charts read the same way; series come from the top-N labels bounded in SQL.
*/
function renderTaskLabelTrend(host, rows, options = {}) {
  if (!host) return;
  host.replaceChildren();
  const labelKey = options.labelKey;
  const valueKey = options.valueKey;
  const secondaryKey = options.secondaryKey;
  const scopedRows = rows.filter((row) => row.stat_hour && row[labelKey]);
  if (!scopedRows.length) {
    const empty = document.createElement('div');
    empty.className = 'chart-empty';
    empty.textContent = options.emptyText || 'No hourly evidence is available for the selected period.';
    host.append(empty);
    return;
  }

  const hourLabels = [...new Set(scopedRows.map((row) => row.stat_hour))].sort();
  const seriesMap = new Map();
  const seriesSecondaryMap = new Map();
  scopedRows.forEach((row) => {
    const name = String(row[labelKey]);
    if (!seriesMap.has(name)) {
      seriesMap.set(name, new Map());
      seriesSecondaryMap.set(name, new Map());
    }
    const bucket = seriesMap.get(name);
    bucket.set(row.stat_hour, (bucket.get(row.stat_hour) || 0) + asNumber(row[valueKey]));
    if (secondaryKey) {
      const secondary = seriesSecondaryMap.get(name);
      secondary.set(row.stat_hour, (secondary.get(row.stat_hour) || 0) + asNumber(row[secondaryKey]));
    }
  });

  const palette = ['#2563eb', '#059669', '#d97706', '#7c3aed', '#db2777', '#0891b2'];
  const series = [...seriesMap.entries()]
    .sort((a, b) => {
      const total = (entry) => [...entry[1].values()].reduce((sum, value) => sum + value, 0);
      return total(b) - total(a);
    })
    .map(([name, values], index) => ({
      name,
      values,
      secondary: seriesSecondaryMap.get(name),
      color: palette[index % palette.length]
    }));

  const max = Math.max(...series.flatMap((item) => hourLabels.map((label) => item.values.get(label) || 0)), 1);
  const width = 780;
  const height = 250;
  const margin = { left: 48, right: 18, top: 16, bottom: 34 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  const x = (index) => margin.left + (index / Math.max(hourLabels.length - 1, 1)) * plotWidth;
  const y = (value) => margin.top + (1 - value / max) * plotHeight;
  const svg = svgElement('svg', { viewBox: `0 0 ${width} ${height}`, role: 'img', 'aria-label': options.ariaLabel || 'Hourly trend' });

  [0, 0.5, 1].forEach((ratio) => {
    const lineY = margin.top + ratio * plotHeight;
    svg.append(svgElement('line', { x1: margin.left, y1: lineY, x2: width - margin.right, y2: lineY, class: 'chart-grid-line' }));
    const axis = svgElement('text', { x: margin.left - 7, y: lineY + 4, 'text-anchor': 'end', class: 'chart-axis-label' });
    axis.textContent = formatNumber(max * (1 - ratio), 0);
    svg.append(axis);
  });

  const tooltip = document.createElement('div');
  tooltip.className = 'chart-tooltip';
  tooltip.hidden = true;
  const tooltipText = (item, label) => {
    const secondaryValue = item.secondary ? item.secondary.get(label) : null;
    return `${item.name} · ${formatShortTime(label)} · ${formatNumber(item.values.get(label) || 0)} ${options.unit || ''}${secondaryValue != null ? ` · ${formatNumber(secondaryValue)} completed` : ''}`.trim();
  };
  const moveTooltip = (event, item) => {
    const svgRect = svg.getBoundingClientRect();
    const renderedX = event.clientX - svgRect.left;
    const viewX = svgRect.width > 0 ? (renderedX / svgRect.width) * width : renderedX;
    const index = Math.min(
      hourLabels.length - 1,
      Math.max(0, Math.round((viewX - margin.left) / plotWidth * (hourLabels.length - 1)))
    );
    tooltip.textContent = tooltipText(item, hourLabels[index]);
    tooltip.hidden = false;
    const hostRect = host.getBoundingClientRect();
    let left = event.clientX - hostRect.left + 12;
    let top = event.clientY - hostRect.top - 12;
    if (left + tooltip.offsetWidth > hostRect.width - 8) {
      left = event.clientX - hostRect.left - tooltip.offsetWidth - 12;
    }
    tooltip.style.left = `${Math.max(4, left)}px`;
    tooltip.style.top = `${Math.max(4, top)}px`;
  };
  const hideTooltip = () => { tooltip.hidden = true; };

  series.forEach((item) => {
    const points = hourLabels.map((label, index) => ({ x: x(index), y: y(item.values.get(label) || 0) }));
    const pathD = buildStepPath(points);
    const line = svgElement('path', { d: pathD, class: 'chart-line task-usage-line' });
    line.style.stroke = item.color;
    svg.append(line);

    const hit = svgElement('path', { d: pathD, class: 'chart-line-hit' });
    hit.style.stroke = 'transparent';
    hit.style.strokeWidth = '18';
    hit.style.fill = 'none';
    hit.style.pointerEvents = 'stroke';
    hit.style.cursor = 'pointer';
    hit.addEventListener('mousemove', (event) => moveTooltip(event, item));
    hit.addEventListener('mouseleave', hideTooltip);
    svg.append(hit);

    hourLabels.forEach((label, index) => {
      if (index % Math.max(1, Math.ceil(hourLabels.length / 18)) !== 0 && index !== hourLabels.length - 1) return;
      const point = svgElement('circle', { cx: x(index), cy: y(item.values.get(label) || 0), r: 2.2, class: 'chart-point' });
      point.style.stroke = item.color;
      point.style.pointerEvents = 'none';
      svg.append(point);
    });
  });

  const xTickCount = Math.min(7, hourLabels.length);
  const xTickIndexes = [...new Set(Array.from({ length: xTickCount }, (_, index) => (
    Math.round((index * (hourLabels.length - 1)) / Math.max(xTickCount - 1, 1))
  )))];
  xTickIndexes.forEach((index) => {
    const tick = svgElement('text', {
      x: x(index),
      y: height - 8,
      'text-anchor': index === 0 ? 'start' : (index === hourLabels.length - 1 ? 'end' : 'middle'),
      class: 'chart-axis-label'
    });
    tick.textContent = formatShortTime(hourLabels[index]);
    svg.append(tick);
  });

  host.append(svg);
  host.append(tooltip);

  const legend = document.createElement('div');
  legend.className = 'task-chart-legend';
  series.forEach((item) => {
    const legendItem = document.createElement('span');
    const swatch = document.createElement('i');
    swatch.style.background = item.color;
    legendItem.append(swatch, document.createTextNode(item.name));
    legendItem.title = item.name;
    legend.append(legendItem);
  });
  host.append(legend);
}

function renderTaskVolumeCharts(data) {
  const callingRows = data.callingBoxHourly || [];
  const assignedRows = data.assignedTaskHourly || [];

  if (elements.taskCallingBoxTrendSubtitle) {
    const labels = new Set(callingRows.map((row) => row.calling_box_label));
    elements.taskCallingBoxTrendSubtitle.textContent = labels.size
      ? `Call count by hour · top ${labels.size} Calling Boxes in the selected period`
      : 'Call count by hour. Series are the top Calling Boxes in the selected period.';
  }
  renderTaskLabelTrend(elements.taskCallingBoxTrendChart, callingRows, {
    labelKey: 'calling_box_label',
    valueKey: 'calling_box_count',
    unit: 'calls',
    ariaLabel: 'Hourly Calling Box call count by label',
    emptyText: 'No Calling Box records are available for the selected period and robot.'
  });

  if (elements.taskAssignedTrendSubtitle) {
    const labels = new Set(assignedRows.map((row) => row.task_label));
    elements.taskAssignedTrendSubtitle.textContent = labels.size
      ? `Assignment count by hour · top ${labels.size} assigned tasks in the selected period`
      : 'Assignment count by hour. Series are the top assigned tasks in the selected period.';
  }
  renderTaskLabelTrend(elements.taskAssignedTrendChart, assignedRows, {
    labelKey: 'task_label',
    valueKey: 'assigned_task_count',
    secondaryKey: 'completed_task_count',
    unit: 'assignments',
    ariaLabel: 'Hourly assigned task count by label',
    emptyText: 'No assigned task records are available for the selected period and robot.'
  });
}

function renderTaskAnalytics(data) {
  const summary = data.summary || {};
  const topLimit = state.taskTopLimit;
  const executionSeconds = asNumber(summary.executing_seconds);
  const idleSeconds = asNumber(summary.no_task_seconds) + asNumber(summary.waiting_seconds) + asNumber(summary.charging_seconds);
  const dataExceptionSeconds = asNumber(summary.data_unavailable_seconds);
  const knownStateSeconds = executionSeconds + idleSeconds;
  const totalSeconds = knownStateSeconds + dataExceptionSeconds;
  const utilizationPercent = knownStateSeconds > 0 ? (100 * executionSeconds / knownStateSeconds) : null;
  const unavailablePercent = totalSeconds > 0 ? (100 * dataExceptionSeconds / totalSeconds) : 0;
  const dataGapRobotHours = asNumber(summary.data_gap_robot_hour_count);
  const dataExceptionRobotHours = asNumber(summary.data_exception_robot_hour_count);
  const dataExceptionRobots = asNumber(summary.data_exception_robot_count);

  populateTaskRobotSelector(data.robots || []);
  if (elements.taskTopLimitSelect) elements.taskTopLimitSelect.value = String(topLimit);

  elements.taskDataScope.dataset.tone = dataExceptionRobotHours > 0 ? 'critical' : (dataExceptionSeconds > 0 ? 'warning' : 'ok');
  elements.taskDataScope.textContent = dataExceptionRobotHours > 0
    ? `Task window ${taskWindowLabel(summary)}. State data exception: ${formatNumber(dataExceptionRobotHours)} full robot-hours across ${formatNumber(dataExceptionRobots)} robots have no execution, charging, waiting, or no-task evidence. Utilization excludes all missing time.`
    : dataExceptionSeconds > 0
      ? `Task window ${taskWindowLabel(summary)}. State coverage gap: ${formatSeconds(dataExceptionSeconds)} is missing from ${formatNumber(dataGapRobotHours)} robot-hours. Each affected hour still has some state evidence; utilization excludes only the missing duration.`
      : `DWS task state coverage is complete for ${formatNumber(summary.robot_count)} robots in ${taskWindowLabel(summary)}.`;

  elements.taskUtilizationValue.textContent = utilizationPercent === null ? 'Not available' : formatPercent(utilizationPercent);
  elements.taskUtilizationDetail.textContent = knownStateSeconds > 0
    ? `Execution / ${formatSeconds(knownStateSeconds)} known state time`
    : 'No confirmed state evidence';
  elements.taskExecutionValue.textContent = formatSeconds(executionSeconds);
  elements.taskExecutionDetail.textContent = `${formatNumber(summary.task_started_count)} task starts / ${formatNumber(summary.subtask_started_count)} subtask starts`;
  elements.taskIdleValue.textContent = formatSeconds(idleSeconds);
  elements.taskIdleDetail.textContent = `No task ${formatSeconds(summary.no_task_seconds)} / wait ${formatSeconds(summary.waiting_seconds)} / charge ${formatSeconds(summary.charging_seconds)}`;
  elements.taskDataExceptionValue.textContent = dataExceptionRobotHours > 0
    ? formatNumber(dataExceptionRobotHours)
    : (dataExceptionSeconds > 0 ? 'Partial' : 'None');
  elements.taskDataExceptionDetail.textContent = dataExceptionRobotHours > 0
    ? `${formatNumber(dataExceptionRobots)} robots fully missing / ${formatPercent(unavailablePercent)} excluded`
    : dataExceptionSeconds > 0
      ? `${formatSeconds(dataExceptionSeconds)} partial gap / ${formatPercent(unavailablePercent)} excluded`
      : 'All four state categories have evidence';
  renderTaskStateExceptionDetails(data.stateExceptionDetails || [], dataGapRobotHours);

  const selectedRobotLabel = taskRobotSelectionLabel(data.robots || []);
  elements.taskUsageSubtitle.textContent = `${selectedRobotLabel} / queues accepted ${formatNumber(summary.accepted_queue_count)} / task starts ${formatNumber(summary.task_started_count)} / subtask starts ${formatNumber(summary.subtask_started_count)} / completed ${formatNumber(summary.task_completed_count)}`;
  renderTaskUsageTrend(elements.taskUsageChart, data.hourlyTrend || [], state.taskRobots);
  renderTaskIdleTrend(elements.taskIdleTrendChart, data.hourlyTrend || []);
  renderTaskIdleCauses(summary);

  elements.taskCallingBoxTitle.textContent = `Top ${topLimit} Calling Boxes`;
  elements.taskAssignedTitle.textContent = `Top ${topLimit} Assigned Tasks`;
  renderTaskRanking(
    elements.taskCallingBoxList,
    (data.callingBoxes || []).slice(0, topLimit),
    'calling_box_count',
    (row) => `${formatNumber(row.robot_count)} robots / latest ${formatTaskLocalDateTime(row.last_called_at)}`
  );
  renderTaskRanking(
    elements.taskAssignedList,
    (data.assignedTasks || []).slice(0, topLimit),
    'assigned_task_count',
    (row) => `${formatNumber(row.completed_task_count)} completed / ${formatNumber(row.robot_count)} robots`
  );
  renderTaskVolumeCharts(data);
}

/*
  Project and task view.

  The whole view is driven by the multi-select scope arrays
  (selectedProjectIds / selectedJobIds / selectedRobotCodes). Every reload asks
  the server for the same scope, so the project table, task table, robot
  breakdown, trend and record list can never disagree about which queue records
  they describe.
*/
async function loadProjectAnalytics({ announce = false } = {}) {
  const requestId = ++state.projectRequestId;
  const analysisWindow = selectedAnalysisWindow();
  const params = new URLSearchParams();
  if (analysisWindow.start && analysisWindow.end) {
    params.set('start', analysisWindow.start);
    params.set('end', analysisWindow.end);
  }
  if (state.selectedProjectIds.length) params.set('projects', state.selectedProjectIds.join(','));
  if (state.selectedJobIds.length) params.set('jobs', state.selectedJobIds.join(','));
  if (state.selectedRobotCodes.length) params.set('robots', state.selectedRobotCodes.join(','));

  if (elements.projectDataScope) elements.projectDataScope.textContent = 'Loading project and task data…';
  try {
    const data = await requestJson(`/api/project-analytics${params.toString() ? `?${params}` : ''}`);
    if (requestId !== state.projectRequestId) return;
    state.projectAnalytics = data;
    renderProjectAnalytics(data);
    if (announce) showToast('Project and task analysis updated');
  } catch (error) {
    if (requestId !== state.projectRequestId) return;
    if (elements.projectDataScope) {
      elements.projectDataScope.dataset.tone = 'critical';
      elements.projectDataScope.textContent = error.message;
    }
    showToast(error.message, 'error');
  }
}

function setProjectScope({ projectIds = [], jobIds = [], robotCodes = [] } = {}) {
  state.selectedProjectIds = projectIds.map(String);
  state.selectedJobIds = jobIds.map(String);
  state.selectedRobotCodes = robotCodes.map(String);
  if (state.projectAnalytics) populateProjectSelectors(state.projectAnalytics);
  loadProjectAnalytics();
}

function projectMultiLabel(values, allLabel) {
  return values.length ? `${values.length} selected` : allLabel;
}

/*
  Shared multi-select renderer for the Project & Task and Analysis Center
  filter bars. Each option is a checkbox; "All" selects every available value
  and "Clear" empties the selection.
*/
function renderProjectMultiMenu(menu, toggleText, options, selectedValues, onChange, allLabel) {
  if (!menu) return;
  menu.replaceChildren();
  const values = options.map((option) => String(option.value));
  const available = new Set(values);
  const selected = selectedValues.filter((value) => available.has(value));

  const actions = document.createElement('div');
  actions.className = 'multi-select-actions';
  const selectAll = document.createElement('button');
  selectAll.type = 'button';
  selectAll.textContent = 'Select all';
  selectAll.addEventListener('click', () => onChange([...values]));
  const clearAll = document.createElement('button');
  clearAll.type = 'button';
  clearAll.textContent = 'Clear';
  clearAll.addEventListener('click', () => onChange([]));
  actions.append(selectAll, clearAll);
  menu.append(actions);

  options.forEach((option) => {
    const label = document.createElement('label');
    label.className = 'multi-select-option';
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.value = String(option.value);
    input.checked = selected.includes(String(option.value));
    input.addEventListener('change', () => {
      const next = new Set(selected);
      if (input.checked) next.add(String(option.value));
      else next.delete(String(option.value));
      onChange(values.filter((value) => next.has(value)));
    });
    const text = document.createElement('span');
    text.textContent = option.label;
    label.append(input, text);
    menu.append(label);
  });

  toggleText.textContent = projectMultiLabel(selected, allLabel);
  toggleText.parentElement.title = selected.length ? selected.join(', ') : '';
}

function populateProjectSelectors(data) {
  const projects = (data.projects || [])
    .filter((row) => row.project_id !== null && row.project_id !== undefined)
    .map((row) => ({
      value: String(row.project_id),
      label: `${row.project_name} · ${formatNumber(row.queue_count)} records`
    }));
  const tasks = (data.tasks || [])
    .filter((row) => row.job_id !== null && row.job_id !== undefined)
    .map((row) => ({
      value: String(row.job_id),
      label: `${row.task_name} · ${formatNumber(row.queue_count)} records`
    }));
  const robots = (data.robots || [])
    .map((row) => ({
      value: String(row.robot_name || '').trim(),
      label: `${row.robot_name || 'Unmapped robot'} · ${formatNumber(row.queue_count)} records`
    }))
    .filter((row) => row.value !== '');

  const projectScope = {
    projectIds: state.selectedProjectIds,
    jobIds: state.selectedJobIds,
    robotCodes: state.selectedRobotCodes
  };

  renderProjectMultiMenu(
    elements.projectMenu,
    elements.projectToggleText,
    projects,
    state.selectedProjectIds,
    (values) => setProjectScope({ ...projectScope, projectIds: values }),
    `All projects (${projects.length})`
  );
  renderProjectMultiMenu(
    elements.analysisProjectMenu,
    elements.analysisProjectToggleText,
    projects,
    state.selectedProjectIds,
    (values) => setProjectScope({ ...projectScope, projectIds: values }),
    `All projects (${projects.length})`
  );
  renderProjectMultiMenu(
    elements.taskMenu,
    elements.taskToggleText,
    tasks,
    state.selectedJobIds,
    (values) => setProjectScope({ ...projectScope, jobIds: values }),
    `All tasks (${tasks.length})`
  );
  renderProjectMultiMenu(
    elements.analysisTaskMenu,
    elements.analysisTaskToggleText,
    tasks,
    state.selectedJobIds,
    (values) => setProjectScope({ ...projectScope, jobIds: values }),
    `All tasks (${tasks.length})`
  );
  renderProjectMultiMenu(
    elements.robotMenu,
    elements.robotToggleText,
    robots,
    state.selectedRobotCodes,
    (values) => setProjectScope({ ...projectScope, robotCodes: values }),
    `All robots (${robots.length})`
  );
  renderProjectMultiMenu(
    elements.analysisRobotMenu,
    elements.analysisRobotToggleText,
    robots,
    state.selectedRobotCodes,
    (values) => setProjectScope({ ...projectScope, robotCodes: values }),
    `All robots (${robots.length})`
  );
}

function projectEmptyRow(host, columnCount, message) {
  const row = document.createElement('tr');
  const cell = document.createElement('td');
  cell.colSpan = columnCount;
  cell.className = 'empty-cell';
  cell.textContent = message;
  row.append(cell);
  host.append(row);
}

function projectTableRow(cells, { onActivate = null, active = false } = {}) {
  const row = document.createElement('tr');
  if (active) row.classList.add('is-selected');
  if (onActivate) {
    row.classList.add('is-clickable');
    row.tabIndex = 0;
    row.addEventListener('click', onActivate);
    row.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        onActivate();
      }
    });
  }
  cells.forEach((cell) => {
    const node = document.createElement('td');
    node.textContent = cell === null || cell === undefined ? '--' : String(cell);
    row.append(node);
  });
  return row;
}

function renderProjectList(rows = []) {
  const host = elements.projectListBody;
  if (!host) return;
  host.replaceChildren();
  if (!rows.length) {
    projectEmptyRow(host, 8, 'No project records in this window');
    return;
  }
  rows.forEach((row) => {
    const projectId = row.project_id === null || row.project_id === undefined ? null : String(row.project_id);
    host.append(projectTableRow(
      [
        row.project_name,
        formatNumber(row.queue_count),
        formatNumber(row.task_count),
        formatNumber(row.robot_count),
        formatNumber(row.completed_count),
        formatNumber(row.unsuccessful_count),
        formatSeconds(row.execution_seconds),
        formatTaskLocalDateTime(row.latest_event_time)
      ],
      {
        active: projectId !== null && state.selectedProjectIds.includes(projectId),
        onActivate: projectId === null
          ? null
          : () => {
            const next = new Set(state.selectedProjectIds);
            if (next.has(projectId)) next.delete(projectId);
            else next.add(projectId);
            setProjectScope({
              projectIds: [...next],
              jobIds: state.selectedJobIds,
              robotCodes: state.selectedRobotCodes
            });
          }
      }
    ));
  });
}

function renderProjectTasks(rows = []) {
  const host = elements.projectTaskBody;
  if (!host) return;
  host.replaceChildren();
  if (!rows.length) {
    projectEmptyRow(host, 9, 'No task records in this scope');
    return;
  }
  rows.forEach((row) => {
    const jobId = row.job_id === null || row.job_id === undefined ? null : String(row.job_id);
    host.append(projectTableRow(
      [
        row.task_name,
        row.project_name,
        formatNumber(row.queue_count),
        formatNumber(row.robot_count),
        formatNumber(row.completed_count),
        formatNumber(row.unsuccessful_count),
        formatNumber(row.open_count),
        row.average_execution_seconds === null || row.average_execution_seconds === undefined
          ? 'Not available'
          : formatSeconds(row.average_execution_seconds),
        formatTaskLocalDateTime(row.latest_event_time)
      ],
      {
        active: jobId !== null && state.selectedJobIds.includes(jobId),
        onActivate: jobId === null
          ? null
          : () => {
            const nextJobs = new Set(state.selectedJobIds);
            if (nextJobs.has(jobId)) nextJobs.delete(jobId);
            else nextJobs.add(jobId);
            const nextProjects = new Set(state.selectedProjectIds);
            const rowProjectId = row.project_id === null || row.project_id === undefined
              ? null
              : String(row.project_id);
            if (rowProjectId !== null && !nextProjects.size) nextProjects.add(rowProjectId);
            setProjectScope({
              projectIds: [...nextProjects],
              jobIds: [...nextJobs],
              robotCodes: state.selectedRobotCodes
            });
          }
      }
    ));
  });
}

function renderProjectRobots(rows = []) {
  const host = elements.projectRobotBody;
  if (!host) return;
  host.replaceChildren();
  if (!rows.length) {
    projectEmptyRow(host, 6, 'No robot carried this work in the selected scope');
    return;
  }
  rows.forEach((row) => {
    host.append(projectTableRow([
      row.robot_name,
      formatNumber(row.queue_count),
      formatNumber(row.task_count),
      formatNumber(row.completed_count),
      formatNumber(row.unsuccessful_count),
      row.average_execution_seconds === null || row.average_execution_seconds === undefined
        ? 'Not available'
        : formatSeconds(row.average_execution_seconds)
    ]));
  });
}

function renderProjectOutcomes(rows = []) {
  const host = elements.projectOutcomeChart;
  if (!host) return;
  host.replaceChildren();
  const total = rows.reduce((sum, row) => sum + asNumber(row.queue_count), 0);
  if (!total) {
    host.classList.add('empty-state');
    host.textContent = 'No recorded outcomes in the selected scope.';
    return;
  }
  host.classList.remove('empty-state');
  const tones = {
    completed: '#059669',
    failed: '#dc2626',
    cancelled: '#d97706',
    canceled: '#d97706',
    in_progress: '#2563eb',
    pending: '#7c3aed'
  };
  const palette = ['#0891b2', '#db2777', '#65a30d', '#a16207'];
  let fallbackIndex = 0;
  const outcomes = rows.map((row) => {
    const status = String(row.queue_status || 'unknown');
    return {
      label: status,
      value: asNumber(row.queue_count),
      robots: asNumber(row.robot_count),
      color: tones[status] || palette[fallbackIndex++ % palette.length]
    };
  });

  let cursor = 0;
  const segments = outcomes.map((item) => {
    const end = cursor + (100 * item.value / total);
    const segment = `${item.color} ${cursor}% ${end}%`;
    cursor = end;
    return segment;
  });
  const donut = document.createElement('div');
  donut.className = 'task-idle-pie';
  donut.style.background = `conic-gradient(${segments.join(', ')})`;
  donut.setAttribute('role', 'img');
  donut.setAttribute('aria-label', `Recorded outcomes across ${formatNumber(total)} task records`);
  const legend = document.createElement('div');
  legend.className = 'task-idle-legend';
  outcomes.forEach((item) => {
    const row = document.createElement('div');
    const swatch = document.createElement('i');
    swatch.style.background = item.color;
    const label = document.createElement('span');
    label.textContent = `${item.label} (${formatNumber(item.robots)} robots)`;
    const value = document.createElement('b');
    value.textContent = formatNumber(item.value);
    row.append(swatch, label, value);
    legend.append(row);
  });
  host.append(donut, legend);
}

function renderProjectRecords(rows = []) {
  const host = elements.projectRecordBody;
  if (!host) return;
  host.replaceChildren();
  if (!rows.length) {
    projectEmptyRow(host, 8, 'No task records in the selected scope');
    return;
  }
  rows.forEach((row) => {
    host.append(projectTableRow([
      formatTaskLocalDateTime(row.event_time),
      row.project_name,
      row.task_name,
      row.robot_name,
      row.queue_status || 'unknown',
      row.calling_box_name || 'Not linked',
      asNumber(row.execution_seconds) > 0 ? formatSeconds(row.execution_seconds) : 'Not available',
      `${formatNumber(row.subjob_success_count)} / ${formatNumber(row.subjob_run_count)}`
    ]));
  });
}

function renderProjectAnalytics(data) {
  const summary = data.summary || {};
  populateProjectSelectors(data);
  if (state.dashboard) {
    renderAnalysis(state.dashboard.analysis, state.dashboard.analysisReadiness, state.dashboard.robots);
  }

  const projectLabel = state.selectedProjectIds.length === 1
    ? (data.projects || []).find((row) => String(row.project_id) === state.selectedProjectIds[0])?.project_name
      || `Project ${state.selectedProjectIds[0]}`
    : state.selectedProjectIds.length > 1
      ? `${state.selectedProjectIds.length} projects`
      : 'All projects';
  const taskLabel = state.selectedJobIds.length === 1
    ? (data.tasks || []).find((row) => String(row.job_id) === state.selectedJobIds[0])?.task_name
      || `Job ${state.selectedJobIds[0]}`
    : state.selectedJobIds.length > 1
      ? `${state.selectedJobIds.length} tasks`
      : 'All tasks';
  const robotLabel = state.selectedRobotCodes.length === 1
    ? state.selectedRobotCodes[0]
    : state.selectedRobotCodes.length > 1
      ? `${state.selectedRobotCodes.length} robots`
      : 'All robots';

  if (elements.projectDataScope) {
    elements.projectDataScope.dataset.tone = 'neutral';
    elements.projectDataScope.textContent = `${projectLabel} / ${taskLabel} / ${robotLabel} · ${formatTaskLocalDateTime(summary.analysis_start)} to ${formatTaskLocalDateTime(summary.analysis_end)} · ${formatNumber(summary.queue_count)} records · ${formatNumber(summary.robot_count)} robots`;
  }

  /*
    The KPI strip describes the selected scope, not the whole window, so it is
    summed from the scoped robot breakdown rather than the window summary.
  */
  const robotRows = data.robots || [];
  const scopedRecords = robotRows.reduce((sum, row) => sum + asNumber(row.queue_count), 0);
  const scopedCompleted = robotRows.reduce((sum, row) => sum + asNumber(row.completed_count), 0);
  const scopedUnsuccessful = robotRows.reduce((sum, row) => sum + asNumber(row.unsuccessful_count), 0);
  const scopedExecution = robotRows.reduce((sum, row) => sum + asNumber(row.execution_seconds), 0);
  const recordedOutcomes = scopedCompleted + scopedUnsuccessful;

  if (elements.projectQueueValue) elements.projectQueueValue.textContent = formatNumber(scopedRecords);
  if (elements.projectQueueDetail) elements.projectQueueDetail.textContent = `${projectLabel} / ${taskLabel}`;
  if (elements.projectCompletionValue) {
    elements.projectCompletionValue.textContent = recordedOutcomes > 0
      ? formatPercent((100 * scopedCompleted) / recordedOutcomes)
      : 'Not available';
  }
  if (elements.projectCompletionDetail) {
    elements.projectCompletionDetail.textContent = recordedOutcomes > 0
      ? `${formatNumber(scopedCompleted)} completed / ${formatNumber(scopedUnsuccessful)} unsuccessful`
      : 'No terminal outcome recorded in this scope';
  }
  if (elements.projectExecutionValue) elements.projectExecutionValue.textContent = formatSeconds(scopedExecution);
  if (elements.projectExecutionDetail) {
    elements.projectExecutionDetail.textContent = 'Summed from closed subjob runs linked by queue ID';
  }
  if (elements.projectRobotValue) elements.projectRobotValue.textContent = formatNumber(robotRows.length);
  if (elements.projectRobotIds) {
    const names = robotRows.slice(0, 6).map((row) => row.robot_name);
    elements.projectRobotIds.textContent = names.length
      ? `${names.join(', ')}${robotRows.length > names.length ? ` +${robotRows.length - names.length} more` : ''}`
      : '--';
  }

  if (elements.projectTaskTitle) {
    elements.projectTaskTitle.textContent = state.selectedProjectIds.length ? `Tasks in ${projectLabel}` : 'Tasks in Scope';
  }
  if (elements.projectRobotTitle) {
    elements.projectRobotTitle.textContent = state.selectedJobIds.length
      ? `Robots Carrying ${taskLabel}`
      : (state.selectedProjectIds.length ? `Robots in ${projectLabel}` : 'Robots in Scope');
  }
  if (elements.projectTrendSubtitle) {
    elements.projectTrendSubtitle.textContent = `${projectLabel} / ${taskLabel} · queue records by hour, one series per robot.`;
  }

  renderProjectList(data.projects || []);
  renderAnalysisBarChart(elements.projectListChart, (data.projects || []).map((row) => ({
    label: row.project_name || 'Unmapped project',
    value: asNumber(row.queue_count),
    detail: `${formatNumber(row.task_count)} tasks · ${formatNumber(row.robot_count)} robots · ${formatSeconds(row.execution_seconds)}`
  })), { emptyText: 'No project records in this window' });
  renderProjectTasks(data.tasks || []);
  renderAnalysisBarChart(elements.projectTaskChart, (data.tasks || []).map((row) => ({
    label: row.task_name || `Job ${row.job_id}`,
    value: asNumber(row.queue_count),
    detail: `${formatNumber(row.completed_count)} completed · ${formatNumber(row.unsuccessful_count)} unsuccessful`
  })), { emptyText: 'No task records in this scope' });
  renderProjectRobots(robotRows);
  renderAnalysisBarChart(elements.projectRobotChart, robotRows.map((row) => ({
    label: row.robot_name || 'Unmapped robot',
    value: asNumber(row.queue_count),
    detail: `${formatNumber(row.completed_count)} completed · ${formatNumber(row.unsuccessful_count)} unsuccessful${row.average_execution_seconds == null ? '' : ` · ${formatSeconds(row.average_execution_seconds)} avg`}`
  })), { emptyText: 'No robot carried this work in the selected scope' });
  renderTaskIdleCauses(data.idleCauses || {}, elements.projectOutcomeChart);
  renderTaskLabelTrend(elements.projectTrendChart, data.hourlyTrend || [], {
    labelKey: 'robot_name',
    valueKey: 'queue_count',
    secondaryKey: 'completed_count',
    unit: 'records',
    ariaLabel: 'Task record trend by robot',
    emptyText: 'No hourly task records are available for the selected project and task.'
  });
  renderProjectRecords(data.recentQueues || []);
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

async function refreshDwsData() {
  if (state.loading) return;
  setBusy(true, 'Reloading ODS, DWD, Task DWS, and leaderboard aggregates...');
  try {
    const result = await requestJson('/api/sync/dws', { method: 'POST' });
    showToast(`DWS reload completed in ${formatNumber(result.elapsedSeconds || 0)} seconds`);
  } catch (error) {
    renderConnectionError(error);
    showToast(error.message, 'error');
    return;
  } finally {
    setBusy(false);
  }

  await loadDashboard({ announce: true });
  await loadTaskAnalytics({ announce: true });
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
  breakdown, which resolves display names through dbo.MA_AMR. Telemetry
  diagnostics are then filtered to exactly those master robot IDs.
*/
function projectScopeRobotNames() {
  const rows = state.projectAnalytics?.robots || [];
  return new Set(rows.map((row) => String(row.robot_name || '').trim()).filter(Boolean));
}

function projectScopeActiveAny() {
  return state.selectedProjectIds.length > 0
    || state.selectedJobIds.length > 0
    || state.selectedRobotCodes.length > 0;
}

function scopedAnalysisRobots(robots = []) {
  if (!projectScopeActiveAny()) return robots;
  const projectScope = state.selectedProjectIds.length > 0 || state.selectedJobIds.length > 0;
  const robotSet = state.selectedRobotCodes.length ? new Set(state.selectedRobotCodes) : null;
  let filtered = robots;
  if (projectScope) {
    const names = projectScopeRobotNames();
    if (!names.size) return [];
    filtered = filtered.filter((robot) => (
      names.has(String(robot.robot_code || '').trim())
      || names.has(String(robot.robot_name || '').trim())
    ));
  }
  if (robotSet) {
    filtered = filtered.filter((robot) => (
      robotSet.has(String(robot.robot_code || '').trim())
      || robotSet.has(String(robot.robot_name || '').trim())
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
function aggregateTargetRowsForRobots(robotTargetRows, selectedRobotSet) {
  const byTarget = new Map();
  robotTargetRows
    .filter((row) => selectedRobotSet.has(String(row.robot_code)))
    .forEach((row) => {
      const key = String(row.poi_target || '');
      if (!key) return;
      const entry = byTarget.get(key) || {
        poi_target: row.poi_target,
        sample_count: 0,
        valid_signal_sample_count: 0,
        zero_signal_sample_count: 0,
        weightedSignalTotal: 0,
        minimum_valid_rssi: null,
        robots: new Set()
      };
      const validCount = asNumber(row.valid_signal_sample_count);
      const average = Number(row.average_valid_rssi);
      if (validCount > 0 && Number.isFinite(average)) {
        entry.weightedSignalTotal += average * validCount;
        entry.valid_signal_sample_count += validCount;
      }
      entry.sample_count += asNumber(row.sample_count);
      entry.zero_signal_sample_count += asNumber(row.zero_signal_sample_count);
      const minimum = Number(row.minimum_valid_rssi);
      if (Number.isFinite(minimum)) {
        entry.minimum_valid_rssi = entry.minimum_valid_rssi == null
          ? minimum
          : Math.min(entry.minimum_valid_rssi, minimum);
      }
      entry.robots.add(String(row.robot_code));
      byTarget.set(key, entry);
    });

  return [...byTarget.values()].map((entry) => ({
    poi_target: entry.poi_target,
    sample_count: entry.sample_count,
    valid_signal_sample_count: entry.valid_signal_sample_count,
    zero_signal_sample_count: entry.zero_signal_sample_count,
    minimum_valid_rssi: entry.minimum_valid_rssi,
    average_valid_rssi: entry.valid_signal_sample_count > 0
      ? entry.weightedSignalTotal / entry.valid_signal_sample_count
      : null,
    robot_count: entry.robots.size
  }));
}

/*
  Multi-select variant of aggregateRunningWifiTrend. An empty selection array
  means "no filter", matching the checkbox dropdown where nothing ticked = all.
*/
function aggregateRunningWifiTrendMulti(rows, selectedPois, selectedRobots) {
  const poiSet = new Set(selectedPois);
  const robotSet = new Set(selectedRobots);
  const filtered = rows.filter((row) => (
    (poiSet.size === 0 || poiSet.has(String(row.poi_target)))
    && (robotSet.size === 0 || robotSet.has(String(row.robot_code)))
  ));
  return aggregateRunningWifiTrend(filtered, 'ALL', 'ALL');
}

function aggregateRunningWifiTrend(rows, selectedPoi, selectedRobot) {
  const buckets = new Map();
  rows
    .filter((row) => (
      (selectedPoi === 'ALL' || String(row.poi_target) === selectedPoi)
      && (selectedRobot === 'ALL' || String(row.robot_code) === selectedRobot)
    ))
    .forEach((row) => {
      const key = String(row.bucket_start || '');
      if (!key) return;
      const bucket = buckets.get(key) || {
        bucket_start: row.bucket_start,
        weightedSignalTotal: 0,
        valid_signal_sample_count: 0,
        zero_signal_sample_count: 0,
        sample_count: 0,
        minimum_valid_rssi: null
      };
      const validCount = asNumber(row.valid_signal_sample_count);
      const average = Number(row.average_valid_rssi);
      if (validCount > 0 && Number.isFinite(average)) {
        bucket.weightedSignalTotal += average * validCount;
        bucket.valid_signal_sample_count += validCount;
      }
      bucket.zero_signal_sample_count += asNumber(row.zero_signal_sample_count);
      bucket.sample_count += asNumber(row.sample_count);
      const minimum = Number(row.minimum_valid_rssi);
      if (Number.isFinite(minimum)) {
        bucket.minimum_valid_rssi = bucket.minimum_valid_rssi == null
          ? minimum
          : Math.min(bucket.minimum_valid_rssi, minimum);
      }
      buckets.set(key, bucket);
    });

  return [...buckets.values()]
    .map((bucket) => ({
      ...bucket,
      average_valid_rssi: bucket.valid_signal_sample_count > 0
        ? bucket.weightedSignalTotal / bucket.valid_signal_sample_count
        : null
    }))
    .sort((a, b) => new Date(a.bucket_start) - new Date(b.bucket_start));
}

function renderRunningWifiTrend(host, rows) {
  host.replaceChildren();
  host.classList.remove('empty-state');
  const points = rows.filter((row) => Number.isFinite(Number(row.average_valid_rssi)));

  if (!points.length) {
    host.classList.add('empty-state');
    host.textContent = 'No negative RSSI samples can be plotted for the selected filters.';
    return;
  }

  if (points.length < 4) {
    const sparse = document.createElement('div');
    sparse.className = 'running-wifi-sparse';
    points.forEach((point) => {
      const item = document.createElement('div');
      item.append(
        textNode('span', '', formatShortTime(point.bucket_start)),
        textNode('strong', '', `${formatNumber(point.average_valid_rssi, 1)} dBm`),
        textNode('small', '', `${formatNumber(point.sample_count)} samples`)
      );
      sparse.append(item);
    });
    host.append(sparse);
    return;
  }

  const width = 760;
  const height = 286;
  const margin = { left: 56, right: 22, top: 16, bottom: 42 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  const values = points.flatMap((point) => [
    Number(point.average_valid_rssi),
    Number(point.minimum_valid_rssi)
  ]).filter(Number.isFinite);
  const observedMin = Math.min(...values);
  const observedMax = Math.max(...values);
  const min = Math.floor((observedMin - 4) / 5) * 5;
  const max = Math.ceil((observedMax + 4) / 5) * 5;
  const x = (index) => margin.left + (index / Math.max(points.length - 1, 1)) * plotWidth;
  const y = (value) => margin.top + (1 - (value - min) / (max - min || 1)) * plotHeight;
  const svg = svgElement('svg', {
    viewBox: `0 0 ${width} ${height}`,
    role: 'img',
    'aria-label': 'Average and minimum WiFi RSSI trend during Running tasks'
  });

  [0, 0.25, 0.5, 0.75, 1].forEach((ratio) => {
    const lineY = margin.top + ratio * plotHeight;
    svg.append(svgElement('line', {
      x1: margin.left,
      y1: lineY,
      x2: width - margin.right,
      y2: lineY,
      class: 'running-wifi-grid-line'
    }));
    const label = svgElement('text', {
      x: margin.left - 9,
      y: lineY + 4,
      'text-anchor': 'end',
      class: 'running-wifi-axis-label'
    });
    label.textContent = `${formatNumber(max - ratio * (max - min), 0)}`;
    svg.append(label);
  });

  const averagePath = points
    .map((point, index) => `${index ? 'L' : 'M'} ${x(index)} ${y(Number(point.average_valid_rssi))}`)
    .join(' ');
  const minimumPath = points
    .filter((point) => Number.isFinite(Number(point.minimum_valid_rssi)))
    .map((point) => {
      const index = points.indexOf(point);
      return `${index ? 'L' : 'M'} ${x(index)} ${y(Number(point.minimum_valid_rssi))}`;
    })
    .join(' ');
  svg.append(svgElement('path', { d: minimumPath, class: 'running-wifi-line minimum' }));
  svg.append(svgElement('path', { d: averagePath, class: 'running-wifi-line average' }));

  const markerInterval = Math.max(1, Math.ceil(points.length / 24));
  points.forEach((point, index) => {
    if (index % markerInterval === 0 || index === points.length - 1) {
      const averagePoint = svgElement('circle', {
        cx: x(index),
        cy: y(Number(point.average_valid_rssi)),
        r: 3,
        class: 'running-wifi-point average'
      });
      const title = svgElement('title');
      title.textContent = `${formatDateTime(point.bucket_start)} · Average ${formatNumber(point.average_valid_rssi, 1)} dBm · Minimum ${formatNumber(point.minimum_valid_rssi, 1)} dBm · ${formatNumber(point.sample_count)} samples`;
      averagePoint.append(title);
      svg.append(averagePoint);
    }
    if (asNumber(point.zero_signal_sample_count) > 0) {
      const zeroMarker = svgElement('path', {
        d: `M ${x(index) - 5} ${height - margin.bottom + 4} L ${x(index) + 5} ${height - margin.bottom + 4} L ${x(index)} ${height - margin.bottom - 5} Z`,
        class: 'running-wifi-zero-marker'
      });
      const title = svgElement('title');
      title.textContent = `${formatDateTime(point.bucket_start)} · ${formatNumber(point.zero_signal_sample_count)} zero-signal samples`;
      zeroMarker.append(title);
      svg.append(zeroMarker);
    }
  });

  const firstLabel = svgElement('text', {
    x: margin.left,
    y: height - 12,
    class: 'running-wifi-axis-label'
  });
  firstLabel.textContent = formatShortTime(points[0].bucket_start);
  const lastLabel = svgElement('text', {
    x: width - margin.right,
    y: height - 12,
    'text-anchor': 'end',
    class: 'running-wifi-axis-label'
  });
  lastLabel.textContent = formatShortTime(points[points.length - 1].bucket_start);
  svg.append(firstLabel, lastLabel);
  host.append(svg);
}

const WIFI_POINT_LINE_STYLES = [
  { color: '#2563eb', dash: '' },
  { color: '#7c3aed', dash: '8 4' },
  { color: '#d97706', dash: '3 4' },
  { color: '#059669', dash: '10 4 2 4' },
  { color: '#db2777', dash: '6 3' },
  { color: '#0891b2', dash: '2 3' },
  { color: '#9333ea', dash: '12 4' },
  { color: '#4d7c0f', dash: '7 3 2 3' },
  { color: '#c2410c', dash: '4 3' },
  { color: '#475569', dash: '10 3' }
];

function wifiPointLineStyle(index) {
  return WIFI_POINT_LINE_STYLES[index % WIFI_POINT_LINE_STYLES.length];
}

function renderWifiPointLineChart(host, rows, selectedRobots, availableRobots) {
  host.replaceChildren();
  const selected = new Set(selectedRobots);
  const validRows = rows.filter((row) => (
    selected.has(String(row.robot_code))
    && row.poi_target
    && Number.isFinite(Number(row.average_valid_rssi))
  ));

  if (!selectedRobots.length) {
    host.classList.add('empty-state');
    host.textContent = 'No selected robot has plottable target-POI signal data in this time range.';
    return;
  }
  if (!validRows.length) {
    host.classList.add('empty-state');
    host.textContent = 'The selected robots have no plottable target-POI signal data in this time range.';
    return;
  }

  host.classList.remove('empty-state');
  const rowsByRobot = new Map();
  validRows.forEach((row) => {
    const robotCode = String(row.robot_code);
    if (!rowsByRobot.has(robotCode)) rowsByRobot.set(robotCode, []);
    rowsByRobot.get(robotCode).push(row);
  });

  const chartList = document.createElement('div');
  chartList.className = 'wifi-point-small-multiples';

  selectedRobots.forEach((robotCode) => {
    const robotRows = (rowsByRobot.get(robotCode) || [])
      .sort((a, b) => String(a.poi_target).localeCompare(String(b.poi_target), 'en', { numeric: true }));
    if (!robotRows.length) return;

    const styleIndex = Math.max(0, availableRobots.indexOf(robotCode));
    const style = wifiPointLineStyle(styleIndex);
    const sampleCount = robotRows.reduce((total, row) => total + asNumber(row.sample_count), 0);
    const weightedRssi = sampleCount
      ? robotRows.reduce(
        (total, row) => total + Number(row.average_valid_rssi) * asNumber(row.sample_count),
        0
      ) / sampleCount
      : null;

    const card = document.createElement('article');
    card.className = 'wifi-point-robot-chart';
    card.style.setProperty('--robot-series-color', style.color);

    const header = document.createElement('header');
    header.className = 'wifi-point-robot-chart-header';
    const heading = document.createElement('div');
    heading.className = 'wifi-point-robot-chart-heading';
    const swatch = document.createElement('i');
    const headingText = document.createElement('div');
    headingText.append(
      textNode('h4', '', robotCode),
      textNode('p', '', `${formatNumber(robotRows.length)} observed target POIs · ${formatNumber(sampleCount)} strict matched samples`)
    );
    heading.append(swatch, headingText);
    const metric = document.createElement('div');
    metric.className = 'wifi-point-robot-chart-metric';
    metric.append(
      textNode('strong', '', `${formatNumber(weightedRssi, 1)} dBm`),
      textNode('span', '', 'Sample-weighted average')
    );
    header.append(heading, metric);
    card.append(header);

    const scaleMin = -90;
    const scaleMax = -30;
    const margin = { left: 62, right: 34, top: 28, bottom: 92 };
    const pointStep = 68;
    const width = Math.max(900, margin.left + margin.right + Math.max(robotRows.length - 1, 1) * pointStep);
    const height = 340;
    const plotWidth = width - margin.left - margin.right;
    const plotHeight = height - margin.top - margin.bottom;
    const x = (index) => robotRows.length === 1
      ? margin.left + plotWidth / 2
      : margin.left + (index / (robotRows.length - 1)) * plotWidth;
    const y = (value) => margin.top + (1 - (Number(value) - scaleMin) / (scaleMax - scaleMin)) * plotHeight;
    const svg = svgElement('svg', {
      viewBox: `0 0 ${width} ${height}`,
      width,
      height,
      role: 'img',
      'aria-label': `${robotCode} average WiFi RSSI line chart by observed target POI`
    });

    for (let tick = scaleMin; tick <= scaleMax; tick += 10) {
      const tickY = y(tick);
      svg.append(svgElement('line', {
        x1: margin.left,
        y1: tickY,
        x2: width - margin.right,
        y2: tickY,
        class: 'wifi-point-line-grid'
      }));
      const label = svgElement('text', {
        x: margin.left - 10,
        y: tickY + 4,
        'text-anchor': 'end',
        class: 'wifi-point-line-axis'
      });
      label.textContent = tick;
      svg.append(label);
    }

    const unit = svgElement('text', {
      x: margin.left,
      y: 16,
      class: 'wifi-point-line-unit'
    });
    unit.textContent = 'RSSI (dBm)';
    svg.append(unit);

    const points = robotRows.map((row, index) => {
      const pointName = String(row.poi_target);
      const pointX = x(index);
      const pointY = y(row.average_valid_rssi);
      const label = svgElement('text', {
        x: pointX,
        y: height - margin.bottom + 22,
        transform: `rotate(-48 ${pointX} ${height - margin.bottom + 22})`,
        'text-anchor': 'end',
        class: 'wifi-point-line-x-label'
      });
      label.textContent = pointName;
      svg.append(label);
      return { x: pointX, y: pointY, row, pointName };
    });

    if (points.length >= 2) {
      const path = points
        .map((point, index) => `${index ? 'L' : 'M'} ${point.x} ${point.y}`)
        .join(' ');
      svg.append(svgElement('path', {
        d: path,
        fill: 'none',
        stroke: style.color,
        'stroke-width': 2.5,
        class: 'wifi-point-series-line'
      }));
    }

    points.forEach((point) => {
      const marker = svgElement('circle', {
        cx: point.x,
        cy: point.y,
        r: 4,
        fill: '#fff',
        stroke: style.color,
        'stroke-width': 2.4,
        class: 'wifi-point-series-marker'
      });
      const title = svgElement('title');
      title.textContent = `${robotCode} · ${point.pointName} · Average ${formatNumber(point.row.average_valid_rssi, 1)} dBm · Minimum ${formatNumber(point.row.minimum_valid_rssi, 1)} dBm · Maximum ${formatNumber(point.row.maximum_valid_rssi, 1)} dBm · ${formatNumber(point.row.sample_count)} samples`;
      marker.append(title);
      svg.append(marker);

      if (robotRows.length <= 18) {
        const valueLabel = svgElement('text', {
          x: point.x,
          y: point.y - 9,
          'text-anchor': 'middle',
          fill: style.color,
          class: 'wifi-point-series-value'
        });
        valueLabel.textContent = formatNumber(point.row.average_valid_rssi, 0);
        svg.append(valueLabel);
      }
    });

    const chartScroll = document.createElement('div');
    chartScroll.className = 'wifi-point-line-scroll';
    chartScroll.append(svg);
    card.append(chartScroll);
    chartList.append(card);
  });

  host.append(chartList);
}

function renderWifiPointComparison(payload) {
  const availableRobots = (payload.byRobot || [])
    .map((row) => String(row.robot_code))
    .sort((a, b) => a.localeCompare(b, 'en', { numeric: true }));
  // Empty selection means all robots; otherwise honour the checkbox selection.
  const selectedRobots = state.selectedWifiRobots.length
    ? availableRobots.filter((robotCode) => state.selectedWifiRobots.includes(robotCode))
    : availableRobots;
  const selected = new Set(selectedRobots);
  const poiFilter = new Set(state.selectedWifiPois);
  const rows = (payload.byRobotTarget || []).filter((row) => (
    selected.has(String(row.robot_code))
    && (poiFilter.size === 0 || poiFilter.has(String(row.poi_target)))
  ));
  const sampleCount = rows.reduce((total, row) => total + asNumber(row.sample_count), 0);
  const scopeLabel = !state.selectedWifiRobots.length
    ? 'All eligible robots'
    : state.selectedWifiRobots.length === 1
      ? state.selectedWifiRobots[0]
      : `${state.selectedWifiRobots.length} selected robots`;
  elements.wifiPointStrengthSubtitle.textContent = `${scopeLabel} · ${formatNumber(selectedRobots.length)} robots · ${formatNumber(rows.length)} robot-target POI pairs · ${formatNumber(sampleCount)} strict matched samples · one chart per robot`;
  renderWifiPointLineChart(
    elements.wifiPointStrengthChart,
    payload.byRobotTarget || [],
    selectedRobots,
    availableRobots
  );
}

function weakSignalRowsForScope(payload, selectedRobot, selectedPoi) {
  const sourceRows = selectedPoi === 'ALL'
    ? (payload.byRobot || [])
    : (payload.byRobotTarget || []).filter((row) => String(row.poi_target) === selectedPoi);
  return sourceRows
    .filter((row) => selectedRobot === 'ALL' || String(row.robot_code) === selectedRobot)
    .filter((row) => asNumber(row.valid_signal_sample_count) > 0);
}

function aggregateWeakSignalTimeline(rows, selectedRobot, selectedPoi) {
  const buckets = new Map();
  rows
    .filter((row) => (
      (selectedRobot === 'ALL' || String(row.robot_code) === selectedRobot)
      && (selectedPoi === 'ALL' || String(row.poi_target) === selectedPoi)
    ))
    .forEach((row) => {
      const key = String(row.bucket_start || '');
      if (!key) return;
      const bucket = buckets.get(key) || {
        bucket_start: row.bucket_start,
        weak_signal_sample_count: 0,
        first_weak_time: null,
        last_weak_time: null,
        minimum_rssi: null,
        maximum_rssi: null
      };
      bucket.weak_signal_sample_count += asNumber(row.weak_signal_sample_count);
      if (!bucket.first_weak_time || new Date(row.first_weak_time) < new Date(bucket.first_weak_time)) {
        bucket.first_weak_time = row.first_weak_time;
      }
      if (!bucket.last_weak_time || new Date(row.last_weak_time) > new Date(bucket.last_weak_time)) {
        bucket.last_weak_time = row.last_weak_time;
      }
      const minimum = Number(row.minimum_rssi);
      const maximum = Number(row.maximum_rssi);
      if (Number.isFinite(minimum)) {
        bucket.minimum_rssi = bucket.minimum_rssi == null ? minimum : Math.min(bucket.minimum_rssi, minimum);
      }
      if (Number.isFinite(maximum)) {
        bucket.maximum_rssi = bucket.maximum_rssi == null ? maximum : Math.max(bucket.maximum_rssi, maximum);
      }
      buckets.set(key, bucket);
    });
  return [...buckets.values()].sort((left, right) => new Date(left.bucket_start) - new Date(right.bucket_start));
}

function weakBucketLabel(value, analysisHours) {
  if (!value) return '--';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  const options = analysisHours <= 24
    ? { hour: '2-digit', minute: '2-digit', hour12: false }
    : analysisHours <= 168
      ? { day: '2-digit', month: 'short', hour: '2-digit', hour12: false }
      : { day: '2-digit', month: 'short' };
  return new Intl.DateTimeFormat('en-GB', options).format(date);
}

function renderWeakSignalBarChart(host, rows, {
  valueKey,
  labelForRow,
  tooltipForRow,
  yAxisLabel,
  formatValue,
  emptyMessage
}) {
  host.replaceChildren();
  host.classList.remove('empty-state');
  const points = rows.filter((row) => Number.isFinite(Number(row[valueKey])));
  if (!points.length) {
    host.classList.add('empty-state');
    host.textContent = emptyMessage;
    return;
  }

  const width = Math.max(620, points.length * 96 + 100);
  const height = 292;
  const margin = { left: 58, right: 18, top: 28, bottom: 72 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  const observedMax = Math.max(...points.map((row) => Number(row[valueKey])), 0);
  const max = observedMax <= 5
    ? 5
    : Math.ceil((observedMax * 1.15) / (observedMax <= 100 ? 5 : 10)) * (observedMax <= 100 ? 5 : 10);
  const barWidth = Math.min(62, (plotWidth / points.length) * 0.62);
  const x = (index) => margin.left + ((index + 0.5) / points.length) * plotWidth;
  const y = (value) => margin.top + (1 - value / (max || 1)) * plotHeight;
  const svg = svgElement('svg', {
    viewBox: `0 0 ${width} ${height}`,
    role: 'img',
    'aria-label': yAxisLabel
  });
  const ticks = 4;
  for (let index = 0; index <= ticks; index += 1) {
    const value = (max / ticks) * index;
    const tickY = y(value);
    svg.append(svgElement('line', {
      x1: margin.left,
      y1: tickY,
      x2: width - margin.right,
      y2: tickY,
      class: 'weak-signal-grid-line'
    }));
    const label = svgElement('text', {
      x: margin.left - 8,
      y: tickY + 4,
      'text-anchor': 'end',
      class: 'weak-signal-axis-label'
    });
    label.textContent = formatValue(value);
    svg.append(label);
  }
  const yTitle = svgElement('text', {
    x: 16,
    y: margin.top + plotHeight / 2,
    transform: `rotate(-90 16 ${margin.top + plotHeight / 2})`,
    'text-anchor': 'middle',
    class: 'weak-signal-axis-title'
  });
  yTitle.textContent = yAxisLabel;
  svg.append(yTitle);

  points.forEach((row, index) => {
    const value = Math.max(0, Number(row[valueKey]));
    const barTop = y(value);
    const bar = svgElement('rect', {
      x: x(index) - barWidth / 2,
      y: barTop,
      width: barWidth,
      height: Math.max(0, margin.top + plotHeight - barTop),
      rx: 5,
      class: 'weak-signal-bar'
    });
    const title = svgElement('title');
    title.textContent = tooltipForRow(row);
    bar.append(title);
    svg.append(bar);

    const valueLabel = svgElement('text', {
      x: x(index),
      y: Math.max(margin.top + 13, barTop - 7),
      'text-anchor': 'middle',
      class: 'weak-signal-value-label'
    });
    valueLabel.textContent = formatValue(value);
    svg.append(valueLabel);

    const axisLabel = svgElement('text', {
      x: x(index),
      y: margin.top + plotHeight + 20,
      'text-anchor': 'end',
      transform: `rotate(-42 ${x(index)} ${margin.top + plotHeight + 20})`,
      class: 'weak-signal-axis-label'
    });
    axisLabel.textContent = labelForRow(row);
    svg.append(axisLabel);
  });

  const scroll = document.createElement('div');
  scroll.className = 'weak-signal-chart-scroll';
  scroll.append(svg);
  host.append(scroll);
}

function renderWeakSignalRate(payload, selectedRobot, selectedPoi) {
  const summary = payload.summary || {};
  const threshold = asNumber(summary.weak_rssi_threshold || -67);
  const rows = weakSignalRowsForScope(payload, selectedRobot, selectedPoi)
    .slice()
    .sort((left, right) => (
      asNumber(right.weak_signal_rate) - asNumber(left.weak_signal_rate)
      || asNumber(right.weak_signal_sample_count) - asNumber(left.weak_signal_sample_count)
      || String(left.robot_code).localeCompare(String(right.robot_code), 'en')
    ));
  elements.weakSignalRateSubtitle.textContent = `Weak means RSSI ≤ ${formatNumber(threshold)} dBm · valid negative RSSI samples are the denominator · zero-signal rows are excluded`;
  renderWeakSignalBarChart(elements.weakSignalRateChart, rows, {
    valueKey: 'weak_signal_rate',
    labelForRow: (row) => String(row.robot_code),
    tooltipForRow: (row) => `${row.robot_code} · ${formatPercent(row.weak_signal_rate, 1)} weak · ${formatNumber(row.weak_signal_sample_count)} weak / ${formatNumber(row.valid_signal_sample_count)} valid samples`,
    yAxisLabel: 'Weak-signal rate (%)',
    formatValue: (value) => formatPercent(value, 1),
    emptyMessage: 'No valid strict Running-task WiFi samples are available for the selected filters.'
  });
}

function renderWeakSignalTimeline(payload, selectedRobot, selectedPoi) {
  const summary = payload.summary || {};
  const rows = aggregateWeakSignalTimeline(payload.weakTimeline || [], selectedRobot, selectedPoi);
  const scopeLabel = [
    selectedRobot === 'ALL' ? 'All robots' : selectedRobot,
    selectedPoi === 'ALL' ? 'All targets' : selectedPoi
  ].join(' · ');
  const busiest = rows.reduce((highest, row) => (
    !highest || asNumber(row.weak_signal_sample_count) > asNumber(highest.weak_signal_sample_count)
      ? row
      : highest
  ), null);
  const totalWeak = rows.reduce((total, row) => total + asNumber(row.weak_signal_sample_count), 0);
  const peakShare = busiest && totalWeak > 0
    ? (100 * asNumber(busiest.weak_signal_sample_count)) / totalWeak
    : null;
  elements.weakSignalTimelineSubtitle.textContent = busiest
    ? `X = time; Y = weak-signal sample count. Peak: ${weakBucketLabel(busiest.bucket_start, asNumber(summary.analysis_window_hours))} · ${formatNumber(busiest.weak_signal_sample_count)} rows${peakShare == null ? '' : ` (${formatPercent(peakShare, 1)} of weak rows)`}.`
    : `No strict sample with RSSI <= ${formatNumber(summary.weak_rssi_threshold || -67)} dBm in the selected filters.`;
  renderWeakSignalBarChart(elements.weakSignalTimelineChart, rows, {
    valueKey: 'weak_signal_sample_count',
    labelForRow: (row) => weakBucketLabel(row.bucket_start, asNumber(summary.analysis_window_hours)),
    tooltipForRow: (row) => `Time: ${formatDateTime(row.first_weak_time)} to ${formatDateTime(row.last_weak_time)} · Weak rows: ${formatNumber(row.weak_signal_sample_count)} · RSSI: ${formatNumber(row.minimum_rssi)} to ${formatNumber(row.maximum_rssi)} dBm`,
    yAxisLabel: 'Weak-signal sample count',
    formatValue: (value) => formatNumber(value),
    emptyMessage: 'No weak-signal observation meets the RSSI ≤ -67 dBm threshold for the selected filters.'
  });
}

function findWeakSignalDiagnostic(payload, selectedRobot, selectedPoi) {
  const diagnostics = payload.weakSignalDiagnostics || [];
  if (selectedRobot !== 'ALL') {
    return diagnostics.find((item) => (
      item.scope_type === 'ROBOT'
      && String(item.scope_robot_code) === selectedRobot
    )) || null;
  }
  if (selectedPoi !== 'ALL') {
    return diagnostics.find((item) => (
      item.scope_type === 'TARGET'
      && String(item.scope_poi_target) === selectedPoi
    )) || null;
  }
  return diagnostics[0] || null;
}

function renderWeakSignalDiagnosis(payload, selectedRobot, selectedPoi) {
  const host = elements.weakSignalDiagnosis;
  const summary = payload.summary || {};
  const diagnostic = findWeakSignalDiagnostic(payload, selectedRobot, selectedPoi);
  host.replaceChildren();
  host.classList.remove('empty-state');
  if (!asNumber(summary.running_matched_sample_count)) {
    host.classList.add('empty-state');
    host.textContent = 'No strict Running-task WiFi sample is available, so a weak-signal cause cannot be assessed.';
    return;
  }
  if (!diagnostic) {
    host.classList.add('empty-state');
    host.textContent = `No weak-signal sample (RSSI ≤ ${formatNumber(summary.weak_rssi_threshold || -67)} dBm) exists in the selected filters; no cause rule was triggered.`;
    return;
  }

  host.dataset.confidence = String(diagnostic.confidence || 'LOW').toLowerCase();
  const header = document.createElement('header');
  header.append(
    textNode('span', 'weak-signal-diagnosis-kicker', diagnostic.cause_status.replaceAll('_', ' ')),
    textNode('strong', '', diagnostic.scope_type === 'ROBOT'
      ? `${diagnostic.scope_robot_code} weak-signal assessment`
      : `${diagnostic.scope_poi_target} route/area assessment`),
    textNode('span', 'wifi-minimum-confidence', `${diagnostic.confidence} confidence`)
  );
  const facts = document.createElement('div');
  facts.className = 'weak-signal-facts';
  [
    ['Weak rate', diagnostic.weak_signal_rate == null ? '--' : formatPercent(diagnostic.weak_signal_rate, 1)],
    ['Weak samples', formatNumber(diagnostic.weak_signal_sample_count)],
    ['Threshold', `≤ ${formatNumber(summary.weak_rssi_threshold || -67)} dBm`]
  ].forEach(([label, value]) => {
    const fact = document.createElement('div');
    fact.append(textNode('span', '', label), textNode('strong', '', value));
    facts.append(fact);
  });
  const cause = document.createElement('div');
  cause.className = 'weak-signal-cause';
  cause.append(textNode('h5', '', 'What the evidence supports'), textNode('p', '', diagnostic.cause));
  const evidence = document.createElement('div');
  evidence.className = 'weak-signal-evidence';
  evidence.append(textNode('h5', '', 'Evidence'));
  const evidenceList = document.createElement('ul');
  (diagnostic.evidence || []).forEach((item) => evidenceList.append(textNode('li', '', item)));
  evidence.append(evidenceList);
  const actions = document.createElement('div');
  actions.className = 'weak-signal-actions';
  actions.append(textNode('h5', '', 'Recommended checks'));
  const actionList = document.createElement('ol');
  (diagnostic.actions || []).forEach((item) => actionList.append(textNode('li', '', item)));
  actions.append(actionList);
  const rule = textNode('p', 'weak-signal-rule', `Transparent rule: ${diagnostic.rule_id} · Version ${diagnostic.rule_version}`);
  host.append(header, facts, cause, evidence, actions, rule);
}

function findWifiMinimumDiagnostic(payload, selectedRobot, selectedPoi) {
  const scopeType = selectedRobot === 'ALL'
    ? (selectedPoi === 'ALL' ? 'ALL' : 'TARGET')
    : (selectedPoi === 'ALL' ? 'ROBOT' : 'ROBOT_TARGET');
  return (payload.minimumDiagnostics || []).find((item) => (
    String(item.scope_type) === scopeType
    && (scopeType === 'ALL' || scopeType === 'TARGET' || String(item.scope_robot_code) === selectedRobot)
    && (scopeType === 'ALL' || scopeType === 'ROBOT' || String(item.scope_poi_target) === selectedPoi)
  )) || null;
}

function renderWifiMinimumDiagnostic(diagnostic) {
  const panel = document.createElement('section');
  panel.className = 'wifi-minimum-diagnostic';
  if (!diagnostic) {
    panel.classList.add('empty-inline');
    panel.textContent = 'No traceable negative-RSSI minimum record exists for the current filters.';
    return panel;
  }

  panel.dataset.confidence = String(diagnostic.confidence || 'LOW').toLowerCase();
  const header = document.createElement('header');
  header.append(
    textNode('h5', '', 'Minimum Location and Cause Assessment'),
    textNode('span', 'wifi-minimum-confidence', `${diagnostic.confidence || 'LOW'} confidence`)
  );

  const facts = document.createElement('div');
  facts.className = 'wifi-minimum-facts';
  [
    ['Minimum', `${formatNumber(diagnostic.minimum_rssi, 1)} dBm`],
    ['Robot', diagnostic.robot_code || '--'],
    ['Event time', formatExactDateTime(diagnostic.event_time)],
    ['Related target POI', diagnostic.poi_target || '--']
  ].forEach(([label, value]) => {
    const fact = document.createElement('div');
    fact.append(textNode('span', '', label), textNode('strong', '', value));
    facts.append(fact);
  });

  const cause = document.createElement('div');
  cause.className = 'wifi-minimum-cause';
  cause.append(
    textNode('h6', '', 'Cause assessment'),
    textNode('p', '', diagnostic.cause || 'Cause not confirmed.')
  );

  const evidence = document.createElement('div');
  evidence.className = 'wifi-minimum-evidence';
  evidence.append(textNode('h6', '', 'Evidence'));
  const evidenceList = document.createElement('ul');
  (diagnostic.evidence || []).forEach((item) => evidenceList.append(textNode('li', '', item)));
  evidence.append(evidenceList);

  const resolution = document.createElement('div');
  resolution.className = 'wifi-minimum-resolution';
  resolution.append(textNode('h6', '', 'Recommended actions'));
  const resolutionList = document.createElement('ol');
  (diagnostic.actions || []).forEach((item) => resolutionList.append(textNode('li', '', item)));
  resolution.append(resolutionList);

  const footer = textNode(
    'p',
    'wifi-minimum-rule',
    `Transparent rule: ${diagnostic.rule_id || '--'} · Version ${diagnostic.rule_version || '--'}`
  );
  const rationale = document.createElement('div');
  rationale.className = 'wifi-minimum-rationale';
  rationale.append(cause, evidence);

  const body = document.createElement('div');
  body.className = 'wifi-minimum-body';
  body.append(rationale, resolution);

  panel.append(header, facts, body, footer);
  return panel;
}

function renderWifiCombinedDiagnostic(minimumDiagnostic, weakSignalDiagnostic, summary = {}) {
  const panel = document.createElement('section');
  panel.className = 'wifi-minimum-diagnostic';
  if (!minimumDiagnostic && !weakSignalDiagnostic) {
    panel.classList.add('empty-inline');
    panel.textContent = 'No traceable negative-RSSI minimum or weak-signal pattern exists for the current filters.';
    return panel;
  }

  const minimumConfidence = String(minimumDiagnostic?.confidence || 'LOW').toUpperCase();
  const patternConfidence = weakSignalDiagnostic
    ? String(weakSignalDiagnostic.confidence || 'LOW').toUpperCase()
    : null;
  panel.dataset.confidence = (patternConfidence || minimumConfidence).toLowerCase();

  const header = document.createElement('header');
  const confidenceLabel = minimumDiagnostic && weakSignalDiagnostic
    ? `Pattern: ${patternConfidence} | Minimum event: ${minimumConfidence}`
    : weakSignalDiagnostic
      ? `Pattern: ${patternConfidence}`
      : `Minimum event: ${minimumConfidence}`;
  header.append(
    textNode('h5', '', 'Lowest Signal: Evidence and Next Step'),
    textNode('span', 'wifi-minimum-confidence', confidenceLabel)
  );

  const facts = document.createElement('div');
  facts.className = 'wifi-minimum-facts';
  const factRows = [];
  if (minimumDiagnostic) {
    factRows.push(
      ['Minimum event', `${formatNumber(minimumDiagnostic.minimum_rssi, 1)} dBm`],
      ['Robot', minimumDiagnostic.robot_code || '--'],
      ['Event time', formatExactDateTime(minimumDiagnostic.event_time)],
      ['Related target POI', minimumDiagnostic.poi_target || '--']
    );
  }
  if (weakSignalDiagnostic) {
    factRows.push(
      ['Weak rate', weakSignalDiagnostic.weak_signal_rate == null ? '--' : formatPercent(weakSignalDiagnostic.weak_signal_rate, 1)],
      ['Weak samples', formatNumber(weakSignalDiagnostic.weak_signal_sample_count)],
      ['Weak threshold', `<= ${formatNumber(summary.weak_rssi_threshold || -67)} dBm`]
    );
  }
  factRows.forEach(([label, value]) => {
    const fact = document.createElement('div');
    fact.append(textNode('span', '', label), textNode('strong', '', value));
    facts.append(fact);
  });

  const cause = document.createElement('div');
  cause.className = 'wifi-minimum-cause';
  cause.append(textNode('h6', '', 'What this means'));
  if (weakSignalDiagnostic) {
    cause.append(
      textNode('strong', 'wifi-diagnostic-label', `Repeated pattern (${patternConfidence})`),
      textNode('p', '', compactDiagnosticCause(weakSignalDiagnostic))
    );
  }
  if (minimumDiagnostic) {
    cause.append(
      textNode('strong', 'wifi-diagnostic-label', `Lowest single event (${minimumConfidence})`),
      textNode('p', '', 'This identifies the record to retest. One lowest value alone cannot prove a point, AP, or robot fault.')
    );
  }

  const actions = document.createElement('div');
  actions.className = 'wifi-minimum-resolution';
  actions.append(textNode('h6', '', 'Do this next'));
  const actionList = document.createElement('ol');
  conciseWifiActions(weakSignalDiagnostic || minimumDiagnostic).slice(0, 3).forEach((item) => (
    actionList.append(textNode('li', '', item))
  ));
  actions.append(actionList);

  const evidence = document.createElement('details');
  evidence.className = 'wifi-evidence-details';
  evidence.append(textNode('summary', '', 'View evidence and rules'));
  const evidenceList = document.createElement('ul');
  if (weakSignalDiagnostic) {
    (weakSignalDiagnostic.evidence || []).forEach((item) => (
      evidenceList.append(textNode('li', '', `Repeated pattern: ${item}`))
    ));
  }
  if (minimumDiagnostic) {
    (minimumDiagnostic.evidence || []).forEach((item) => (
      evidenceList.append(textNode('li', '', `Minimum event: ${item}`))
    ));
  }
  evidence.append(evidenceList);

  const rules = [
    minimumDiagnostic && `Minimum event: ${minimumDiagnostic.rule_id || '--'} (v${minimumDiagnostic.rule_version || '--'})`,
    weakSignalDiagnostic && `Repeated pattern: ${weakSignalDiagnostic.rule_id || '--'} (v${weakSignalDiagnostic.rule_version || '--'})`
  ].filter(Boolean);
  const footer = textNode('p', 'wifi-minimum-rule', `Transparent rules: ${rules.join(' | ')}`);

  const rationale = document.createElement('div');
  rationale.className = 'wifi-minimum-rationale';
  rationale.append(cause, evidence);
  const body = document.createElement('div');
  body.className = 'wifi-minimum-body';
  body.append(rationale, actions);
  panel.append(header, facts, body, footer);
  return panel;
}

function renderRunningWifiNarrative(payload, selectedPoi, selectedRobot, targetRows) {
  const host = elements.runningWifiNarrative;
  const minimumHost = elements.runningWifiMinimumDiagnostic;
  const summary = payload.summary || {};
  const robotRows = selectedPoi === 'ALL'
    ? (payload.byRobot || [])
    : (payload.byRobotTarget || []).filter((row) => String(row.poi_target) === selectedPoi);
  host.replaceChildren();
  host.classList.remove('empty-state');

  if (!asNumber(summary.running_matched_sample_count)) {
    minimumHost.replaceChildren();
    minimumHost.classList.add('empty-state');
    minimumHost.textContent = 'No locatable minimum RSSI record exists in the current analysis window.';
    host.classList.add('empty-state');
    host.textContent = 'No job and WiFi records share the same robot, timestamp, and Running status in the current analysis window.';
    return;
  }

  const selectedRow = selectedPoi === 'ALL'
    ? null
    : targetRows.find((row) => String(row.poi_target) === selectedPoi);
  const selectedRobotRow = selectedRobot === 'ALL'
    ? null
    : (payload.byRobot || []).find((row) => String(row.robot_code) === selectedRobot);
  const scope = selectedRow || selectedRobotRow || summary;
  const sampleCount = asNumber(scope.sample_count ?? summary.running_matched_sample_count);
  const validCount = asNumber(scope.valid_signal_sample_count);
  const zeroCount = asNumber(scope.zero_signal_sample_count);
  const zeroRate = sampleCount > 0 ? (zeroCount / sampleCount) * 100 : 0;
  const minimumDiagnostic = findWifiMinimumDiagnostic(payload, selectedRobot, selectedPoi);
  const weakSignalDiagnostic = findWeakSignalDiagnostic(payload, selectedRobot, selectedPoi);
  const title = textNode('h4', '', 'Data Scope');
  const lead = textNode(
    'p',
    'wifi-analysis-lead',
    summary.is_current
      ? `${formatNumber(sampleCount)} Running-task WiFi samples match the current filters.`
      : summary.source_is_current
        ? `ODS source data is current, but the latest matched Running sample is ${formatNumber(summary.running_sample_age_minutes)} minutes old.`
        : `This view shows historical data: the latest ODS record is ${formatNumber(summary.source_age_minutes)} minutes old.`
  );

  const sourceRobots = robotRows
    .filter((row) => selectedRobot === 'ALL' || String(row.robot_code) === selectedRobot)
    .sort((a, b) => asNumber(b.sample_count) - asNumber(a.sample_count));
  const robotSource = document.createElement('div');
  robotSource.className = 'wifi-source-robots';
  robotSource.append(textNode('span', '', 'Robots contributing signal data'));
  const robotChips = document.createElement('div');
  robotChips.className = 'wifi-source-robot-chips';
  sourceRobots.forEach((row) => {
    const chip = textNode(
      'button',
      '',
      `${row.robot_code} · ${formatNumber(row.sample_count)} samples · ${formatNumber(row.average_valid_rssi, 1)} dBm`
    );
    chip.type = 'button';
    chip.addEventListener('click', () => {
      // Drill-down chip: narrow to this one robot and reset the target scope.
      state.selectedWifiRobots = [String(row.robot_code)];
      state.selectedWifiPois = [];
      renderRunningWifiAnalysis(state.dashboard?.wifiRunningAnalysis || {});
    });
    robotChips.append(chip);
  });
  if (!sourceRobots.length) robotChips.append(textNode('span', 'empty-inline', 'No matched robots'));
  robotSource.append(robotChips);

  const metrics = document.createElement('div');
  metrics.className = 'wifi-analysis-metrics';
  [
    ['Matched samples', formatNumber(sampleCount), 'Running + exact timestamp match'],
    ['Average RSSI', `${formatNumber(scope.average_valid_rssi, 1)} dBm`, `${formatNumber(validCount)} valid negative-RSSI samples`],
    [
      'Minimum RSSI',
      `${formatNumber(scope.minimum_valid_rssi, 1)} dBm`,
      minimumDiagnostic
        ? `${minimumDiagnostic.robot_code} · ${minimumDiagnostic.poi_target} · ${formatDateTime(minimumDiagnostic.event_time)}`
        : 'Observed minimum in the window'
    ],
    ['Confirmed zero signal', `${formatNumber(zeroCount)} · ${formatPercent(zeroRate, 1)}`, 'wifi_signal_level = 0']
  ].forEach(([label, value, detail]) => {
    const item = document.createElement('div');
    item.append(textNode('span', '', label), textNode('strong', '', value), textNode('small', '', detail));
    metrics.append(item);
  });
  minimumHost.replaceChildren(renderWifiCombinedDiagnostic(minimumDiagnostic, weakSignalDiagnostic, summary));
  minimumHost.classList.remove('empty-state');

  const boundary = textNode(
    'p',
    'wifi-scope-note',
    `Scope: ${formatNumber(sourceRobots.length)} robots, ${formatNumber(targetRows.length)} target POIs, ${formatNumber(validCount)} valid RSSI rows. Target POI is a task destination, not a measured physical RF position. Use the conclusion above for the rule and next step.`
  );

  host.append(title, lead, robotSource, metrics, boundary);
}

function primaryWifiDiagnostic(payload, selectedRobot, selectedPoi) {
  if (selectedRobot !== 'ALL' || selectedPoi !== 'ALL') {
    return findWeakSignalDiagnostic(payload, selectedRobot, selectedPoi);
  }
  const confidenceRank = { HIGH: 3, MEDIUM: 2, LOW: 1 };
  const robotRows = new Map((payload.byRobot || []).map((row) => [String(row.robot_code), row]));
  return (payload.weakSignalDiagnostics || [])
    .filter((item) => item.scope_type === 'ROBOT')
    .slice()
    .sort((left, right) => {
      const confidenceGap = asNumber(confidenceRank[String(right.confidence || 'LOW').toUpperCase()])
        - asNumber(confidenceRank[String(left.confidence || 'LOW').toUpperCase()]);
      if (confidenceGap) return confidenceGap;
      const leftRow = robotRows.get(String(left.scope_robot_code)) || {};
      const rightRow = robotRows.get(String(right.scope_robot_code)) || {};
      return asNumber(rightRow.weak_signal_rate) - asNumber(leftRow.weak_signal_rate)
        || asNumber(rightRow.weak_signal_sample_count) - asNumber(leftRow.weak_signal_sample_count);
    })[0] || null;
}

function conciseWifiCause(diagnostic, payload) {
  if (!diagnostic) return 'No weak-signal rule was triggered in the selected strict samples.';
  if (diagnostic.cause_status === 'DATA_QUALITY_RISK') {
    return 'The RSSI value remains fixed across many samples. Validate the telemetry stream before changing wireless hardware.';
  }
  if (diagnostic.scope_type === 'ROBOT') {
    const robotRow = (payload.byRobot || []).find((row) => String(row.robot_code) === String(diagnostic.scope_robot_code)) || {};
    return `${diagnostic.scope_robot_code} has weak samples across ${formatNumber(robotRow.weak_target_count)} task destinations. This is a robot-side candidate, not a confirmed hardware fault.`;
  }
  const targetRow = (payload.byTarget || []).find((row) => String(row.poi_target) === String(diagnostic.scope_poi_target)) || {};
  return `${diagnostic.scope_poi_target} is associated with weak samples from ${formatNumber(targetRow.weak_robot_count)} robots. This is a route/area candidate, not proof of the exact physical point.`;
}

function conciseWifiActions(diagnostic) {
  if (!diagnostic) return ['Collect more strict Running-task WiFi samples before scheduling maintenance.'];
  if (diagnostic.cause_status === 'DATA_QUALITY_RISK') {
    return [
      'Verify that raw RSSI changes on the robot and in ODS.',
      'Repair collection or publishing if only the ODS value is fixed.',
      'Retest the route after telemetry is validated.'
    ];
  }
  if (diagnostic.scope_type === 'ROBOT') {
    return [
      `Run ${diagnostic.scope_robot_code} and one comparison robot on the same route.`,
      `Inspect ${diagnostic.scope_robot_code}'s antenna, cable, WiFi adapter, and roaming configuration.`,
      'Check controller association, retry, and roaming logs during the peak window.'
    ];
  }
  return [
    `Run at least two robots on the route associated with ${diagnostic.scope_poi_target}.`,
    'Check AP coverage, channel plan, interference, and roaming during the peak window.',
    'Make physical changes only after the pattern repeats across robots.'
  ];
}

function compactDiagnosticCause(diagnostic) {
  if (!diagnostic) return 'No repeatable weak-signal pattern is available in this filter.';
  if (diagnostic.cause_status === 'DATA_QUALITY_RISK') {
    return 'RSSI is fixed across many samples. Check telemetry before changing WiFi hardware.';
  }
  if (diagnostic.scope_type === 'ROBOT') {
    return 'Weak readings repeat across several task destinations. Check this robot first, then compare it on the same route with another robot.';
  }
  return 'Weak readings repeat across several robots. Check the route area and AP behavior; target POI is not an exact RF position.';
}

function renderWifiConclusion(payload, selectedRobot, selectedPoi) {
  const host = elements.wifiConclusion;
  const summary = payload.summary || {};
  const threshold = asNumber(summary.weak_rssi_threshold || -67);
  host.replaceChildren();
  host.classList.remove('empty-state');

  if (!asNumber(summary.running_matched_sample_count)) {
    host.classList.add('empty-state');
    host.textContent = 'No conclusion: this time period has no strict match of Running task, robot ID, timestamp, and target POI.';
    return;
  }

  const diagnostic = primaryWifiDiagnostic(payload, selectedRobot, selectedPoi);
  const timeline = aggregateWeakSignalTimeline(payload.weakTimeline || [], selectedRobot, selectedPoi);
  const peak = timeline.reduce((current, row) => (
    !current || asNumber(row.weak_signal_sample_count) > asNumber(current.weak_signal_sample_count) ? row : current
  ), null);
  const totalWeak = timeline.reduce((total, row) => total + asNumber(row.weak_signal_sample_count), 0);
  const peakShare = peak && totalWeak > 0
    ? (100 * asNumber(peak.weak_signal_sample_count)) / totalWeak
    : null;
  const scope = selectedRobot !== 'ALL' ? selectedRobot : selectedPoi !== 'ALL' ? selectedPoi : 'Fleet';
  const hasWeakSignal = asNumber(summary.weak_signal_sample_count) > 0;

  const heading = textNode(
    'h3',
    '',
    hasWeakSignal
      ? `${scope}: WiFi follow-up is needed`
      : `${scope}: no weak-signal threshold was reached`
  );
  const summaryText = textNode(
    'p',
    'wifi-conclusion-summary',
    hasWeakSignal
      ? conciseWifiCause(diagnostic, payload)
      : `No strict Running-task sample is at or below ${formatNumber(threshold)} dBm. This does not assess periods without matched task and WiFi records.`
  );
  const header = document.createElement('header');
  header.append(textNode('span', 'section-kicker', 'WIFI CONCLUSION'), heading, summaryText);

  const metrics = document.createElement('div');
  metrics.className = 'wifi-conclusion-metrics';
  [
    ['Weak rate', hasWeakSignal ? formatPercent(summary.weak_signal_rate, 1) : '0%', `RSSI <= ${formatNumber(threshold)} dBm`],
    ['Priority scope', diagnostic ? (diagnostic.scope_robot_code || diagnostic.scope_poi_target || scope) : scope, diagnostic?.cause_status?.replaceAll('_', ' ') || 'No weak pattern'],
    ['Peak time', peak ? weakBucketLabel(peak.bucket_start, asNumber(summary.analysis_window_hours)) : '--', peak ? `${formatNumber(peak.weak_signal_sample_count)} weak rows${peakShare == null ? '' : ` (${formatPercent(peakShare, 1)})`}` : 'No weak rows'],
    ['Next action', conciseWifiActions(diagnostic)[0], 'Complete this before hardware replacement']
  ].forEach(([label, value, detail]) => {
    const metric = document.createElement('div');
    metric.append(textNode('span', '', label), textNode('strong', '', value), textNode('small', '', detail));
    metrics.append(metric);
  });

  const details = document.createElement('details');
  details.className = 'wifi-method-details';
  details.append(textNode('summary', '', 'How this conclusion is determined'));
  const methodList = document.createElement('ul');
  [
    'Data scope: ODS job and WiFi rows must have the same robot ID and exact timestamp; job_status must be Running and target POI must exist.',
    `Weak signal: negative RSSI <= ${formatNumber(threshold)} dBm. The rate is weak rows divided by valid negative-RSSI rows; zero-signal rows are excluded.`,
    'Confidence: a single minimum is LOW; repeated weak samples across multiple task destinations or across robots can be MEDIUM; fixed RSSI values are a HIGH data-quality risk.',
    diagnostic ? `Triggered rule: ${diagnostic.rule_id} (version ${diagnostic.rule_version}).` : 'No weak-signal rule was triggered.'
  ].forEach((item) => methodList.append(textNode('li', '', item)));
  details.append(methodList);

  host.append(header, metrics, details);
}

/*
  Checkbox dropdown for the Running-task WiFi filters.

  No checkbox ticked means "all", which matches the previous 'ALL' option
  without needing a sentinel entry in the list.
*/
function renderMultiSelect(menuHost, toggle, toggleText, values, selected, allLabel, onChange) {
  if (!menuHost || !toggle || !toggleText) return;
  menuHost.replaceChildren();

  if (!values.length) {
    toggle.disabled = true;
    toggleText.textContent = allLabel;
    menuHost.append(textNode('div', 'multi-select-empty', 'No options are available for the current range.'));
    return;
  }
  toggle.disabled = false;

  const actions = document.createElement('div');
  actions.className = 'multi-select-actions';
  const selectAll = document.createElement('button');
  selectAll.type = 'button';
  selectAll.textContent = 'Select all';
  selectAll.addEventListener('click', () => onChange([...values]));
  const clear = document.createElement('button');
  clear.type = 'button';
  clear.textContent = 'Clear';
  clear.addEventListener('click', () => onChange([]));
  actions.append(selectAll, clear);
  menuHost.append(actions);

  const selectedSet = new Set(selected);
  values.forEach((value) => {
    const option = document.createElement('label');
    option.className = 'multi-select-option';
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.value = value;
    box.checked = selectedSet.has(value);
    box.addEventListener('change', () => {
      const next = new Set(selectedSet);
      if (box.checked) next.add(value);
      else next.delete(value);
      onChange(values.filter((item) => next.has(item)));
    });
    const caption = document.createElement('span');
    caption.textContent = value;
    caption.title = value;
    option.append(box, caption);
    menuHost.append(option);
  });

  // No selection and every option selected both mean "no filter".
  if (!selected.length || selected.length === values.length) {
    toggleText.textContent = allLabel;
  } else if (selected.length === 1) {
    toggleText.textContent = selected[0];
  } else {
    toggleText.textContent = `${selected.length} selected`;
  }
  toggleText.parentElement.title = selected.length ? selected.join(', ') : allLabel;
}

function closeMultiSelectMenus(except) {
  [
    [elements.wifiRobotToggle, elements.wifiRobotMenu],
    [elements.wifiPoiToggle, elements.wifiPoiMenu],
    [elements.projectToggle, elements.projectMenu],
    [elements.taskToggle, elements.taskMenu],
    [elements.robotToggle, elements.robotMenu],
    [elements.analysisProjectToggle, elements.analysisProjectMenu],
    [elements.analysisTaskToggle, elements.analysisTaskMenu],
    [elements.analysisRobotToggle, elements.analysisRobotMenu]
  ]
    .forEach(([toggle, menu]) => {
      if (!toggle || !menu || menu === except) return;
      menu.hidden = true;
      toggle.setAttribute('aria-expanded', 'false');
    });
}

function bindMultiSelectToggle(toggle, menu) {
  if (!toggle || !menu) return;
  toggle.addEventListener('click', (event) => {
    event.stopPropagation();
    const open = menu.hidden;
    closeMultiSelectMenus(open ? menu : null);
    menu.hidden = !open;
    toggle.setAttribute('aria-expanded', String(open));
  });
  menu.addEventListener('click', (event) => event.stopPropagation());
}

/*
  Keep the legacy single-value state in sync so the existing renderers keep
  working: one selection behaves exactly as before, zero or several fall back
  to 'ALL' and the array is applied by the callers that support it.
*/
function syncWifiLegacySelection(values, availableCount) {
  if (values.length === 1) return values[0];
  if (values.length && values.length < availableCount) return 'ALL';
  return 'ALL';
}

function renderRunningWifiAnalysis(payload) {
  if (!elements.runningWifiTrendChart || !elements.wifiPoiToggle || !elements.wifiRobotToggle) return;
  const summary = payload.summary || {};
  const byRobot = payload.byRobot || [];
  const robotTargets = payload.byRobotTarget || [];
  const actualAnalysisHours = asNumber(summary.analysis_window_hours);
  const requestedAnalysisHours = asNumber(payload.window?.hours, state.window.hours);
  const rangeIsLimited = actualAnalysisHours > 0 && actualAnalysisHours < requestedAnalysisHours;

  const sourceAge = asNumber(summary.source_age_minutes);
  const sourceIsCurrent = summary.source_is_current === true || asNumber(summary.source_is_current) === 1;
  elements.runningWifiFreshness.dataset.tone = sourceIsCurrent ? 'current' : 'stale';
  elements.runningWifiFreshness.textContent = sourceIsCurrent
    ? `Analysis data: Current · ${formatNumber(sourceAge)} min`
    : `Analysis data: Stale · ${formatNumber(sourceAge)} min`;
  elements.runningWifiFreshness.title = 'Freshness of the records used by this Running-task WiFi analysis.';
  renderWifiConclusion(payload, state.selectedWifiRobot, state.selectedWifiPoi);

  if (rangeIsLimited) {
    state.selectedWifiRobot = 'ALL';
    state.selectedWifiPoi = 'ALL';
    state.selectedWifiRobots = [];
    state.selectedWifiPois = [];
    elements.wifiRobotMenu.replaceChildren();
    elements.wifiPoiMenu.replaceChildren();
    elements.wifiRobotMenu.append(textNode('div', 'multi-select-empty', 'Long-range data not loaded'));
    elements.wifiPoiMenu.append(textNode('div', 'multi-select-empty', 'Long-range data not loaded'));
    elements.wifiRobotToggleText.textContent = 'Long-range data not loaded';
    elements.wifiPoiToggleText.textContent = 'Long-range data not loaded';
    elements.wifiRobotToggle.disabled = true;
    elements.wifiPoiToggle.disabled = true;
    closeMultiSelectMenus(null);
    elements.runningWifiFreshness.dataset.tone = 'stale';
    elements.runningWifiFreshness.textContent = 'Long-range query is not enabled';
    elements.runningWifiChartSubtitle.textContent = `${state.window.label} is synchronized; the current safe ODS query limit is ${formatNumber(actualAnalysisHours)} hours.`;
    elements.wifiPointStrengthSubtitle.textContent = 'No 24-hour data is used as a substitute for the selected long-range result.';
    [
      [elements.runningWifiTrendChart, 'WiFi trend data for the current time range is not loaded.'],
      [elements.runningWifiMinimumDiagnostic, 'Minimum-value diagnostics for the current time range are not loaded.'],
      [elements.runningWifiNarrative, 'An ODS long-range query index is required before findings can be generated for this time range.'],
      [elements.weakSignalRateChart, 'Weak-signal rates for the current time range are not loaded.'],
      [elements.weakSignalTimelineChart, 'Weak-signal timing for the current time range is not loaded.'],
      [elements.wifiPointStrengthChart, 'Target-POI signal data for the current time range is not loaded.']
    ].forEach(([host, message]) => {
      host.replaceChildren();
      host.classList.add('empty-state');
      host.textContent = message;
    });
    return;
  }

  elements.wifiRobotToggle.disabled = false;
  elements.wifiPoiToggle.disabled = false;

  const robotValues = byRobot
    .map((row) => String(row.robot_code))
    .sort((a, b) => a.localeCompare(b, 'en'));
  const availableRobots = new Set(robotValues);
  // Drop selections that the current time range no longer offers.
  state.selectedWifiRobots = state.selectedWifiRobots.filter((code) => availableRobots.has(code));
  state.selectedWifiRobot = syncWifiLegacySelection(state.selectedWifiRobots, robotValues.length);

  // A single robot selection keeps the per-robot target rows; otherwise use the
  // fleet-wide target rows and narrow them by the selected robots.
  const robotFilterActive = state.selectedWifiRobots.length > 0
    && state.selectedWifiRobots.length < robotValues.length;
  const selectedRobotSet = new Set(state.selectedWifiRobots);
  const targetRows = !robotFilterActive
    ? (payload.byTarget || [])
    : state.selectedWifiRobots.length === 1
      ? robotTargets
        .filter((row) => selectedRobotSet.has(String(row.robot_code)))
        .map((row) => ({ ...row, robot_count: 1 }))
      : aggregateTargetRowsForRobots(robotTargets, selectedRobotSet);

  const targetValues = targetRows
    .map((row) => String(row.poi_target))
    .sort((a, b) => a.localeCompare(b, 'en'));
  const availableTargets = new Set(targetValues);
  state.selectedWifiPois = state.selectedWifiPois.filter((poi) => availableTargets.has(poi));
  state.selectedWifiPoi = syncWifiLegacySelection(state.selectedWifiPois, targetValues.length);

  const activeRobotCount = asNumber(state.dashboard?.summary?.active_robot_count);
  const allRobotsLabel = activeRobotCount > 0
    ? `All eligible (${formatNumber(byRobot.length)} / ${formatNumber(activeRobotCount)})`
    : `All eligible (${formatNumber(byRobot.length)})`;

  renderMultiSelect(
    elements.wifiRobotMenu,
    elements.wifiRobotToggle,
    elements.wifiRobotToggleText,
    robotValues,
    state.selectedWifiRobots,
    allRobotsLabel,
    (next) => {
      state.selectedWifiRobots = next;
      // Robot scope changed, so target options are recomputed on the next pass.
      state.selectedWifiPois = [];
      renderRunningWifiAnalysis(state.dashboard?.wifiRunningAnalysis || {});
    }
  );

  renderMultiSelect(
    elements.wifiPoiMenu,
    elements.wifiPoiToggle,
    elements.wifiPoiToggleText,
    targetValues,
    state.selectedWifiPois,
    `All targets (${formatNumber(targetValues.length)})`,
    (next) => {
      state.selectedWifiPois = next;
      renderRunningWifiAnalysis(state.dashboard?.wifiRunningAnalysis || {});
    }
  );

  const robotScopeLabel = !robotFilterActive
    ? 'All robots'
    : state.selectedWifiRobots.length === 1
      ? state.selectedWifiRobots[0]
      : `${state.selectedWifiRobots.length} robots`;
  const poiFilterActive = state.selectedWifiPois.length > 0
    && state.selectedWifiPois.length < targetValues.length;
  const poiScopeLabel = !poiFilterActive
    ? 'All targets'
    : state.selectedWifiPois.length === 1
      ? state.selectedWifiPois[0]
      : `${state.selectedWifiPois.length} targets`;
  const scopeLabel = [robotScopeLabel, poiScopeLabel].join(' · ');
  elements.runningWifiChartSubtitle.textContent = `${scopeLabel} · ${formatNumber(summary.analysis_window_hours)} hours · ${formatNumber(summary.bucket_minutes)}-minute buckets · averages exclude zero-signal samples`;

  const trend = aggregateRunningWifiTrendMulti(
    payload.trend || [],
    state.selectedWifiPois,
    state.selectedWifiRobots
  );
  renderRunningWifiTrend(elements.runningWifiTrendChart, trend);
  renderRunningWifiNarrative(payload, state.selectedWifiPoi, state.selectedWifiRobot, targetRows);
  renderWeakSignalRate(payload, state.selectedWifiRobot, state.selectedWifiPoi);
  renderWeakSignalTimeline(payload, state.selectedWifiRobot, state.selectedWifiPoi);
  renderWifiPointComparison(payload);
}

function renderRobotProfile(profile) {
  const current = (state.dashboard?.robots || []).find(
    (robot) => String(robot.master_robot_id) === String(profile.robot.master_robot_id)
  );
  if (!current) {
    elements.profileAlertBanner.dataset.tone = 'critical';
    elements.profileAlertBanner.querySelector('strong').textContent = 'The selected robot is not present in the current DWS dashboard dataset.';
    return;
  }

  const robotId = robotIdentifier(current);
  const diagnosis = robotDiagnostic(current);
  elements.profileRobotSelect.value = String(current.master_robot_id);
  elements.profileRobotSubtitle.textContent = `Master ID ${current.master_robot_id} · ${state.window.label} · ${profile.robot.robot_serial_number || 'Serial number not reported'}`;
  elements.profileAlertBanner.dataset.tone = diagnosis ? 'critical' : 'healthy';
  elements.profileAlertBanner.querySelector('span').textContent = diagnosis ? 'Transparent Diagnosis' : 'Current Health';
  elements.profileAlertBanner.querySelector('strong').textContent = diagnosis
    ? `${diagnosis.diagnosis} (${diagnosis.confidence} confidence) Next: ${diagnosis.recommendedActions?.[0] || 'inspect current evidence'}`
    : 'No current diagnostic rule was triggered for this robot.';

  elements.profileStatusValue.textContent = String(current.data_freshness_status || 'MISSING').replaceAll('_', ' ');
  elements.profileStatusDetail.textContent = `Non-snapshot DWS · threshold ${formatNumber(state.dashboard?.staleMinutes || 30)} min`;
  elements.profileBatteryValue.textContent = current.battery_soc == null ? '--' : `${formatNumber(current.battery_soc, 1)}%`;
  elements.profileBatteryValue.className = batteryClass(current.battery_soc);
  elements.profileBatteryDetail.textContent = current.battery_freshness_status === 'CURRENT'
    ? `Latest DWS hourly average · ${formatNumber(current.battery_voltage, 2)}V · ${formatNumber(current.battery_current, 2)}A`
    : `Suppressed · ${String(current.battery_freshness_status || 'MISSING').replaceAll('_', ' ')}`;
  elements.profileTaskValue.textContent = 'Not available';
  elements.profileTaskDetail.textContent = 'Current task ID is not stored in DWS daily aggregates';
  elements.profileWifiValue.textContent = current.current_rssi == null ? '--' : `${formatNumber(current.current_rssi)} dBm`;
  elements.profileWifiDetail.textContent = current.wifi_freshness_status === 'CURRENT'
    ? 'Latest DWS hourly RSSI average · AP identity not stored'
    : `Suppressed · ${String(current.wifi_freshness_status || 'MISSING').replaceAll('_', ' ')}`;
  elements.profilePositionValue.textContent = 'Not available';
  elements.profilePositionDetail.textContent = 'Position is not stored in the non-snapshot DWS hourly tables';
  elements.profileDataTimeValue.textContent = formatDateTime(current.status_dws_load_time || current.dws_load_time);
  elements.profileDataTimeValue.className = dataTimeClass(current.status_dws_load_time || current.dws_load_time);
  elements.profileDataTimeDetail.textContent = `DWS load ${formatDataAge(current.status_dws_load_time || current.dws_load_time)}`;

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
    ['Last task in DWS history', current.job_event_time],
    ['DWS status load', current.status_dws_load_time],
    ['DWS battery load', current.battery_dws_load_time],
    ['DWS WiFi load', current.wifi_dws_load_time]
  ];
  elements.profileSourceTimesBody.replaceChildren();
  sourceTimes.forEach(([source, time]) => {
    const row = elements.profileSourceTimesBody.insertRow();
    row.insertCell().textContent = source;
    const timeCell = row.insertCell();
    timeCell.textContent = formatDateTime(time);
    timeCell.className = dataTimeClass(time);
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

function buildExportRows(dataset) {
  const data = state.dashboard || {};
  const summary = data.summary || {};
  const robots = data.robots || [];
  const profile = state.robotProfile || {};
  const selectedProfileRobot = robots.find(
    (robot) => String(robot.master_robot_id) === String(state.selectedRobotId)
  );

  switch (dataset) {
    case 'project-analytics': {
      /*
        Export the task rows of the current scope: the project/task axis is what
        this view is about, and each row already carries its robot count.
      */
      const projectData = state.projectAnalytics || {};
      return (projectData.tasks || []).map((row) => ({
        Project: row.project_name,
        Project_ID: row.project_id,
        Task: row.task_name,
        Job_ID: row.job_id,
        Task_Records: row.queue_count,
        Robots: row.robot_count,
        Completed: row.completed_count,
        Unsuccessful: row.unsuccessful_count,
        Open: row.open_count,
        Execution_Seconds: row.execution_seconds,
        Average_Execution_Seconds: row.average_execution_seconds,
        Subjob_Runs: row.subjob_run_count,
        Latest_Record: row.latest_event_time,
        Analysis_Start: projectData.summary?.analysis_start,
        Analysis_End: projectData.summary?.analysis_end,
        Selected_Projects: state.selectedProjectIds.join(',') || 'ALL',
        Selected_Jobs: state.selectedJobIds.join(',') || 'ALL',
        Selected_Robots: state.selectedRobotCodes.join(',') || 'ALL',
        Identity_Rule: projectData.identityRule
      }));
    }
    case 'analysis':
      return (data.analysis?.priorityDiagnostics || []).map((diagnostic) => ({
        Robot_ID: diagnostic.robotId,
        Robot_Type: diagnostic.robotType,
        Phenomenon: diagnostic.phenomenon,
        Most_Likely_Explanation: diagnostic.diagnosis,
        Confidence: diagnostic.confidence,
        Severity: diagnostic.severity,
        Evidence: (diagnostic.evidence || []).join('; '),
        Recommended_Actions: (diagnostic.recommendedActions || []).join('; '),
        Alternative_Causes: (diagnostic.alternativeCauses || []).join('; '),
        Triggered_Rules: (diagnostic.ruleIds || []).join('; '),
        Rule_Version: data.analysis?.ruleVersion,
        Analysis_Generated_At: data.analysis?.generatedAt
      }));
    case 'overview': {
      const totals = (data.jobTrend || []).reduce((result, row) => ({
        completed: result.completed + asNumber(row.completed_status_count),
        failed: result.failed + asNumber(row.failed_status_count)
      }), { completed: 0, failed: 0 });
      const finished = totals.completed + totals.failed;
      return [{
        Robot_Type_Filter: robotTypeLabel(),
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
        Robot_Type: robot.robot_type,
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
        Robot_Type: selectedProfileRobot.robot_type,
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
        Robot_Type: robot.robot_type,
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
        Robot_Type: robot.robot_type,
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
  downloadBlob(`\uFEFF${lines.join('\r\n')}`, 'text/csv;charset=utf-8', `robot-${state.robotType.toLowerCase()}-${dataset}-${state.window.key}-${stamp}.csv`);
  showToast(`Downloaded: ${rows.length} rows`);
}

function exportAllData() {
  if (!state.dashboard) {
    showToast('Data has not loaded yet, so the export is unavailable', 'error');
    return;
  }
  const payload = {
    exportedAt: new Date().toISOString(),
    selectedRobotType: state.robotType,
    selectedWindow: state.window,
    sourceNote: 'IOT2020 DWS dashboard response; WiFi detail uses strict ODS Running-task matching and supports an exact window up to 30 days.',
    dashboard: state.dashboard
  };
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  downloadBlob(JSON.stringify(payload, null, 2), 'application/json;charset=utf-8', `robot-dashboard-${state.robotType.toLowerCase()}-${state.window.key}-${stamp}.json`);
  showToast('Downloaded all current dashboard data');
}

elements.refreshButton.addEventListener('click', () => {
  loadDashboard({ announce: true });
  loadProjectAnalytics();
});
elements.syncButton.addEventListener('click', refreshDwsData);
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
// Checkbox dropdowns: option changes are wired in renderMultiSelect; these
// bindings only open/close the menus.
bindMultiSelectToggle(elements.wifiRobotToggle, elements.wifiRobotMenu);
bindMultiSelectToggle(elements.wifiPoiToggle, elements.wifiPoiMenu);
document.addEventListener('click', () => closeMultiSelectMenus(null));
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') closeMultiSelectMenus(null);
});
elements.wifiApplyWindow.addEventListener('click', () => {
  const start = String(elements.wifiStartTime.value || '').trim();
  const end = String(elements.wifiEndTime.value || '').trim();
  if (!start || !end) {
    showToast('Choose both exact analysis start and end times', 'error');
    return;
  }
  state.analysisWindow = { isCustom: true, start, end };
  state.selectedWifiRobot = 'ALL';
  state.selectedWifiPoi = 'ALL';
  state.selectedWifiRobots = [];
  state.selectedWifiPois = [];
  elements.analysisWindowLabel.textContent = `${robotTypeLabel()} · ${analysisWindowLabelText()}`;
  loadDashboard({ announce: true });
  loadTaskAnalytics();
  loadProjectAnalytics();
});
if (elements.windowClearButton) {
  elements.windowClearButton.addEventListener('click', () => {
    state.analysisWindow = { isCustom: false, start: null, end: null };
    if (elements.wifiStartTime) elements.wifiStartTime.value = '';
    if (elements.wifiEndTime) elements.wifiEndTime.value = '';
    elements.analysisWindowLabel.textContent = `${robotTypeLabel()} · ${analysisWindowLabelText()}`;
    loadDashboard({ announce: true });
    loadTaskAnalytics();
    loadProjectAnalytics();
  });
}
elements.taskApplyWindow.addEventListener('click', () => {
  loadTaskAnalytics({ announce: true });
});
bindMultiSelectToggle(elements.projectToggle, elements.projectMenu);
bindMultiSelectToggle(elements.taskToggle, elements.taskMenu);
bindMultiSelectToggle(elements.robotToggle, elements.robotMenu);
bindMultiSelectToggle(elements.analysisProjectToggle, elements.analysisProjectMenu);
bindMultiSelectToggle(elements.analysisTaskToggle, elements.analysisTaskMenu);
bindMultiSelectToggle(elements.analysisRobotToggle, elements.analysisRobotMenu);
if (elements.projectClearFilter) {
  elements.projectClearFilter.addEventListener('click', () => setProjectScope({ projectIds: [], jobIds: [], robotCodes: [] }));
}
if (elements.analysisClearFilter) {
  elements.analysisClearFilter.addEventListener('click', () => setProjectScope({ projectIds: [], jobIds: [], robotCodes: [] }));
}
elements.taskRobotToggle.addEventListener('click', () => {
  const opening = elements.taskRobotMenu.hidden;
  elements.taskRobotMenu.hidden = !opening;
  elements.taskRobotToggle.setAttribute('aria-expanded', String(opening));
});
document.addEventListener('click', (event) => {
  if (!elements.taskRobotMenu || elements.taskRobotMenu.hidden) return;
  if (event.target.closest('.task-robot-picker')) return;
  elements.taskRobotMenu.hidden = true;
  elements.taskRobotToggle.setAttribute('aria-expanded', 'false');
});
elements.taskTopLimitSelect.addEventListener('change', () => {
  state.taskTopLimit = Number(elements.taskTopLimitSelect.value) || 5;
  if (state.taskAnalytics) renderTaskAnalytics(state.taskAnalytics);
});
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
activateView(VIEW_META[initialView] ? initialView : 'projects', { updateHash: false });
loadDashboard();
loadTaskAnalytics();
loadProjectAnalytics();
