USE [IOT2020];

/* Read-only post-validation after script 104 and Task DWS reload. */
SET NOCOUNT ON;

IF DB_NAME() <> N'IOT2020'
BEGIN
    THROW 58520, N'Expected database IOT2020.', 1;
END;

DECLARE @window_end DATETIME2(3) = SYSDATETIME();
DECLARE @window_start DATETIME2(3) = DATEADD(DAY, -30, @window_end);

;WITH latest_master_robot AS
(
    SELECT
        master_row.[id] AS [amr_id],
        master_row.[name] AS [robot_code],
        ROW_NUMBER() OVER (PARTITION BY master_row.[id] ORDER BY master_row.[ods_row_id] DESC) AS [rn]
    FROM [ODS].[MA_AMR] AS master_row
)
SELECT
    COUNT_BIG(*) AS [scoped_dwd_battery_rows],
    SUM(CASE WHEN master_robot.[amr_id] IS NOT NULL
                  AND (ISNULL(battery_fact.[robot_id], N'') <> CONVERT(NVARCHAR(100), master_robot.[amr_id])
                    OR ISNULL(battery_fact.[robot_code], N'') <> ISNULL(master_robot.[robot_code], N''))
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [remaining_exact_mapping_mismatches],
    SUM(CASE WHEN master_robot.[amr_id] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [unmapped_source_rows]
FROM [DWD].[fact_robot_battery] AS battery_fact
LEFT JOIN [ODS].[robot_battery_history] AS ods_battery
    ON ods_battery.[ods_row_id] = battery_fact.[source_ods_row_id]
LEFT JOIN latest_master_robot AS master_robot
    ON master_robot.[amr_id] = ods_battery.[amr_id]
   AND master_robot.[rn] = 1
WHERE battery_fact.[sample_time] >= @window_start
  AND battery_fact.[sample_time] < @window_end
  AND battery_fact.[source_schema] = N'ODS'
  AND battery_fact.[source_table] = N'robot_battery_history';

SELECT
    task_hourly.[robot_code],
    COUNT_BIG(*) AS [full_state_exception_hours],
    MIN(task_hourly.[stat_hour]) AS [first_exception_hour],
    MAX(task_hourly.[stat_hour]) AS [last_exception_hour]
FROM [DWS].[dws_robot_task_hourly] AS task_hourly
WHERE task_hourly.[stat_hour] >= @window_start
  AND task_hourly.[stat_hour] < @window_end
  AND task_hourly.[data_unavailable_seconds] = 3600
GROUP BY task_hourly.[robot_code]
ORDER BY [full_state_exception_hours] DESC, task_hourly.[robot_code];

SELECT
    COUNT_BIG(*) AS [full_state_exception_hours],
    COUNT_BIG(DISTINCT task_hourly.[robot_code]) AS [robots_with_full_state_exception]
FROM [DWS].[dws_robot_task_hourly] AS task_hourly
WHERE task_hourly.[stat_hour] >= @window_start
  AND task_hourly.[stat_hour] < @window_end
  AND task_hourly.[data_unavailable_seconds] = 3600;
