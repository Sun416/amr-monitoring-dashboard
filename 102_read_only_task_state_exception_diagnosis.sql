/*
    Read-only diagnosis for Task Analytics state-data exceptions.

    A DWS task hour is fully exceptional only when all 3,600 seconds are
    data_unavailable: no execution interval, no charging interval, no waiting
    interval, and no observed battery interval from which "no task" can be
    established.

    This script separates missing DWD battery evidence from task/queue event
    coverage. It does not write to any layer.
*/
SET NOCOUNT ON;

DECLARE @analysis_end DATETIME2(3);
DECLARE @analysis_start DATETIME2(3);

SELECT @analysis_end = DATEADD(HOUR, 1, MAX(task_hour.[stat_hour]))
FROM [DWS].[dws_robot_task_hourly] AS task_hour;

IF @analysis_end IS NULL
BEGIN
    THROW 58501, N'DWS task-hourly data is unavailable.', 1;
END;

SET @analysis_start = DATEADD(DAY, -30, @analysis_end);

;WITH battery_hour AS
(
    SELECT
        DATEADD(HOUR, DATEDIFF(HOUR, 0, battery.[sample_time]), 0) AS [stat_hour],
        battery.[robot_code],
        COUNT_BIG(1) AS [battery_sample_count],
        MAX(battery.[sample_time]) AS [latest_battery_sample_time]
    FROM [DWD].[fact_robot_battery] AS battery
    WHERE battery.[sample_time] >= DATEADD(MINUTE, -5, @analysis_start)
      AND battery.[sample_time] < @analysis_end
      AND NULLIF(LTRIM(RTRIM(battery.[robot_code])), N'') IS NOT NULL
    GROUP BY
        DATEADD(HOUR, DATEDIFF(HOUR, 0, battery.[sample_time]), 0),
        battery.[robot_code]
),
event_hour AS
(
    SELECT
        DATEADD(HOUR, DATEDIFF(HOUR, 0, event_row.[event_time]), 0) AS [stat_hour],
        event_row.[robot_code],
        COUNT_BIG(1) AS [task_event_count]
    FROM [DWD].[fact_robot_operation_event] AS event_row
    WHERE event_row.[event_time] >= @analysis_start
      AND event_row.[event_time] < @analysis_end
      AND event_row.[event_type] IN (N'QUEUE_ENQUEUED', N'JOB_STARTED', N'SUBJOB_STARTED', N'JOB_ENDED')
      AND NULLIF(LTRIM(RTRIM(event_row.[robot_code])), N'') IS NOT NULL
    GROUP BY
        DATEADD(HOUR, DATEDIFF(HOUR, 0, event_row.[event_time]), 0),
        event_row.[robot_code]
),
queue_hour AS
(
    SELECT
        DATEADD(HOUR, DATEDIFF(HOUR, 0, queue_fact.[event_time]), 0) AS [stat_hour],
        queue_fact.[robot_code],
        COUNT_BIG(DISTINCT queue_fact.[queue_id]) AS [queue_count]
    FROM [DWD].[fact_amr_queue] AS queue_fact
    WHERE queue_fact.[event_time] >= @analysis_start
      AND queue_fact.[event_time] < @analysis_end
      AND NULLIF(LTRIM(RTRIM(queue_fact.[robot_code])), N'') IS NOT NULL
    GROUP BY
        DATEADD(HOUR, DATEDIFF(HOUR, 0, queue_fact.[event_time]), 0),
        queue_fact.[robot_code]
),
joined AS
(
    SELECT
        task_hour.[stat_hour],
        task_hour.[robot_code],
        task_hour.[executing_seconds],
        task_hour.[charging_seconds],
        task_hour.[waiting_seconds],
        task_hour.[no_task_seconds],
        task_hour.[data_unavailable_seconds],
        COALESCE(battery_hour.[battery_sample_count], 0) AS [battery_sample_count],
        COALESCE(event_hour.[task_event_count], 0) AS [task_event_count],
        COALESCE(queue_hour.[queue_count], 0) AS [queue_count]
    FROM [DWS].[dws_robot_task_hourly] AS task_hour
    LEFT JOIN battery_hour
        ON battery_hour.[stat_hour] = task_hour.[stat_hour]
       AND battery_hour.[robot_code] = task_hour.[robot_code]
    LEFT JOIN event_hour
        ON event_hour.[stat_hour] = task_hour.[stat_hour]
       AND event_hour.[robot_code] = task_hour.[robot_code]
    LEFT JOIN queue_hour
        ON queue_hour.[stat_hour] = task_hour.[stat_hour]
       AND queue_hour.[robot_code] = task_hour.[robot_code]
    WHERE task_hour.[stat_hour] >= @analysis_start
      AND task_hour.[stat_hour] < @analysis_end
)
SELECT
    joined.[robot_code],
    COUNT_BIG(1) AS [dws_robot_hours],
    SUM(CASE WHEN joined.[data_unavailable_seconds] = 3600 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [full_exception_hours],
    SUM(CASE WHEN joined.[data_unavailable_seconds] > 0 AND joined.[data_unavailable_seconds] < 3600 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [partial_gap_hours],
    SUM(CASE WHEN joined.[data_unavailable_seconds] = 3600 AND joined.[battery_sample_count] = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [full_exception_without_battery_hour],
    SUM(CASE WHEN joined.[data_unavailable_seconds] = 3600 AND joined.[battery_sample_count] > 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [full_exception_with_battery_hour],
    SUM(CASE WHEN joined.[data_unavailable_seconds] = 3600 AND joined.[task_event_count] > 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [full_exception_with_task_event_hour],
    SUM(CASE WHEN joined.[data_unavailable_seconds] = 3600 AND joined.[queue_count] > 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [full_exception_with_queue_hour],
    MAX(CASE WHEN joined.[battery_sample_count] > 0 THEN joined.[stat_hour] END) AS [last_battery_hour],
    MAX(CASE WHEN joined.[task_event_count] > 0 THEN joined.[stat_hour] END) AS [last_task_event_hour],
    MAX(CASE WHEN joined.[queue_count] > 0 THEN joined.[stat_hour] END) AS [last_queue_hour],
    CASE
        WHEN SUM(CASE WHEN joined.[data_unavailable_seconds] = 3600 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) = 0
            THEN N'NO_FULL_EXCEPTION'
        WHEN SUM(CASE WHEN joined.[data_unavailable_seconds] = 3600 AND joined.[battery_sample_count] = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
             = SUM(CASE WHEN joined.[data_unavailable_seconds] = 3600 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            THEN N'MISSING_DWD_BATTERY_EVIDENCE'
        WHEN SUM(CASE WHEN joined.[data_unavailable_seconds] = 3600 AND joined.[battery_sample_count] > 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) > 0
            THEN N'BATTERY_PRESENT_BUT_HOURLY_CLASSIFICATION_NEEDS_REVIEW'
        ELSE N'MIXED_SOURCE_COVERAGE'
    END AS [evidence_classification]
FROM joined
GROUP BY joined.[robot_code]
ORDER BY [full_exception_hours] DESC, joined.[robot_code];

;WITH daily_state AS
(
    SELECT
        CONVERT(DATE, task_hour.[stat_hour]) AS [stat_date],
        COUNT_BIG(1) AS [dws_robot_hours],
        SUM(CASE WHEN task_hour.[data_unavailable_seconds] = 3600 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [full_exception_hours],
        SUM(task_hour.[data_unavailable_seconds]) AS [data_unavailable_seconds],
        SUM(task_hour.[executing_seconds]) AS [executing_seconds],
        SUM(task_hour.[charging_seconds]) AS [charging_seconds],
        SUM(task_hour.[waiting_seconds]) AS [waiting_seconds],
        SUM(task_hour.[no_task_seconds]) AS [no_task_seconds]
    FROM [DWS].[dws_robot_task_hourly] AS task_hour
    WHERE task_hour.[stat_hour] >= @analysis_start
      AND task_hour.[stat_hour] < @analysis_end
    GROUP BY CONVERT(DATE, task_hour.[stat_hour])
)
SELECT
    daily_state.[stat_date],
    daily_state.[dws_robot_hours],
    daily_state.[full_exception_hours],
    daily_state.[data_unavailable_seconds],
    daily_state.[executing_seconds],
    daily_state.[charging_seconds],
    daily_state.[waiting_seconds],
    daily_state.[no_task_seconds]
FROM daily_state
ORDER BY daily_state.[stat_date] DESC;

SELECT
    N'DWD.fact_robot_battery' AS [source_name],
    COUNT_BIG(1) AS [row_count],
    COUNT(DISTINCT battery.[robot_code]) AS [robot_count],
    MIN(battery.[sample_time]) AS [first_event_time],
    MAX(battery.[sample_time]) AS [last_event_time]
FROM [DWD].[fact_robot_battery] AS battery
WHERE battery.[sample_time] >= @analysis_start
  AND battery.[sample_time] < @analysis_end

UNION ALL

SELECT
    N'DWD.fact_robot_operation_event',
    COUNT_BIG(1),
    COUNT(DISTINCT event_row.[robot_code]),
    MIN(event_row.[event_time]),
    MAX(event_row.[event_time])
FROM [DWD].[fact_robot_operation_event] AS event_row
WHERE event_row.[event_time] >= @analysis_start
  AND event_row.[event_time] < @analysis_end
  AND event_row.[event_type] IN (N'QUEUE_ENQUEUED', N'JOB_STARTED', N'SUBJOB_STARTED', N'JOB_ENDED')

UNION ALL

SELECT
    N'DWD.fact_amr_queue',
    COUNT_BIG(1),
    COUNT(DISTINCT queue_fact.[robot_code]),
    MIN(queue_fact.[event_time]),
    MAX(queue_fact.[event_time])
FROM [DWD].[fact_amr_queue] AS queue_fact
WHERE queue_fact.[event_time] >= @analysis_start
  AND queue_fact.[event_time] < @analysis_end;

;WITH active_task_robot AS
(
    SELECT DISTINCT task_hour.[robot_code]
    FROM [DWS].[dws_robot_task_hourly] AS task_hour
    WHERE task_hour.[stat_hour] >= @analysis_start
      AND task_hour.[stat_hour] < @analysis_end
),
battery_window AS
(
    SELECT
        battery.[robot_code],
        battery.[sample_time],
        CASE
            WHEN NULLIF(LTRIM(RTRIM(battery.[charging_status])), N'') IS NOT NULL THEN CONVERT(BIT, 1)
            ELSE CONVERT(BIT, 0)
        END AS [has_charging_status],
        LAG(battery.[sample_time]) OVER
        (
            PARTITION BY battery.[robot_code]
            ORDER BY battery.[sample_time]
        ) AS [prior_sample_time]
    FROM [DWD].[fact_robot_battery] AS battery
    INNER JOIN active_task_robot AS active_robot
        ON active_robot.[robot_code] = battery.[robot_code]
    WHERE battery.[sample_time] >= @analysis_start
      AND battery.[sample_time] < @analysis_end
),
battery_coverage AS
(
    SELECT
        battery_window.[robot_code],
        COUNT_BIG(1) AS [battery_rows],
        SUM(CASE WHEN battery_window.[has_charging_status] = CONVERT(BIT, 1) THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [valid_status_rows],
        MIN(battery_window.[sample_time]) AS [first_battery_sample_time],
        MAX(battery_window.[sample_time]) AS [last_battery_sample_time],
        MAX(DATEDIFF(SECOND, battery_window.[prior_sample_time], battery_window.[sample_time])) AS [maximum_sample_gap_seconds]
    FROM battery_window
    GROUP BY battery_window.[robot_code]
)
SELECT
    active_robot.[robot_code],
    COALESCE(coverage.[battery_rows], 0) AS [battery_rows],
    COALESCE(coverage.[valid_status_rows], 0) AS [valid_status_rows],
    coverage.[first_battery_sample_time],
    coverage.[last_battery_sample_time],
    coverage.[maximum_sample_gap_seconds],
    CASE
        WHEN COALESCE(coverage.[battery_rows], 0) = 0 THEN N'NO_DWD_BATTERY_ROWS_FOR_CURRENT_ROBOT_CODE'
        WHEN COALESCE(coverage.[valid_status_rows], 0) = 0 THEN N'BATTERY_ROWS_HAVE_NO_CHARGING_STATUS'
        WHEN COALESCE(coverage.[maximum_sample_gap_seconds], 0) > 300 THEN N'BATTERY_CADENCE_EXCEEDS_5_MINUTE_CLASSIFICATION_GAP'
        ELSE N'BATTERY_COVERAGE_PRESENT'
    END AS [battery_evidence_assessment]
FROM active_task_robot AS active_robot
LEFT JOIN battery_coverage AS coverage
    ON coverage.[robot_code] = active_robot.[robot_code]
ORDER BY active_robot.[robot_code];

;WITH active_task_robot AS
(
    SELECT DISTINCT task_hour.[robot_code]
    FROM [DWS].[dws_robot_task_hourly] AS task_hour
    WHERE task_hour.[stat_hour] >= @analysis_start
      AND task_hour.[stat_hour] < @analysis_end
)
SELECT TOP (50)
    battery.[robot_code],
    COUNT_BIG(1) AS [battery_rows],
    COUNT_BIG(CASE WHEN NULLIF(LTRIM(RTRIM(battery.[charging_status])), N'') IS NOT NULL THEN 1 END) AS [valid_status_rows],
    MIN(battery.[sample_time]) AS [first_battery_sample_time],
    MAX(battery.[sample_time]) AS [last_battery_sample_time]
FROM [DWD].[fact_robot_battery] AS battery
LEFT JOIN active_task_robot AS active_robot
    ON active_robot.[robot_code] = battery.[robot_code]
WHERE battery.[sample_time] >= @analysis_start
  AND battery.[sample_time] < @analysis_end
  AND active_robot.[robot_code] IS NULL
GROUP BY battery.[robot_code]
ORDER BY [battery_rows] DESC, battery.[robot_code];
