USE [IOT2020];

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

/*
    Explain why a robot remains stale after ODS/DWD/DWS successfully refresh.

    Boundary checks:
      1. Read the latest row per active robot directly from dbo source tables.
      2. Compare dbo event times with the latest non-snapshot DWS aggregates.
      3. Detect whether status, battery and WiFi stopped together.

    This script is read-only. It does not update ETL watermarks or business data.
*/
DECLARE
    @database_now DATETIME2(3) = SYSDATETIME(),
    @freshness_minutes INT = 30,
    @topic_stop_spread_seconds INT = 120;

WITH robot_source AS
(
    SELECT
        master_robot.[id] AS [master_robot_id],
        master_robot.[name] AS [robot_code],
        master_robot.[status] AS [master_status],
        status_source.[pc_timestamp] AS [dbo_status_time],
        battery_source.[pc_timestamp] AS [dbo_battery_time],
        wifi_source.[pc_timestamp] AS [dbo_wifi_time],
        job_source.[pc_timestamp] AS [dbo_job_time],
        status_dws.[last_status_time] AS [dws_status_time],
        battery_dws.[last_sample_time] AS [dws_battery_time],
        wifi_dws.[last_sample_time] AS [dws_wifi_time]
    FROM [dbo].[MA_AMR] AS master_robot
    OUTER APPLY
    (
        SELECT TOP (1)
            status_history.[pc_timestamp]
        FROM [dbo].[robot_status_history] AS status_history
            WITH (INDEX([IX_status_performance]), FORCESEEK)
        WHERE status_history.[amr_id] = master_robot.[id]
        ORDER BY status_history.[pc_timestamp] DESC
    ) AS status_source
    OUTER APPLY
    (
        SELECT TOP (1)
            battery_history.[pc_timestamp]
        FROM [dbo].[robot_battery_history] AS battery_history
            WITH (INDEX([IX_battery_performance]), FORCESEEK)
        WHERE battery_history.[amr_id] = master_robot.[id]
        ORDER BY battery_history.[pc_timestamp] DESC
    ) AS battery_source
    OUTER APPLY
    (
        SELECT TOP (1)
            wifi_history.[pc_timestamp]
        FROM [dbo].[robot_wifi_history] AS wifi_history
            WITH (INDEX([IX_wifi_performance]), FORCESEEK)
        WHERE wifi_history.[amr_id] = master_robot.[id]
        ORDER BY wifi_history.[pc_timestamp] DESC
    ) AS wifi_source
    OUTER APPLY
    (
        SELECT TOP (1)
            job_history.[pc_timestamp]
        FROM [dbo].[robot_job_history] AS job_history
            WITH (INDEX([IX_job_performance]), FORCESEEK)
        WHERE job_history.[amr_id] = master_robot.[id]
        ORDER BY job_history.[pc_timestamp] DESC
    ) AS job_source
    OUTER APPLY
    (
        SELECT TOP (1)
            status_hourly.[last_status_time]
        FROM [DWS].[dws_robot_status_hourly] AS status_hourly
        WHERE status_hourly.[robot_code] IN
        (
            master_robot.[name],
            CONVERT(NVARCHAR(100), master_robot.[id])
        )
        ORDER BY
            status_hourly.[last_status_time] DESC,
            status_hourly.[dws_load_time] DESC,
            status_hourly.[status_hourly_id] DESC
    ) AS status_dws
    OUTER APPLY
    (
        SELECT TOP (1)
            battery_hourly.[last_sample_time]
        FROM [DWS].[dws_robot_battery_hourly] AS battery_hourly
        WHERE battery_hourly.[robot_code] IN
        (
            master_robot.[name],
            CONVERT(NVARCHAR(100), master_robot.[id])
        )
        ORDER BY
            battery_hourly.[last_sample_time] DESC,
            battery_hourly.[dws_load_time] DESC,
            battery_hourly.[battery_hourly_id] DESC
    ) AS battery_dws
    OUTER APPLY
    (
        SELECT TOP (1)
            wifi_hourly.[last_sample_time]
        FROM [DWS].[dws_robot_wifi_hourly] AS wifi_hourly
        WHERE wifi_hourly.[robot_code] IN
        (
            master_robot.[name],
            CONVERT(NVARCHAR(100), master_robot.[id])
        )
        ORDER BY
            wifi_hourly.[last_sample_time] DESC,
            wifi_hourly.[dws_load_time] DESC,
            wifi_hourly.[wifi_hourly_id] DESC
    ) AS wifi_dws
    WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y'
),
robot_boundary AS
(
    SELECT
        source_row.[master_robot_id],
        source_row.[robot_code],
        source_row.[master_status],
        source_row.[dbo_status_time],
        source_row.[dbo_battery_time],
        source_row.[dbo_wifi_time],
        source_row.[dbo_job_time],
        source_row.[dws_status_time],
        source_row.[dws_battery_time],
        source_row.[dws_wifi_time],
        DATEDIFF(MINUTE, source_row.[dbo_status_time], @database_now) AS [status_age_minutes],
        DATEDIFF(MINUTE, source_row.[dbo_battery_time], @database_now) AS [battery_age_minutes],
        DATEDIFF(MINUTE, source_row.[dbo_wifi_time], @database_now) AS [wifi_age_minutes],
        DATEDIFF(MINUTE, source_row.[dbo_job_time], @database_now) AS [job_age_minutes],
        DATEDIFF(MINUTE, source_row.[dws_status_time], @database_now) AS [dws_status_age_minutes],
        ABS(DATEDIFF(SECOND, source_row.[dws_status_time], source_row.[dbo_status_time])) AS [status_dbo_to_dws_gap_seconds],
        topic_times.[topic_stop_spread_seconds]
    FROM robot_source AS source_row
    OUTER APPLY
    (
        SELECT
            DATEDIFF
            (
                SECOND,
                MIN(topic_time.[event_time]),
                MAX(topic_time.[event_time])
            ) AS [topic_stop_spread_seconds]
        FROM
        (
            VALUES
                (source_row.[dbo_status_time]),
                (source_row.[dbo_battery_time]),
                (source_row.[dbo_wifi_time])
        ) AS topic_time([event_time])
    ) AS topic_times
)
SELECT
    boundary.[master_robot_id],
    boundary.[robot_code],
    boundary.[master_status],
    boundary.[dbo_status_time],
    boundary.[dbo_battery_time],
    boundary.[dbo_wifi_time],
    boundary.[dbo_job_time],
    boundary.[status_age_minutes],
    boundary.[battery_age_minutes],
    boundary.[wifi_age_minutes],
    boundary.[job_age_minutes],
    boundary.[dws_status_age_minutes],
    boundary.[status_dbo_to_dws_gap_seconds],
    boundary.[topic_stop_spread_seconds],
    CASE
        WHEN boundary.[dbo_status_time] IS NULL
            THEN N'NO_DBO_STATUS_HISTORY'
        WHEN boundary.[status_age_minutes] <= @freshness_minutes
         AND
         (
             boundary.[dws_status_age_minutes] > @freshness_minutes
             OR boundary.[dws_status_age_minutes] IS NULL
         )
            THEN N'WAREHOUSE_NOT_CAUGHT_UP_TO_CURRENT_DBO'
        WHEN boundary.[status_age_minutes] <= @freshness_minutes
            THEN N'CURRENT'
        WHEN boundary.[battery_age_minutes] > @freshness_minutes
         AND boundary.[wifi_age_minutes] > @freshness_minutes
         AND boundary.[topic_stop_spread_seconds] <= @topic_stop_spread_seconds
            THEN N'DBO_THREE_TELEMETRY_TOPICS_STOPPED_TOGETHER'
        ELSE N'DBO_SOURCE_TOPIC_STALE'
    END AS [evidence_conclusion],
    @database_now AS [database_current_time]
FROM robot_boundary AS boundary
WHERE boundary.[status_age_minutes] > @freshness_minutes
   OR boundary.[status_age_minutes] IS NULL
   OR boundary.[dws_status_age_minutes] > @freshness_minutes
   OR boundary.[dws_status_age_minutes] IS NULL
ORDER BY
    boundary.[status_age_minutes] DESC,
    boundary.[robot_code];
