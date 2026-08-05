USE [IOT2020];

/*
  Read-only preview for the Task Analytics state-exception drill-down.

  It uses the same durable DWS serving facts as the Web:
    - DWS.dws_robot_task_hourly
    - DWS.dws_robot_battery_hourly

  Grain: one robot + calendar hour with data_unavailable_seconds > 0.
  Exception types describe missing evidence only; they do not infer a physical
  cause such as a battery, WiFi, or robot hardware fault.
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

DECLARE @window_end DATETIME2(3);
DECLARE @window_start DATETIME2(3);

SELECT
    @window_end = DATEADD(HOUR, 1, MAX(task_hour.[stat_hour]))
FROM [DWS].[dws_robot_task_hourly] AS task_hour;

IF @window_end IS NULL
BEGIN
    THROW 58560, N'DWS.dws_robot_task_hourly has no serving rows.', 1;
END;

SET @window_start = DATEADD(DAY, -30, @window_end);

;WITH exception_hour AS
(
    SELECT
        task_hour.[stat_hour],
        task_hour.[robot_code],
        task_hour.[robot_id],
        task_hour.[data_unavailable_seconds],
        task_hour.[accepted_queue_count],
        task_hour.[task_started_count],
        task_hour.[subtask_started_count],
        task_hour.[task_completed_count],
        task_hour.[last_source_event_time]
    FROM [DWS].[dws_robot_task_hourly] AS task_hour
    WHERE task_hour.[stat_hour] >= @window_start
      AND task_hour.[stat_hour] < @window_end
      AND task_hour.[data_unavailable_seconds] > 0
)
SELECT TOP (50)
    exception_hour.[stat_hour],
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
    battery_hour.[last_sample_time] AS [battery_event_time_in_hour],
    exception_hour.[last_source_event_time] AS [task_event_time_in_hour],
    last_battery.[last_battery_event_time_before_hour],
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

;WITH exception_hour AS
(
    SELECT
        task_hour.[data_unavailable_seconds],
        COALESCE(battery_hour.[sample_count], 0) AS [battery_event_count],
        COALESCE
        (
            task_hour.[accepted_queue_count]
            + task_hour.[task_started_count]
            + task_hour.[subtask_started_count]
            + task_hour.[task_completed_count],
            0
        ) AS [task_event_count]
    FROM [DWS].[dws_robot_task_hourly] AS task_hour
    LEFT JOIN [DWS].[dws_robot_battery_hourly] AS battery_hour
        ON battery_hour.[robot_code] = task_hour.[robot_code]
       AND battery_hour.[stat_hour] = task_hour.[stat_hour]
    WHERE task_hour.[stat_hour] >= @window_start
      AND task_hour.[stat_hour] < @window_end
      AND task_hour.[data_unavailable_seconds] > 0
), typed_exception AS
(
    SELECT
        CASE
            WHEN exception_hour.[data_unavailable_seconds] = 3600
             AND exception_hour.[battery_event_count] = 0
             AND exception_hour.[task_event_count] = 0
                THEN N'FULL_NO_BATTERY_OR_TASK_EVIDENCE'
            WHEN exception_hour.[data_unavailable_seconds] = 3600
             AND exception_hour.[battery_event_count] = 0
                THEN N'FULL_TASK_EVENT_WITHOUT_BATTERY_EVIDENCE'
            WHEN exception_hour.[data_unavailable_seconds] = 3600
                THEN N'FULL_STATE_COVERAGE_GAP_UNRESOLVED'
            ELSE N'PARTIAL_STATE_COVERAGE_GAP'
        END AS [exception_type]
    FROM exception_hour
)
SELECT
    typed_exception.[exception_type],
    COUNT_BIG(*) AS [robot_hour_count]
FROM typed_exception
GROUP BY typed_exception.[exception_type]
ORDER BY typed_exception.[exception_type];

SELECT
    @window_start AS [window_start],
    @window_end AS [window_end],
    COUNT_BIG(*) AS [exception_row_count],
    SUM(CASE WHEN task_hour.[data_unavailable_seconds] = 3600 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [full_exception_robot_hour_count],
    SUM(task_hour.[data_unavailable_seconds]) AS [total_data_unavailable_seconds]
FROM [DWS].[dws_robot_task_hourly] AS task_hour
WHERE task_hour.[stat_hour] >= @window_start
  AND task_hour.[stat_hour] < @window_end
  AND task_hour.[data_unavailable_seconds] > 0;
