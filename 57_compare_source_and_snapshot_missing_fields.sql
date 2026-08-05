USE [IOT2020];

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

WITH field_comparison AS
(
    SELECT
        master_robot.[id] AS [master_robot_id],
        master_robot.[name] AS [robot_code],
        status_row.[pc_timestamp] AS [source_status_time],
        NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), status_row.[robot_move_state]))), N''), N'-') AS [source_status],
        snapshot_row.[current_status] AS [snapshot_status],
        NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), status_row.[robot_current_map]))), N''), N'-') AS [source_map],
        snapshot_row.[map_code] AS [snapshot_map],
        battery_row.[pc_timestamp] AS [source_battery_time],
        TRY_CONVERT(DECIMAL(9,4), battery_row.[batt_level]) AS [source_battery_soc],
        snapshot_row.[battery_soc] AS [snapshot_battery_soc],
        wifi_row.[pc_timestamp] AS [source_wifi_time],
        wifi_row.[wifi_signal_level] AS [source_rssi],
        NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(200), wifi_row.[wifi_ap_connected]))), N''), N'-') AS [source_wifi_ap],
        snapshot_row.[dws_load_time] AS [snapshot_load_time]
    FROM [dbo].[MA_AMR] AS master_robot
    LEFT JOIN [DWS].[dws_robot_current_snapshot] AS snapshot_row
        ON snapshot_row.[robot_code] = master_robot.[name]
    OUTER APPLY
    (
        SELECT TOP (1)
            status_history.[pc_timestamp],
            status_history.[robot_move_state],
            status_history.[robot_current_map]
        FROM [dbo].[robot_status_history] AS status_history
            WITH (INDEX([IX_status_performance]), FORCESEEK)
        WHERE status_history.[amr_id] = master_robot.[id]
        ORDER BY status_history.[pc_timestamp] DESC
    ) AS status_row
    OUTER APPLY
    (
        SELECT TOP (1)
            battery_history.[pc_timestamp],
            battery_history.[batt_level]
        FROM [dbo].[robot_battery_history] AS battery_history
            WITH (INDEX([IX_battery_performance]), FORCESEEK)
        WHERE battery_history.[amr_id] = master_robot.[id]
        ORDER BY battery_history.[pc_timestamp] DESC
    ) AS battery_row
    OUTER APPLY
    (
        SELECT TOP (1)
            wifi_history.[pc_timestamp],
            wifi_history.[wifi_signal_level],
            wifi_history.[wifi_ap_connected]
        FROM [dbo].[robot_wifi_history] AS wifi_history
            WITH (INDEX([IX_wifi_performance]), FORCESEEK)
        WHERE wifi_history.[amr_id] = master_robot.[id]
        ORDER BY wifi_history.[pc_timestamp] DESC
    ) AS wifi_row
    WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y'
)
SELECT
    comparison.[master_robot_id],
    comparison.[robot_code],
    comparison.[source_status_time],
    comparison.[source_status],
    comparison.[snapshot_status],
    CASE
        WHEN comparison.[source_status] IS NULL AND comparison.[snapshot_status] IS NULL THEN N'SOURCE_NULL'
        WHEN comparison.[source_status] IS NOT NULL AND comparison.[snapshot_status] IS NULL THEN N'PIPELINE_LOSS'
        WHEN COALESCE(comparison.[source_status], N'') <> COALESCE(comparison.[snapshot_status], N'') THEN N'TRANSFORM_MISMATCH'
        ELSE N'OK'
    END AS [status_diagnosis],
    comparison.[source_map],
    comparison.[snapshot_map],
    CASE
        WHEN comparison.[source_map] IS NULL AND comparison.[snapshot_map] IS NULL THEN N'SOURCE_NULL'
        WHEN comparison.[source_map] IS NOT NULL AND comparison.[snapshot_map] IS NULL THEN N'PIPELINE_LOSS'
        WHEN COALESCE(comparison.[source_map], N'') <> COALESCE(comparison.[snapshot_map], N'') THEN N'TRANSFORM_MISMATCH'
        ELSE N'OK'
    END AS [map_diagnosis],
    comparison.[source_battery_time],
    comparison.[source_battery_soc],
    comparison.[snapshot_battery_soc],
    CASE
        WHEN comparison.[source_battery_soc] IS NULL AND comparison.[snapshot_battery_soc] IS NULL THEN N'SOURCE_NULL'
        WHEN comparison.[source_battery_soc] IS NOT NULL AND comparison.[snapshot_battery_soc] IS NULL THEN N'PIPELINE_LOSS'
        WHEN comparison.[source_battery_soc] <> comparison.[snapshot_battery_soc] THEN N'TRANSFORM_MISMATCH'
        ELSE N'OK'
    END AS [battery_diagnosis],
    comparison.[source_wifi_time],
    comparison.[source_rssi],
    comparison.[source_wifi_ap],
    CASE
        WHEN comparison.[source_wifi_ap] IS NULL THEN N'SOURCE_NULL'
        ELSE N'OK'
    END AS [wifi_ap_diagnosis],
    comparison.[snapshot_load_time]
FROM field_comparison AS comparison
WHERE comparison.[source_status] IS NULL
   OR comparison.[snapshot_status] IS NULL
   OR comparison.[source_map] IS NULL
   OR comparison.[snapshot_map] IS NULL
   OR comparison.[source_battery_soc] IS NULL
   OR comparison.[snapshot_battery_soc] IS NULL
   OR comparison.[source_wifi_ap] IS NULL
   OR COALESCE(comparison.[source_status], N'') <> COALESCE(comparison.[snapshot_status], N'')
   OR COALESCE(comparison.[source_map], N'') <> COALESCE(comparison.[snapshot_map], N'')
   OR comparison.[source_battery_soc] <> comparison.[snapshot_battery_soc]
ORDER BY comparison.[robot_code];
