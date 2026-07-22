USE IOT2020;
GO

/*
    Quick validation for core DWS tables.
    Run after:
    1. 25_create_dws_core_tables.sql
    2. 26_load_dws_core_upsert.sql
*/

SET NOCOUNT ON;

SELECT
    N'DWS batch' AS [check_section],
    [batch_id],
    [batch_start_time],
    [batch_end_time],
    [batch_status],
    [error_message]
FROM [DWS].[etl_batch]
ORDER BY
    [batch_id] DESC;

SELECT
    N'DWS latest load log' AS [check_section],
    [load_id],
    [batch_id],
    [target_table],
    [source_table],
    [load_mode],
    [affected_rows],
    [load_status],
    [error_message],
    [load_start_time],
    [load_end_time]
FROM [DWS].[etl_load_log]
WHERE [batch_id] = (
    SELECT MAX([batch_id])
    FROM [DWS].[etl_batch]
)
ORDER BY
    [load_id];

SELECT
    N'dws_robot_battery_hourly' AS [table_name],
    COUNT_BIG(*) AS [row_count],
    MIN([stat_hour]) AS [min_time],
    MAX([stat_hour]) AS [max_time]
FROM [DWS].[dws_robot_battery_hourly]
UNION ALL
SELECT
    N'dws_robot_status_hourly',
    COUNT_BIG(*),
    MIN([stat_hour]),
    MAX([stat_hour])
FROM [DWS].[dws_robot_status_hourly]
UNION ALL
SELECT
    N'dws_robot_wifi_hourly',
    COUNT_BIG(*),
    MIN([stat_hour]),
    MAX([stat_hour])
FROM [DWS].[dws_robot_wifi_hourly]
UNION ALL
SELECT
    N'dws_robot_job_daily',
    COUNT_BIG(*),
    CONVERT(DATETIME2(0), MIN([stat_date])),
    CONVERT(DATETIME2(0), MAX([stat_date]))
FROM [DWS].[dws_robot_job_daily]
UNION ALL
SELECT
    N'dws_amr_queue_daily',
    COUNT_BIG(*),
    CONVERT(DATETIME2(0), MIN([stat_date])),
    CONVERT(DATETIME2(0), MAX([stat_date]))
FROM [DWS].[dws_amr_queue_daily]
UNION ALL
SELECT
    N'dws_robot_current_snapshot',
    COUNT_BIG(*),
    MIN([source_snapshot_time]),
    MAX([source_snapshot_time])
FROM [DWS].[dws_robot_current_snapshot];

SELECT TOP (50)
    N'DWS current snapshot sample' AS [check_section],
    [robot_code],
    [robot_name],
    [current_status],
    [current_mode],
    [online_status],
    [battery_soc],
    [source_event_time],
    [source_snapshot_time],
    [dws_load_time]
FROM [DWS].[dws_robot_current_snapshot]
ORDER BY
    [robot_code];
GO
