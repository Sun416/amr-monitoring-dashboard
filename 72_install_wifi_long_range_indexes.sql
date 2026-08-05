USE [IOT2020];
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET LOCK_TIMEOUT 60000;

/*
Installs the two indexes required by the Web running-task WiFi analysis.

No business rows are changed. Index creation can consume storage, CPU, I/O and
transaction-log space. The script is idempotent by index name.
*/

IF OBJECT_ID(N'[ODS].[robot_job_history]', N'U') IS NULL
    THROW 50001, N'ODS.robot_job_history does not exist.', 1;

IF OBJECT_ID(N'[ODS].[robot_wifi_history]', N'U') IS NULL
    THROW 50002, N'ODS.robot_wifi_history does not exist.', 1;

IF COL_LENGTH(N'ODS.robot_job_history', N'amr_id') IS NULL
   OR COL_LENGTH(N'ODS.robot_job_history', N'pc_timestamp') IS NULL
   OR COL_LENGTH(N'ODS.robot_job_history', N'job_status') IS NULL
   OR COL_LENGTH(N'ODS.robot_job_history', N'poi_target') IS NULL
    THROW 50003, N'ODS.robot_job_history is missing a required analysis column.', 1;

IF COL_LENGTH(N'ODS.robot_wifi_history', N'amr_id') IS NULL
   OR COL_LENGTH(N'ODS.robot_wifi_history', N'pc_timestamp') IS NULL
   OR COL_LENGTH(N'ODS.robot_wifi_history', N'wifi_signal_level') IS NULL
    THROW 50004, N'ODS.robot_wifi_history is missing a required analysis column.', 1;

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes AS index_info
    WHERE index_info.[object_id] = OBJECT_ID(N'[ODS].[robot_job_history]')
      AND index_info.[name] = N'IX_ODS_robot_job_history_running_amr_time'
)
BEGIN
    CREATE NONCLUSTERED INDEX [IX_ODS_robot_job_history_running_amr_time]
        ON [ODS].[robot_job_history] ([amr_id], [pc_timestamp])
        INCLUDE ([poi_target])
        WHERE [job_status] = N'Running'
        WITH (MAXDOP = 2);
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes AS index_info
    WHERE index_info.[object_id] = OBJECT_ID(N'[ODS].[robot_wifi_history]')
      AND index_info.[name] = N'IX_ODS_robot_wifi_history_amr_time'
)
BEGIN
    CREATE NONCLUSTERED INDEX [IX_ODS_robot_wifi_history_amr_time]
        ON [ODS].[robot_wifi_history] ([amr_id], [pc_timestamp])
        INCLUDE ([wifi_signal_level])
        WITH (MAXDOP = 2);
END;

SELECT
    schema_info.[name] AS [schema_name],
    object_info.[name] AS [table_name],
    index_info.[name] AS [index_name],
    index_info.[type_desc],
    index_info.[has_filter],
    index_info.[filter_definition],
    index_info.[is_disabled]
FROM sys.indexes AS index_info
INNER JOIN sys.objects AS object_info
    ON object_info.[object_id] = index_info.[object_id]
INNER JOIN sys.schemas AS schema_info
    ON schema_info.[schema_id] = object_info.[schema_id]
WHERE schema_info.[name] = N'ODS'
  AND (
      (
          object_info.[name] = N'robot_job_history'
          AND index_info.[name] = N'IX_ODS_robot_job_history_running_amr_time'
      )
      OR
      (
          object_info.[name] = N'robot_wifi_history'
          AND index_info.[name] = N'IX_ODS_robot_wifi_history_amr_time'
      )
  )
ORDER BY object_info.[name];

