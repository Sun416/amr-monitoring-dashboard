USE [IOT2020];

/*
  Read-only diagnosis for the exact Task Analytics window currently shown in UI.
  A full exception is a robot-hour with 3,600 data-unavailable seconds.
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

DECLARE @analysis_start DATETIME2(3) = '2026-08-03T09:00:00';
DECLARE @analysis_end DATETIME2(3) = '2026-08-04T15:00:00';

IF @analysis_end <= @analysis_start
BEGIN
    THROW 58540, N'@analysis_end must be after @analysis_start.', 1;
END;

;WITH full_exception AS
(
    SELECT
        task_hour.[robot_code],
        task_hour.[stat_hour]
    FROM [DWS].[dws_robot_task_hourly] AS task_hour
    WHERE task_hour.[stat_hour] >= @analysis_start
      AND task_hour.[stat_hour] < @analysis_end
      AND task_hour.[data_unavailable_seconds] = 3600
), per_robot AS
(
    SELECT
        full_exception.[robot_code],
        COUNT_BIG(*) AS [full_exception_hours],
        MIN(full_exception.[stat_hour]) AS [first_exception_hour],
        MAX(full_exception.[stat_hour]) AS [last_exception_hour]
    FROM full_exception
    GROUP BY full_exception.[robot_code]
), battery_window AS
(
    SELECT
        battery.[robot_code],
        COUNT_BIG(*) AS [battery_rows_in_window],
        MAX(battery.[sample_time]) AS [last_battery_event_time]
    FROM [DWD].[fact_robot_battery] AS battery
    WHERE battery.[sample_time] >= @analysis_start
      AND battery.[sample_time] < @analysis_end
    GROUP BY battery.[robot_code]
), task_window AS
(
    SELECT
        event_row.[robot_code],
        COUNT_BIG(*) AS [task_events_in_window],
        MAX(event_row.[event_time]) AS [last_task_event_time]
    FROM [DWD].[fact_robot_operation_event] AS event_row
    WHERE event_row.[event_time] >= @analysis_start
      AND event_row.[event_time] < @analysis_end
      AND event_row.[event_type] IN (N'QUEUE_ENQUEUED', N'JOB_STARTED', N'SUBJOB_STARTED', N'JOB_ENDED')
    GROUP BY event_row.[robot_code]
), exception_hour_evidence AS
(
    SELECT
        full_exception.[robot_code],
        COUNT_BIG(DISTINCT CASE WHEN battery.[battery_fact_id] IS NOT NULL THEN full_exception.[stat_hour] END) AS [full_exception_hours_with_battery_event],
        COUNT_BIG(DISTINCT CASE WHEN event_row.[operation_event_fact_id] IS NOT NULL THEN full_exception.[stat_hour] END) AS [full_exception_hours_with_task_event]
    FROM full_exception
    LEFT JOIN [DWD].[fact_robot_battery] AS battery
        ON battery.[robot_code] = full_exception.[robot_code]
       AND battery.[sample_time] >= full_exception.[stat_hour]
       AND battery.[sample_time] < DATEADD(HOUR, 1, full_exception.[stat_hour])
    LEFT JOIN [DWD].[fact_robot_operation_event] AS event_row
        ON event_row.[robot_code] = full_exception.[robot_code]
       AND event_row.[event_time] >= full_exception.[stat_hour]
       AND event_row.[event_time] < DATEADD(HOUR, 1, full_exception.[stat_hour])
       AND event_row.[event_type] IN (N'QUEUE_ENQUEUED', N'JOB_STARTED', N'SUBJOB_STARTED', N'JOB_ENDED')
    GROUP BY full_exception.[robot_code]
)
SELECT
    per_robot.[robot_code],
    per_robot.[full_exception_hours],
    per_robot.[first_exception_hour],
    per_robot.[last_exception_hour],
    COALESCE(battery_window.[battery_rows_in_window], 0) AS [battery_rows_in_window],
    battery_window.[last_battery_event_time],
    COALESCE(task_window.[task_events_in_window], 0) AS [task_events_in_window],
    task_window.[last_task_event_time],
    COALESCE(exception_hour_evidence.[full_exception_hours_with_battery_event], 0) AS [exception_hours_with_battery_event],
    COALESCE(exception_hour_evidence.[full_exception_hours_with_task_event], 0) AS [exception_hours_with_task_event],
    CASE
        WHEN COALESCE(exception_hour_evidence.[full_exception_hours_with_battery_event], 0) > 0
            THEN N'CLASSIFICATION_REVIEW_REQUIRED'
        WHEN COALESCE(battery_window.[battery_rows_in_window], 0) = 0
            THEN N'NO_BATTERY_EVENT_IN_SELECTED_WINDOW'
        WHEN COALESCE(task_window.[task_events_in_window], 0) > 0
            THEN N'TASK_EVENT_EXISTS_BUT_BATTERY_EVENT_MISSING'
        ELSE N'NO_STATE_EVIDENCE_IN_SELECTED_WINDOW'
    END AS [diagnosis]
FROM per_robot
LEFT JOIN battery_window
    ON battery_window.[robot_code] = per_robot.[robot_code]
LEFT JOIN task_window
    ON task_window.[robot_code] = per_robot.[robot_code]
LEFT JOIN exception_hour_evidence
    ON exception_hour_evidence.[robot_code] = per_robot.[robot_code]
ORDER BY per_robot.[full_exception_hours] DESC, per_robot.[robot_code];

SELECT
    COUNT_BIG(*) AS [full_exception_robot_hours],
    COUNT_BIG(DISTINCT task_hour.[robot_code]) AS [affected_robot_count]
FROM [DWS].[dws_robot_task_hourly] AS task_hour
WHERE task_hour.[stat_hour] >= @analysis_start
  AND task_hour.[stat_hour] < @analysis_end
  AND task_hour.[data_unavailable_seconds] = 3600;
