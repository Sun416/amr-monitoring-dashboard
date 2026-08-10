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
  selectedProjectRobotCodes: [],
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
    'analysisWindowLabel', 'windowClearButton', 'refreshButton', 'exportAllButton', 'metricTotal', 'metricTotalScope', 'metricOnline',
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
