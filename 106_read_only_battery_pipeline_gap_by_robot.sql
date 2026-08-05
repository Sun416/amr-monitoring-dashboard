USE [IOT2020];

/*
  Read-only battery-pipeline boundary check for enabled robots.
  It identifies the first lagging layer: dbo -> ODS -> DWD.
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

DECLARE @database_now DATETIME2(3) = SYSDATETIME();
DECLARE @freshness_minutes INT = 30;
DECLARE @pipeline_lag_seconds INT = 600;

;WITH active_robot AS
(
    SELECT
        master_robot.[id],
        master_robot.[name]
    FROM [dbo].[MA_AMR] AS master_robot
    WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y'
), ods_latest_battery AS
(
    /* ODS has no (amr_id, pc_timestamp) index; aggregate it once rather than scan it per robot. */
    SELECT
        battery_row.[amr_id],
        MAX(battery_row.[pc_timestamp]) AS [pc_timestamp],
        MAX(battery_row.[robot_datetime]) AS [robot_datetime]
    FROM [ODS].[robot_battery_history] AS battery_row
    INNER JOIN active_robot AS active_robot
        ON active_robot.[id] = battery_row.[amr_id]
    GROUP BY battery_row.[amr_id]
)
SELECT
    master_robot.[id] AS [amr_id],
    master_robot.[name] AS [robot_code],
    dbo_battery.[pc_timestamp] AS [dbo_latest_battery_time],
    ods_battery.[pc_timestamp] AS [ods_latest_battery_time],
    ods_battery.[robot_datetime] AS [ods_latest_robot_event_time],
    dwd_battery.[sample_time] AS [dwd_latest_battery_time],
    DATEDIFF(MINUTE, dbo_battery.[pc_timestamp], @database_now) AS [dbo_battery_age_minutes],
    DATEDIFF(SECOND, ods_battery.[pc_timestamp], dbo_battery.[pc_timestamp]) AS [dbo_to_ods_lag_seconds],
    DATEDIFF(SECOND, dwd_battery.[sample_time], ods_battery.[robot_datetime]) AS [ods_event_to_dwd_lag_seconds],
    CASE
        WHEN dbo_battery.[pc_timestamp] IS NULL THEN N'NO_DBO_BATTERY_SOURCE'
        WHEN DATEDIFF(MINUTE, dbo_battery.[pc_timestamp], @database_now) > @freshness_minutes THEN N'DBO_BATTERY_SOURCE_STALE'
        WHEN ods_battery.[pc_timestamp] IS NULL
          OR DATEDIFF(SECOND, ods_battery.[pc_timestamp], dbo_battery.[pc_timestamp]) > @pipeline_lag_seconds THEN N'ODS_BATTERY_NOT_CAUGHT_UP'
        WHEN dwd_battery.[sample_time] IS NULL
          OR DATEDIFF(SECOND, dwd_battery.[sample_time], ods_battery.[robot_datetime]) > @pipeline_lag_seconds THEN N'DWD_BATTERY_NOT_CAUGHT_UP'
        WHEN ods_battery.[robot_datetime] IS NOT NULL
          AND DATEDIFF(MINUTE, ods_battery.[robot_datetime], @database_now) > @freshness_minutes THEN N'ROBOT_EVENT_TIMESTAMP_STALE_BUT_INGEST_CURRENT'
        ELSE N'BATTERY_PIPELINE_CURRENT'
    END AS [pipeline_assessment]
FROM [dbo].[MA_AMR] AS master_robot
OUTER APPLY
(
    SELECT TOP (1) battery_row.[pc_timestamp]
    FROM [dbo].[robot_battery_history] AS battery_row WITH (INDEX([IX_battery_performance]), FORCESEEK)
    WHERE battery_row.[amr_id] = master_robot.[id]
    ORDER BY battery_row.[pc_timestamp] DESC
) AS dbo_battery
LEFT JOIN ods_latest_battery AS ods_battery
    ON ods_battery.[amr_id] = master_robot.[id]
OUTER APPLY
(
    SELECT TOP (1) battery_row.[sample_time]
    FROM [DWD].[fact_robot_battery] AS battery_row WITH (INDEX([IX_DWD_fact_robot_battery_robot_time]))
    WHERE battery_row.[robot_code] = master_robot.[name]
    ORDER BY battery_row.[sample_time] DESC, battery_row.[battery_fact_id] DESC
) AS dwd_battery
WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y'
ORDER BY master_robot.[name];
