'use strict';

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
