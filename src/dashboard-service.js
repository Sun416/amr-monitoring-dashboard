'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { sql, getPool, parseInteger } = require('./db');

const queryPath = path.join(__dirname, 'dashboard-query.sql');
const dashboardQuery = fs.readFileSync(queryPath, 'utf8');
const wifiQueryPath = path.join(__dirname, 'wifi-monitor-query.sql');
const wifiMonitorQuery = fs.readFileSync(wifiQueryPath, 'utf8');
const robotProfileQueryPath = path.join(__dirname, 'robot-profile-query.sql');
const robotProfileQuery = fs.readFileSync(robotProfileQueryPath, 'utf8');
const analysisQueryPath = path.join(__dirname, 'analysis-query.sql');
const analysisQuery = fs.readFileSync(analysisQueryPath, 'utf8');
const wifiRunningAnalysisQueryPath = path.join(__dirname, 'wifi-running-analysis-query.sql');
const wifiRunningAnalysisQuery = fs.readFileSync(wifiRunningAnalysisQueryPath, 'utf8');
const taskAnalyticsQueryPath = path.join(__dirname, 'task-analytics-query.sql');
const taskAnalyticsQuery = fs.readFileSync(taskAnalyticsQueryPath, 'utf8');
const projectAnalyticsQueryPath = path.join(__dirname, 'project-analytics-query.sql');
const projectAnalyticsQuery = fs.readFileSync(projectAnalyticsQueryPath, 'utf8');
const { buildAnalysis } = require('./analysis-engine');
const { buildWifiMinimumDiagnostics } = require('./wifi-minimum-diagnostic');
const { buildWifiWeakSignalDiagnostics } = require('./wifi-weak-signal-diagnostic');

function normalizeWindow(hours, days) {
  return {
    hours: parseInteger(hours, 24, 1, 720),
    days: parseInteger(days, 7, 1, 90)
  };
}

const WIFI_ANALYSIS_MAX_HOURS = 720;

function wifiWindowError(message) {
  const error = new Error(message);
  error.code = 'INVALID_WIFI_ANALYSIS_WINDOW';
  error.statusCode = 400;
  return error;
}

function parseDatabaseLocalDateTime(value, label) {
  if (value === undefined || value === null || String(value).trim() === '') return null;

  const text = String(value).trim();
  const match = text.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?$/);
  if (!match) throw wifiWindowError(`${label} must use a valid local date and time.`);

  const [, yearText, monthText, dayText, hourText, minuteText, secondText = '0', millisecondText = '0'] = match;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = Number(secondText);
  const millisecond = Number(millisecondText.padEnd(3, '0'));
  const timestamp = Date.UTC(year, month - 1, day, hour, minute, second, millisecond);
  const parsed = new Date(timestamp);

  if (
    parsed.getUTCFullYear() !== year
    || parsed.getUTCMonth() !== month - 1
    || parsed.getUTCDate() !== day
    || parsed.getUTCHours() !== hour
    || parsed.getUTCMinutes() !== minute
    || parsed.getUTCSeconds() !== second
  ) {
    throw wifiWindowError(`${label} must use a valid local date and time.`);
  }

  return {
    timestamp,
    sqlText: `${yearText}-${monthText}-${dayText}T${hourText}:${minuteText}:${secondText}.${millisecondText.padEnd(3, '0')}`
  };
}

function normalizeWifiAnalysisWindow(wifiStart, wifiEnd, fallbackHours) {
  const start = parseDatabaseLocalDateTime(wifiStart, 'WiFi start time');
  const end = parseDatabaseLocalDateTime(wifiEnd, 'WiFi end time');

  if (!start && !end) {
    return {
      isCustom: false,
      start: null,
      end: null,
      hours: fallbackHours
    };
  }
  if (!start || !end) {
    throw wifiWindowError('Choose both a WiFi start time and end time.');
  }

  const durationMilliseconds = end.timestamp - start.timestamp;
  if (durationMilliseconds <= 0) {
    throw wifiWindowError('WiFi end time must be later than the start time.');
  }
  if (durationMilliseconds > WIFI_ANALYSIS_MAX_HOURS * 60 * 60 * 1000) {
    throw wifiWindowError('A custom WiFi analysis window can be at most 30 days.');
  }

  return {
    isCustom: true,
    start: start.sqlText,
    end: end.sqlText,
    hours: Math.max(1, Math.ceil(durationMilliseconds / (60 * 60 * 1000)))
  };
}

function normalizeRobotType(value) {
  const robotType = String(value || 'ALL').trim().toUpperCase();
  return ['AMR', 'AMB'].includes(robotType) ? robotType : 'ALL';
}

function latestDateTime(values) {
  let latest = null;

  values.forEach((value) => {
    if (!value) return;
    const date = value instanceof Date ? value : new Date(value);
    if (Number.isNaN(date.getTime())) return;
    if (!latest || date > latest) latest = date;
  });

  return latest;
}

async function loadDashboard({ hours, days, robotType, wifiStart, wifiEnd } = {}) {
  const window = normalizeWindow(hours, days);
  const wifiAnalysisWindow = normalizeWifiAnalysisWindow(wifiStart, wifiEnd, window.hours);
  const normalizedRobotType = normalizeRobotType(robotType);
  const freshnessTimeoutMinutes = parseInteger(
    process.env.DWS_FRESHNESS_TIMEOUT_MINUTES || process.env.DASHBOARD_STALE_MINUTES,
    30,
    1,
    1440
  );
  const pool = await getPool();
  const dashboardRequest = pool.request();
  dashboardRequest.multiple = true;
  dashboardRequest.input('hours', sql.Int, window.hours);
  dashboardRequest.input('days', sql.Int, window.days);
  dashboardRequest.input('online_anchor_minutes', sql.Int, freshnessTimeoutMinutes);
  dashboardRequest.input('freshness_timeout_minutes', sql.Int, freshnessTimeoutMinutes);
  dashboardRequest.input('robot_type', sql.NVarChar(10), normalizedRobotType);

  const wifiRequest = pool.request();
  wifiRequest.multiple = true;
  wifiRequest.input('hours', sql.Int, window.hours);
  wifiRequest.input('freshness_timeout_minutes', sql.Int, freshnessTimeoutMinutes);
  wifiRequest.input('robot_type', sql.NVarChar(10), normalizedRobotType);

  const analysisRequest = pool.request();
  analysisRequest.multiple = true;
  analysisRequest.input('hours', sql.Int, window.hours);
  analysisRequest.input('days', sql.Int, window.days);
  analysisRequest.input('robot_type', sql.NVarChar(10), normalizedRobotType);

  const wifiRunningRequest = pool.request();
  wifiRunningRequest.multiple = true;
  wifiRunningRequest.input('hours', sql.Int, wifiAnalysisWindow.hours);
  wifiRunningRequest.input('freshness_timeout_minutes', sql.Int, freshnessTimeoutMinutes);
  wifiRunningRequest.input('robot_type', sql.NVarChar(10), normalizedRobotType);
  wifiRunningRequest.input('wifi_analysis_start', sql.NVarChar(23), wifiAnalysisWindow.start);
  wifiRunningRequest.input('wifi_analysis_end', sql.NVarChar(23), wifiAnalysisWindow.end);

  const [result, wifiResult, analysisResult, wifiRunningResult] = await Promise.all([
    dashboardRequest.query(dashboardQuery),
    wifiRequest.query(wifiMonitorQuery),
    analysisRequest.query(analysisQuery),
    wifiRunningRequest.query(wifiRunningAnalysisQuery)
  ]);
  const sets = result.recordsets || [];
  const wifiSets = wifiResult.recordsets || [];
  const analysisSets = analysisResult.recordsets || [];
  const wifiRunningSets = wifiRunningResult.recordsets || [];
  const wifiSummary = wifiSets[0]?.[0] || {};
  const wifiByMasterId = new Map(
    (wifiSets[1] || []).map((row) => [String(row.master_robot_id), row])
  );
  const robots = (sets[1] || []).map((robot) => {
    const mergedRobot = {
      ...robot,
      ...(wifiByMasterId.get(String(robot.master_robot_id)) || {})
    };

    return {
      ...mergedRobot,
      latest_data_time: latestDateTime([
        mergedRobot.status_event_time || mergedRobot.source_event_time,
        mergedRobot.battery_event_time,
        mergedRobot.latest_wifi_time
      ])
    };
  });

  const summary = { ...(sets[0]?.[0] || {}), ...wifiSummary };
  const workloadRows = analysisSets[0] || [];
  const statusCoverageRows = analysisSets[1] || [];
  const analysisReadiness = analysisSets[2]?.[0] || {};
  const taskTimingRows = analysisSets[3] || [];
  const queueWaitRows = analysisSets[4] || [];
  const batteryAbove60Rows = analysisSets[5] || [];
  const routeSegmentRows = analysisSets[6] || [];
  const eventAuditCoverageRows = analysisSets[7] || [];
  const wifiRunningSummary = wifiRunningSets[0]?.[0] || {};
  const wifiRunningTrend = wifiRunningSets[1] || [];
  const wifiRunningByTarget = wifiRunningSets[2] || [];
  const wifiRunningByRobot = wifiRunningSets[3] || [];
  const wifiRunningByRobotTarget = wifiRunningSets[4] || [];
  const wifiRunningWorstSamples = wifiRunningSets[5] || [];
  const wifiRunningWeakTimeline = wifiRunningSets[6] || [];
  const wifiMinimumDiagnostics = buildWifiMinimumDiagnostics({
    byTarget: wifiRunningByTarget,
    byRobot: wifiRunningByRobot,
    byRobotTarget: wifiRunningByRobotTarget,
    worstSamples: wifiRunningWorstSamples
  });
  const wifiWeakSignalDiagnostics = buildWifiWeakSignalDiagnostics({
    byTarget: wifiRunningByTarget,
    byRobot: wifiRunningByRobot
  });
  const analysis = buildAnalysis({
    summary,
    robots,
    workloadRows,
    statusCoverageRows,
    readiness: analysisReadiness,
    taskTimingRows,
    queueWaitRows,
    batteryAbove60Rows,
    routeSegmentRows,
    staleMinutes: freshnessTimeoutMinutes,
    window
  });

  return {
    generatedAt: new Date().toISOString(),
    staleMinutes: freshnessTimeoutMinutes,
    freshnessTimeoutMinutes,
    onlineAnchorMinutes: freshnessTimeoutMinutes,
    window,
    robotType: normalizedRobotType,
    currentDataSource: 'DWS non-snapshot hourly aggregates',
    wifiDataSource: 'DWS.dws_robot_wifi_hourly',
    summary,
    robots,
    analysis,
    robotWorkload: workloadRows,
    statusCoverage: statusCoverageRows,
    analysisReadiness,
    taskTiming: taskTimingRows,
    queueWait: queueWaitRows,
    batteryAbove60: batteryAbove60Rows,
    routeSegments: routeSegmentRows,
    eventAuditCoverage: eventAuditCoverageRows,
    wifiRunningAnalysis: {
      window: wifiAnalysisWindow,
      summary: wifiRunningSummary,
      trend: wifiRunningTrend,
      byTarget: wifiRunningByTarget,
      byRobot: wifiRunningByRobot,
      byRobotTarget: wifiRunningByRobotTarget,
      worstSamples: wifiRunningWorstSamples,
      minimumDiagnostics: wifiMinimumDiagnostics,
      weakTimeline: wifiRunningWeakTimeline,
      weakSignalDiagnostics: wifiWeakSignalDiagnostics
    },
    statusDistribution: sets[2] || [],
    modeDistribution: sets[3] || [],
    batteryTrend: sets[4] || [],
    statusTrend: sets[5] || [],
    wifiTrend: wifiSets[3] || [],
    wifiAccessPointRisk: wifiSets[2] || [],
    jobTrend: sets[7] || [],
    queueTrend: sets[8] || [],
    taskFailureOutcomes: sets[9] || [],
    recentBatches: sets[10] || []
  };
}

async function loadTaskAnalytics({ taskStart, taskEnd, robotCodes } = {}) {
  const pool = await getPool();
  const request = pool.request();
  request.multiple = true;
  request.input('task_analysis_start', sql.NVarChar(23), String(taskStart || '').trim() || null);
  request.input('task_analysis_end', sql.NVarChar(23), String(taskEnd || '').trim() || null);
  const normalizedRobotCodes = Array.isArray(robotCodes)
    ? robotCodes.map((code) => String(code || '').trim()).filter(Boolean).join(',')
    : String(robotCodes || '').trim();
  request.input('robot_codes', sql.NVarChar(sql.MAX), normalizedRobotCodes || null);

  const result = await request.query(taskAnalyticsQuery);
  const sets = result.recordsets || [];
  const summary = sets[0]?.[0] || {};

  return {
    generatedAt: new Date().toISOString(),
    dataSource: 'DWS task, battery, Calling Box, and assigned-task hourly aggregates',
    metricAvailability: {
      utilizationRate: 'AVAILABLE: execution / (execution + waiting + charging + no task); data-unavailable time is excluded.',
      idleTime: 'AVAILABLE: no task, waiting, and charging time from DWS task-hourly evidence.',
      leaderboard: 'AVAILABLE: all Calling Box-linked and assigned queue records in DWS hourly aggregates.',
      stateDataException: 'AVAILABLE: a robot-hour is exceptional when no execution, charging, waiting, or no-task evidence is available; detail is bounded to the latest 100 affected hours.'
    },
    summary,
    robots: sets[1] || [],
    hourlyTrend: sets[2] || [],
    callingBoxes: sets[3] || [],
    assignedTasks: sets[4] || [],
    stateExceptionDetails: sets[5] || [],
    callingBoxHourly: sets[6] || [],
    assignedTaskHourly: sets[7] || []
  };
}

function normalizeOptionalIdList(value) {
  if (value === undefined || value === null || value === '') return [];
  const parts = Array.isArray(value) ? value : String(value).split(',');
  const ids = [];
  parts.forEach((part) => {
    const text = String(part).trim();
    if (!text) return;
    const parsed = Number.parseInt(text, 10);
    if (!Number.isSafeInteger(parsed) || String(parsed) !== text) {
      const error = new Error('Project and task identifiers must be integers.');
      error.code = 'INVALID_PROJECT_SCOPE';
      error.statusCode = 400;
      throw error;
    }
    ids.push(String(parsed));
  });
  return ids;
}

/*
  Executive navigation is strictly project -> task -> robot. Only project and
  task are accepted as filters; robots are derived from the selected work.
*/
async function loadProjectAnalytics({ start, end, projectId, jobId, projectIds, jobIds } = {}) {
  const pool = await getPool();
  const request = pool.request();
  request.multiple = true;
  request.input('analysis_start_text', sql.NVarChar(23), String(start || '').trim() || null);
  request.input('analysis_end_text', sql.NVarChar(23), String(end || '').trim() || null);
  request.input('project_ids_text_param', sql.NVarChar(sql.MAX), normalizeOptionalIdList(projectIds ?? projectId).join(',') || null);
  request.input('job_ids_text_param', sql.NVarChar(sql.MAX), normalizeOptionalIdList(jobIds ?? jobId).join(',') || null);

  const result = await request.query(projectAnalyticsQuery);
  const sets = result.recordsets || [];

  return {
    generatedAt: new Date().toISOString(),
    dataSource: 'DWD.fact_amr_queue joined to dbo.MA_AMR_Project, DWD.dim_amr_task and dbo.MA_AMR',
    identityRule: 'Robot identity resolves through DWD.fact_amr_queue.robot_id = dbo.MA_AMR.id; robot_code is never used for display.',
    navigationModel: {
      filters: ['project', 'task'],
      derivedBreakdown: 'robot',
      drilldown: 'robot-profile'
    },
    metricAvailability: {
      executionSeconds: 'AVAILABLE: summed from closed ODS.TA_AMR subjob runs linked by queue_id. DWD.fact_amr_queue.duration_seconds is NULL in the source and is not used.',
      queueOutcome: 'AVAILABLE: DWD.fact_amr_queue.queue_status records the outcome only; the source has no root-cause field.',
      openQueues: 'AVAILABLE: in_progress and pending queue records within the window.'
    },
    summary: sets[0]?.[0] || {},
    projects: sets[1] || [],
    tasks: sets[2] || [],
    robots: sets[3] || [],
    hourlyTrend: sets[4] || [],
    outcomes: sets[5] || [],
    recentQueues: sets[6] || [],
    idleCausesByRobot: sets[7] || []
  };
}

async function loadRobotProfile({ robotId, hours, days } = {}) {
  const parsedRobotId = Number.parseInt(robotId, 10);
  if (!Number.isSafeInteger(parsedRobotId) || parsedRobotId < 1 || String(parsedRobotId) !== String(robotId).trim()) {
    const error = new Error('Robot ID must be a positive integer.');
    error.code = 'INVALID_ROBOT_ID';
    error.statusCode = 400;
    throw error;
  }

  const window = normalizeWindow(hours, days);
  const pool = await getPool();
  const request = pool.request();
  request.multiple = true;
  request.input('robot_id', sql.Int, parsedRobotId);
  request.input('hours', sql.Int, window.hours);
  request.input('days', sql.Int, window.days);

  const result = await request.query(robotProfileQuery);
  const sets = result.recordsets || [];
  const robot = sets[0]?.[0];
  if (!robot) {
    const error = new Error('The selected active robot was not found.');
    error.code = 'ROBOT_NOT_FOUND';
    error.statusCode = 404;
    throw error;
  }

  return {
    generatedAt: new Date().toISOString(),
    window,
    robot,
    batteryTrend: sets[1] || [],
    statusTrend: sets[2] || [],
    wifiTrend: sets[3] || [],
    jobTrend: sets[4] || [],
    taskBreakdown: sets[5] || [],
    anchors: sets[6]?.[0] || {}
  };
}

async function checkDatabase() {
  const pool = await getPool();
  const result = await pool.request().query(`
    SELECT
        DB_NAME() AS [database_name],
        SYSDATETIME() AS [database_time],
        CASE
            WHEN OBJECT_ID(N'[DWS].[dws_robot_status_hourly]', N'U') IS NULL THEN CONVERT(BIT, 0)
            ELSE CONVERT(BIT, 1)
        END AS [status_hourly_table_exists],
        CASE
            WHEN OBJECT_ID(N'[DWS].[dws_robot_battery_hourly]', N'U') IS NULL THEN CONVERT(BIT, 0)
            ELSE CONVERT(BIT, 1)
        END AS [battery_hourly_table_exists],
        CASE
            WHEN OBJECT_ID(N'[DWS].[dws_robot_wifi_hourly]', N'U') IS NULL THEN CONVERT(BIT, 0)
            ELSE CONVERT(BIT, 1)
        END AS [wifi_hourly_table_exists];
  `);

  return result.recordset[0];
}

module.exports = {
  loadDashboard,
  loadTaskAnalytics,
  loadProjectAnalytics,
  loadRobotProfile,
  checkDatabase,
  normalizeWifiAnalysisWindow
};
