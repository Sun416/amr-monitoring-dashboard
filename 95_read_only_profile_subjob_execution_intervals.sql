/*
  Read-only assessment of DWD subjob intervals as the possible execution-time source.
  The recent 24-hour window matches Task Analytics; the 7-day profile checks coverage.
*/
SET NOCOUNT ON;

DECLARE @window_end DATETIME2(0) = DATEADD(HOUR, DATEDIFF(HOUR, 0, SYSDATETIME()) + 1, 0);
DECLARE @window_start DATETIME2(0) = DATEADD(DAY, -1, @window_end);
DECLARE @profile_start DATETIME2(0) = DATEADD(DAY, -7, @window_end);

SELECT
    COUNT_BIG(1) AS subjob_rows_overlapping_7_days,
    SUM(CASE WHEN s.subjob_start_time IS NOT NULL AND s.subjob_end_time IS NOT NULL AND s.subjob_end_time >= s.subjob_start_time THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS closed_valid_interval_count,
    SUM(CASE WHEN s.subjob_start_time IS NOT NULL AND s.subjob_end_time IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS unresolved_interval_count,
    SUM(CASE WHEN s.subjob_start_time IS NULL OR s.subjob_end_time IS NULL OR s.subjob_end_time < s.subjob_start_time THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS invalid_or_incomplete_interval_count,
    MIN(s.subjob_start_time) AS earliest_start_time,
    MAX(s.subjob_end_time) AS latest_end_time
FROM DWD.fact_amr_subjob AS s
WHERE s.subjob_start_time < @window_end
  AND COALESCE(s.subjob_end_time, @window_end) > @profile_start;

SELECT
    s.robot_code,
    COUNT_BIG(1) AS rows_overlapping_recent_24_hours,
    SUM(CASE WHEN s.subjob_start_time IS NOT NULL AND s.subjob_end_time IS NOT NULL AND s.subjob_end_time >= s.subjob_start_time THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS closed_valid_interval_count,
    SUM(CASE WHEN s.subjob_start_time IS NOT NULL AND s.subjob_end_time IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS unresolved_interval_count,
    SUM(CASE WHEN s.subjob_start_time IS NOT NULL AND s.subjob_end_time IS NOT NULL AND s.subjob_end_time >= s.subjob_start_time
             THEN DATEDIFF_BIG(SECOND, CASE WHEN s.subjob_start_time < @window_start THEN @window_start ELSE s.subjob_start_time END, CASE WHEN s.subjob_end_time > @window_end THEN @window_end ELSE s.subjob_end_time END)
             ELSE CONVERT(BIGINT, 0) END) AS closed_interval_seconds_before_overlap_union
FROM DWD.fact_amr_subjob AS s
WHERE s.subjob_start_time < @window_end
  AND COALESCE(s.subjob_end_time, @window_end) > @window_start
GROUP BY s.robot_code
ORDER BY closed_valid_interval_count DESC, s.robot_code;

SELECT TOP (30)
    s.robot_code,
    s.subjob_id,
    s.job_id,
    s.subjob_status,
    s.subjob_start_time,
    s.subjob_end_time,
    DATEDIFF_BIG(SECOND, s.subjob_start_time, s.subjob_end_time) AS source_duration_seconds,
    s.source_table,
    s.source_ods_row_id
FROM DWD.fact_amr_subjob AS s
WHERE s.subjob_start_time >= @profile_start
  AND s.subjob_end_time IS NOT NULL
  AND s.subjob_end_time >= s.subjob_start_time
ORDER BY s.subjob_end_time DESC, s.source_ods_row_id DESC;
