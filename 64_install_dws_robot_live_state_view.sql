USE [IOT2020];
GO

/*
    Proposed non-persistent DWS live-state contract.

    Purpose
    -------
    Preserve exact current position, current robot state, robot-reported job,
    battery and WiFi fields without reading DWS.dws_robot_current_snapshot.

    Important task-identity boundary
    --------------------------------
    dbo.robot_job_history.job_name is a robot-reported job/command name, not a
    proven business task ID. The business task ID must be sourced separately
    from dbo.TA_AMR after its ID/status contract is confirmed.

    Design
    ------
    - The object is a normal view, not a stored snapshot table.
    - Every read performs bounded TOP (1) index seeks for the 19 active robots.
    - Values are returned only when the corresponding source event is no more
      than 10 minutes old. Stale values are returned as NULL.
    - Source timestamps remain visible so the Web can diagnose timeout causes.
    - DWS hourly/daily tables remain the source for trends and historical analysis.

    Required existing indexes
    -------------------------
    dbo.robot_status_history  : IX_status_performance
    dbo.robot_battery_history : IX_battery_performance
    dbo.robot_job_history     : IX_job_performance
    dbo.robot_wifi_history    : IX_wifi_performance
*/

CREATE OR ALTER VIEW [DWS].[v_robot_live_state]
AS
SELECT
    master_robot.[id] AS [master_robot_id],
    CONVERT(NVARCHAR(100), master_robot.[name]) AS [robot_code],
    CONVERT(NVARCHAR(200), master_robot.[name]) AS [robot_name],
    CONVERT(NVARCHAR(100), master_robot.[serial_number]) AS [robot_serial_number],
    master_robot.[factory_id],
    CONVERT(TINYINT, 10) AS [freshness_threshold_minutes],
    freshness.[read_time] AS [dws_read_time],

    status_freshness.[freshness_status] AS [status_freshness_status],
    CASE
        WHEN status_freshness.[freshness_status] = N'CURRENT'
            THEN NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), status_row.[robot_move_state]))), N''), N'-')
    END AS [current_status],
    CASE
        WHEN status_freshness.[freshness_status] = N'CURRENT'
            THEN TRY_CONVERT(NVARCHAR(100), status_row.[robot_mode])
    END AS [current_mode_id],
    CASE
        WHEN status_freshness.[freshness_status] = N'CURRENT'
            THEN COALESCE(
                NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(200), mode_dictionary.[Mode_Detail]))), N''),
                CASE
                    WHEN status_row.[robot_mode] IS NULL THEN NULL
                    ELSE CONCAT(N'MODE_', CONVERT(NVARCHAR(30), status_row.[robot_mode]))
                END
            )
    END AS [current_mode],
    CASE
        WHEN status_freshness.[freshness_status] = N'CURRENT'
            THEN NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), status_row.[robot_current_map]))), N''), N'-')
    END AS [map_code],
    CASE
        WHEN status_freshness.[freshness_status] = N'CURRENT'
            THEN COALESCE(
                NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), status_row.[robot_zone_name]))), N''), N'-'),
                NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), status_row.[robot_zone_id]))), N''), N'-')
            )
    END AS [station_code],
    CASE
        WHEN status_freshness.[freshness_status] = N'CURRENT'
            THEN TRY_CONVERT(DECIMAL(18,6), status_row.[robot_position_x])
    END AS [position_x],
    CASE
        WHEN status_freshness.[freshness_status] = N'CURRENT'
            THEN TRY_CONVERT(DECIMAL(18,6), status_row.[robot_position_y])
    END AS [position_y],
    CASE
        WHEN status_freshness.[freshness_status] = N'CURRENT'
            THEN TRY_CONVERT(DECIMAL(18,6), status_row.[robot_orientation_z])
    END AS [position_theta],
    CASE
        WHEN status_freshness.[freshness_status] = N'CURRENT'
            THEN TRY_CONVERT(DECIMAL(18,6), status_row.[robot_speed])
    END AS [speed_mps],
    CASE
        WHEN status_freshness.[freshness_status] = N'CURRENT'
            THEN TRY_CONVERT(NVARCHAR(100), status_row.[robot_emer_status])
    END AS [emergency_status],
    status_row.[pc_timestamp] AS [status_event_time],
    status_freshness.[data_age_minutes] AS [status_data_age_minutes],

    job_freshness.[freshness_status] AS [job_freshness_status],
    CASE
        WHEN job_freshness.[freshness_status] = N'CURRENT'
            THEN job_row.[source_job_history_row_id]
    END AS [source_job_history_row_id],
    CASE
        WHEN job_freshness.[freshness_status] = N'CURRENT'
            THEN NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), job_row.[job_name]))), N''), N'-')
    END AS [robot_reported_job_name],
    CASE
        WHEN job_freshness.[freshness_status] = N'CURRENT'
            THEN NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), job_row.[job_status]))), N''), N'-')
    END AS [robot_job_status],
    CASE
        WHEN job_freshness.[freshness_status] = N'CURRENT'
            THEN NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), job_row.[poi_current]))), N''), N'-')
    END AS [current_station_code],
    CASE
        WHEN job_freshness.[freshness_status] = N'CURRENT'
            THEN NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), job_row.[poi_target]))), N''), N'-')
    END AS [target_station_code],
    job_row.[pc_timestamp] AS [job_event_time],
    job_freshness.[data_age_minutes] AS [job_data_age_minutes],

    battery_freshness.[freshness_status] AS [battery_freshness_status],
    CASE
        WHEN battery_freshness.[freshness_status] = N'CURRENT'
            THEN TRY_CONVERT(DECIMAL(9,4), battery_row.[batt_level])
    END AS [battery_soc],
    CASE
        WHEN battery_freshness.[freshness_status] = N'CURRENT'
            THEN TRY_CONVERT(DECIMAL(18,6), battery_row.[batt_volt])
    END AS [battery_voltage],
    CASE
        WHEN battery_freshness.[freshness_status] = N'CURRENT'
            THEN TRY_CONVERT(DECIMAL(18,6), battery_row.[batt_current])
    END AS [battery_current],
    CASE
        WHEN battery_freshness.[freshness_status] = N'CURRENT'
            THEN NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), battery_row.[batt_charge_status]))), N''), N'-')
    END AS [charging_status],
    battery_row.[pc_timestamp] AS [battery_event_time],
    battery_freshness.[data_age_minutes] AS [battery_data_age_minutes],

    wifi_freshness.[freshness_status] AS [wifi_freshness_status],
    CASE
        WHEN wifi_freshness.[freshness_status] = N'CURRENT'
            THEN TRY_CONVERT(DECIMAL(18,2), wifi_row.[wifi_signal_level])
    END AS [current_rssi],
    CASE
        WHEN wifi_freshness.[freshness_status] = N'CURRENT'
            THEN TRY_CONVERT(DECIMAL(18,2), wifi_row.[wifi_quality])
    END AS [current_wifi_quality],
    CASE
        WHEN wifi_freshness.[freshness_status] = N'CURRENT'
            THEN NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(200), wifi_row.[wifi_ap_connected]))), N''), N'-')
    END AS [current_wifi_ap],
    CASE
        WHEN wifi_freshness.[freshness_status] = N'CURRENT'
            THEN TRY_CONVERT(INT, wifi_row.[wifi_count])
    END AS [current_wifi_count],
    wifi_row.[pc_timestamp] AS [wifi_event_time],
    wifi_freshness.[data_age_minutes] AS [wifi_data_age_minutes],

    latest_event.[latest_event_time],
    CASE
        WHEN status_freshness.[freshness_status] = N'CURRENT' THEN N'CURRENT'
        WHEN status_freshness.[freshness_status] = N'MISSING' THEN N'MISSING'
        ELSE N'TIMEOUT'
    END AS [live_state_status]
FROM [dbo].[MA_AMR] AS master_robot
CROSS APPLY (
    SELECT SYSDATETIME() AS [read_time]
) AS freshness
OUTER APPLY (
    SELECT TOP (1)
        status_source.[pc_timestamp],
        status_source.[robot_speed],
        status_source.[robot_position_x],
        status_source.[robot_position_y],
        status_source.[robot_orientation_z],
        status_source.[robot_move_state],
        status_source.[robot_mode],
        status_source.[robot_emer_status],
        status_source.[robot_current_map],
        status_source.[robot_zone_id],
        status_source.[robot_zone_name]
    FROM [dbo].[robot_status_history] AS status_source
        WITH (INDEX([IX_status_performance]), FORCESEEK)
    WHERE status_source.[amr_id] = master_robot.[id]
    ORDER BY status_source.[pc_timestamp] DESC
) AS status_row
OUTER APPLY (
    SELECT TOP (1)
        job_source.[id] AS [source_job_history_row_id],
        job_source.[pc_timestamp],
        job_source.[job_name],
        job_source.[job_status],
        job_source.[poi_current],
        job_source.[poi_target]
    FROM [dbo].[robot_job_history] AS job_source
        WITH (INDEX([IX_job_performance]), FORCESEEK)
    WHERE job_source.[amr_id] = master_robot.[id]
    ORDER BY job_source.[pc_timestamp] DESC
) AS job_row
OUTER APPLY (
    SELECT TOP (1)
        battery_source.[pc_timestamp],
        battery_source.[batt_level],
        battery_source.[batt_volt],
        battery_source.[batt_current],
        battery_source.[batt_charge_status]
    FROM [dbo].[robot_battery_history] AS battery_source
        WITH (INDEX([IX_battery_performance]), FORCESEEK)
    WHERE battery_source.[amr_id] = master_robot.[id]
    ORDER BY battery_source.[pc_timestamp] DESC
) AS battery_row
OUTER APPLY (
    SELECT TOP (1)
        wifi_source.[pc_timestamp],
        wifi_source.[wifi_signal_level],
        wifi_source.[wifi_quality],
        wifi_source.[wifi_ap_connected],
        wifi_source.[wifi_count]
    FROM [dbo].[robot_wifi_history] AS wifi_source
        WITH (INDEX([IX_wifi_performance]), FORCESEEK)
    WHERE wifi_source.[amr_id] = master_robot.[id]
    ORDER BY wifi_source.[pc_timestamp] DESC
) AS wifi_row
OUTER APPLY (
    SELECT TOP (1)
        mode_reference.[Mode_Detail]
    FROM [dbo].[AMR_Robot_Mode] AS mode_reference
    WHERE TRY_CONVERT(INT, mode_reference.[Mode_ID]) = status_row.[robot_mode]
    ORDER BY mode_reference.[Mode_ID]
) AS mode_dictionary
CROSS APPLY (
    SELECT
        DATEDIFF(MINUTE, status_row.[pc_timestamp], freshness.[read_time]) AS [data_age_minutes],
        CASE
            WHEN status_row.[pc_timestamp] IS NULL THEN N'MISSING'
            WHEN DATEDIFF(MINUTE, status_row.[pc_timestamp], freshness.[read_time]) > 10 THEN N'TIMEOUT'
            ELSE N'CURRENT'
        END AS [freshness_status]
) AS status_freshness
CROSS APPLY (
    SELECT
        DATEDIFF(MINUTE, job_row.[pc_timestamp], freshness.[read_time]) AS [data_age_minutes],
        CASE
            WHEN job_row.[pc_timestamp] IS NULL THEN N'MISSING'
            WHEN DATEDIFF(MINUTE, job_row.[pc_timestamp], freshness.[read_time]) > 10 THEN N'TIMEOUT'
            ELSE N'CURRENT'
        END AS [freshness_status]
) AS job_freshness
CROSS APPLY (
    SELECT
        DATEDIFF(MINUTE, battery_row.[pc_timestamp], freshness.[read_time]) AS [data_age_minutes],
        CASE
            WHEN battery_row.[pc_timestamp] IS NULL THEN N'MISSING'
            WHEN DATEDIFF(MINUTE, battery_row.[pc_timestamp], freshness.[read_time]) > 10 THEN N'TIMEOUT'
            ELSE N'CURRENT'
        END AS [freshness_status]
) AS battery_freshness
CROSS APPLY (
    SELECT
        DATEDIFF(MINUTE, wifi_row.[pc_timestamp], freshness.[read_time]) AS [data_age_minutes],
        CASE
            WHEN wifi_row.[pc_timestamp] IS NULL THEN N'MISSING'
            WHEN DATEDIFF(MINUTE, wifi_row.[pc_timestamp], freshness.[read_time]) > 10 THEN N'TIMEOUT'
            ELSE N'CURRENT'
        END AS [freshness_status]
) AS wifi_freshness
OUTER APPLY (
    SELECT MAX(event_time.[value]) AS [latest_event_time]
    FROM (VALUES
        (status_row.[pc_timestamp]),
        (job_row.[pc_timestamp]),
        (battery_row.[pc_timestamp]),
        (wifi_row.[pc_timestamp])
    ) AS event_time ([value])
) AS latest_event
WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y'
  AND NULLIF(LTRIM(RTRIM(master_robot.[name])), N'') IS NOT NULL;
GO

/*
    Pre-execution validation:

    SELECT
        live_state.[robot_code],
        live_state.[live_state_status],
        live_state.[status_freshness_status],
        live_state.[current_status],
        live_state.[source_job_history_row_id],
        live_state.[robot_reported_job_name],
        live_state.[robot_job_status],
        live_state.[map_code],
        live_state.[position_x],
        live_state.[position_y],
        live_state.[status_event_time],
        live_state.[dws_read_time]
    FROM [DWS].[v_robot_live_state] AS live_state
    ORDER BY live_state.[robot_code];
*/
