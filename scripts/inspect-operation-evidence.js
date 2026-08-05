'use strict';

const path = require('node:path');
const { getPool, closePool } = require('../src/db');

try {
  if (typeof process.loadEnvFile === 'function') {
    process.loadEnvFile(path.join(__dirname, '..', '.env'));
  }
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
}

const query = `
SET NOCOUNT ON;

DECLARE
    @task_anchor DATETIMEOFFSET,
    @queue_anchor DATETIME2(3),
    @battery_anchor DATETIME2(3);

SELECT @task_anchor = MAX(task.[start_time])
FROM [dbo].[TA_AMR] AS task;

SELECT @queue_anchor = MAX(queue_fact.[event_time])
FROM [DWD].[fact_amr_queue] AS queue_fact;

SELECT @battery_anchor = MAX(battery.[pc_timestamp])
FROM [dbo].[robot_battery_history] AS battery;

SELECT TOP (20)
    task.[id],
    robot.[name] AS [robot_code],
    task.[queue_id],
    task.[job_id],
    task.[subjob_id],
    task.[start_time],
    task.[end_time],
    DATEDIFF(SECOND, task.[start_time], task.[end_time]) AS [actual_duration_seconds],
    task.[status],
    task.[start_map],
    task.[start_zone],
    task.[start_battery],
    task.[end_battery]
FROM [dbo].[TA_AMR] AS task
LEFT JOIN [dbo].[MA_AMR] AS robot
    ON robot.[id] = task.[AMR_id]
ORDER BY task.[id] DESC;

SELECT TOP (20)
    analysis.[id],
    analysis.[job_id],
    analysis.[subjob_id],
    analysis.[min_value],
    analysis.[q1_value],
    analysis.[median_value],
    analysis.[mean_value],
    analysis.[q3_value],
    analysis.[max_value],
    analysis.[sd_value],
    analysis.[limit]
FROM [dbo].[AMR_Subjob_Analyze] AS analysis
ORDER BY analysis.[id] DESC;

SELECT
    COUNT_BIG(1) AS [task_row_count],
    SUM(CASE WHEN task.[start_time] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [start_time_row_count],
    SUM(CASE WHEN task.[end_time] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [end_time_row_count],
    SUM(CASE WHEN task.[start_time] IS NOT NULL AND task.[end_time] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [duration_row_count],
    SUM(CASE WHEN analysis.[limit] IS NOT NULL AND analysis.[limit] > 0 THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [estimated_duration_row_count],
    MIN(task.[start_time]) AS [first_task_time],
    MAX(task.[start_time]) AS [last_task_time]
FROM [dbo].[TA_AMR] AS task
LEFT JOIN [dbo].[AMR_Subjob_Analyze] AS analysis
    ON analysis.[job_id] = task.[job_id]
   AND analysis.[subjob_id] = task.[subjob_id]
WHERE @task_anchor IS NOT NULL
  AND task.[start_time] >= DATEADD(DAY, -7, @task_anchor)
  AND task.[start_time] <= @task_anchor;

SELECT
    COUNT_BIG(1) AS [queue_row_count],
    SUM(CASE WHEN queue_fact.[queue_start_time] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [queue_start_row_count],
    SUM(CASE WHEN queue_fact.[queue_end_time] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [queue_end_row_count],
    SUM(CASE WHEN queue_fact.[duration_seconds] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [duration_row_count],
    MIN(queue_fact.[event_time]) AS [first_queue_time],
    MAX(queue_fact.[event_time]) AS [last_queue_time]
FROM [DWD].[fact_amr_queue] AS queue_fact
WHERE @queue_anchor IS NOT NULL
  AND queue_fact.[event_time] >= DATEADD(DAY, -7, @queue_anchor)
  AND queue_fact.[event_time] <= @queue_anchor;

SELECT
    COUNT_BIG(1) AS [subjob_row_count],
    SUM(CASE WHEN subjob.[subjob_start_time] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [start_time_row_count],
    SUM(CASE WHEN subjob.[subjob_end_time] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [end_time_row_count],
    SUM(CASE WHEN subjob.[duration_seconds] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [duration_row_count],
    SUM(CASE WHEN subjob.[start_station_code] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [start_station_row_count],
    SUM(CASE WHEN subjob.[end_station_code] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [end_station_row_count]
FROM [DWD].[fact_amr_subjob] AS subjob;

SELECT
    robot.[name] AS [robot_code],
    COUNT_BIG(1) AS [sample_count],
    SUM(CASE WHEN battery.[batt_level] > 60 THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [above_60_sample_count],
    CAST(
        100.0 * SUM(CASE WHEN battery.[batt_level] > 60 THEN CONVERT(BIGINT, 1) ELSE 0 END)
        / NULLIF(COUNT_BIG(1), 0)
        AS DECIMAL(9, 2)
    ) AS [above_60_sample_share_percent],
    MIN(battery.[pc_timestamp]) AS [first_sample_time],
    MAX(battery.[pc_timestamp]) AS [last_sample_time]
FROM [dbo].[robot_battery_history] AS battery WITH (INDEX([IX_battery_performance]))
INNER JOIN [dbo].[MA_AMR] AS robot
    ON robot.[id] = battery.[amr_id]
WHERE @battery_anchor IS NOT NULL
  AND battery.[pc_timestamp] >= DATEADD(HOUR, -24, @battery_anchor)
  AND battery.[pc_timestamp] <= @battery_anchor
  AND UPPER(LTRIM(RTRIM(COALESCE(robot.[is_active], N'')))) = N'Y'
GROUP BY robot.[name]
ORDER BY robot.[name];

SELECT
    schema_info.[name] AS [schema_name],
    table_info.[name] AS [table_name],
    index_info.[name] AS [index_name],
    index_info.[type_desc],
    index_column.[key_ordinal],
    column_info.[name] AS [column_name],
    index_column.[is_included_column]
FROM [sys].[indexes] AS index_info
INNER JOIN [sys].[tables] AS table_info
    ON table_info.[object_id] = index_info.[object_id]
INNER JOIN [sys].[schemas] AS schema_info
    ON schema_info.[schema_id] = table_info.[schema_id]
INNER JOIN [sys].[index_columns] AS index_column
    ON index_column.[object_id] = index_info.[object_id]
   AND index_column.[index_id] = index_info.[index_id]
INNER JOIN [sys].[columns] AS column_info
    ON column_info.[object_id] = index_column.[object_id]
   AND column_info.[column_id] = index_column.[column_id]
WHERE schema_info.[name] = N'dbo'
  AND table_info.[name] IN (N'TA_AMR', N'AMR_Queue', N'robot_battery_history')
ORDER BY
    table_info.[name],
    index_info.[name],
    index_column.[key_ordinal],
    column_info.[column_id];

SELECT
    subjob.[id],
    subjob.[job_id],
    subjob.[name],
    subjob.[order],
    subjob.[type_id],
    subjob_type.[name] AS [subjob_type_name]
FROM [dbo].[MA_AMR_Subjob] AS subjob
LEFT JOIN [dbo].[MA_AMR_Subjob_Type] AS subjob_type
    ON subjob_type.[id] = subjob.[type_id]
WHERE subjob.[id] IN (1200, 1201)
ORDER BY subjob.[id];
`;

async function main() {
  const pool = await getPool();
  const request = pool.request();
  request.multiple = true;
  const result = await request.query(query);
  const payload = {
    recentTasks: result.recordsets[0] || [],
    estimatedDurationReference: result.recordsets[1] || [],
    taskCoverage: result.recordsets[2]?.[0] || {},
    queueCoverage: result.recordsets[3]?.[0] || {},
    subjobCoverage: result.recordsets[4]?.[0] || {},
    batteryAbove60SampleShare: result.recordsets[5] || [],
    indexes: result.recordsets[6] || [],
    recentSubjobDefinitions: result.recordsets[7] || []
  };
  if (process.argv.includes('--compact')) {
    delete payload.recentTasks;
    delete payload.estimatedDurationReference;
  }
  process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
}

main()
  .then(closePool)
  .catch(async (error) => {
    console.error(error);
    await closePool();
    process.exitCode = 1;
  });
