/* Read-only comparison of all currently available DWD execution-time evidence. */
SET NOCOUNT ON;

SELECT
    N'DWD.fact_robot_operation_event / ODS.TA_AMR' AS source_name,
    COUNT_BIG(1) AS source_event_row_count,
    MAX(CASE WHEN e.source_event_part = N'START' THEN e.event_time END) AS latest_start_event_time,
    MAX(CASE WHEN e.source_event_part = N'END' THEN e.event_time END) AS latest_end_event_time,
    SUM(CASE WHEN e.source_event_part = N'START' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS start_event_count,
    SUM(CASE WHEN e.source_event_part = N'END' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS end_event_count
FROM DWD.fact_robot_operation_event AS e
WHERE e.source_schema = N'ODS'
  AND e.source_table = N'TA_AMR'

UNION ALL

SELECT
    N'DWD.fact_amr_subjob' AS source_name,
    COUNT_BIG(1),
    MAX(s.subjob_start_time),
    MAX(s.subjob_end_time),
    SUM(CASE WHEN s.subjob_start_time IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    SUM(CASE WHEN s.subjob_end_time IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
FROM DWD.fact_amr_subjob AS s;

SELECT
    w.source_schema,
    w.source_table,
    w.target_schema,
    w.target_table,
    w.load_mode,
    w.last_bigint_value,
    w.last_datetime_value,
    w.last_load_time,
    w.is_enabled
FROM DWD.etl_watermark AS w
WHERE w.target_table IN (N'fact_amr_subjob', N'fact_robot_job')
   OR w.source_table IN (N'AMR_Subjob_Analyze', N'TA_AMR');

;WITH closed_task AS
(
    SELECT
        s.robot_code,
        s.source_ods_row_id,
        s.event_time AS start_time,
        e.event_time AS end_time
    FROM DWD.fact_robot_operation_event AS s
    INNER JOIN DWD.fact_robot_operation_event AS e
        ON e.source_schema = s.source_schema
       AND e.source_table = s.source_table
       AND e.source_ods_row_id = s.source_ods_row_id
       AND e.source_event_part = N'END'
    WHERE s.source_schema = N'ODS'
      AND s.source_table = N'TA_AMR'
      AND s.source_event_part = N'START'
      AND e.event_time >= s.event_time
)
SELECT TOP (20)
    c.robot_code,
    c.source_ods_row_id,
    c.start_time,
    c.end_time,
    DATEDIFF_BIG(SECOND, c.start_time, c.end_time) AS duration_seconds
FROM closed_task AS c
ORDER BY c.end_time DESC, c.source_ods_row_id DESC;
