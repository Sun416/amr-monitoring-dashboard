USE [IOT2020];

/*
    Read-only validation for the Web DWS live-data gate.

    The Web must not use DWS.dws_robot_current_snapshot for current state.
    A topic is current only when:
      1. its latest event/sample is no more than 30 minutes old;
      2. its latest DWS load is no more than 30 minutes old;
      3. the event-to-DWS-load pipeline lag is no more than 30 minutes.
*/

SET NOCOUNT ON;

DECLARE
    @database_now DATETIME2(3) = SYSDATETIME(),
    @freshness_minutes INT = 30;

SELECT
    robot.[id] AS [master_robot_id],
    robot.[name] AS [robot_code],
    status_latest.[last_status_time],
    status_latest.[dws_load_time] AS [status_dws_load_time],
    DATEDIFF(MINUTE, status_latest.[last_status_time], @database_now) AS [status_data_age_minutes],
    DATEDIFF(MINUTE, status_latest.[dws_load_time], @database_now) AS [status_refresh_age_minutes],
    DATEDIFF(MINUTE, status_latest.[last_status_time], status_latest.[dws_load_time]) AS [status_pipeline_lag_minutes],
    CASE
        WHEN status_latest.[last_status_time] IS NULL THEN N'MISSING'
        WHEN status_latest.[dws_load_time] IS NULL THEN N'MISSING'
        WHEN DATEDIFF(MINUTE, status_latest.[dws_load_time], @database_now) > @freshness_minutes
            THEN N'DWS_REFRESH_TIMEOUT'
        WHEN DATEDIFF(MINUTE, status_latest.[last_status_time], status_latest.[dws_load_time]) > @freshness_minutes
            THEN N'DWS_SOURCE_LAG'
        WHEN DATEDIFF(MINUTE, status_latest.[last_status_time], @database_now) > @freshness_minutes
            THEN N'SOURCE_TIMEOUT'
        ELSE N'CURRENT'
    END AS [status_freshness],
    battery_latest.[last_sample_time] AS [battery_last_sample_time],
    battery_latest.[dws_load_time] AS [battery_dws_load_time],
    DATEDIFF(MINUTE, battery_latest.[last_sample_time], @database_now) AS [battery_data_age_minutes],
    wifi_latest.[last_sample_time] AS [wifi_last_sample_time],
    wifi_latest.[dws_load_time] AS [wifi_dws_load_time],
    DATEDIFF(MINUTE, wifi_latest.[last_sample_time], @database_now) AS [wifi_data_age_minutes],
    @database_now AS [database_current_time]
FROM [dbo].[MA_AMR] AS robot
OUTER APPLY (
    SELECT TOP (1)
        status_hour.[last_status_time],
        status_hour.[dws_load_time]
    FROM [DWS].[dws_robot_status_hourly] AS status_hour
    WHERE status_hour.[robot_code] IN (
        robot.[name],
        CONVERT(NVARCHAR(100), robot.[id])
    )
    ORDER BY
        status_hour.[last_status_time] DESC,
        status_hour.[dws_load_time] DESC,
        status_hour.[status_hourly_id] DESC
) AS status_latest
OUTER APPLY (
    SELECT TOP (1)
        battery_hour.[last_sample_time],
        battery_hour.[dws_load_time]
    FROM [DWS].[dws_robot_battery_hourly] AS battery_hour
    WHERE battery_hour.[robot_code] IN (
        robot.[name],
        CONVERT(NVARCHAR(100), robot.[id])
    )
    ORDER BY
        battery_hour.[last_sample_time] DESC,
        battery_hour.[dws_load_time] DESC,
        battery_hour.[battery_hourly_id] DESC
) AS battery_latest
OUTER APPLY (
    SELECT TOP (1)
        wifi_hour.[last_sample_time],
        wifi_hour.[dws_load_time]
    FROM [DWS].[dws_robot_wifi_hourly] AS wifi_hour
    WHERE wifi_hour.[robot_code] IN (
        robot.[name],
        CONVERT(NVARCHAR(100), robot.[id])
    )
    ORDER BY
        wifi_hour.[last_sample_time] DESC,
        wifi_hour.[dws_load_time] DESC,
        wifi_hour.[wifi_hourly_id] DESC
) AS wifi_latest
WHERE UPPER(LTRIM(RTRIM(COALESCE(robot.[is_active], N'')))) = N'Y'
ORDER BY robot.[name], robot.[id];
