/* DWS-only Task Analytics API query. */
SET NOCOUNT ON;

DECLARE @requested_start DATETIME2(0) = TRY_CONVERT(DATETIME2(0), REPLACE(@task_analysis_start, N'T', N' '));
DECLARE @requested_end DATETIME2(0) = TRY_CONVERT(DATETIME2(0), REPLACE(@task_analysis_end, N'T', N' '));
DECLARE @analysis_start DATETIME2(0);
DECLARE @analysis_end DATETIME2(0);
DECLARE @anchor DATETIME2(0);
DECLARE @selected_robot_codes NVARCHAR(MAX) = NULLIF(LTRIM(RTRIM(@robot_codes)), N'');
DECLARE @selected_robot_xml XML = TRY_CONVERT(XML,
    CASE
        WHEN @selected_robot_codes IS NULL THEN N'<robots />'
        ELSE N'<robots><robot>' + REPLACE(@selected_robot_codes, N',', N'</robot><robot>') + N'</robot></robots>'
    END
);
DECLARE @selected_robots TABLE
(
    robot_code NVARCHAR(100) NOT NULL PRIMARY KEY
);

INSERT INTO @selected_robots (robot_code)
SELECT DISTINCT LTRIM(RTRIM(split.value(N'.', N'NVARCHAR(100)')))
FROM @selected_robot_xml.nodes(N'/robots/robot') AS robots(split)
WHERE LTRIM(RTRIM(split.value(N'.', N'NVARCHAR(100)'))) <> N'';

SELECT @anchor = DATEADD(HOUR, 1, MAX(h.stat_hour))
FROM [DWS].[dws_robot_task_hourly] AS h;

IF @requested_start IS NULL AND @requested_end IS NULL
BEGIN
    SET @requested_end = @anchor;
    SET @requested_start = DATEADD(HOUR, -24, @requested_end);
END;

IF @requested_start IS NULL OR @requested_end IS NULL OR @requested_end <= @requested_start
BEGIN
    THROW 51001, N'Task Analytics requires a valid start and end time.', 1;
END;

IF DATEDIFF(HOUR, @requested_start, @requested_end) > 720
BEGIN
    THROW 51002, N'Task Analytics supports an analysis window of at most 30 days.', 1;
END;

/*
  All Task Analytics serving facts are at hourly grain. Use only full hours
  contained in the requested window, never partial hours outside it.
*/
SET @analysis_start = DATEADD
(
    HOUR,
    DATEDIFF(HOUR, 0, @requested_start)
        + CASE
            WHEN @requested_start > DATEADD(HOUR, DATEDIFF(HOUR, 0, @requested_start), 0) THEN 1
            ELSE 0
          END,
    0
);
SET @analysis_end = DATEADD(HOUR, DATEDIFF(HOUR, 0, @requested_end), 0);

IF @analysis_end <= @analysis_start
BEGIN
    THROW 51003, N'Task Analytics requires at least one full calendar hour inside the selected time range.', 1;
END;

;WITH scoped_hourly AS
(
    SELECT
        h.[stat_hour],
        h.[robot_code],
        h.[executing_seconds],
        h.[charging_seconds],
        h.[waiting_seconds],
        h.[no_task_seconds],
        h.[data_unavailable_seconds],
        h.[accepted_queue_count],
        h.[task_started_count],
        h.[subtask_started_count],
        h.[task_completed_count],
        h.[first_source_event_time],
        h.[last_source_event_time],
        h.[dws_load_time]
    FROM [DWS].[dws_robot_task_hourly] AS h
    WHERE h.[stat_hour] >= @analysis_start
      AND h.[stat_hour] < @analysis_end
      AND
      (
          NOT EXISTS (SELECT 1 FROM @selected_robots)
          OR EXISTS
          (
              SELECT 1
              FROM @selected_robots AS selected
              WHERE selected.[robot_code] = h.[robot_code]
          )
      )
)
SELECT
    CONVERT(NVARCHAR(19), @requested_start, 120) AS [requested_start],
    CONVERT(NVARCHAR(19), @requested_end, 120) AS [requested_end],
    CONVERT(NVARCHAR(19), @analysis_start, 120) AS [analysis_start],
    CONVERT(NVARCHAR(19), @analysis_end, 120) AS [analysis_end],
    CONVERT(NVARCHAR(19), @anchor, 120) AS [latest_available_end],
    (SELECT COUNT(1) FROM @selected_robots) AS [selected_robot_count],
    COUNT_BIG(1) AS [hourly_row_count],
    COUNT(DISTINCT h.[robot_code]) AS [robot_count],
    SUM(h.[executing_seconds]) AS [executing_seconds],
    SUM(h.[charging_seconds]) AS [charging_seconds],
    SUM(h.[waiting_seconds]) AS [waiting_seconds],
    SUM(h.[no_task_seconds]) AS [no_task_seconds],
    SUM(h.[data_unavailable_seconds]) AS [data_unavailable_seconds],
    SUM(CASE WHEN h.[data_unavailable_seconds] > 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [data_gap_robot_hour_count],
    SUM(CASE WHEN h.[data_unavailable_seconds] = 3600 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [data_exception_robot_hour_count],
    COUNT(DISTINCT CASE WHEN h.[data_unavailable_seconds] = 3600 THEN h.[robot_code] END) AS [data_exception_robot_count],
    SUM(h.[accepted_queue_count]) AS [accepted_queue_count],
    SUM(h.[task_started_count]) AS [task_started_count],
    SUM(h.[subtask_started_count]) AS [subtask_started_count],
    SUM(h.[task_completed_count]) AS [task_completed_count],
    COALESCE(MAX(assignment.[assigned_task_count]), 0) AS [queue_assigned_task_count],
    COALESCE(MAX(assignment.[completed_task_count]), 0) AS [queue_completed_task_count],
    COALESCE(MAX(assignment.[task_robot_count]), 0) AS [task_activity_robot_count],
    CONVERT(NVARCHAR(19), MAX(h.[last_source_event_time]), 120) AS [latest_source_event_time],
    CONVERT(NVARCHAR(19), MAX(h.[dws_load_time]), 120) AS [latest_dws_load_time]
FROM scoped_hourly AS h
OUTER APPLY
(
    SELECT
        SUM(task_hour.[assigned_task_count]) AS [assigned_task_count],
        SUM(task_hour.[completed_task_count]) AS [completed_task_count],
        COUNT(DISTINCT task_hour.[robot_code]) AS [task_robot_count]
    FROM [DWS].[dws_robot_assigned_task_hourly] AS task_hour
    WHERE task_hour.[stat_hour] >= @analysis_start
      AND task_hour.[stat_hour] < @analysis_end
      AND
      (
          NOT EXISTS (SELECT 1 FROM @selected_robots)
          OR EXISTS
          (
              SELECT 1
              FROM @selected_robots AS selected
              WHERE selected.[robot_code] = task_hour.[robot_code]
          )
      )
) AS assignment;

SELECT
    robot.[robot_code],
    MAX(robot.[robot_id]) AS [robot_id],
    CONVERT(NVARCHAR(19), MAX(robot.[dws_load_time]), 120) AS [latest_dws_load_time]
FROM [DWS].[dws_robot_task_hourly] AS robot
GROUP BY robot.[robot_code]
ORDER BY robot.[robot_code];

;WITH scoped_hourly AS
(
    SELECT
        h.[stat_hour],
        h.[robot_code],
        h.[executing_seconds],
        h.[charging_seconds],
        h.[waiting_seconds],
        h.[no_task_seconds],
        h.[data_unavailable_seconds],
        h.[accepted_queue_count],
        h.[task_started_count],
        h.[subtask_started_count],
        h.[task_completed_count]
    FROM [DWS].[dws_robot_task_hourly] AS h
    WHERE h.[stat_hour] >= @analysis_start
      AND h.[stat_hour] < @analysis_end
      AND
      (
          NOT EXISTS (SELECT 1 FROM @selected_robots)
          OR EXISTS
          (
              SELECT 1
              FROM @selected_robots AS selected
              WHERE selected.[robot_code] = h.[robot_code]
          )
      )
)
SELECT
    CONVERT(NVARCHAR(19), h.[stat_hour], 120) AS [stat_hour],
    h.[robot_code],
    SUM(h.[executing_seconds]) AS [executing_seconds],
    SUM(h.[charging_seconds]) AS [charging_seconds],
    SUM(h.[waiting_seconds]) AS [waiting_seconds],
    SUM(h.[no_task_seconds]) AS [no_task_seconds],
    SUM(h.[data_unavailable_seconds]) AS [data_unavailable_seconds],
    SUM(h.[accepted_queue_count]) AS [accepted_queue_count],
    SUM(h.[task_started_count]) AS [task_started_count],
    SUM(h.[subtask_started_count]) AS [subtask_started_count],
    SUM(h.[task_completed_count]) AS [task_completed_count]
FROM scoped_hourly AS h
GROUP BY h.[stat_hour], h.[robot_code]
ORDER BY h.[stat_hour], h.[robot_code];

SELECT TOP (10)
    calling_box.[calling_box_label],
    SUM(calling_box.[calling_box_count]) AS [calling_box_count],
    COUNT(DISTINCT calling_box.[robot_code]) AS [robot_count],
    CONVERT(NVARCHAR(19), MIN(calling_box.[first_called_at]), 120) AS [first_called_at],
    CONVERT(NVARCHAR(19), MAX(calling_box.[last_called_at]), 120) AS [last_called_at]
FROM [DWS].[dws_robot_calling_box_hourly] AS calling_box
WHERE calling_box.[stat_hour] >= @analysis_start
  AND calling_box.[stat_hour] < @analysis_end
  AND
  (
      NOT EXISTS (SELECT 1 FROM @selected_robots)
      OR EXISTS
      (
          SELECT 1
          FROM @selected_robots AS selected
          WHERE selected.[robot_code] = calling_box.[robot_code]
      )
  )
GROUP BY calling_box.[calling_box_label]
ORDER BY [calling_box_count] DESC, calling_box.[calling_box_label];

SELECT TOP (10)
    task_hour.[task_label],
    SUM(task_hour.[assigned_task_count]) AS [assigned_task_count],
    SUM(task_hour.[completed_task_count]) AS [completed_task_count],
    COUNT(DISTINCT task_hour.[robot_code]) AS [robot_count],
    CONVERT(NVARCHAR(19), MIN(task_hour.[first_assigned_at]), 120) AS [first_assigned_at],
    CONVERT(NVARCHAR(19), MAX(task_hour.[last_assigned_at]), 120) AS [last_assigned_at]
FROM [DWS].[dws_robot_assigned_task_hourly] AS task_hour
WHERE task_hour.[stat_hour] >= @analysis_start
  AND task_hour.[stat_hour] < @analysis_end
  AND
  (
      NOT EXISTS (SELECT 1 FROM @selected_robots)
      OR EXISTS
      (
          SELECT 1
          FROM @selected_robots AS selected
          WHERE selected.[robot_code] = task_hour.[robot_code]
      )
  )
GROUP BY task_hour.[task_label]
ORDER BY [assigned_task_count] DESC, task_hour.[task_label];

/*
  Bounded drill-down for the state-data exception KPI.
  This remains DWS-only: task state evidence is from task_hourly and battery
  evidence is from battery_hourly. The type describes coverage only, never a
  physical failure cause.
*/
;WITH exception_hour AS
(
    SELECT
        h.[stat_hour],
        h.[robot_code],
        h.[robot_id],
        h.[data_unavailable_seconds],
        h.[accepted_queue_count],
        h.[task_started_count],
        h.[subtask_started_count],
        h.[task_completed_count],
        h.[last_source_event_time]
    FROM [DWS].[dws_robot_task_hourly] AS h
    WHERE h.[stat_hour] >= @analysis_start
      AND h.[stat_hour] < @analysis_end
      AND h.[data_unavailable_seconds] > 0
      AND
      (
          NOT EXISTS (SELECT 1 FROM @selected_robots)
          OR EXISTS
          (
              SELECT 1
              FROM @selected_robots AS selected
              WHERE selected.[robot_code] = h.[robot_code]
          )
      )
)
SELECT TOP (100)
    CONVERT(NVARCHAR(19), exception_hour.[stat_hour], 120) AS [stat_hour],
    exception_hour.[robot_code],
    exception_hour.[robot_id],
    exception_hour.[data_unavailable_seconds],
    COALESCE(battery_hour.[sample_count], 0) AS [battery_event_count],
    COALESCE(battery_hour.[charging_sample_count], 0) AS [charging_sample_count],
    COALESCE
    (
        exception_hour.[accepted_queue_count]
        + exception_hour.[task_started_count]
        + exception_hour.[subtask_started_count]
        + exception_hour.[task_completed_count],
        0
    ) AS [task_event_count],
    CONVERT(NVARCHAR(19), battery_hour.[last_sample_time], 120) AS [battery_event_time_in_hour],
    CONVERT(NVARCHAR(19), exception_hour.[last_source_event_time], 120) AS [task_event_time_in_hour],
    CONVERT(NVARCHAR(19), last_battery.[last_battery_event_time_before_hour], 120) AS [last_battery_event_time_before_hour],
    CASE
        WHEN exception_hour.[data_unavailable_seconds] = 3600
         AND COALESCE(battery_hour.[sample_count], 0) = 0
         AND COALESCE
         (
             exception_hour.[accepted_queue_count]
             + exception_hour.[task_started_count]
             + exception_hour.[subtask_started_count]
             + exception_hour.[task_completed_count],
             0
         ) = 0
            THEN N'FULL_NO_BATTERY_OR_TASK_EVIDENCE'
        WHEN exception_hour.[data_unavailable_seconds] = 3600
         AND COALESCE(battery_hour.[sample_count], 0) = 0
            THEN N'FULL_TASK_EVENT_WITHOUT_BATTERY_EVIDENCE'
        WHEN exception_hour.[data_unavailable_seconds] = 3600
            THEN N'FULL_STATE_COVERAGE_GAP_UNRESOLVED'
        ELSE N'PARTIAL_STATE_COVERAGE_GAP'
    END AS [exception_type]
FROM exception_hour
LEFT JOIN [DWS].[dws_robot_battery_hourly] AS battery_hour
    ON battery_hour.[robot_code] = exception_hour.[robot_code]
   AND battery_hour.[stat_hour] = exception_hour.[stat_hour]
OUTER APPLY
(
    SELECT TOP (1)
        prior_battery_hour.[last_sample_time] AS [last_battery_event_time_before_hour]
    FROM [DWS].[dws_robot_battery_hourly] AS prior_battery_hour
    WHERE prior_battery_hour.[robot_code] = exception_hour.[robot_code]
      AND prior_battery_hour.[stat_hour] < exception_hour.[stat_hour]
      AND prior_battery_hour.[sample_count] > 0
    ORDER BY prior_battery_hour.[stat_hour] DESC
) AS last_battery
ORDER BY
    exception_hour.[data_unavailable_seconds] DESC,
    exception_hour.[stat_hour] DESC,
    exception_hour.[robot_code];
