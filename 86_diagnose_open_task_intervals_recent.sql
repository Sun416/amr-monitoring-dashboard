/* Read-only diagnosis: open DWD task intervals that overlap the recent 24-hour window. */
SET NOCOUNT ON;

DECLARE @window_end DATETIME2(0) = DATEADD(HOUR, DATEDIFF(HOUR, 0, SYSDATETIME()) + 1, 0);
DECLARE @window_start DATETIME2(0) = DATEADD(DAY, -1, @window_end);

;WITH active_robot AS
(
    SELECT r.robot_code
    FROM DWD.dim_amr_robot AS r
    WHERE r.is_enabled = CONVERT(BIT, 1)
      AND r.robot_code IS NOT NULL
),
task_interval AS
(
    SELECT
        s.robot_code,
        s.source_ods_row_id,
        s.event_time AS start_time,
        e.event_time AS end_time
    FROM DWD.fact_robot_operation_event AS s
    INNER JOIN active_robot AS r
        ON r.robot_code = s.robot_code
    LEFT JOIN DWD.fact_robot_operation_event AS e
        ON e.source_schema = s.source_schema
       AND e.source_table = s.source_table
       AND e.source_ods_row_id = s.source_ods_row_id
       AND e.source_event_part = N'END'
    WHERE s.source_schema = N'ODS'
      AND s.source_table = N'TA_AMR'
      AND s.source_event_part = N'START'
      AND s.event_time < @window_end
      AND COALESCE(e.event_time, @window_end) > @window_start
)
SELECT
    i.robot_code,
    COUNT_BIG(1) AS interval_count_overlapping_window,
    SUM(CASE WHEN i.end_time IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS open_interval_count,
    MIN(i.start_time) AS earliest_interval_start,
    MAX(i.end_time) AS latest_interval_end
FROM task_interval AS i
GROUP BY i.robot_code
ORDER BY i.robot_code;

;WITH active_robot AS
(
    SELECT r.robot_code
    FROM DWD.dim_amr_robot AS r
    WHERE r.is_enabled = CONVERT(BIT, 1)
      AND r.robot_code IS NOT NULL
),
task_interval AS
(
    SELECT
        s.robot_code,
        s.source_ods_row_id,
        s.event_time AS start_time,
        e.event_time AS end_time
    FROM DWD.fact_robot_operation_event AS s
    INNER JOIN active_robot AS r
        ON r.robot_code = s.robot_code
    LEFT JOIN DWD.fact_robot_operation_event AS e
        ON e.source_schema = s.source_schema
       AND e.source_table = s.source_table
       AND e.source_ods_row_id = s.source_ods_row_id
       AND e.source_event_part = N'END'
    WHERE s.source_schema = N'ODS'
      AND s.source_table = N'TA_AMR'
      AND s.source_event_part = N'START'
      AND s.event_time < @window_end
      AND COALESCE(e.event_time, @window_end) > @window_start
)
SELECT TOP (30)
    i.robot_code,
    i.source_ods_row_id,
    i.start_time,
    i.end_time,
    DATEDIFF_BIG(SECOND, CASE WHEN i.start_time < @window_start THEN @window_start ELSE i.start_time END, COALESCE(i.end_time, @window_end)) AS seconds_inside_window
FROM task_interval AS i
WHERE i.end_time IS NULL
ORDER BY i.start_time, i.robot_code;

/* 3. The raw source status is required before any open interval is called Running. */
SELECT TOP (30)
    r.name AS robot_code,
    source_row.ods_row_id,
    source_row.start_time,
    source_row.end_time,
    source_row.status,
    source_row.queue_id,
    source_row.job_id,
    source_row.subjob_id,
    source_row.ods_load_time
FROM ODS.TA_AMR AS source_row
INNER JOIN ODS.MA_AMR AS r
    ON r.id = source_row.AMR_id
INNER JOIN DWD.dim_amr_robot AS enabled_robot
    ON enabled_robot.robot_code = r.name
   AND enabled_robot.is_enabled = CONVERT(BIT, 1)
WHERE source_row.start_time < @window_end
  AND source_row.end_time IS NULL
ORDER BY source_row.start_time, source_row.ods_row_id;
