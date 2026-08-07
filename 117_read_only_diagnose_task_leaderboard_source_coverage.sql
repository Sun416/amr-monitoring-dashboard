USE [IOT2020];

/*
    Read-only diagnosis: Task Analytics leaderboard source coverage.

    Compares DWD.fact_amr_queue (the serving source for Calling Box and
    Assigned-task leaderboards) with dbo.AMR_Queue for the robots that have
    execution-trend data but no rows in the DWS hourly leaderboards.
*/

SET NOCOUNT ON;

/* 1. Column inventory for the two queue layers. */
SELECT
    N'DWD.fact_amr_queue' AS [object_name],
    c.[name] AS [column_name],
    ty.[name] AS [data_type],
    c.[max_length],
    c.[precision],
    c.[scale]
FROM [sys].[columns] AS c
INNER JOIN [sys].[tables] AS t
    ON t.[object_id] = c.[object_id]
INNER JOIN [sys].[schemas] AS s
    ON s.[schema_id] = t.[schema_id]
INNER JOIN [sys].[types] AS ty
    ON ty.[user_type_id] = c.[user_type_id]
WHERE s.[name] = N'DWD'
  AND t.[name] = N'fact_amr_queue'
ORDER BY c.[column_id];

SELECT
    N'dbo.AMR_Queue' AS [object_name],
    c.[name] AS [column_name],
    ty.[name] AS [data_type],
    c.[max_length],
    c.[precision],
    c.[scale]
FROM [sys].[columns] AS c
INNER JOIN [sys].[tables] AS t
    ON t.[object_id] = c.[object_id]
INNER JOIN [sys].[schemas] AS s
    ON s.[schema_id] = t.[schema_id]
INNER JOIN [sys].[types] AS ty
    ON ty.[user_type_id] = c.[user_type_id]
WHERE s.[name] = N'dbo'
  AND t.[name] = N'AMR_Queue'
ORDER BY c.[column_id];

/* 2. Per-robot DWD queue coverage for the last 30 days. */
SELECT
    queue_fact.[robot_code],
    MAX(queue_fact.[robot_id]) AS [robot_id],
    COUNT_BIG(1) AS [queue_row_count],
    SUM(CASE WHEN queue_fact.[calling_box_id] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [with_calling_box],
    SUM(CASE WHEN TRY_CONVERT(INT, queue_fact.[job_id]) IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [with_job],
    CONVERT(NVARCHAR(19), MIN(queue_fact.[event_time]), 120) AS [first_event_time],
    CONVERT(NVARCHAR(19), MAX(queue_fact.[event_time]), 120) AS [last_event_time],
    MIN(queue_fact.[dwd_batch_id]) AS [min_dwd_batch],
    MAX(queue_fact.[dwd_batch_id]) AS [max_dwd_batch]
FROM [DWD].[fact_amr_queue] AS queue_fact
WHERE queue_fact.[event_time] >= DATEADD(DAY, -30, SYSDATETIME())
GROUP BY queue_fact.[robot_code]
ORDER BY queue_fact.[robot_code];

/* 3. Source-side dbo.AMR_Queue rows per robot for the last 30 days. */
SELECT
    queue_source.[AMR_id],
    master_amr.[name] AS [robot_name],
    COUNT_BIG(1) AS [source_row_count],
    SUM(CASE WHEN queue_source.[esp_button_id] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [with_esp_button],
    CONVERT(NVARCHAR(19), MIN(queue_source.[enqueued_at]), 120) AS [first_enqueued_at],
    CONVERT(NVARCHAR(19), MAX(queue_source.[enqueued_at]), 120) AS [last_enqueued_at]
FROM [dbo].[AMR_Queue] AS queue_source
LEFT JOIN [dbo].[MA_AMR] AS master_amr
    ON master_amr.[id] = queue_source.[AMR_id]
WHERE queue_source.[enqueued_at] >= DATEADD(DAY, -30, SYSDATETIME())
GROUP BY queue_source.[AMR_id], master_amr.[name]
ORDER BY queue_source.[AMR_id];
