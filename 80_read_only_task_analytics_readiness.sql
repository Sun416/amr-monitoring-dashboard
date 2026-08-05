USE [IOT2020];

/*
    Task Analytics warehouse readiness check
    =========================================

    Read-only only. No data, schema, watermark, batch log, or configuration is changed.

    Purpose:
      1. Confirm the required source path exists: ODS -> DWD -> DWS.
      2. Quantify the current DWD/DWS gaps before installing the Task Analytics mart.
      3. Prevent the Web from deriving operational metrics directly from dbo or ODS.

    Confirmed idle-classification precedence for the future DWS mart:
      Charging -> Waiting -> No task -> Data unavailable.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'IOT2020'
BEGIN
    THROW 58000, N'Expected database IOT2020.', 1;
END;

DECLARE @database_now DATETIME2(3) = SYSDATETIME();
DECLARE @window_start DATETIME2(3) = DATEADD(DAY, -7, @database_now);

/* 1. Required source objects and fields. */
WITH required_object AS
(
    SELECT N'ODS' AS [schema_name], N'TA_AMR' AS [table_name], N'Task execution source' AS [purpose]
    UNION ALL SELECT N'ODS', N'AMR_Queue', N'Queue and Calling Box assignment source'
    UNION ALL SELECT N'ODS', N'MA_AMR_Job', N'Assigned-task name source'
    UNION ALL SELECT N'ODS', N'AMR_ESP_Button_Configuration', N'Calling Box configuration source'
    UNION ALL SELECT N'DWD', N'fact_robot_operation_event', N'Cleaned task start/end event source'
    UNION ALL SELECT N'DWD', N'fact_amr_queue', N'Cleaned queue source'
    UNION ALL SELECT N'DWD', N'fact_robot_battery', N'Cleaned charging source'
    UNION ALL SELECT N'DWS', N'dws_robot_job_daily', N'Existing daily task aggregate'
    UNION ALL SELECT N'DWS', N'dws_amr_queue_daily', N'Existing daily queue aggregate'
    UNION ALL SELECT N'DWS', N'dws_robot_battery_hourly', N'Existing hourly charging aggregate'
),
existing_object AS
(
    SELECT schema_row.[name] AS [schema_name], table_row.[name] AS [table_name]
    FROM sys.tables AS table_row
    INNER JOIN sys.schemas AS schema_row
        ON schema_row.[schema_id] = table_row.[schema_id]
)
SELECT
    required.[schema_name],
    required.[table_name],
    required.[purpose],
    CASE WHEN existing.[table_name] IS NULL THEN N'MISSING' ELSE N'PRESENT' END AS [object_status]
FROM required_object AS required
LEFT JOIN existing_object AS existing
    ON existing.[schema_name] = required.[schema_name]
   AND existing.[table_name] = required.[table_name]
ORDER BY required.[schema_name], required.[table_name];

/* 2. Fields required by the requested Task Analytics view. */
WITH required_column AS
(
    SELECT N'ODS' AS [schema_name], N'AMR_Queue' AS [table_name], N'esp_button_id' AS [column_name], N'Calling Box attribution' AS [purpose]
    UNION ALL SELECT N'ODS', N'AMR_Queue', N'enqueued_at', N'Queue waiting start'
    UNION ALL SELECT N'ODS', N'TA_AMR', N'start_time', N'Execution start'
    UNION ALL SELECT N'ODS', N'TA_AMR', N'end_time', N'Execution end'
    UNION ALL SELECT N'ODS', N'MA_AMR_Job', N'name', N'Assigned-task label'
    UNION ALL SELECT N'DWD', N'fact_amr_queue', N'queue_start_time', N'Cleaned queue start'
    UNION ALL SELECT N'DWD', N'fact_amr_queue', N'calling_box_id', N'Calling Box attribution in DWD'
    UNION ALL SELECT N'DWD', N'fact_robot_operation_event', N'event_time', N'Cleaned execution event time'
    UNION ALL SELECT N'DWD', N'fact_robot_battery', N'charging_status', N'Charging classification'
    UNION ALL SELECT N'DWS', N'dws_robot_task_hourly', N'executing_seconds', N'Hourly utilization'
    UNION ALL SELECT N'DWS', N'dws_robot_task_hourly', N'charging_seconds', N'Hourly idle reason'
    UNION ALL SELECT N'DWS', N'dws_robot_task_hourly', N'waiting_seconds', N'Hourly idle reason'
    UNION ALL SELECT N'DWS', N'dws_robot_task_hourly', N'no_task_seconds', N'Hourly idle reason'
    UNION ALL SELECT N'DWS', N'dws_robot_task_hourly', N'data_unavailable_seconds', N'Explicit coverage gap'
    UNION ALL SELECT N'DWS', N'dws_robot_calling_box_daily', N'calling_box_name', N'Calling Box leaderboard'
    UNION ALL SELECT N'DWS', N'dws_robot_assigned_task_daily', N'task_name', N'Assigned-task leaderboard'
),
existing_column AS
(
    SELECT schema_row.[name] AS [schema_name], table_row.[name] AS [table_name], column_row.[name] AS [column_name]
    FROM sys.columns AS column_row
    INNER JOIN sys.tables AS table_row
        ON table_row.[object_id] = column_row.[object_id]
    INNER JOIN sys.schemas AS schema_row
        ON schema_row.[schema_id] = table_row.[schema_id]
)
SELECT
    required.[schema_name],
    required.[table_name],
    required.[column_name],
    required.[purpose],
    CASE WHEN existing.[column_name] IS NULL THEN N'MISSING' ELSE N'PRESENT' END AS [column_status]
FROM required_column AS required
LEFT JOIN existing_column AS existing
    ON existing.[schema_name] = required.[schema_name]
   AND existing.[table_name] = required.[table_name]
   AND existing.[column_name] = required.[column_name]
ORDER BY required.[schema_name], required.[table_name], required.[column_name];

/* 3. Recent ODS coverage and Calling Box availability. */
SELECT
    @window_start AS [window_start],
    @database_now AS [window_end],
    COUNT_BIG(*) AS [task_rows],
    SUM(CASE WHEN task_row.[start_time] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [started_task_rows],
    SUM(CASE WHEN task_row.[end_time] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [ended_task_rows],
    SUM(CASE WHEN task_row.[start_time] IS NOT NULL AND task_row.[end_time] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [open_task_rows],
    MIN(CONVERT(DATETIME2(3), task_row.[start_time])) AS [first_task_start_time],
    MAX(CONVERT(DATETIME2(3), COALESCE(task_row.[end_time], task_row.[start_time]))) AS [last_task_event_time]
FROM [ODS].[TA_AMR] AS task_row
WHERE CONVERT(DATETIME2(3), COALESCE(task_row.[end_time], task_row.[start_time])) >= @window_start
  AND CONVERT(DATETIME2(3), COALESCE(task_row.[end_time], task_row.[start_time])) < @database_now;

SELECT
    @window_start AS [window_start],
    @database_now AS [window_end],
    COUNT_BIG(*) AS [queue_rows],
    SUM(CASE WHEN queue_row.[esp_button_id] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [calling_box_queue_rows],
    SUM(CASE WHEN queue_row.[esp_button_id] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [non_calling_box_queue_rows],
    COUNT_BIG(DISTINCT queue_row.[esp_button_id]) AS [distinct_calling_box_count],
    MIN(CONVERT(DATETIME2(3), queue_row.[enqueued_at])) AS [first_queue_time],
    MAX(CONVERT(DATETIME2(3), queue_row.[enqueued_at])) AS [last_queue_time]
FROM [ODS].[AMR_Queue] AS queue_row
WHERE CONVERT(DATETIME2(3), queue_row.[enqueued_at]) >= @window_start
  AND CONVERT(DATETIME2(3), queue_row.[enqueued_at]) < @database_now;

/* 4. Current DWD event coverage: a gap here must be repaired before DWS serves hourly utilization. */
SELECT
    @window_start AS [window_start],
    @database_now AS [window_end],
    COUNT_BIG(*) AS [ods_started_tasks],
    SUM(CASE WHEN start_event.[operation_event_fact_id] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [dwd_start_event_rows],
    SUM(CASE WHEN start_event.[operation_event_fact_id] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [missing_dwd_start_event_rows],
    SUM(CASE WHEN task_row.[end_time] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [ods_ended_tasks],
    SUM(CASE WHEN task_row.[end_time] IS NOT NULL AND end_event.[operation_event_fact_id] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [dwd_end_event_rows],
    SUM(CASE WHEN task_row.[end_time] IS NOT NULL AND end_event.[operation_event_fact_id] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [missing_dwd_end_event_rows]
FROM [ODS].[TA_AMR] AS task_row
LEFT JOIN [DWD].[fact_robot_operation_event] AS start_event
    ON start_event.[source_schema] = N'ODS'
   AND start_event.[source_table] = N'TA_AMR'
   AND start_event.[source_ods_row_id] = task_row.[ods_row_id]
   AND start_event.[source_event_part] = N'START'
LEFT JOIN [DWD].[fact_robot_operation_event] AS end_event
    ON end_event.[source_schema] = N'ODS'
   AND end_event.[source_table] = N'TA_AMR'
   AND end_event.[source_ods_row_id] = task_row.[ods_row_id]
   AND end_event.[source_event_part] = N'END'
WHERE CONVERT(DATETIME2(3), COALESCE(task_row.[end_time], task_row.[start_time])) >= @window_start
  AND CONVERT(DATETIME2(3), COALESCE(task_row.[end_time], task_row.[start_time])) < @database_now;

/* 5. Charging-source coverage is evidence only: sampled intervals must not be treated as continuous time without the DWS interval logic. */
SELECT
    @window_start AS [window_start],
    @database_now AS [window_end],
    COUNT_BIG(*) AS [battery_sample_rows],
    SUM(CASE WHEN battery_row.[charging_status] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [classified_battery_sample_rows],
    SUM(CASE WHEN UPPER(LTRIM(RTRIM(COALESCE(battery_row.[charging_status], N'')))) = N'CHARGING' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [charging_sample_rows],
    COUNT_BIG(DISTINCT battery_row.[robot_code]) AS [robots_with_battery_samples],
    MIN(battery_row.[sample_time]) AS [first_battery_sample_time],
    MAX(battery_row.[sample_time]) AS [last_battery_sample_time]
FROM [DWD].[fact_robot_battery] AS battery_row
WHERE battery_row.[sample_time] >= @window_start
  AND battery_row.[sample_time] < @database_now;

/* 6. Required DWS serving tables. Their absence is expected until the Task Analytics mart is installed. */
SELECT
    required.[table_name],
    CASE WHEN OBJECT_ID(N'DWS.' + required.[table_name], N'U') IS NULL THEN N'NOT_INSTALLED' ELSE N'INSTALLED' END AS [dws_serving_status]
FROM (VALUES
    (N'dws_robot_task_hourly'),
    (N'dws_robot_calling_box_daily'),
    (N'dws_robot_assigned_task_daily')
) AS required([table_name])
ORDER BY required.[table_name];
