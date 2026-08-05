USE [IOT2020];
SET NOCOUNT ON;

/*
Read-only precheck for the ODS indexes required by the 7-day and 30-day
running-task WiFi analysis.
*/

SELECT
    CONVERT(NVARCHAR(128), SERVERPROPERTY(N'Edition')) AS [edition],
    CONVERT(INT, SERVERPROPERTY(N'EngineEdition')) AS [engine_edition],
    CONVERT(NVARCHAR(128), SERVERPROPERTY(N'ProductVersion')) AS [product_version],
    CONVERT(NVARCHAR(128), SERVERPROPERTY(N'ProductLevel')) AS [product_level],
    DB_NAME() AS [database_name],
    CAST(DATABASEPROPERTYEX(DB_NAME(), N'Updateability') AS NVARCHAR(128)) AS [updateability];

SELECT
    database_file.[file_id],
    database_file.[name] AS [logical_file_name],
    database_file.[type_desc],
    CAST(database_file.[size] * 8.0 / 1024 AS DECIMAL(18, 2)) AS [allocated_mb],
    CAST(
        CASE
            WHEN database_file.[type_desc] = N'ROWS'
                THEN FILEPROPERTY(database_file.[name], N'SpaceUsed') * 8.0 / 1024
            ELSE NULL
        END
        AS DECIMAL(18, 2)
    ) AS [used_mb],
    CAST(
        CASE
            WHEN database_file.[type_desc] = N'ROWS'
                THEN (
                    database_file.[size] - FILEPROPERTY(database_file.[name], N'SpaceUsed')
                ) * 8.0 / 1024
            ELSE NULL
        END
        AS DECIMAL(18, 2)
    ) AS [free_inside_file_mb],
    database_file.[growth],
    database_file.[is_percent_growth],
    database_file.[max_size]
FROM sys.database_files AS database_file
ORDER BY database_file.[file_id];

SELECT
    database_file.[file_id],
    database_file.[name] AS [logical_file_name],
    database_file.[physical_name],
    volume_stats.[volume_mount_point],
    CAST(volume_stats.[total_bytes] / 1073741824.0 AS DECIMAL(18, 2)) AS [volume_total_gb],
    CAST(volume_stats.[available_bytes] / 1073741824.0 AS DECIMAL(18, 2)) AS [volume_available_gb],
    CAST(
        100.0 * volume_stats.[available_bytes] / NULLIF(volume_stats.[total_bytes], 0)
        AS DECIMAL(9, 2)
    ) AS [volume_available_percent]
FROM sys.database_files AS database_file
CROSS APPLY sys.dm_os_volume_stats(DB_ID(), database_file.[file_id]) AS volume_stats
ORDER BY database_file.[file_id];

SELECT
    CAST(log_space.[total_log_size_in_bytes] / 1073741824.0 AS DECIMAL(18, 2)) AS [total_log_size_gb],
    CAST(log_space.[used_log_space_in_bytes] / 1073741824.0 AS DECIMAL(18, 2)) AS [used_log_space_gb],
    CAST(log_space.[used_log_space_in_percent] AS DECIMAL(9, 2)) AS [used_log_space_percent]
FROM sys.dm_db_log_space_usage AS log_space;

;WITH table_rows AS (
    SELECT
        partition_stats.[object_id],
        SUM(partition_stats.[row_count]) AS [row_count],
        SUM(partition_stats.[reserved_page_count]) * 8.0 / 1024 AS [reserved_mb]
    FROM sys.dm_db_partition_stats AS partition_stats
    WHERE partition_stats.[index_id] IN (0, 1)
    GROUP BY partition_stats.[object_id]
)
SELECT
    schema_info.[name] AS [schema_name],
    object_info.[name] AS [table_name],
    table_rows.[row_count],
    CAST(table_rows.[reserved_mb] AS DECIMAL(18, 2)) AS [table_reserved_mb]
FROM sys.objects AS object_info
INNER JOIN sys.schemas AS schema_info
    ON schema_info.[schema_id] = object_info.[schema_id]
INNER JOIN table_rows
    ON table_rows.[object_id] = object_info.[object_id]
WHERE schema_info.[name] = N'ODS'
  AND object_info.[name] IN (N'robot_job_history', N'robot_wifi_history')
ORDER BY object_info.[name];

SELECT
    schema_info.[name] AS [schema_name],
    object_info.[name] AS [table_name],
    index_info.[index_id],
    index_info.[name] AS [index_name],
    index_info.[type_desc],
    index_info.[is_unique],
    index_info.[has_filter],
    index_info.[filter_definition],
    index_column.[key_ordinal],
    index_column.[is_included_column],
    column_info.[name] AS [column_name]
FROM sys.objects AS object_info
INNER JOIN sys.schemas AS schema_info
    ON schema_info.[schema_id] = object_info.[schema_id]
INNER JOIN sys.indexes AS index_info
    ON index_info.[object_id] = object_info.[object_id]
INNER JOIN sys.index_columns AS index_column
    ON index_column.[object_id] = index_info.[object_id]
   AND index_column.[index_id] = index_info.[index_id]
INNER JOIN sys.columns AS column_info
    ON column_info.[object_id] = index_column.[object_id]
   AND column_info.[column_id] = index_column.[column_id]
WHERE schema_info.[name] = N'ODS'
  AND object_info.[name] IN (N'robot_job_history', N'robot_wifi_history')
ORDER BY
    object_info.[name],
    index_info.[index_id],
    index_column.[is_included_column],
    index_column.[key_ordinal],
    index_column.[index_column_id];
