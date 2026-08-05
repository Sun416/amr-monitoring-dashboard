USE [IOT2020];

/* Read-only index inventory before loading DWS task-state exception detail. */
SET NOCOUNT ON;

SELECT
    schema_row.[name] AS [schema_name],
    table_row.[name] AS [table_name],
    index_row.[name] AS [index_name],
    index_row.[type_desc]
FROM sys.indexes AS index_row
INNER JOIN sys.tables AS table_row
    ON table_row.[object_id] = index_row.[object_id]
INNER JOIN sys.schemas AS schema_row
    ON schema_row.[schema_id] = table_row.[schema_id]
WHERE
(
    schema_row.[name] = N'DWD'
    AND table_row.[name] IN (N'fact_robot_battery', N'fact_robot_operation_event')
)
OR
(
    schema_row.[name] = N'DWS'
    AND table_row.[name] = N'dws_robot_task_hourly'
)
ORDER BY
    schema_row.[name],
    table_row.[name],
    index_row.[index_id];

SELECT
    schema_row.[name] AS [schema_name],
    table_row.[name] AS [table_name],
    index_row.[name] AS [index_name],
    index_column.[key_ordinal],
    index_column.[is_included_column],
    column_row.[name] AS [column_name]
FROM sys.index_columns AS index_column
INNER JOIN sys.indexes AS index_row
    ON index_row.[object_id] = index_column.[object_id]
   AND index_row.[index_id] = index_column.[index_id]
INNER JOIN sys.tables AS table_row
    ON table_row.[object_id] = index_row.[object_id]
INNER JOIN sys.schemas AS schema_row
    ON schema_row.[schema_id] = table_row.[schema_id]
INNER JOIN sys.columns AS column_row
    ON column_row.[object_id] = index_column.[object_id]
   AND column_row.[column_id] = index_column.[column_id]
WHERE
(
    schema_row.[name] = N'DWD'
    AND table_row.[name] IN (N'fact_robot_battery', N'fact_robot_operation_event')
)
OR
(
    schema_row.[name] = N'DWS'
    AND table_row.[name] = N'dws_robot_task_hourly'
)
ORDER BY
    schema_row.[name],
    table_row.[name],
    index_row.[index_id],
    index_column.[key_ordinal],
    index_column.[index_column_id];

SELECT
    COUNT_BIG(*) AS [task_hour_count],
    SUM(CASE WHEN task_hour.[robot_id] IS NULL OR LTRIM(RTRIM(task_hour.[robot_id])) = N'' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [null_or_empty_robot_id_count],
    SUM(CASE WHEN task_hour.[data_unavailable_seconds] > 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [exception_hour_count]
FROM [DWS].[dws_robot_task_hourly] AS task_hour;
