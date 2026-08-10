'use strict';

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

function setProjectScope({ projectIds = [], jobIds = [] } = {}) {
  state.selectedProjectIds = projectIds.map(String);
  state.selectedJobIds = jobIds.map(String);
  state.selectedProjectRobotCodes = [];
  if (state.projectAnalytics) populateProjectSelectors(state.projectAnalytics);
  loadProjectAnalytics();
}

function setProjectRobotDisplayScope(robotCodes = []) {
  state.selectedProjectRobotCodes = robotCodes.map(String);
  if (state.projectAnalytics) renderProjectAnalytics(state.projectAnalytics);
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
  const availableRobots = new Set(robots.map((row) => row.value));
  state.selectedProjectRobotCodes = state.selectedProjectRobotCodes
    .filter((robotCode) => availableRobots.has(robotCode));
  const projectScope = {
    projectIds: state.selectedProjectIds,
    jobIds: state.selectedJobIds
  };

  renderProjectMultiMenu(
    elements.projectMenu,
    elements.projectToggleText,
    projects,
    state.selectedProjectIds,
    (values) => setProjectScope({ projectIds: values, jobIds: [] }),
    `All projects (${projects.length})`
  );
  renderProjectMultiMenu(
    elements.analysisProjectMenu,
    elements.analysisProjectToggleText,
    projects,
    state.selectedProjectIds,
    (values) => setProjectScope({ projectIds: values, jobIds: [] }),
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
    state.selectedProjectRobotCodes,
    setProjectRobotDisplayScope,
    `All derived robots (${robots.length})`
  );
  renderProjectMultiMenu(
    elements.analysisRobotMenu,
    elements.analysisRobotToggleText,
    robots,
    state.selectedProjectRobotCodes,
    setProjectRobotDisplayScope,
    `All derived robots (${robots.length})`
  );
}

function projectDisplayRobotRows(rows = [], key = 'robot_name') {
  if (!state.selectedProjectRobotCodes.length) return rows;
  const selected = new Set(state.selectedProjectRobotCodes);
  return rows.filter((row) => selected.has(String(row[key] || '').trim()));
}

function projectDisplayIdleCauses(rows = []) {
  const scopedRows = projectDisplayRobotRows(rows, 'robot_name');
  return scopedRows.reduce((total, row) => ({
    no_task_seconds: total.no_task_seconds + asNumber(row.no_task_seconds),
    waiting_seconds: total.waiting_seconds + asNumber(row.waiting_seconds),
    charging_seconds: total.charging_seconds + asNumber(row.charging_seconds),
    executing_seconds: total.executing_seconds + asNumber(row.executing_seconds),
    robot_count: total.robot_count + 1
  }), {
    no_task_seconds: 0,
    waiting_seconds: 0,
    charging_seconds: 0,
    executing_seconds: 0,
    robot_count: 0
  });
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
              jobIds: []
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
              jobIds: [...nextJobs]
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
    const robotId = row.robot_master_id === null || row.robot_master_id === undefined
      ? null
      : String(row.robot_master_id);
    host.append(projectTableRow(
      [
        row.robot_name,
        formatNumber(row.queue_count),
        formatNumber(row.task_count),
        formatNumber(row.completed_count),
        formatNumber(row.unsuccessful_count),
        row.average_execution_seconds === null || row.average_execution_seconds === undefined
          ? 'Not available'
          : formatSeconds(row.average_execution_seconds)
      ],
      {
        onActivate: robotId === null ? null : () => selectRobotProfile(robotId)
      }
    ));
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
  const trendGrain = data.trendGrain || { label: '15 Minutes', bucketLabel: '15-minute buckets' };
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
  const allRobotRows = data.robots || [];
  const robotRows = projectDisplayRobotRows(allRobotRows);
  const displayRobotLabel = state.selectedProjectRobotCodes.length === 1
    ? state.selectedProjectRobotCodes[0]
    : state.selectedProjectRobotCodes.length > 1
      ? `${state.selectedProjectRobotCodes.length} robots displayed`
      : 'All derived robots';
  /*
    The KPI strip describes the selected scope, not the whole window, so it is
    summed from the scoped robot breakdown rather than the window summary.
  */
  const scopedRecords = robotRows.reduce((sum, row) => sum + asNumber(row.queue_count), 0);
  const scopedCompleted = robotRows.reduce((sum, row) => sum + asNumber(row.completed_count), 0);
  const scopedUnsuccessful = robotRows.reduce((sum, row) => sum + asNumber(row.unsuccessful_count), 0);
  const scopedExecution = robotRows.reduce((sum, row) => sum + asNumber(row.execution_seconds), 0);
  const recordedOutcomes = scopedCompleted + scopedUnsuccessful;

  if (elements.projectDataScope) {
    elements.projectDataScope.dataset.tone = 'neutral';
    elements.projectDataScope.textContent = `${projectLabel} / ${taskLabel} · ${formatTaskLocalDateTime(summary.analysis_start)} to ${formatTaskLocalDateTime(summary.analysis_end)} · query scope ${formatNumber(summary.queue_count)} records · display ${formatNumber(scopedRecords)} records from ${formatNumber(robotRows.length)} of ${formatNumber(allRobotRows.length)} derived robots`;
  }

  if (elements.projectQueueValue) elements.projectQueueValue.textContent = formatNumber(scopedRecords);
  if (elements.projectQueueDetail) elements.projectQueueDetail.textContent = `${projectLabel} / ${taskLabel} / ${displayRobotLabel}`;
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
    elements.projectTrendSubtitle.textContent = `${projectLabel} / ${taskLabel} / ${displayRobotLabel} · queue records in ${trendGrain.bucketLabel}.`;
  }
  if (elements.projectTrendTitle) elements.projectTrendTitle.textContent = `Task Records by ${trendGrain.label}`;

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
  renderTaskIdleCauses(projectDisplayIdleCauses(data.idleCausesByRobot || []), elements.projectOutcomeChart);
  renderTaskLabelTrend(elements.projectTrendChart, projectDisplayRobotRows(data.hourlyTrend || []), {
    labelKey: 'robot_name',
    valueKey: 'queue_count',
    secondaryKey: 'completed_count',
    unit: 'records',
    ariaLabel: 'Task record trend by robot',
    emptyText: `No task records are available in ${trendGrain.bucketLabel} for the selected project and task.`
  });
  renderProjectRecords(projectDisplayRobotRows(data.recentQueues || []));
}
