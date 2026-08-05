USE [IOT2020];
SET NOCOUNT ON;

/*
Read-only capacity and retention profile for extending the running-task WiFi
analysis from 24 hours to 7 and 30 days.

This script only reads metadata and the first/latest rows through the clustered
ods_row_id keys. It does not scan or modify the full ODS history tables.
*/

;WITH table_rows AS (
    SELECT
        p.[object_id],
        SUM(p.[row_count]) AS [row_count]
    FROM sys.dm_db_partition_stats AS p
    WHERE p.[index_id] IN (0, 1)
    GROUP BY p.[object_id]
)
SELECT
    s.[name] AS [schema_name],
    o.[name] AS [table_name],
    tr.[row_count]
FROM sys.objects AS o
INNER JOIN sys.schemas AS s
    ON s.[schema_id] = o.[schema_id]
INNER JOIN table_rows AS tr
    ON tr.[object_id] = o.[object_id]
WHERE o.[type] = N'U'
  AND s.[name] = N'ODS'
  AND o.[name] IN (N'robot_job_history', N'robot_wifi_history')
ORDER BY o.[name];

SELECT
    N'robot_job_history' AS [table_name],
    first_row.[ods_row_id] AS [first_ods_row_id],
    first_row.[pc_timestamp] AS [first_event_time],
    first_row.[ods_load_time] AS [first_load_time],
    latest_row.[ods_row_id] AS [latest_ods_row_id],
    latest_row.[pc_timestamp] AS [latest_event_time],
    latest_row.[ods_load_time] AS [latest_load_time],
    DATEDIFF(DAY, first_row.[pc_timestamp], latest_row.[pc_timestamp]) AS [event_retention_days]
FROM (
    SELECT TOP (1)
        j.[ods_row_id],
        j.[pc_timestamp],
        j.[ods_load_time]
    FROM [ODS].[robot_job_history] AS j
    ORDER BY j.[ods_row_id]
) AS first_row
CROSS JOIN (
    SELECT TOP (1)
        j.[ods_row_id],
        j.[pc_timestamp],
        j.[ods_load_time]
    FROM [ODS].[robot_job_history] AS j
    ORDER BY j.[ods_row_id] DESC
) AS latest_row
UNION ALL
SELECT
    N'robot_wifi_history',
    first_row.[ods_row_id],
    first_row.[pc_timestamp],
    first_row.[ods_load_time],
    latest_row.[ods_row_id],
    latest_row.[pc_timestamp],
    latest_row.[ods_load_time],
    DATEDIFF(DAY, first_row.[pc_timestamp], latest_row.[pc_timestamp])
FROM (
    SELECT TOP (1)
        w.[ods_row_id],
        w.[pc_timestamp],
        w.[ods_load_time]
    FROM [ODS].[robot_wifi_history] AS w
    ORDER BY w.[ods_row_id]
) AS first_row
CROSS JOIN (
    SELECT TOP (1)
        w.[ods_row_id],
        w.[pc_timestamp],
        w.[ods_load_time]
    FROM [ODS].[robot_wifi_history] AS w
    ORDER BY w.[ods_row_id] DESC
) AS latest_row;

SELECT TOP (20)
    master_robot.[id] AS [master_robot_id],
    master_robot.[name] AS [robot_code],
    master_robot.[is_active]
FROM [dbo].[MA_AMR] AS master_robot
WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y'
ORDER BY master_robot.[name];

