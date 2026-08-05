USE [IOT2020];

/*
    Read-only audit of the task-analysis time axis.

    Purpose
      1. Confirm the raw timestamp types retained in dbo and ODS.
      2. Compare ODS.TA_AMR UTC instants with the current DWD naive values.
      3. Confirm whether the queue and task event facts share the same
         seven-hour error before changing DWS hourly buckets.

    No source, ODS, DWD, or DWS rows are changed by this script.
*/

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

/* A. Timestamp contract inventory. */
SELECT
    schema_row.[name] AS [schema_name],
    table_row.[name] AS [table_name],
    column_row.[name] AS [column_name],
    type_row.[name] AS [data_type],
    column_row.[scale]
FROM sys.columns AS column_row
INNER JOIN sys.tables AS table_row
    ON table_row.[object_id] = column_row.[object_id]
INNER JOIN sys.schemas AS schema_row
    ON schema_row.[schema_id] = table_row.[schema_id]
INNER JOIN sys.types AS type_row
    ON type_row.[user_type_id] = column_row.[user_type_id]
WHERE
(
    schema_row.[name] IN (N'dbo', N'ODS')
    AND table_row.[name] IN (N'AMR_Queue', N'TA_AMR')
    AND column_row.[name] IN (N'enqueued_at', N'start_time', N'end_time')
)
OR
(
    schema_row.[name] = N'DWD'
    AND table_row.[name] = N'fact_amr_queue'
    AND column_row.[name] IN (N'event_time', N'queue_start_time')
)
OR
(
    schema_row.[name] = N'DWD'
    AND table_row.[name] = N'fact_robot_operation_event'
    AND column_row.[name] IN (N'event_time', N'source_event_time')
)
ORDER BY schema_row.[name], table_row.[name], column_row.[column_id];

/* B. Current operational-event source composition. */
SELECT
    event_row.[source_schema],
    event_row.[source_table],
    event_row.[source_event_part],
    COUNT_BIG(1) AS [event_rows],
    CONVERT(NVARCHAR(23), MIN(event_row.[event_time]), 121) AS [first_dwd_wall_clock],
    CONVERT(NVARCHAR(23), MAX(event_row.[event_time]), 121) AS [last_dwd_wall_clock]
FROM [DWD].[fact_robot_operation_event] AS event_row
WHERE event_row.[source_schema] = N'ODS'
  AND event_row.[source_table] IN (N'AMR_Queue', N'TA_AMR')
GROUP BY
    event_row.[source_schema],
    event_row.[source_table],
    event_row.[source_event_part]
ORDER BY event_row.[source_table], event_row.[source_event_part];

/*
   C. TA_AMR source-to-DWD comparison.
   SWITCHOFFSET converts an offset-aware source instant to Thailand (+07:00).
   The DATEDIFF value is compared against the corresponding DWD wall clock.
*/
SELECT TOP (30)
    task_row.[ods_row_id],
    task_row.[id] AS [ta_amr_id],
    task_row.[queue_id],
    task_row.[AMR_id],
    N'START' AS [event_part],
    CONVERT(NVARCHAR(33), task_row.[start_time], 127) AS [source_timestamp_with_offset],
    DATENAME(TZOFFSET, task_row.[start_time]) AS [source_offset],
    CONVERT(NVARCHAR(23), CONVERT(DATETIME2(3), SWITCHOFFSET(task_row.[start_time], N'+07:00')), 121) AS [expected_thailand_wall_clock],
    DATENAME(TZOFFSET, SWITCHOFFSET(task_row.[start_time], N'+07:00')) AS [expected_thailand_offset],
    CONVERT(NVARCHAR(23), event_row.[event_time], 121) AS [current_dwd_wall_clock],
    DATEDIFF(MINUTE, CONVERT(DATETIME2(3), SWITCHOFFSET(task_row.[start_time], N'+07:00')), event_row.[event_time]) AS [dwd_minus_expected_th_minutes]
FROM [ODS].[TA_AMR] AS task_row
INNER JOIN [DWD].[fact_robot_operation_event] AS event_row
    ON event_row.[source_schema] = N'ODS'
   AND event_row.[source_table] = N'TA_AMR'
   AND event_row.[source_ods_row_id] = task_row.[ods_row_id]
   AND event_row.[source_event_part] = N'START'
WHERE task_row.[start_time] IS NOT NULL
ORDER BY task_row.[ods_row_id] DESC;

SELECT TOP (30)
    task_row.[ods_row_id],
    task_row.[id] AS [ta_amr_id],
    task_row.[queue_id],
    task_row.[AMR_id],
    N'END' AS [event_part],
    CONVERT(NVARCHAR(33), task_row.[end_time], 127) AS [source_timestamp_with_offset],
    DATENAME(TZOFFSET, task_row.[end_time]) AS [source_offset],
    CONVERT(NVARCHAR(23), CONVERT(DATETIME2(3), SWITCHOFFSET(task_row.[end_time], N'+07:00')), 121) AS [expected_thailand_wall_clock],
    DATENAME(TZOFFSET, SWITCHOFFSET(task_row.[end_time], N'+07:00')) AS [expected_thailand_offset],
    CONVERT(NVARCHAR(23), event_row.[event_time], 121) AS [current_dwd_wall_clock],
    DATEDIFF(MINUTE, CONVERT(DATETIME2(3), SWITCHOFFSET(task_row.[end_time], N'+07:00')), event_row.[event_time]) AS [dwd_minus_expected_th_minutes]
FROM [ODS].[TA_AMR] AS task_row
INNER JOIN [DWD].[fact_robot_operation_event] AS event_row
    ON event_row.[source_schema] = N'ODS'
   AND event_row.[source_table] = N'TA_AMR'
   AND event_row.[source_ods_row_id] = task_row.[ods_row_id]
   AND event_row.[source_event_part] = N'END'
WHERE task_row.[end_time] IS NOT NULL
ORDER BY task_row.[ods_row_id] DESC;

/* D. Aggregate evidence, avoiding any dependency on driver-side date serialization. */
SELECT
    COUNT_BIG(1) AS [comparable_start_events],
    SUM(CASE WHEN DATEDIFF(MINUTE, CONVERT(DATETIME2(3), SWITCHOFFSET(task_row.[start_time], N'+07:00')), event_row.[event_time]) = -420
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [dwd_seven_hours_behind_thailand_count],
    SUM(CASE WHEN DATEDIFF(MINUTE, CONVERT(DATETIME2(3), SWITCHOFFSET(task_row.[start_time], N'+07:00')), event_row.[event_time]) = 0
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [already_thailand_local_count]
FROM [ODS].[TA_AMR] AS task_row
INNER JOIN [DWD].[fact_robot_operation_event] AS event_row
    ON event_row.[source_schema] = N'ODS'
   AND event_row.[source_table] = N'TA_AMR'
   AND event_row.[source_ods_row_id] = task_row.[ods_row_id]
   AND event_row.[source_event_part] = N'START'
WHERE task_row.[start_time] IS NOT NULL;

/* E. Queue-to-task elapsed time in the current DWD clock, for a direct sanity check. */
SELECT TOP (30)
    queue_fact.[queue_id],
    task_event.[robot_code],
    CONVERT(NVARCHAR(23), queue_fact.[queue_start_time], 121) AS [queue_dwd_wall_clock],
    CONVERT(NVARCHAR(23), task_event.[event_time], 121) AS [task_start_dwd_wall_clock],
    DATEDIFF(SECOND, queue_fact.[queue_start_time], task_event.[event_time]) AS [current_dwd_wait_seconds]
FROM [DWD].[fact_amr_queue] AS queue_fact
INNER JOIN [DWD].[fact_robot_operation_event] AS task_event
    ON task_event.[source_schema] = N'ODS'
   AND task_event.[source_table] = N'TA_AMR'
   AND task_event.[source_event_part] = N'START'
   AND task_event.[queue_id] = queue_fact.[queue_id]
WHERE queue_fact.[queue_start_time] IS NOT NULL
  AND task_event.[event_time] >= queue_fact.[queue_start_time]
ORDER BY task_event.[event_time] DESC;
