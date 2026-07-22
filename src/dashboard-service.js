'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { sql, getPool, parseInteger } = require('./db');

const queryPath = path.join(__dirname, 'dashboard-query.sql');
const dashboardQuery = fs.readFileSync(queryPath, 'utf8');
const wifiQueryPath = path.join(__dirname, 'wifi-monitor-query.sql');
const wifiMonitorQuery = fs.readFileSync(wifiQueryPath, 'utf8');

function normalizeWindow(hours, days) {
  return {
    hours: parseInteger(hours, 24, 1, 720),
    days: parseInteger(days, 7, 1, 90)
  };
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

async function loadDashboard({ hours, days } = {}) {
  const window = normalizeWindow(hours, days);
  const onlineAnchorMinutes = parseInteger(process.env.ONLINE_ANCHOR_MINUTES, 5, 1, 120);
  const pool = await getPool();
  const dashboardRequest = pool.request();
  dashboardRequest.multiple = true;
  dashboardRequest.input('hours', sql.Int, window.hours);
  dashboardRequest.input('days', sql.Int, window.days);
  dashboardRequest.input('online_anchor_minutes', sql.Int, onlineAnchorMinutes);

  const wifiRequest = pool.request();
  wifiRequest.multiple = true;
  wifiRequest.input('hours', sql.Int, window.hours);

  const [result, wifiResult] = await Promise.all([
    dashboardRequest.query(dashboardQuery),
    wifiRequest.query(wifiMonitorQuery)
  ]);
  const sets = result.recordsets || [];
  const wifiSets = wifiResult.recordsets || [];
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

  return {
    generatedAt: new Date().toISOString(),
    staleMinutes: parseInteger(process.env.DASHBOARD_STALE_MINUTES, 5, 1, 1440),
    onlineAnchorMinutes,
    window,
    wifiDataSource: 'dbo.robot_wifi_history (bounded indexed window)',
    summary: { ...(sets[0]?.[0] || {}), ...wifiSummary },
    robots,
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

async function synchronizeCurrentSnapshot() {
  const pool = await getPool();
  const request = pool.request();
  const startedAt = new Date();
  const onlineAnchorMinutes = parseInteger(process.env.ONLINE_ANCHOR_MINUTES, 5, 1, 120);

  request.input('online_anchor_minutes', sql.Int, onlineAnchorMinutes);
  await request.execute('[DWS].[sp_refresh_robot_current_snapshot_fast]');

  return {
    status: 'SUCCESS',
    onlineAnchorMinutes,
    startedAt: startedAt.toISOString(),
    finishedAt: new Date().toISOString()
  };
}

async function checkDatabase() {
  const pool = await getPool();
  const result = await pool.request().query(`
    SELECT
        DB_NAME() AS [database_name],
        SYSDATETIME() AS [database_time],
        CASE
            WHEN OBJECT_ID(N'[DWS].[dws_robot_current_snapshot]', N'U') IS NULL THEN CONVERT(BIT, 0)
            ELSE CONVERT(BIT, 1)
        END AS [snapshot_table_exists],
        CASE
            WHEN OBJECT_ID(N'[DWS].[sp_refresh_robot_current_snapshot_fast]', N'P') IS NULL THEN CONVERT(BIT, 0)
            ELSE CONVERT(BIT, 1)
        END AS [fast_sync_procedure_exists];
  `);

  return result.recordset[0];
}

module.exports = {
  loadDashboard,
  synchronizeCurrentSnapshot,
  checkDatabase
};
