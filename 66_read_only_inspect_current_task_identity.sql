USE [IOT2020];

/*
    Read-only inspection for the exact "current task ID" contract.

    This intentionally distinguishes:
    - robot_job_history.id: source telemetry row identity
    - robot_job_history.job_name: robot-reported job/command name
    - TA_AMR identifiers: business task identity

    No table, watermark, batch or monitoring state is changed.
*/

SELECT
    schema_source.[name] AS [schema_name],
    table_source.[name] AS [table_name],
    column_source.[column_id],
    column_source.[name] AS [column_name],
    type_source.[name] AS [data_type],
    column_source.[max_length],
    column_source.[is_nullable]
FROM sys.tables AS table_source
INNER JOIN sys.schemas AS schema_source
    ON schema_source.[schema_id] = table_source.[schema_id]
INNER JOIN sys.columns AS column_source
    ON column_source.[object_id] = table_source.[object_id]
INNER JOIN sys.types AS type_source
    ON type_source.[user_type_id] = column_source.[user_type_id]
WHERE schema_source.[name] = N'dbo'
  AND table_source.[name] IN (N'robot_job_history', N'TA_AMR')
ORDER BY
    table_source.[name],
    column_source.[column_id];

SELECT TOP (30)
    job_source.[id] AS [source_job_history_row_id],
    job_source.[amr_id],
    master_robot.[name] AS [robot_code],
    job_source.[job_name] AS [robot_reported_job_name],
    job_source.[job_status],
    job_source.[poi_current],
    job_source.[poi_target],
    job_source.[pc_timestamp]
FROM [dbo].[robot_job_history] AS job_source
LEFT JOIN [dbo].[MA_AMR] AS master_robot
    ON master_robot.[id] = job_source.[amr_id]
ORDER BY
    job_source.[pc_timestamp] DESC,
    job_source.[id] DESC;

SELECT
    task_source.[status],
    COUNT_BIG(*) AS [task_count],
    SUM(CASE WHEN task_source.[end_time] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [open_end_time_count]
FROM [dbo].[TA_AMR] AS task_source
GROUP BY task_source.[status]
ORDER BY [task_count] DESC;

SELECT TOP (30)
    task_source.[id] AS [business_task_id],
    task_source.[AMR_id] AS [master_robot_id],
    master_robot.[name] AS [robot_code],
    task_source.[queue_id],
    task_source.[job_id] AS [business_job_id],
    task_source.[subjob_id] AS [business_subjob_id],
    task_source.[status] AS [business_task_status],
    task_source.[start_time],
    task_source.[end_time],
    task_source.[created_at],
    task_source.[updated_at]
FROM [dbo].[TA_AMR] AS task_source
LEFT JOIN [dbo].[MA_AMR] AS master_robot
    ON master_robot.[id] = task_source.[AMR_id]
WHERE task_source.[end_time] IS NULL
ORDER BY
    COALESCE(task_source.[updated_at], task_source.[created_at], task_source.[start_time]) DESC,
    task_source.[id] DESC;

SELECT
    index_source.[name] AS [index_name],
    index_source.[type_desc],
    index_source.[is_unique],
    index_column.[key_ordinal],
    column_source.[name] AS [column_name],
    index_column.[is_included_column]
FROM sys.indexes AS index_source
INNER JOIN sys.index_columns AS index_column
    ON index_column.[object_id] = index_source.[object_id]
   AND index_column.[index_id] = index_source.[index_id]
INNER JOIN sys.columns AS column_source
    ON column_source.[object_id] = index_column.[object_id]
   AND column_source.[column_id] = index_column.[column_id]
WHERE index_source.[object_id] = OBJECT_ID(N'[dbo].[TA_AMR]')
ORDER BY
    index_source.[name],
    index_column.[key_ordinal],
    index_column.[index_column_id];
