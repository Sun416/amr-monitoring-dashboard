USE [IOT2020];

SET NOCOUNT ON;

/*
    Read-only data-quality gate before production analysis or external integration.

    This script does not modify business data, ETL control data, or monitoring logs.
    It returns compact evidence for:
      1. current fleet/snapshot coverage
      2. latest persisted ETL freshness checks
      3. recent DWD/DWS batch health
      4. active robot master-data and snapshot key integrity
      5. per-robot source telemetry freshness
      6. current-snapshot field completeness
      7. DWS analytical anchor freshness

    Important:
      - A SUCCESS batch proves that a procedure ran; it does not prove that the
        upstream robot source produced fresh telemetry.
      - Persisted freshness checks can themselves be stale. Always inspect
        check_age_minutes.
*/

DECLARE
    @database_now DATETIME2(3) = SYSDATETIME(),
    @status_threshold_minutes INT = 5,
    @wifi_threshold_minutes INT = 5,
    @battery_threshold_minutes INT = 15,
    @snapshot_load_threshold_minutes INT = 3,
    @freshness_monitor_threshold_minutes INT = 15;

/* 1. Fleet and current-snapshot coverage. */
WITH active_robot AS
(
    SELECT
        master_robot.[id] AS [master_robot_id],
        master_robot.[name] AS [robot_code]
    FROM [dbo].[MA_AMR] AS master_robot
    WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y'
),
coverage AS
(
    SELECT
        COUNT_BIG(*) AS [active_robot_count],
        SUM(CASE WHEN snapshot_row.[robot_code] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [matched_snapshot_count],
        SUM(CASE WHEN snapshot_row.[robot_code] IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [missing_snapshot_count],
        MAX(snapshot_row.[dws_load_time]) AS [latest_snapshot_load_time]
    FROM active_robot AS active
    LEFT JOIN [DWS].[dws_robot_current_snapshot] AS snapshot_row
        ON snapshot_row.[robot_code] = active.[robot_code]
)
SELECT
    @database_now AS [database_time],
    coverage.[active_robot_count],
    coverage.[matched_snapshot_count],
    coverage.[missing_snapshot_count],
    coverage.[latest_snapshot_load_time],
    DATEDIFF(MINUTE, coverage.[latest_snapshot_load_time], @database_now) AS [snapshot_load_age_minutes],
    CASE
        WHEN coverage.[missing_snapshot_count] > 0 THEN N'FAIL'
        WHEN coverage.[latest_snapshot_load_time] IS NULL THEN N'FAIL'
        WHEN DATEDIFF(MINUTE, coverage.[latest_snapshot_load_time], @database_now) > @snapshot_load_threshold_minutes THEN N'FAIL'
        ELSE N'PASS'
    END AS [coverage_gate]
FROM coverage;

/* 2. Latest persisted freshness checks. */
SELECT
    freshness.[check_time],
    DATEDIFF(MINUTE, freshness.[check_time], @database_now) AS [check_age_minutes],
    freshness.[pipeline_layer],
    freshness.[source_schema],
    freshness.[source_table],
    freshness.[target_schema],
    freshness.[target_table],
    freshness.[source_max_id],
    freshness.[target_watermark],
    freshness.[estimated_rows_behind],
    freshness.[source_max_time],
    freshness.[target_max_time],
    freshness.[source_age_minutes],
    freshness.[target_age_minutes],
    freshness.[freshness_minutes],
    freshness.[threshold_minutes],
    freshness.[freshness_status],
    freshness.[status_detail],
    CASE
        WHEN DATEDIFF(MINUTE, freshness.[check_time], @database_now) > @freshness_monitor_threshold_minutes
            THEN N'FAIL_MONITOR_STALE'
        WHEN freshness.[freshness_status] <> N'SUCCESS'
            THEN N'FAIL_PIPELINE'
        ELSE N'PASS'
    END AS [quality_gate]
FROM [DWS].[v_etl_freshness_latest] AS freshness
ORDER BY
    CASE
        WHEN DATEDIFF(MINUTE, freshness.[check_time], @database_now) > @freshness_monitor_threshold_minutes THEN 1
        WHEN freshness.[freshness_status] = N'FAILED' THEN 2
        WHEN freshness.[freshness_status] = N'STALE' THEN 3
        ELSE 4
    END,
    freshness.[pipeline_layer],
    freshness.[source_table],
    freshness.[target_table];

/* 3. Recent DWS snapshot/aggregate batches. */
SELECT TOP (20)
    batch.[batch_id],
    batch.[batch_start_time],
    batch.[batch_end_time],
    batch.[batch_status],
    DATEDIFF(SECOND, batch.[batch_start_time], batch.[batch_end_time]) AS [duration_seconds],
    DATEDIFF(MINUTE, batch.[batch_end_time], @database_now) AS [batch_age_minutes],
    batch.[error_message]
FROM [DWS].[etl_batch] AS batch
ORDER BY batch.[batch_id] DESC;

/* 4. Recent DWD transformation batches. */
SELECT TOP (20)
    batch.[batch_id],
    batch.[batch_start_time],
    batch.[batch_end_time],
    batch.[batch_status],
    DATEDIFF(SECOND, batch.[batch_start_time], batch.[batch_end_time]) AS [duration_seconds],
    DATEDIFF(MINUTE, batch.[batch_end_time], @database_now) AS [batch_age_minutes],
    batch.[error_message]
FROM [DWD].[etl_batch] AS batch
ORDER BY batch.[batch_id] DESC;

/* 5. Active master-data keys and current-snapshot join integrity. */
WITH active_robot AS
(
    SELECT
        master_robot.[id] AS [master_robot_id],
        master_robot.[name] AS [robot_code],
        UPPER(LTRIM(RTRIM(master_robot.[name]))) AS [normalized_robot_code]
    FROM [dbo].[MA_AMR] AS master_robot
    WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y'
),
duplicate_active_code AS
(
    SELECT
        active.[normalized_robot_code],
        COUNT_BIG(*) AS [duplicate_count]
    FROM active_robot AS active
    GROUP BY active.[normalized_robot_code]
    HAVING COUNT_BIG(*) > 1
)
SELECT
    N'DUPLICATE_ACTIVE_ROBOT_CODE' AS [check_name],
    duplicate.[normalized_robot_code] AS [affected_key],
    duplicate.[duplicate_count] AS [affected_count],
    N'FAIL' AS [quality_gate]
FROM duplicate_active_code AS duplicate

UNION ALL

SELECT
    N'ACTIVE_ROBOT_WITHOUT_SNAPSHOT',
    active.[robot_code],
    CONVERT(BIGINT, 1),
    N'FAIL'
FROM active_robot AS active
LEFT JOIN [DWS].[dws_robot_current_snapshot] AS snapshot_row
    ON snapshot_row.[robot_code] = active.[robot_code]
WHERE snapshot_row.[robot_code] IS NULL

UNION ALL

SELECT
    N'ORPHAN_SNAPSHOT_ROBOT_CODE',
    snapshot_row.[robot_code],
    CONVERT(BIGINT, 1),
    N'FAIL'
FROM [DWS].[dws_robot_current_snapshot] AS snapshot_row
LEFT JOIN [dbo].[MA_AMR] AS master_robot
    ON master_robot.[name] = snapshot_row.[robot_code]
WHERE master_robot.[id] IS NULL
ORDER BY
    [check_name],
    [affected_key];

/* 6. Per-robot source telemetry freshness. */
WITH active_robot AS
(
    SELECT
        master_robot.[id] AS [master_robot_id],
        master_robot.[name] AS [robot_code]
    FROM [dbo].[MA_AMR] AS master_robot
    WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y'
)
SELECT
    active.[master_robot_id],
    active.[robot_code],
    snapshot_row.[online_status],
    snapshot_row.[status_event_time],
    DATEDIFF(MINUTE, snapshot_row.[status_event_time], @database_now) AS [status_age_minutes],
    latest_wifi.[pc_timestamp] AS [latest_wifi_time],
    DATEDIFF(MINUTE, latest_wifi.[pc_timestamp], @database_now) AS [wifi_age_minutes],
    snapshot_row.[battery_event_time],
    DATEDIFF(MINUTE, snapshot_row.[battery_event_time], @database_now) AS [battery_age_minutes],
    snapshot_row.[dws_load_time],
    DATEDIFF(MINUTE, snapshot_row.[dws_load_time], @database_now) AS [snapshot_load_age_minutes],
    CASE
        WHEN snapshot_row.[robot_code] IS NULL THEN N'FAIL_NO_SNAPSHOT'
        WHEN snapshot_row.[status_event_time] IS NULL THEN N'FAIL_STATUS_MISSING'
        WHEN latest_wifi.[pc_timestamp] IS NULL THEN N'FAIL_WIFI_MISSING'
        WHEN snapshot_row.[battery_event_time] IS NULL THEN N'FAIL_BATTERY_MISSING'
        WHEN DATEDIFF(MINUTE, snapshot_row.[status_event_time], @database_now) > @status_threshold_minutes THEN N'FAIL_STATUS_STALE'
        WHEN DATEDIFF(MINUTE, latest_wifi.[pc_timestamp], @database_now) > @wifi_threshold_minutes THEN N'FAIL_WIFI_STALE'
        WHEN DATEDIFF(MINUTE, snapshot_row.[battery_event_time], @database_now) > @battery_threshold_minutes THEN N'FAIL_BATTERY_STALE'
        ELSE N'PASS'
    END AS [telemetry_gate]
FROM active_robot AS active
LEFT JOIN [DWS].[dws_robot_current_snapshot] AS snapshot_row
    ON snapshot_row.[robot_code] = active.[robot_code]
OUTER APPLY
(
    SELECT TOP (1)
        wifi_history.[pc_timestamp]
    FROM [dbo].[robot_wifi_history] AS wifi_history WITH (INDEX([IX_wifi_performance]))
    WHERE wifi_history.[amr_id] = active.[master_robot_id]
    ORDER BY wifi_history.[pc_timestamp] DESC
) AS latest_wifi
ORDER BY
    CASE
        WHEN snapshot_row.[status_event_time] IS NULL THEN 1
        WHEN DATEDIFF(MINUTE, snapshot_row.[status_event_time], @database_now) > @status_threshold_minutes THEN 2
        ELSE 3
    END,
    active.[robot_code];

/* 7. Current-snapshot field completeness. */
WITH active_snapshot AS
(
    SELECT
        master_robot.[id] AS [master_robot_id],
        master_robot.[name] AS [robot_code],
        snapshot_row.[current_status],
        snapshot_row.[current_mode],
        snapshot_row.[map_code],
        snapshot_row.[position_x],
        snapshot_row.[position_y],
        snapshot_row.[battery_soc],
        latest_wifi.[wifi_signal_level] AS [current_rssi],
        NULLIF(
            NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(200), latest_wifi.[wifi_ap_connected]))), N''),
            N'-'
        ) AS [current_wifi_ap]
    FROM [dbo].[MA_AMR] AS master_robot
    LEFT JOIN [DWS].[dws_robot_current_snapshot] AS snapshot_row
        ON snapshot_row.[robot_code] = master_robot.[name]
    OUTER APPLY
    (
        SELECT TOP (1)
            wifi_history.[wifi_signal_level],
            wifi_history.[wifi_ap_connected]
        FROM [dbo].[robot_wifi_history] AS wifi_history WITH (INDEX([IX_wifi_performance]))
        WHERE wifi_history.[amr_id] = master_robot.[id]
        ORDER BY wifi_history.[pc_timestamp] DESC
    ) AS latest_wifi
    WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y'
)
SELECT
    COUNT_BIG(*) AS [active_robot_count],
    SUM(CASE WHEN [current_status] IS NULL OR LTRIM(RTRIM([current_status])) = N'' THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [missing_status_count],
    SUM(CASE WHEN [current_mode] IS NULL OR LTRIM(RTRIM([current_mode])) = N'' THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [missing_mode_count],
    SUM(CASE WHEN [map_code] IS NULL OR LTRIM(RTRIM([map_code])) = N'' THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [missing_map_count],
    SUM(CASE WHEN [position_x] IS NULL OR [position_y] IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [missing_position_count],
    SUM(CASE WHEN [battery_soc] IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [missing_battery_count],
    SUM(CASE WHEN [current_rssi] IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [missing_rssi_count],
    SUM(CASE WHEN [current_wifi_ap] IS NULL OR LTRIM(RTRIM([current_wifi_ap])) = N'' THEN CONVERT(BIGINT, 1) ELSE 0 END) AS [missing_wifi_ap_count]
FROM active_snapshot;

/* 8. DWS analytical anchor freshness. */
SELECT
    anchors.[dataset_name],
    anchors.[anchor_time],
    DATEDIFF(MINUTE, anchors.[anchor_time], @database_now) AS [anchor_age_minutes],
    anchors.[expected_max_age_minutes],
    CASE
        WHEN anchors.[anchor_time] IS NULL THEN N'FAIL_MISSING'
        WHEN DATEDIFF(MINUTE, anchors.[anchor_time], @database_now) > anchors.[expected_max_age_minutes] THEN N'FAIL_STALE'
        ELSE N'PASS'
    END AS [anchor_gate]
FROM
(
    SELECT
        N'DWS.dws_robot_status_hourly' AS [dataset_name],
        MAX(status_hour.[stat_hour]) AS [anchor_time],
        120 AS [expected_max_age_minutes]
    FROM [DWS].[dws_robot_status_hourly] AS status_hour

    UNION ALL

    SELECT
        N'DWS.dws_robot_battery_hourly',
        MAX(battery_hour.[stat_hour]),
        120
    FROM [DWS].[dws_robot_battery_hourly] AS battery_hour

    UNION ALL

    SELECT
        N'DWS.dws_robot_job_daily',
        CONVERT(DATETIME2(3), MAX(job_daily.[stat_date])),
        2880
    FROM [DWS].[dws_robot_job_daily] AS job_daily

    UNION ALL

    SELECT
        N'DWS.dws_amr_queue_daily',
        CONVERT(DATETIME2(3), MAX(queue_daily.[stat_date])),
        2880
    FROM [DWS].[dws_amr_queue_daily] AS queue_daily
) AS anchors
ORDER BY
    anchors.[dataset_name];
