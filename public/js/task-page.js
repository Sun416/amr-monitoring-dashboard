'use strict';

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
