USE IOT2020;
GO

/*
    Diagnose why DWS.dws_robot_current_snapshot only has UNKNOWN / NULL values.

    Read-only script.
    It does not INSERT / UPDATE / DELETE / TRUNCATE / DROP any table.
*/

SET NOCOUNT ON;

SELECT
    N'01_dws_current_snapshot_profile' AS [check_section],
    COUNT_BIG(*) AS [row_count],
    COUNT_BIG(CASE WHEN [robot_code] IS NULL OR [robot_code] = N'' OR [robot_code] = N'UNKNOWN' THEN 1 END) AS [blank_or_unknown_robot_code_count],
    COUNT_BIG(CASE WHEN [robot_id] IS NULL OR [robot_id] = N'' THEN 1 END) AS [blank_robot_id_count],
    COUNT_BIG(CASE WHEN [robot_name] IS NULL OR [robot_name] = N'' THEN 1 END) AS [blank_robot_name_count],
    COUNT_BIG(CASE WHEN [current_status] IS NULL OR [current_status] = N'' THEN 1 END) AS [blank_current_status_count],
    COUNT_BIG(CASE WHEN [battery_soc] IS NULL THEN 1 END) AS [blank_battery_soc_count],
    MIN([source_snapshot_time]) AS [min_source_snapshot_time],
    MAX([source_snapshot_time]) AS [max_source_snapshot_time]
FROM [DWS].[dws_robot_current_snapshot];

SELECT TOP (50)
    N'02_dws_current_snapshot_sample' AS [check_section],
    [robot_code],
    [robot_id],
    [robot_name],
    [current_status],
    [current_mode],
    [online_status],
    [job_id],
    [subjob_id],
    [map_code],
    [station_code],
    [position_x],
    [position_y],
    [position_theta],
    [speed_mps],
    [battery_soc],
    [error_code],
    [source_event_time],
    [source_snapshot_time],
    [dws_load_time],
    [dws_batch_id]
FROM [DWS].[dws_robot_current_snapshot]
ORDER BY
    [robot_code];

SELECT
    N'03_dwd_snap_profile' AS [check_section],
    COUNT_BIG(*) AS [row_count],
    COUNT_BIG(CASE WHEN [robot_code] IS NULL OR [robot_code] = N'' THEN 1 END) AS [blank_robot_code_count],
    COUNT_BIG(CASE WHEN [robot_id] IS NULL OR [robot_id] = N'' THEN 1 END) AS [blank_robot_id_count],
    COUNT_BIG(CASE WHEN [robot_name] IS NULL OR [robot_name] = N'' THEN 1 END) AS [blank_robot_name_count],
    COUNT_BIG(CASE WHEN [current_status] IS NULL OR [current_status] = N'' THEN 1 END) AS [blank_current_status_count],
    COUNT_BIG(CASE WHEN [battery_soc] IS NULL THEN 1 END) AS [blank_battery_soc_count],
    MIN([snapshot_time]) AS [min_snapshot_time],
    MAX([snapshot_time]) AS [max_snapshot_time]
FROM [DWD].[snap_amr_current_status];

SELECT TOP (100)
    N'04_dwd_snap_sample' AS [check_section],
    [snapshot_id],
    [robot_code],
    [robot_id],
    [robot_name],
    [current_status],
    [current_mode],
    [online_status],
    [job_id],
    [subjob_id],
    [map_code],
    [station_code],
    [position_x],
    [position_y],
    [position_theta],
    [speed_mps],
    [battery_soc],
    [error_code],
    [source_event_time],
    [snapshot_time],
    [source_table],
    [source_ods_row_id],
    [dwd_batch_id]
FROM [DWD].[snap_amr_current_status]
ORDER BY
    [snapshot_id];

SELECT
    N'05_dwd_snap_by_source_table' AS [check_section],
    [source_table],
    COUNT_BIG(*) AS [row_count],
    COUNT_BIG(CASE WHEN [robot_code] IS NULL OR [robot_code] = N'' THEN 1 END) AS [blank_robot_code_count],
    COUNT_BIG(CASE WHEN [robot_id] IS NULL OR [robot_id] = N'' THEN 1 END) AS [blank_robot_id_count],
    COUNT_BIG(CASE WHEN [current_status] IS NULL OR [current_status] = N'' THEN 1 END) AS [blank_current_status_count],
    COUNT_BIG(CASE WHEN [battery_soc] IS NULL THEN 1 END) AS [blank_battery_soc_count],
    MIN([snapshot_time]) AS [min_snapshot_time],
    MAX([snapshot_time]) AS [max_snapshot_time]
FROM [DWD].[snap_amr_current_status]
GROUP BY
    [source_table]
ORDER BY
    [source_table];

SELECT
    N'06_ods_currentdata_profile' AS [check_section],
    COUNT_BIG(*) AS [row_count],
    MIN([ods_row_id]) AS [min_ods_row_id],
    MAX([ods_row_id]) AS [max_ods_row_id],
    MIN([ods_load_time]) AS [min_ods_load_time],
    MAX([ods_load_time]) AS [max_ods_load_time]
FROM [ODS].[AMR_Currentdata];

SELECT
    N'07_ods_robot_mode_profile' AS [check_section],
    COUNT_BIG(*) AS [row_count],
    MIN([ods_row_id]) AS [min_ods_row_id],
    MAX([ods_row_id]) AS [max_ods_row_id],
    MIN([ods_load_time]) AS [min_ods_load_time],
    MAX([ods_load_time]) AS [max_ods_load_time]
FROM [ODS].[AMR_Robot_Mode];

SELECT
    N'08_ods_currentdata_columns' AS [check_section],
    c.[column_id],
    c.[name] AS [column_name],
    ty.[name] AS [data_type],
    c.[max_length],
    c.[precision],
    c.[scale],
    c.[is_nullable]
FROM sys.columns AS c
JOIN sys.types AS ty
    ON ty.[user_type_id] = c.[user_type_id]
WHERE c.[object_id] = OBJECT_ID(N'[ODS].[AMR_Currentdata]', N'U')
ORDER BY
    c.[column_id];

SELECT
    N'09_ods_robot_mode_columns' AS [check_section],
    c.[column_id],
    c.[name] AS [column_name],
    ty.[name] AS [data_type],
    c.[max_length],
    c.[precision],
    c.[scale],
    c.[is_nullable]
FROM sys.columns AS c
JOIN sys.types AS ty
    ON ty.[user_type_id] = c.[user_type_id]
WHERE c.[object_id] = OBJECT_ID(N'[ODS].[AMR_Robot_Mode]', N'U')
ORDER BY
    c.[column_id];
GO
