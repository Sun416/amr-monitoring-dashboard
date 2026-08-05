USE [IOT2020];

/*
    Load DWS.dws_robot_task_hourly from DWD only.

    Classification is performed over exact interval boundaries, not by counting
    telemetry rows. Per atomic interval the precedence is:
      executing -> Charging -> Waiting -> No task -> Data unavailable.

    No task is assigned only when battery telemetry proves that the robot was
    observed in that interval. A battery gap is retained as Data unavailable.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'IOT2020'
BEGIN
    THROW 58300, N'Expected database IOT2020.', 1;
END;

/*
  The Web permits an exact Task Analytics period up to 30 days. Rebuild that
  full serving horizon from the reconciled DWD task/queue facts so all
  selectable hours share the same source lineage.
*/
DECLARE @window_end DATETIME2(3) = DATEADD(HOUR, DATEDIFF(HOUR, 0, SYSDATETIME()) + 1, 0);
DECLARE @window_start DATETIME2(3) = DATEADD(DAY, -30, @window_end);
DECLARE @battery_max_gap_seconds INT = 300;

/* The refresh is bounded to the current 30-day serving horizon. */

CREATE TABLE #active_robot
(
    [robot_code] NVARCHAR(100) NOT NULL PRIMARY KEY,
    [robot_id] NVARCHAR(100) NULL
);

INSERT INTO #active_robot ([robot_code], [robot_id])
SELECT
    robot_dim.[robot_code],
    robot_dim.[robot_id]
FROM [DWD].[dim_amr_robot] AS robot_dim
WHERE robot_dim.[is_enabled] = CONVERT(BIT, 1)
  AND NULLIF(LTRIM(RTRIM(robot_dim.[robot_code])), N'') IS NOT NULL;

IF NOT EXISTS (SELECT 1 FROM #active_robot)
BEGIN
    THROW 58302, N'No enabled DWD robot is available for Task Analytics.', 1;
END;

CREATE TABLE #execution_raw
(
    [robot_code] NVARCHAR(100) NOT NULL,
    [start_time] DATETIME2(3) NOT NULL,
    [end_time] DATETIME2(3) NOT NULL,
    [source_ods_row_id] BIGINT NOT NULL,
    PRIMARY KEY ([robot_code], [start_time], [end_time], [source_ods_row_id])
);

/*
  A source task without end_time is unresolved, not evidence of continuous execution.
  It is deliberately excluded here; battery evidence may still classify the interval as charging.
*/
INSERT INTO #execution_raw ([robot_code], [start_time], [end_time], [source_ods_row_id])
SELECT
    start_event.[robot_code],
    CASE WHEN start_event.[event_time] < @window_start THEN @window_start ELSE start_event.[event_time] END,
    CASE WHEN end_event.[event_time] > @window_end THEN @window_end ELSE end_event.[event_time] END,
    start_event.[source_ods_row_id]
FROM [DWD].[fact_robot_operation_event] AS start_event
INNER JOIN #active_robot AS active_robot
    ON active_robot.[robot_code] = start_event.[robot_code]
INNER JOIN [DWD].[fact_robot_operation_event] AS end_event
    ON end_event.[source_schema] = start_event.[source_schema]
   AND end_event.[source_table] = start_event.[source_table]
   AND end_event.[source_ods_row_id] = start_event.[source_ods_row_id]
   AND end_event.[source_event_part] = N'END'
WHERE start_event.[source_schema] = N'ODS'
  AND start_event.[source_table] = N'TA_AMR'
  AND start_event.[source_event_part] = N'START'
  AND start_event.[event_time] < @window_end
  AND end_event.[event_time] > @window_start
  AND end_event.[event_time] >= start_event.[event_time];

CREATE TABLE #execution_interval
(
    [robot_code] NVARCHAR(100) NOT NULL,
    [start_time] DATETIME2(3) NOT NULL,
    [end_time] DATETIME2(3) NOT NULL,
    PRIMARY KEY ([robot_code], [start_time], [end_time])
);

;WITH ordered AS
(
    SELECT
        source_row.[robot_code],
        source_row.[start_time],
        source_row.[end_time],
        MAX(source_row.[end_time]) OVER
        (
            PARTITION BY source_row.[robot_code]
            ORDER BY source_row.[start_time], source_row.[end_time], source_row.[source_ods_row_id]
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS [prior_max_end_time]
    FROM #execution_raw AS source_row
),
marked AS
(
    SELECT
        ordered.[robot_code],
        ordered.[start_time],
        ordered.[end_time],
        CASE WHEN ordered.[prior_max_end_time] IS NULL OR ordered.[prior_max_end_time] < ordered.[start_time] THEN 1 ELSE 0 END AS [new_group]
    FROM ordered
),
grouped AS
(
    SELECT
        marked.[robot_code],
        marked.[start_time],
        marked.[end_time],
        SUM(marked.[new_group]) OVER
        (
            PARTITION BY marked.[robot_code]
            ORDER BY marked.[start_time], marked.[end_time]
            ROWS UNBOUNDED PRECEDING
        ) AS [interval_group]
    FROM marked
)
INSERT INTO #execution_interval ([robot_code], [start_time], [end_time])
SELECT
    grouped.[robot_code],
    MIN(grouped.[start_time]),
    MAX(grouped.[end_time])
FROM grouped
GROUP BY grouped.[robot_code], grouped.[interval_group];

CREATE TABLE #battery_interval
(
    [robot_code] NVARCHAR(100) NOT NULL,
    [start_time] DATETIME2(3) NOT NULL,
    [end_time] DATETIME2(3) NOT NULL,
    [is_charging] BIT NOT NULL,
    PRIMARY KEY ([robot_code], [start_time], [end_time])
);

;WITH battery_source AS
(
    /*
      sample_time is the DWD-preserved robot event time (ODS.robot_datetime for
      this source). pc_timestamp/ods_load_time describe arrival, not when the
      robot measured battery state, and must not make an old event current.
    */
    SELECT
        battery_row.[robot_code],
        battery_row.[sample_time],
        CASE WHEN UPPER(LTRIM(RTRIM(COALESCE(battery_row.[charging_status], N'')))) = N'CHARGING' THEN CONVERT(BIT, 1) ELSE CONVERT(BIT, 0) END AS [is_charging]
    FROM [DWD].[fact_robot_battery] AS battery_row WITH (INDEX([IX_DWD_fact_robot_battery_robot_time]))
    INNER JOIN #active_robot AS active_robot
        ON active_robot.[robot_code] = battery_row.[robot_code]
    WHERE battery_row.[sample_time] >= DATEADD(SECOND, -@battery_max_gap_seconds, @window_start)
      AND battery_row.[sample_time] < @window_end
      AND NULLIF(LTRIM(RTRIM(battery_row.[charging_status])), N'') IS NOT NULL
),
ordered AS
(
    SELECT
        source_row.[robot_code],
        source_row.[sample_time],
        source_row.[is_charging],
        LAG(source_row.[sample_time]) OVER (PARTITION BY source_row.[robot_code] ORDER BY source_row.[sample_time]) AS [prior_sample_time],
        LAG(source_row.[is_charging]) OVER (PARTITION BY source_row.[robot_code] ORDER BY source_row.[sample_time]) AS [prior_is_charging]
    FROM battery_source AS source_row
),
marked AS
(
    SELECT
        ordered.[robot_code],
        ordered.[sample_time],
        ordered.[is_charging],
        CASE
            WHEN ordered.[prior_sample_time] IS NULL THEN 1
            WHEN DATEDIFF(SECOND, ordered.[prior_sample_time], ordered.[sample_time]) > @battery_max_gap_seconds THEN 1
            WHEN ordered.[prior_is_charging] <> ordered.[is_charging] THEN 1
            ELSE 0
        END AS [new_group]
    FROM ordered
),
grouped AS
(
    SELECT
        marked.[robot_code],
        marked.[sample_time],
        marked.[is_charging],
        SUM(marked.[new_group]) OVER
        (
            PARTITION BY marked.[robot_code]
            ORDER BY marked.[sample_time]
            ROWS UNBOUNDED PRECEDING
        ) AS [interval_group]
    FROM marked
),
collapsed AS
(
    SELECT
        grouped.[robot_code],
        grouped.[interval_group],
        MIN(grouped.[sample_time]) AS [start_time],
        MAX(grouped.[sample_time]) AS [last_sample_time],
        CONVERT(BIT, MAX(CONVERT(TINYINT, grouped.[is_charging]))) AS [is_charging]
    FROM grouped
    GROUP BY grouped.[robot_code], grouped.[interval_group]
),
with_next AS
(
    SELECT
        collapsed.[robot_code],
        collapsed.[start_time],
        collapsed.[last_sample_time],
        collapsed.[is_charging],
        LEAD(collapsed.[start_time]) OVER (PARTITION BY collapsed.[robot_code] ORDER BY collapsed.[start_time]) AS [next_start_time]
    FROM collapsed
)
INSERT INTO #battery_interval ([robot_code], [start_time], [end_time], [is_charging])
SELECT
    source_row.[robot_code],
    CASE WHEN source_row.[start_time] < @window_start THEN @window_start ELSE source_row.[start_time] END,
    CASE
        WHEN source_row.[next_start_time] IS NOT NULL
         AND source_row.[next_start_time] <= DATEADD(SECOND, @battery_max_gap_seconds, source_row.[last_sample_time])
            THEN source_row.[next_start_time]
        ELSE source_row.[last_sample_time]
    END,
    source_row.[is_charging]
FROM with_next AS source_row
WHERE
    CASE
        WHEN source_row.[next_start_time] IS NOT NULL
         AND source_row.[next_start_time] <= DATEADD(SECOND, @battery_max_gap_seconds, source_row.[last_sample_time])
            THEN source_row.[next_start_time]
        ELSE source_row.[last_sample_time]
    END > @window_start;

CREATE TABLE #waiting_raw
(
    [robot_code] NVARCHAR(100) NOT NULL,
    [start_time] DATETIME2(3) NOT NULL,
    [end_time] DATETIME2(3) NOT NULL,
    [queue_id] NVARCHAR(100) NOT NULL,
    PRIMARY KEY ([robot_code], [start_time], [end_time], [queue_id])
);

INSERT INTO #waiting_raw ([robot_code], [start_time], [end_time], [queue_id])
SELECT
    start_event.[robot_code],
    CASE WHEN queue_fact.[queue_start_time] < @window_start THEN @window_start ELSE queue_fact.[queue_start_time] END,
    CASE WHEN MIN(start_event.[event_time]) > @window_end THEN @window_end ELSE MIN(start_event.[event_time]) END,
    queue_fact.[queue_id]
FROM [DWD].[fact_amr_queue] AS queue_fact
INNER JOIN [DWD].[fact_robot_operation_event] AS start_event
    ON start_event.[source_schema] = N'ODS'
   AND start_event.[source_table] = N'TA_AMR'
   AND start_event.[source_event_part] = N'START'
   AND start_event.[queue_id] = queue_fact.[queue_id]
INNER JOIN #active_robot AS active_robot
    ON active_robot.[robot_code] = start_event.[robot_code]
WHERE queue_fact.[queue_start_time] IS NOT NULL
  AND queue_fact.[queue_start_time] < @window_end
  AND start_event.[event_time] > @window_start
  AND start_event.[event_time] >= queue_fact.[queue_start_time]
GROUP BY
    start_event.[robot_code],
    queue_fact.[queue_start_time],
    queue_fact.[queue_id];

CREATE TABLE #waiting_interval
(
    [robot_code] NVARCHAR(100) NOT NULL,
    [start_time] DATETIME2(3) NOT NULL,
    [end_time] DATETIME2(3) NOT NULL,
    PRIMARY KEY ([robot_code], [start_time], [end_time])
);

;WITH ordered AS
(
    SELECT
        source_row.[robot_code],
        source_row.[start_time],
        source_row.[end_time],
        MAX(source_row.[end_time]) OVER
        (
            PARTITION BY source_row.[robot_code]
            ORDER BY source_row.[start_time], source_row.[end_time], source_row.[queue_id]
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS [prior_max_end_time]
    FROM #waiting_raw AS source_row
),
marked AS
(
    SELECT
        ordered.[robot_code],
        ordered.[start_time],
        ordered.[end_time],
        CASE WHEN ordered.[prior_max_end_time] IS NULL OR ordered.[prior_max_end_time] < ordered.[start_time] THEN 1 ELSE 0 END AS [new_group]
    FROM ordered
),
grouped AS
(
    SELECT
        marked.[robot_code],
        marked.[start_time],
        marked.[end_time],
        SUM(marked.[new_group]) OVER
        (
            PARTITION BY marked.[robot_code]
            ORDER BY marked.[start_time], marked.[end_time]
            ROWS UNBOUNDED PRECEDING
        ) AS [interval_group]
    FROM marked
)
INSERT INTO #waiting_interval ([robot_code], [start_time], [end_time])
SELECT
    grouped.[robot_code],
    MIN(grouped.[start_time]),
    MAX(grouped.[end_time])
FROM grouped
GROUP BY grouped.[robot_code], grouped.[interval_group];

CREATE TABLE #cut_point
(
    [robot_code] NVARCHAR(100) NOT NULL,
    [point_time] DATETIME2(3) NOT NULL,
    PRIMARY KEY ([robot_code], [point_time])
);

;WITH hour_spine AS
(
    SELECT @window_start AS [stat_hour]
    UNION ALL
    SELECT DATEADD(HOUR, 1, hour_spine.[stat_hour])
    FROM hour_spine
    WHERE DATEADD(HOUR, 1, hour_spine.[stat_hour]) <= @window_end
)
INSERT INTO #cut_point ([robot_code], [point_time])
SELECT active_robot.[robot_code], hour_spine.[stat_hour]
FROM #active_robot AS active_robot
CROSS JOIN hour_spine
OPTION (MAXRECURSION 0);

;WITH interval_boundary AS
(
    SELECT source_row.[robot_code], source_row.[start_time] AS [point_time] FROM #execution_interval AS source_row
    UNION
    SELECT source_row.[robot_code], source_row.[end_time] FROM #execution_interval AS source_row
    UNION
    SELECT source_row.[robot_code], source_row.[start_time] FROM #battery_interval AS source_row
    UNION
    SELECT source_row.[robot_code], source_row.[end_time] FROM #battery_interval AS source_row
    UNION
    SELECT source_row.[robot_code], source_row.[start_time] FROM #waiting_interval AS source_row
    UNION
    SELECT source_row.[robot_code], source_row.[end_time] FROM #waiting_interval AS source_row
)
INSERT INTO #cut_point ([robot_code], [point_time])
SELECT boundary.[robot_code], boundary.[point_time]
FROM interval_boundary AS boundary
WHERE NOT EXISTS
(
    SELECT 1
    FROM #cut_point AS existing_point
    WHERE existing_point.[robot_code] = boundary.[robot_code]
      AND existing_point.[point_time] = boundary.[point_time]
);

CREATE TABLE #atomic_segment
(
    [robot_code] NVARCHAR(100) NOT NULL,
    [start_time] DATETIME2(3) NOT NULL,
    [end_time] DATETIME2(3) NOT NULL,
    PRIMARY KEY ([robot_code], [start_time], [end_time])
);

;WITH ordered AS
(
    SELECT
        cut_point.[robot_code],
        cut_point.[point_time] AS [start_time],
        LEAD(cut_point.[point_time]) OVER (PARTITION BY cut_point.[robot_code] ORDER BY cut_point.[point_time]) AS [end_time]
    FROM #cut_point AS cut_point
)
INSERT INTO #atomic_segment ([robot_code], [start_time], [end_time])
SELECT ordered.[robot_code], ordered.[start_time], ordered.[end_time]
FROM ordered
WHERE ordered.[end_time] IS NOT NULL
  AND ordered.[end_time] > ordered.[start_time];

CREATE TABLE #hour_classification
(
    [stat_hour] DATETIME2(3) NOT NULL,
    [robot_code] NVARCHAR(100) NOT NULL,
    [executing_seconds] INT NOT NULL,
    [charging_seconds] INT NOT NULL,
    [waiting_seconds] INT NOT NULL,
    [no_task_seconds] INT NOT NULL,
    [data_unavailable_seconds] INT NOT NULL,
    PRIMARY KEY ([robot_code], [stat_hour])
);

INSERT INTO #hour_classification
(
    [stat_hour], [robot_code], [executing_seconds], [charging_seconds], [waiting_seconds], [no_task_seconds], [data_unavailable_seconds]
)
SELECT
    DATEADD(HOUR, DATEDIFF(HOUR, 0, segment.[start_time]), 0),
    segment.[robot_code],
    SUM(CASE WHEN execution_interval.[robot_code] IS NOT NULL THEN CONVERT(INT, DATEDIFF_BIG(SECOND, segment.[start_time], segment.[end_time])) ELSE 0 END),
    SUM(CASE WHEN execution_interval.[robot_code] IS NULL AND charging_interval.[robot_code] IS NOT NULL THEN CONVERT(INT, DATEDIFF_BIG(SECOND, segment.[start_time], segment.[end_time])) ELSE 0 END),
    SUM(CASE WHEN execution_interval.[robot_code] IS NULL AND charging_interval.[robot_code] IS NULL AND waiting_interval.[robot_code] IS NOT NULL THEN CONVERT(INT, DATEDIFF_BIG(SECOND, segment.[start_time], segment.[end_time])) ELSE 0 END),
    SUM(CASE WHEN execution_interval.[robot_code] IS NULL AND charging_interval.[robot_code] IS NULL AND waiting_interval.[robot_code] IS NULL AND observed_battery_interval.[robot_code] IS NOT NULL THEN CONVERT(INT, DATEDIFF_BIG(SECOND, segment.[start_time], segment.[end_time])) ELSE 0 END),
    SUM(CASE WHEN execution_interval.[robot_code] IS NULL AND charging_interval.[robot_code] IS NULL AND waiting_interval.[robot_code] IS NULL AND observed_battery_interval.[robot_code] IS NULL THEN CONVERT(INT, DATEDIFF_BIG(SECOND, segment.[start_time], segment.[end_time])) ELSE 0 END)
FROM #atomic_segment AS segment
LEFT JOIN #execution_interval AS execution_interval
    ON execution_interval.[robot_code] = segment.[robot_code]
   AND segment.[start_time] >= execution_interval.[start_time]
   AND segment.[start_time] < execution_interval.[end_time]
LEFT JOIN #battery_interval AS charging_interval
    ON charging_interval.[robot_code] = segment.[robot_code]
   AND charging_interval.[is_charging] = CONVERT(BIT, 1)
   AND segment.[start_time] >= charging_interval.[start_time]
   AND segment.[start_time] < charging_interval.[end_time]
LEFT JOIN #waiting_interval AS waiting_interval
    ON waiting_interval.[robot_code] = segment.[robot_code]
   AND segment.[start_time] >= waiting_interval.[start_time]
   AND segment.[start_time] < waiting_interval.[end_time]
LEFT JOIN #battery_interval AS observed_battery_interval
    ON observed_battery_interval.[robot_code] = segment.[robot_code]
   AND segment.[start_time] >= observed_battery_interval.[start_time]
   AND segment.[start_time] < observed_battery_interval.[end_time]
GROUP BY
    DATEADD(HOUR, DATEDIFF(HOUR, 0, segment.[start_time]), 0),
    segment.[robot_code];

CREATE TABLE #hour_event_count
(
    [stat_hour] DATETIME2(3) NOT NULL,
    [robot_code] NVARCHAR(100) NOT NULL,
    [accepted_queue_count] BIGINT NOT NULL,
    [task_started_count] BIGINT NOT NULL,
    [subtask_started_count] BIGINT NOT NULL,
    [task_completed_count] BIGINT NOT NULL,
    [first_source_event_time] DATETIME2(3) NULL,
    [last_source_event_time] DATETIME2(3) NULL,
    PRIMARY KEY ([robot_code], [stat_hour])
);

INSERT INTO #hour_event_count
(
    [stat_hour], [robot_code], [accepted_queue_count], [task_started_count], [subtask_started_count], [task_completed_count], [first_source_event_time], [last_source_event_time]
)
SELECT
    DATEADD(HOUR, DATEDIFF(HOUR, 0, event_row.[event_time]), 0),
    event_row.[robot_code],
    SUM(CASE WHEN event_row.[event_type] = N'QUEUE_ENQUEUED' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    SUM(CASE WHEN event_row.[event_type] = N'JOB_STARTED' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    SUM(CASE WHEN event_row.[event_type] = N'SUBJOB_STARTED' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    SUM(CASE WHEN event_row.[event_type] = N'JOB_ENDED' AND LOWER(LTRIM(RTRIM(COALESCE(event_row.[event_status], N'')))) = N'success' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    MIN(event_row.[event_time]),
    MAX(event_row.[event_time])
FROM [DWD].[fact_robot_operation_event] AS event_row
INNER JOIN #active_robot AS active_robot
    ON active_robot.[robot_code] = event_row.[robot_code]
WHERE event_row.[event_time] >= @window_start
  AND event_row.[event_time] < @window_end
  AND event_row.[event_type] IN (N'QUEUE_ENQUEUED', N'JOB_STARTED', N'SUBJOB_STARTED', N'JOB_ENDED')
GROUP BY
    DATEADD(HOUR, DATEDIFF(HOUR, 0, event_row.[event_time]), 0),
    event_row.[robot_code];

BEGIN TRY
    BEGIN TRANSACTION;

    DELETE FROM [DWS].[dws_robot_task_hourly]
    WHERE [stat_hour] >= @window_start
      AND [stat_hour] < @window_end;

    INSERT INTO [DWS].[dws_robot_task_hourly]
    (
        [stat_hour], [robot_code], [robot_id], [accepted_queue_count], [task_started_count], [subtask_started_count], [task_completed_count],
        [executing_seconds], [charging_seconds], [waiting_seconds], [no_task_seconds], [data_unavailable_seconds], [execution_overlap_seconds],
        [first_source_event_time], [last_source_event_time]
    )
    SELECT
        classification.[stat_hour],
        classification.[robot_code],
        active_robot.[robot_id],
        COALESCE(event_count.[accepted_queue_count], CONVERT(BIGINT, 0)),
        COALESCE(event_count.[task_started_count], CONVERT(BIGINT, 0)),
        COALESCE(event_count.[subtask_started_count], CONVERT(BIGINT, 0)),
        COALESCE(event_count.[task_completed_count], CONVERT(BIGINT, 0)),
        classification.[executing_seconds],
        classification.[charging_seconds],
        classification.[waiting_seconds],
        classification.[no_task_seconds],
        classification.[data_unavailable_seconds],
        0,
        event_count.[first_source_event_time],
        event_count.[last_source_event_time]
    FROM #hour_classification AS classification
    INNER JOIN #active_robot AS active_robot
        ON active_robot.[robot_code] = classification.[robot_code]
    LEFT JOIN #hour_event_count AS event_count
        ON event_count.[robot_code] = classification.[robot_code]
       AND event_count.[stat_hour] = classification.[stat_hour];

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
    BEGIN
        ROLLBACK TRANSACTION;
    END;

    THROW;
END CATCH;

SELECT
    @window_start AS [loaded_window_start],
    @window_end AS [loaded_window_end],
    COUNT_BIG(*) AS [dws_hour_rows],
    COUNT_BIG(DISTINCT task_hour.[robot_code]) AS [robot_count],
    SUM(task_hour.[executing_seconds]) AS [executing_seconds],
    SUM(task_hour.[charging_seconds]) AS [charging_seconds],
    SUM(task_hour.[waiting_seconds]) AS [waiting_seconds],
    SUM(task_hour.[no_task_seconds]) AS [no_task_seconds],
    SUM(task_hour.[data_unavailable_seconds]) AS [data_unavailable_seconds]
FROM [DWS].[dws_robot_task_hourly] AS task_hour
WHERE task_hour.[stat_hour] >= @window_start
  AND task_hour.[stat_hour] < @window_end;

SELECT TOP (20)
    task_hour.[stat_hour],
    task_hour.[robot_code],
    task_hour.[executing_seconds],
    task_hour.[charging_seconds],
    task_hour.[waiting_seconds],
    task_hour.[no_task_seconds],
    task_hour.[data_unavailable_seconds],
    task_hour.[accepted_queue_count],
    task_hour.[subtask_started_count],
    task_hour.[task_completed_count]
FROM [DWS].[dws_robot_task_hourly] AS task_hour
WHERE task_hour.[stat_hour] >= @window_start
  AND task_hour.[stat_hour] < @window_end
ORDER BY task_hour.[stat_hour] DESC, task_hour.[robot_code];
