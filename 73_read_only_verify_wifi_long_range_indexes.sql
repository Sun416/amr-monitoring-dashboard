USE [IOT2020];
SET NOCOUNT ON;

/*
Read-only verification for the two long-range WiFi analysis indexes.
*/

SELECT
    schema_info.[name] AS [schema_name],
    object_info.[name] AS [table_name],
    index_info.[index_id],
    index_info.[name] AS [index_name],
    index_info.[type_desc],
    index_info.[has_filter],
    index_info.[filter_definition],
    index_info.[is_disabled],
    index_column.[key_ordinal],
    index_column.[is_included_column],
    column_info.[name] AS [column_name]
FROM sys.indexes AS index_info
INNER JOIN sys.objects AS object_info
    ON object_info.[object_id] = index_info.[object_id]
INNER JOIN sys.schemas AS schema_info
    ON schema_info.[schema_id] = object_info.[schema_id]
INNER JOIN sys.index_columns AS index_column
    ON index_column.[object_id] = index_info.[object_id]
   AND index_column.[index_id] = index_info.[index_id]
INNER JOIN sys.columns AS column_info
    ON column_info.[object_id] = index_column.[object_id]
   AND column_info.[column_id] = index_column.[column_id]
WHERE schema_info.[name] = N'ODS'
  AND index_info.[name] IN (
      N'IX_ODS_robot_job_history_running_amr_time',
      N'IX_ODS_robot_wifi_history_amr_time'
  )
ORDER BY
    object_info.[name],
    index_info.[index_id],
    index_column.[is_included_column],
    index_column.[key_ordinal],
    index_column.[index_column_id];

SELECT
    schema_info.[name] AS [schema_name],
    object_info.[name] AS [table_name],
    index_info.[name] AS [index_name],
    SUM(partition_stats.[row_count]) AS [index_row_count],
    CAST(
        SUM(partition_stats.[reserved_page_count]) * 8.0 / 1024
        AS DECIMAL(18, 2)
    ) AS [reserved_mb]
FROM sys.indexes AS index_info
INNER JOIN sys.objects AS object_info
    ON object_info.[object_id] = index_info.[object_id]
INNER JOIN sys.schemas AS schema_info
    ON schema_info.[schema_id] = object_info.[schema_id]
INNER JOIN sys.dm_db_partition_stats AS partition_stats
    ON partition_stats.[object_id] = index_info.[object_id]
   AND partition_stats.[index_id] = index_info.[index_id]
WHERE schema_info.[name] = N'ODS'
  AND index_info.[name] IN (
      N'IX_ODS_robot_job_history_running_amr_time',
      N'IX_ODS_robot_wifi_history_amr_time'
  )
GROUP BY
    schema_info.[name],
    object_info.[name],
    index_info.[name]
ORDER BY object_info.[name];

