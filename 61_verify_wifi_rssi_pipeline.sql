USE [IOT2020];
GO

/*
    Read-only verification for:
      ODS.robot_wifi_history.wifi_signal_level
          -> DWD.fact_robot_wifi.rssi
          -> DWS.dws_robot_wifi_hourly RSSI metrics

    This script does not modify any table.
*/

SET NOCOUNT ON;

/* 1. Required objects, columns, and future mapping. */
SELECT
    CASE
        WHEN OBJECT_ID(N'[ODS].[robot_wifi_history]', N'U') IS NOT NULL THEN 1
        ELSE 0
    END AS [ods_wifi_table_exists],
    CASE
        WHEN COL_LENGTH(N'ODS.robot_wifi_history', N'wifi_signal_level') IS NOT NULL THEN 1
        ELSE 0
    END AS [ods_wifi_signal_level_exists],
    CASE
        WHEN OBJECT_ID(N'[DWD].[fact_robot_wifi]', N'U') IS NOT NULL THEN 1
        ELSE 0
    END AS [dwd_wifi_table_exists],
    CASE
        WHEN COL_LENGTH(N'DWD.fact_robot_wifi', N'rssi') IS NOT NULL THEN 1
        ELSE 0
    END AS [dwd_rssi_exists],
    CASE
        WHEN OBJECT_ID(N'[DWS].[dws_robot_wifi_hourly]', N'U') IS NOT NULL THEN 1
        ELSE 0
    END AS [dws_wifi_table_exists],
    CASE
        WHEN CHARINDEX(
            N'(N''rssi'', N''decimal18'', N''wifi_signal_level'', 20),',
            ISNULL(
                OBJECT_DEFINITION(
                    OBJECT_ID(N'[DWD].[sp_load_dwd_all_incremental]', N'P')
                ),
                N''
            )
        ) > 0 THEN 1
        ELSE 0
    END AS [future_mapping_is_installed];

IF OBJECT_ID(N'[ODS].[robot_wifi_history]', N'U') IS NULL
   OR OBJECT_ID(N'[DWD].[fact_robot_wifi]', N'U') IS NULL
   OR OBJECT_ID(N'[DWS].[dws_robot_wifi_hourly]', N'U') IS NULL
BEGIN
    RAISERROR(N'Required ODS, DWD, or DWS WiFi table is missing.', 16, 1);
    RETURN;
END;

/*
    2. Bounded ODS-to-DWD validation.
       Expected after the future mapping is active:
         source_nonnull_but_dwd_null = 0
         different_value_rows = 0
*/
;WITH latest_dwd AS (
    SELECT TOP (10000)
        fw.[wifi_fact_id],
        fw.[source_ods_row_id],
        fw.[rssi],
        fw.[sample_time],
        fw.[robot_code]
    FROM [DWD].[fact_robot_wifi] AS fw
    WHERE fw.[source_schema] = N'ODS'
      AND fw.[source_table] = N'robot_wifi_history'
      AND fw.[source_ods_row_id] IS NOT NULL
    ORDER BY fw.[source_ods_row_id] DESC
)
SELECT
    COUNT_BIG(*) AS [checked_recent_rows],
    SUM(
        CASE
            WHEN ow.[wifi_signal_level] IS NOT NULL
             AND d.[rssi] IS NULL
                THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END
    ) AS [source_nonnull_but_dwd_null],
    SUM(
        CASE
            WHEN d.[rssi] IS NOT NULL
             AND TRY_CONVERT(DECIMAL(18,6), ow.[wifi_signal_level]) IS NOT NULL
             AND d.[rssi] <> TRY_CONVERT(DECIMAL(18,6), ow.[wifi_signal_level])
                THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END
    ) AS [different_value_rows],
    SUM(CASE WHEN d.[rssi] < 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS [valid_negative_rssi_rows],
    SUM(CASE WHEN d.[rssi] = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS [zero_signal_rows],
    MIN(d.[sample_time]) AS [first_checked_sample_time],
    MAX(d.[sample_time]) AS [last_checked_sample_time]
FROM latest_dwd AS d
JOIN [ODS].[robot_wifi_history] AS ow
    ON ow.[ods_row_id] = d.[source_ods_row_id];

/* Sample any remaining recent mismatches. Expected result: no rows. */
;WITH latest_dwd AS (
    SELECT TOP (10000)
        fw.[wifi_fact_id],
        fw.[source_ods_row_id],
        fw.[rssi],
        fw.[sample_time],
        fw.[robot_code]
    FROM [DWD].[fact_robot_wifi] AS fw
    WHERE fw.[source_schema] = N'ODS'
      AND fw.[source_table] = N'robot_wifi_history'
      AND fw.[source_ods_row_id] IS NOT NULL
    ORDER BY fw.[source_ods_row_id] DESC
)
SELECT TOP (20)
    d.[wifi_fact_id],
    d.[source_ods_row_id],
    d.[robot_code],
    d.[sample_time],
    ow.[wifi_signal_level] AS [ods_wifi_signal_level],
    d.[rssi] AS [dwd_rssi]
FROM latest_dwd AS d
JOIN [ODS].[robot_wifi_history] AS ow
    ON ow.[ods_row_id] = d.[source_ods_row_id]
WHERE (
          ow.[wifi_signal_level] IS NOT NULL
      AND d.[rssi] IS NULL
      )
   OR (
          d.[rssi] IS NOT NULL
      AND TRY_CONVERT(DECIMAL(18,6), ow.[wifi_signal_level]) IS NOT NULL
      AND d.[rssi] <> TRY_CONVERT(DECIMAL(18,6), ow.[wifi_signal_level])
      )
ORDER BY d.[source_ods_row_id] DESC;

/*
    3. Historical-repair progress.
       Expected at final completion:
         repair_status = COMPLETE
         pending_dws_robot_hours = 0
*/
IF OBJECT_ID(N'[DWD].[etl_wifi_rssi_repair_state]', N'U') IS NOT NULL
BEGIN
    SELECT
        rs.[repair_name],
        rs.[last_source_ods_row_id],
        rs.[upper_source_ods_row_id],
        CAST(
            CASE
                WHEN rs.[upper_source_ods_row_id] = 0 THEN 100.0000
                ELSE 100.0 * rs.[last_source_ods_row_id]
                     / rs.[upper_source_ods_row_id]
            END
            AS DECIMAL(9,4)
        ) AS [scan_progress_percent],
        rs.[repair_status],
        rs.[total_rows_updated],
        rs.[started_at],
        rs.[last_batch_at],
        rs.[completed_at],
        rs.[error_message]
    FROM [DWD].[etl_wifi_rssi_repair_state] AS rs
    WHERE rs.[repair_name] = N'FACT_ROBOT_WIFI_RSSI_V1';
END;

IF OBJECT_ID(N'[DWD].[etl_wifi_rssi_repair_hour_queue]', N'U') IS NOT NULL
BEGIN
    SELECT
        COUNT_BIG(*) AS [total_queued_robot_hours],
        SUM(
            CASE
                WHEN q.[is_processed] = 0 THEN CONVERT(BIGINT, 1)
                ELSE CONVERT(BIGINT, 0)
            END
        ) AS [pending_dws_robot_hours],
        SUM(
            CASE
                WHEN q.[is_processed] = 1 THEN CONVERT(BIGINT, 1)
                ELSE CONVERT(BIGINT, 0)
            END
        ) AS [processed_dws_robot_hours],
        MIN(CASE WHEN q.[is_processed] = 0 THEN q.[stat_hour] END)
            AS [first_pending_hour],
        MAX(CASE WHEN q.[is_processed] = 0 THEN q.[stat_hour] END)
            AS [last_pending_hour]
    FROM [DWD].[etl_wifi_rssi_repair_hour_queue] AS q
    WHERE q.[repair_name] = N'FACT_ROBOT_WIFI_RSSI_V1';
END;

/*
    4. Recent DWS metric profile.

       avg/min/max RSSI are intentionally NULL when every sample in an hour is
       RSSI = 0 (no signal). Such a row is legitimate when:
         avg_rssi IS NULL
         weak_signal_sample_count = sample_count

       suspicious_null_metric_rows should become 0 after the DWS queue drains.
*/
DECLARE @latest_dws_hour DATETIME2(0);

SELECT
    @latest_dws_hour = MAX(dh.[stat_hour])
FROM [DWS].[dws_robot_wifi_hourly] AS dh;

SELECT
    COUNT_BIG(*) AS [recent_robot_hour_rows],
    SUM(
        CASE
            WHEN dh.[avg_rssi] IS NOT NULL THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END
    ) AS [rows_with_valid_rssi_metrics],
    SUM(
        CASE
            WHEN dh.[avg_rssi] IS NULL
             AND dh.[sample_count] > 0
             AND dh.[weak_signal_sample_count] = dh.[sample_count]
                THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END
    ) AS [legitimate_all_zero_signal_rows],
    SUM(
        CASE
            WHEN dh.[avg_rssi] IS NULL
             AND dh.[sample_count] > 0
             AND dh.[weak_signal_sample_count] = 0
                THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END
    ) AS [suspicious_null_metric_rows],
    MIN(dh.[avg_rssi]) AS [minimum_recent_average_rssi],
    MAX(dh.[avg_rssi]) AS [maximum_recent_average_rssi],
    MIN(dh.[stat_hour]) AS [first_checked_hour],
    MAX(dh.[stat_hour]) AS [last_checked_hour]
FROM [DWS].[dws_robot_wifi_hourly] AS dh
WHERE dh.[stat_hour] >= DATEADD(HOUR, -48, @latest_dws_hour)
  AND dh.[stat_hour] <= @latest_dws_hour;

SELECT TOP (50)
    dh.[stat_hour],
    dh.[robot_code],
    dh.[sample_count],
    dh.[avg_rssi],
    dh.[min_rssi],
    dh.[max_rssi],
    dh.[weak_signal_sample_count],
    dh.[first_sample_time],
    dh.[last_sample_time],
    dh.[dws_load_time],
    dh.[dws_batch_id]
FROM [DWS].[dws_robot_wifi_hourly] AS dh
ORDER BY
    dh.[stat_hour] DESC,
    dh.[robot_code];

/* 5. Latest targeted DWS repair batches. */
SELECT TOP (20)
    l.[load_id],
    l.[batch_id],
    l.[target_schema],
    l.[target_table],
    l.[source_schema],
    l.[source_table],
    l.[load_mode],
    l.[affected_rows],
    l.[load_status],
    l.[error_message],
    l.[load_start_time],
    l.[load_end_time]
FROM [DWS].[etl_load_log] AS l
WHERE l.[target_schema] = N'DWS'
  AND l.[target_table] = N'dws_robot_wifi_hourly'
  AND l.[load_mode] = N'TARGETED_REPAIR_UPSERT'
ORDER BY l.[load_id] DESC;
GO
