/*
  Read-only validation for the most recent 24-hour Task Analytics DWS load.
  The window matches 83_load_dws_robot_task_hourly.sql.
*/
SET NOCOUNT ON;

DECLARE @window_end DATETIME2(0) = DATEADD(HOUR, DATEDIFF(HOUR, 0, SYSDATETIME()) + 1, 0);
DECLARE @window_start DATETIME2(0) = DATEADD(DAY, -1, @window_end);

/* 1. Source battery coverage for enabled robots only. */
SELECT
    b.robot_code,
    COUNT_BIG(1) AS battery_sample_count,
    SUM(CASE
            WHEN UPPER(LTRIM(RTRIM(COALESCE(b.charging_status, N'')))) = N'CHARGING'
                THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END) AS charging_sample_count,
    MIN(b.sample_time) AS first_sample_time,
    MAX(b.sample_time) AS last_sample_time
FROM DWD.fact_robot_battery AS b WITH (INDEX(IX_DWD_fact_robot_battery_robot_time))
INNER JOIN DWD.dim_amr_robot AS r
    ON r.robot_code = b.robot_code
   AND r.is_enabled = CONVERT(BIT, 1)
WHERE b.sample_time >= @window_start
  AND b.sample_time < @window_end
GROUP BY b.robot_code
ORDER BY charging_sample_count DESC, battery_sample_count DESC, b.robot_code;

/* 2. Every populated DWS hour must classify exactly 3,600 seconds. */
SELECT
    COUNT_BIG(1) AS dws_hour_row_count,
    SUM(CASE
            WHEN executing_seconds + charging_seconds + waiting_seconds + no_task_seconds + data_unavailable_seconds = 3600
                THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END) AS balanced_hour_row_count,
    SUM(CASE
            WHEN executing_seconds + charging_seconds + waiting_seconds + no_task_seconds + data_unavailable_seconds <> 3600
                THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END) AS unbalanced_hour_row_count,
    MIN(executing_seconds + charging_seconds + waiting_seconds + no_task_seconds + data_unavailable_seconds) AS minimum_classified_seconds,
    MAX(executing_seconds + charging_seconds + waiting_seconds + no_task_seconds + data_unavailable_seconds) AS maximum_classified_seconds
FROM DWS.dws_robot_task_hourly
WHERE stat_hour >= @window_start
  AND stat_hour < @window_end;

/* 3. Per-robot DWS distribution, so source coverage and classification can be reviewed together. */
SELECT
    h.robot_code,
    COUNT_BIG(1) AS hour_row_count,
    SUM(h.executing_seconds) AS executing_seconds,
    SUM(h.charging_seconds) AS charging_seconds,
    SUM(h.waiting_seconds) AS waiting_seconds,
    SUM(h.no_task_seconds) AS no_task_seconds,
    SUM(h.data_unavailable_seconds) AS data_unavailable_seconds,
    SUM(h.executing_seconds + h.charging_seconds + h.waiting_seconds + h.no_task_seconds + h.data_unavailable_seconds) AS classified_seconds
FROM DWS.dws_robot_task_hourly AS h
WHERE h.stat_hour >= @window_start
  AND h.stat_hour < @window_end
GROUP BY h.robot_code
ORDER BY h.robot_code;
