USE [IOT2020];
SET NOCOUNT ON;

/*
Read-only fallback for SQL Server volume free space when VIEW SERVER STATE is
not granted to the Web database login.
*/

SELECT
    database_file.[file_id],
    database_file.[name] AS [logical_file_name],
    database_file.[type_desc],
    database_file.[physical_name]
FROM sys.database_files AS database_file
ORDER BY database_file.[file_id];

SELECT
    database_info.[name] AS [database_name],
    database_info.[recovery_model_desc],
    database_info.[log_reuse_wait_desc],
    HAS_PERMS_BY_NAME(N'ODS.robot_job_history', N'OBJECT', N'ALTER') AS [can_alter_job_history],
    HAS_PERMS_BY_NAME(N'ODS.robot_wifi_history', N'OBJECT', N'ALTER') AS [can_alter_wifi_history],
    HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'VIEW DATABASE STATE') AS [can_view_database_state],
    HAS_PERMS_BY_NAME(NULL, NULL, N'VIEW SERVER STATE') AS [can_view_server_state]
FROM sys.databases AS database_info
WHERE database_info.[database_id] = DB_ID();

EXEC [master].[dbo].[xp_fixeddrives];
