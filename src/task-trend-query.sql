/*
  Exact-window Task Analytics trends.

  KPI totals remain served from DWS hourly facts in task-analytics-query.sql.
  This read-only companion reconstructs time-series rows from DWD interval and
  queue-event evidence so 5/15-minute charts never imply false sub-hour detail.
*/
SET NOCOUNT ON;

DECLARE @requested_start DATETIME2(3) = TRY_CONVERT(DATETIME2(3), REPLACE(@task_analysis_start, N'T', N' '));
DECLARE @requested_end DATETIME2(3) = TRY_CONVERT(DATETIME2(3), REPLACE(@task_analysis_end, N'T', N' '));
DECLARE @anchor DATETIME2(3);
DECLARE @bucket_minutes INT;
DECLARE @battery_max_gap_seconds INT = 300;
DECLARE @epoch DATETIME2(0) = CONVERT(DATETIME2(0), '20000101');
DECLARE @selected_robot_codes NVARCHAR(MAX) = NULLIF(LTRIM(RTRIM(@robot_codes)), N'');
DECLARE @selected_robot_xml XML = TRY_CONVERT(XML,
    CASE
        WHEN @selected_robot_codes IS NULL THEN N'<robots />'
        ELSE N'<robots><robot>' + REPLACE(@selected_robot_codes, N',', N'</robot><robot>') + N'</robot></robots>'
    END
);
DECLARE @selected_robots TABLE
(
    [robot_code] NVARCHAR(100) NOT NULL PRIMARY KEY
);

INSERT INTO @selected_robots ([robot_code])
SELECT DISTINCT LTRIM(RTRIM(split.value(N'.', N'NVARCHAR(100)')))
FROM @selected_robot_xml.nodes(N'/robots/robot') AS robots(split)
WHERE LTRIM(RTRIM(split.value(N'.', N'NVARCHAR(100)'))) <> N'';

SELECT @anchor = DATEADD(HOUR, 1, MAX(task_hour.[stat_hour]))
FROM [DWS].[dws_robot_task_hourly] AS task_hour;

IF @requested_start IS NULL AND @requested_end IS NULL
BEGIN
    SET @requested_end = @anchor;
    SET @requested_start = DATEADD(HOUR, -24, @requested_end);
END;

IF @requested_start IS NULL OR @requested_end IS NULL OR @requested_end <= @requested_start
BEGIN
    THROW 51201, N'Task trend analysis requires a valid start and end time.', 1;
END;

IF DATEDIFF_BIG(MINUTE, @requested_start, @requested_end) > 43200
BEGIN
    THROW 51202, N'Task trend analysis supports a window of at most 30 days.', 1;
END;

SET @bucket_minutes = CASE
    WHEN DATEDIFF_BIG(SECOND, @requested_start, @requested_end) <= 21600 THEN 5
    WHEN DATEDIFF_BIG(SECOND, @requested_start, @requested_end) <= 86400 THEN 15
    WHEN DATEDIFF_BIG(SECOND, @requested_start, @requested_end) <= 604800 THEN 60
    ELSE 1440
END;

/*
  Hour/day requests can be served exactly from the existing hourly DWS grain.
  Only sub-hour requests need the interval reconstruction below. Partial edge
  hours are excluded, matching the Task KPI contract.
*/
IF @bucket_minutes >= 60
BEGIN
    DECLARE @dws_start DATETIME2(0) = DATEADD
    (
        HOUR,
        DATEDIFF(HOUR, 0, @requested_start)
            + CASE
                WHEN @requested_start > DATEADD(HOUR, DATEDIFF(HOUR, 0, @requested_start), 0) THEN 1
                ELSE 0
              END,
        0
    );
    DECLARE @dws_end DATETIME2(0) = DATEADD(HOUR, DATEDIFF(HOUR, 0, @requested_end), 0);

    /* 0: grain metadata and full-hour DWS trend coverage. */
    SELECT
        CONVERT(NVARCHAR(19), @dws_start, 120) AS [analysis_start],
        CONVERT(NVARCHAR(19), @dws_end, 120) AS [analysis_end],
        @bucket_minutes AS [bucket_minutes],
        COUNT_BIG(1) AS [trend_row_count],
        COUNT(DISTINCT task_hour.[robot_code]) AS [robot_count]
    FROM [DWS].[dws_robot_task_hourly] AS task_hour
    WHERE task_hour.[stat_hour] >= @dws_start
      AND task_hour.[stat_hour] < @dws_end
      AND
      (
          NOT EXISTS (SELECT 1 FROM @selected_robots)
          OR EXISTS (SELECT 1 FROM @selected_robots AS selected WHERE selected.[robot_code] = task_hour.[robot_code])
      );

    /* 1: hourly or daily state and event trend. */
    SELECT
        CONVERT
        (
            NVARCHAR(19),
            DATEADD(MINUTE, (DATEDIFF(MINUTE, @epoch, task_hour.[stat_hour]) / @bucket_minutes) * @bucket_minutes, @epoch),
            120
        ) AS [stat_hour],
        task_hour.[robot_code],
        SUM(task_hour.[executing_seconds]) AS [executing_seconds],
        SUM(task_hour.[charging_seconds]) AS [charging_seconds],
        SUM(task_hour.[waiting_seconds]) AS [waiting_seconds],
        SUM(task_hour.[no_task_seconds]) AS [no_task_seconds],
        SUM(task_hour.[data_unavailable_seconds]) AS [data_unavailable_seconds],
        SUM(task_hour.[accepted_queue_count]) AS [accepted_queue_count],
        SUM(task_hour.[task_started_count]) AS [task_started_count],
        SUM(task_hour.[subtask_started_count]) AS [subtask_started_count],
        SUM(task_hour.[task_completed_count]) AS [task_completed_count]
    FROM [DWS].[dws_robot_task_hourly] AS task_hour
    WHERE task_hour.[stat_hour] >= @dws_start
      AND task_hour.[stat_hour] < @dws_end
      AND
      (
          NOT EXISTS (SELECT 1 FROM @selected_robots)
          OR EXISTS (SELECT 1 FROM @selected_robots AS selected WHERE selected.[robot_code] = task_hour.[robot_code])
      )
    GROUP BY
        DATEADD(MINUTE, (DATEDIFF(MINUTE, @epoch, task_hour.[stat_hour]) / @bucket_minutes) * @bucket_minutes, @epoch),
        task_hour.[robot_code]
    ORDER BY [stat_hour], task_hour.[robot_code];

    /* 2: hourly or daily Calling Box trend. */
    ;WITH top_labels AS
    (
        SELECT TOP (6) calling_box.[calling_box_label]
        FROM [DWS].[dws_robot_calling_box_hourly] AS calling_box
        WHERE calling_box.[stat_hour] >= @dws_start
          AND calling_box.[stat_hour] < @dws_end
          AND
          (
              NOT EXISTS (SELECT 1 FROM @selected_robots)
              OR EXISTS (SELECT 1 FROM @selected_robots AS selected WHERE selected.[robot_code] = calling_box.[robot_code])
          )
        GROUP BY calling_box.[calling_box_label]
        ORDER BY SUM(calling_box.[calling_box_count]) DESC, calling_box.[calling_box_label]
    )
    SELECT
        CONVERT
        (
            NVARCHAR(19),
            DATEADD(MINUTE, (DATEDIFF(MINUTE, @epoch, calling_box.[stat_hour]) / @bucket_minutes) * @bucket_minutes, @epoch),
            120
        ) AS [stat_hour],
        calling_box.[calling_box_label],
        SUM(calling_box.[calling_box_count]) AS [calling_box_count]
    FROM [DWS].[dws_robot_calling_box_hourly] AS calling_box
    INNER JOIN top_labels
        ON top_labels.[calling_box_label] = calling_box.[calling_box_label]
    WHERE calling_box.[stat_hour] >= @dws_start
      AND calling_box.[stat_hour] < @dws_end
      AND
      (
          NOT EXISTS (SELECT 1 FROM @selected_robots)
          OR EXISTS (SELECT 1 FROM @selected_robots AS selected WHERE selected.[robot_code] = calling_box.[robot_code])
      )
    GROUP BY
        DATEADD(MINUTE, (DATEDIFF(MINUTE, @epoch, calling_box.[stat_hour]) / @bucket_minutes) * @bucket_minutes, @epoch),
        calling_box.[calling_box_label]
    ORDER BY [stat_hour], calling_box.[calling_box_label];

    /* 3: hourly or daily assigned-task trend. */
    ;WITH top_labels AS
    (
        SELECT TOP (6) assigned_task.[task_label]
        FROM [DWS].[dws_robot_assigned_task_hourly] AS assigned_task
        WHERE assigned_task.[stat_hour] >= @dws_start
          AND assigned_task.[stat_hour] < @dws_end
          AND
          (
              NOT EXISTS (SELECT 1 FROM @selected_robots)
              OR EXISTS (SELECT 1 FROM @selected_robots AS selected WHERE selected.[robot_code] = assigned_task.[robot_code])
          )
        GROUP BY assigned_task.[task_label]
        ORDER BY SUM(assigned_task.[assigned_task_count]) DESC, assigned_task.[task_label]
    )
    SELECT
        CONVERT
        (
            NVARCHAR(19),
            DATEADD(MINUTE, (DATEDIFF(MINUTE, @epoch, assigned_task.[stat_hour]) / @bucket_minutes) * @bucket_minutes, @epoch),
            120
        ) AS [stat_hour],
        assigned_task.[task_label],
        SUM(assigned_task.[assigned_task_count]) AS [assigned_task_count],
        SUM(assigned_task.[completed_task_count]) AS [completed_task_count]
    FROM [DWS].[dws_robot_assigned_task_hourly] AS assigned_task
    INNER JOIN top_labels
        ON top_labels.[task_label] = assigned_task.[task_label]
    WHERE assigned_task.[stat_hour] >= @dws_start
      AND assigned_task.[stat_hour] < @dws_end
      AND
      (
          NOT EXISTS (SELECT 1 FROM @selected_robots)
          OR EXISTS (SELECT 1 FROM @selected_robots AS selected WHERE selected.[robot_code] = assigned_task.[robot_code])
      )
    GROUP BY
        DATEADD(MINUTE, (DATEDIFF(MINUTE, @epoch, assigned_task.[stat_hour]) / @bucket_minutes) * @bucket_minutes, @epoch),
        assigned_task.[task_label]
    ORDER BY [stat_hour], assigned_task.[task_label];

    RETURN;
END;

CREATE TABLE #active_robot
(
    [robot_code] NVARCHAR(100) NOT NULL PRIMARY KEY,
    [robot_id] NVARCHAR(100) NULL
);

INSERT INTO #active_robot ([robot_code], [robot_id])
SELECT robot_dim.[robot_code], robot_dim.[robot_id]
FROM [DWD].[dim_amr_robot] AS robot_dim
WHERE robot_dim.[is_enabled] = CONVERT(BIT, 1)
  AND NULLIF(LTRIM(RTRIM(robot_dim.[robot_code])), N'') IS NOT NULL
  AND
  (
      NOT EXISTS (SELECT 1 FROM @selected_robots)
      OR EXISTS
      (
          SELECT 1
          FROM @selected_robots AS selected
          WHERE selected.[robot_code] = robot_dim.[robot_code]
      )
  );

CREATE TABLE #execution_raw
(
    [robot_code] NVARCHAR(100) NOT NULL,
    [start_time] DATETIME2(3) NOT NULL,
    [end_time] DATETIME2(3) NOT NULL,
    [source_ods_row_id] BIGINT NOT NULL,
    PRIMARY KEY ([robot_code], [start_time], [end_time], [source_ods_row_id])
);

INSERT INTO #execution_raw ([robot_code], [start_time], [end_time], [source_ods_row_id])
SELECT
    start_event.[robot_code],
    CASE WHEN start_event.[event_time] < @requested_start THEN @requested_start ELSE start_event.[event_time] END,
    CASE WHEN end_event.[event_time] > @requested_end THEN @requested_end ELSE end_event.[event_time] END,
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
  AND start_event.[event_time] < @requested_end
  AND end_event.[event_time] > @requested_start
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
        ordered.[robot_code], ordered.[start_time], ordered.[end_time],
        CASE WHEN ordered.[prior_max_end_time] IS NULL OR ordered.[prior_max_end_time] < ordered.[start_time] THEN 1 ELSE 0 END AS [new_group]
    FROM ordered
),
grouped AS
(
    SELECT
        marked.[robot_code], marked.[start_time], marked.[end_time],
        SUM(marked.[new_group]) OVER
        (
            PARTITION BY marked.[robot_code]
            ORDER BY marked.[start_time], marked.[end_time]
            ROWS UNBOUNDED PRECEDING
        ) AS [interval_group]
    FROM marked
)
INSERT INTO #execution_interval ([robot_code], [start_time], [end_time])
SELECT grouped.[robot_code], MIN(grouped.[start_time]), MAX(grouped.[end_time])
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
    SELECT
        battery_row.[robot_code],
        battery_row.[sample_time],
        CASE WHEN UPPER(LTRIM(RTRIM(COALESCE(battery_row.[charging_status], N'')))) = N'CHARGING' THEN CONVERT(BIT, 1) ELSE CONVERT(BIT, 0) END AS [is_charging]
    FROM [DWD].[fact_robot_battery] AS battery_row WITH (INDEX([IX_DWD_fact_robot_battery_robot_time]))
    INNER JOIN #active_robot AS active_robot
        ON active_robot.[robot_code] = battery_row.[robot_code]
    WHERE battery_row.[sample_time] >= DATEADD(SECOND, -@battery_max_gap_seconds, @requested_start)
      AND battery_row.[sample_time] < @requested_end
      AND NULLIF(LTRIM(RTRIM(battery_row.[charging_status])), N'') IS NOT NULL
),
ordered AS
(
    SELECT
        source_row.[robot_code], source_row.[sample_time], source_row.[is_charging],
        LAG(source_row.[sample_time]) OVER (PARTITION BY source_row.[robot_code] ORDER BY source_row.[sample_time]) AS [prior_sample_time],
        LAG(source_row.[is_charging]) OVER (PARTITION BY source_row.[robot_code] ORDER BY source_row.[sample_time]) AS [prior_is_charging]
    FROM battery_source AS source_row
),
marked AS
(
    SELECT
        ordered.[robot_code], ordered.[sample_time], ordered.[is_charging],
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
        marked.[robot_code], marked.[sample_time], marked.[is_charging],
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
        grouped.[robot_code], grouped.[interval_group],
        MIN(grouped.[sample_time]) AS [start_time],
        MAX(grouped.[sample_time]) AS [last_sample_time],
        CONVERT(BIT, MAX(CONVERT(TINYINT, grouped.[is_charging]))) AS [is_charging]
    FROM grouped
    GROUP BY grouped.[robot_code], grouped.[interval_group]
),
with_next AS
(
    SELECT
        collapsed.[robot_code], collapsed.[start_time], collapsed.[last_sample_time], collapsed.[is_charging],
        LEAD(collapsed.[start_time]) OVER (PARTITION BY collapsed.[robot_code] ORDER BY collapsed.[start_time]) AS [next_start_time]
    FROM collapsed
)
INSERT INTO #battery_interval ([robot_code], [start_time], [end_time], [is_charging])
SELECT
    source_row.[robot_code],
    CASE WHEN source_row.[start_time] < @requested_start THEN @requested_start ELSE source_row.[start_time] END,
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
    END > @requested_start;

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
    CASE WHEN queue_fact.[queue_start_time] < @requested_start THEN @requested_start ELSE queue_fact.[queue_start_time] END,
    CASE WHEN MIN(start_event.[event_time]) > @requested_end THEN @requested_end ELSE MIN(start_event.[event_time]) END,
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
  AND queue_fact.[queue_start_time] < @requested_end
  AND start_event.[event_time] > @requested_start
  AND start_event.[event_time] >= queue_fact.[queue_start_time]
GROUP BY start_event.[robot_code], queue_fact.[queue_start_time], queue_fact.[queue_id];

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
        source_row.[robot_code], source_row.[start_time], source_row.[end_time],
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
        ordered.[robot_code], ordered.[start_time], ordered.[end_time],
        CASE WHEN ordered.[prior_max_end_time] IS NULL OR ordered.[prior_max_end_time] < ordered.[start_time] THEN 1 ELSE 0 END AS [new_group]
    FROM ordered
),
grouped AS
(
    SELECT
        marked.[robot_code], marked.[start_time], marked.[end_time],
        SUM(marked.[new_group]) OVER
        (
            PARTITION BY marked.[robot_code]
            ORDER BY marked.[start_time], marked.[end_time]
            ROWS UNBOUNDED PRECEDING
        ) AS [interval_group]
    FROM marked
)
INSERT INTO #waiting_interval ([robot_code], [start_time], [end_time])
SELECT grouped.[robot_code], MIN(grouped.[start_time]), MAX(grouped.[end_time])
FROM grouped
GROUP BY grouped.[robot_code], grouped.[interval_group];

CREATE TABLE #cut_point
(
    [robot_code] NVARCHAR(100) NOT NULL,
    [point_time] DATETIME2(3) NOT NULL,
    PRIMARY KEY ([robot_code], [point_time])
);

INSERT INTO #cut_point ([robot_code], [point_time])
SELECT active_robot.[robot_code], boundary.[point_time]
FROM #active_robot AS active_robot
CROSS JOIN (VALUES (@requested_start), (@requested_end)) AS boundary([point_time]);

DECLARE @first_bucket DATETIME2(3) = DATEADD
(
    MINUTE,
    (DATEDIFF(MINUTE, @epoch, @requested_start) / @bucket_minutes) * @bucket_minutes,
    @epoch
);

;WITH bucket_spine AS
(
    SELECT DATEADD(MINUTE, @bucket_minutes, @first_bucket) AS [point_time]
    UNION ALL
    SELECT DATEADD(MINUTE, @bucket_minutes, bucket_spine.[point_time])
    FROM bucket_spine
    WHERE DATEADD(MINUTE, @bucket_minutes, bucket_spine.[point_time]) < @requested_end
)
INSERT INTO #cut_point ([robot_code], [point_time])
SELECT active_robot.[robot_code], bucket_spine.[point_time]
FROM #active_robot AS active_robot
CROSS JOIN bucket_spine
WHERE bucket_spine.[point_time] > @requested_start
  AND bucket_spine.[point_time] < @requested_end
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
WHERE boundary.[point_time] > @requested_start
  AND boundary.[point_time] < @requested_end
  AND NOT EXISTS
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

CREATE TABLE #trend_state
(
    [bucket_start] DATETIME2(3) NOT NULL,
    [robot_code] NVARCHAR(100) NOT NULL,
    [executing_seconds] BIGINT NOT NULL,
    [charging_seconds] BIGINT NOT NULL,
    [waiting_seconds] BIGINT NOT NULL,
    [no_task_seconds] BIGINT NOT NULL,
    [data_unavailable_seconds] BIGINT NOT NULL,
    PRIMARY KEY ([robot_code], [bucket_start])
);

INSERT INTO #trend_state
(
    [bucket_start], [robot_code], [executing_seconds], [charging_seconds],
    [waiting_seconds], [no_task_seconds], [data_unavailable_seconds]
)
SELECT
    DATEADD(MINUTE, (DATEDIFF(MINUTE, @epoch, segment.[start_time]) / @bucket_minutes) * @bucket_minutes, @epoch),
    segment.[robot_code],
    SUM(CASE WHEN execution_interval.[robot_code] IS NOT NULL THEN DATEDIFF_BIG(SECOND, segment.[start_time], segment.[end_time]) ELSE 0 END),
    SUM(CASE WHEN execution_interval.[robot_code] IS NULL AND charging_interval.[robot_code] IS NOT NULL THEN DATEDIFF_BIG(SECOND, segment.[start_time], segment.[end_time]) ELSE 0 END),
    SUM(CASE WHEN execution_interval.[robot_code] IS NULL AND charging_interval.[robot_code] IS NULL AND waiting_interval.[robot_code] IS NOT NULL THEN DATEDIFF_BIG(SECOND, segment.[start_time], segment.[end_time]) ELSE 0 END),
    SUM(CASE WHEN execution_interval.[robot_code] IS NULL AND charging_interval.[robot_code] IS NULL AND waiting_interval.[robot_code] IS NULL AND observed_battery_interval.[robot_code] IS NOT NULL THEN DATEDIFF_BIG(SECOND, segment.[start_time], segment.[end_time]) ELSE 0 END),
    SUM(CASE WHEN execution_interval.[robot_code] IS NULL AND charging_interval.[robot_code] IS NULL AND waiting_interval.[robot_code] IS NULL AND observed_battery_interval.[robot_code] IS NULL THEN DATEDIFF_BIG(SECOND, segment.[start_time], segment.[end_time]) ELSE 0 END)
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
    DATEADD(MINUTE, (DATEDIFF(MINUTE, @epoch, segment.[start_time]) / @bucket_minutes) * @bucket_minutes, @epoch),
    segment.[robot_code];

/* 0: grain metadata and exact trend coverage. */
SELECT
    CONVERT(NVARCHAR(19), @requested_start, 120) AS [analysis_start],
    CONVERT(NVARCHAR(19), @requested_end, 120) AS [analysis_end],
    @bucket_minutes AS [bucket_minutes],
    COUNT_BIG(1) AS [trend_row_count],
    COUNT(DISTINCT trend_state.[robot_code]) AS [robot_count]
FROM #trend_state AS trend_state;

/* 1: exact state-duration and task-event trend by robot and adaptive bucket. */
SELECT
    CONVERT(NVARCHAR(19), trend_state.[bucket_start], 120) AS [stat_hour],
    trend_state.[robot_code],
    trend_state.[executing_seconds],
    trend_state.[charging_seconds],
    trend_state.[waiting_seconds],
    trend_state.[no_task_seconds],
    trend_state.[data_unavailable_seconds],
    COALESCE(event_count.[accepted_queue_count], CONVERT(BIGINT, 0)) AS [accepted_queue_count],
    COALESCE(event_count.[task_started_count], CONVERT(BIGINT, 0)) AS [task_started_count],
    COALESCE(event_count.[subtask_started_count], CONVERT(BIGINT, 0)) AS [subtask_started_count],
    COALESCE(event_count.[task_completed_count], CONVERT(BIGINT, 0)) AS [task_completed_count]
FROM #trend_state AS trend_state
OUTER APPLY
(
    SELECT
        SUM(CASE WHEN event_row.[event_type] = N'QUEUE_ENQUEUED' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [accepted_queue_count],
        SUM(CASE WHEN event_row.[event_type] = N'JOB_STARTED' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [task_started_count],
        SUM(CASE WHEN event_row.[event_type] = N'SUBJOB_STARTED' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [subtask_started_count],
        SUM(CASE WHEN event_row.[event_type] = N'JOB_ENDED' AND LOWER(LTRIM(RTRIM(COALESCE(event_row.[event_status], N'')))) = N'success' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [task_completed_count]
    FROM [DWD].[fact_robot_operation_event] AS event_row
    WHERE event_row.[robot_code] = trend_state.[robot_code]
      AND event_row.[event_time] >= trend_state.[bucket_start]
      AND event_row.[event_time] < DATEADD(MINUTE, @bucket_minutes, trend_state.[bucket_start])
      AND event_row.[event_time] >= @requested_start
      AND event_row.[event_time] < @requested_end
      AND event_row.[event_type] IN (N'QUEUE_ENQUEUED', N'JOB_STARTED', N'SUBJOB_STARTED', N'JOB_ENDED')
) AS event_count
ORDER BY trend_state.[bucket_start], trend_state.[robot_code];

/* 2: adaptive Calling Box event trend, restricted to the top six labels. */
;WITH scoped_queue AS
(
    SELECT
        queue_fact.[queue_id], queue_fact.[event_time], queue_fact.[calling_box_id], queue_fact.[calling_box_name],
        robot_master.[name] AS [robot_code]
    FROM [DWD].[fact_amr_queue] AS queue_fact
    INNER JOIN [dbo].[MA_AMR] AS robot_master
        ON robot_master.[id] = TRY_CONVERT(INT, queue_fact.[robot_id])
    WHERE queue_fact.[event_time] >= @requested_start
      AND queue_fact.[event_time] < @requested_end
      AND queue_fact.[calling_box_id] IS NOT NULL
      AND
      (
          NOT EXISTS (SELECT 1 FROM @selected_robots)
          OR EXISTS (SELECT 1 FROM @selected_robots AS selected WHERE selected.[robot_code] = robot_master.[name])
      )
),
labeled AS
(
    SELECT
        scoped_queue.[queue_id], scoped_queue.[event_time], scoped_queue.[robot_code],
        COALESCE(NULLIF(scoped_queue.[calling_box_name], N''), N'Calling Box #')
          + CASE
                WHEN NULLIF(scoped_queue.[calling_box_name], N'') IS NULL
                    THEN CONVERT(NVARCHAR(20), scoped_queue.[calling_box_id])
                ELSE N' · #' + CONVERT(NVARCHAR(20), scoped_queue.[calling_box_id])
            END AS [calling_box_label]
    FROM scoped_queue
),
top_labels AS
(
    SELECT TOP (6) labeled.[calling_box_label]
    FROM labeled
    GROUP BY labeled.[calling_box_label]
    ORDER BY COUNT_BIG(DISTINCT labeled.[queue_id]) DESC, labeled.[calling_box_label]
)
SELECT
    CONVERT(NVARCHAR(19), DATEADD(MINUTE, (DATEDIFF(MINUTE, @epoch, labeled.[event_time]) / @bucket_minutes) * @bucket_minutes, @epoch), 120) AS [stat_hour],
    labeled.[calling_box_label],
    COUNT_BIG(DISTINCT labeled.[queue_id]) AS [calling_box_count]
FROM labeled
INNER JOIN top_labels
    ON top_labels.[calling_box_label] = labeled.[calling_box_label]
GROUP BY
    DATEADD(MINUTE, (DATEDIFF(MINUTE, @epoch, labeled.[event_time]) / @bucket_minutes) * @bucket_minutes, @epoch),
    labeled.[calling_box_label]
ORDER BY [stat_hour], labeled.[calling_box_label];

/* 3: adaptive assigned-task event trend, restricted to the top six labels. */
;WITH scoped_queue AS
(
    SELECT
        queue_fact.[queue_id], queue_fact.[event_time], queue_fact.[queue_status],
        TRY_CONVERT(INT, queue_fact.[job_id]) AS [job_id], task_dim.[task_name], robot_master.[name] AS [robot_code]
    FROM [DWD].[fact_amr_queue] AS queue_fact
    INNER JOIN [dbo].[MA_AMR] AS robot_master
        ON robot_master.[id] = TRY_CONVERT(INT, queue_fact.[robot_id])
    LEFT JOIN [DWD].[dim_amr_task] AS task_dim
        ON task_dim.[job_id] = TRY_CONVERT(INT, queue_fact.[job_id])
    WHERE queue_fact.[event_time] >= @requested_start
      AND queue_fact.[event_time] < @requested_end
      AND TRY_CONVERT(INT, queue_fact.[job_id]) IS NOT NULL
      AND
      (
          NOT EXISTS (SELECT 1 FROM @selected_robots)
          OR EXISTS (SELECT 1 FROM @selected_robots AS selected WHERE selected.[robot_code] = robot_master.[name])
      )
),
labeled AS
(
    SELECT
        scoped_queue.[queue_id], scoped_queue.[event_time], scoped_queue.[queue_status], scoped_queue.[robot_code],
        COALESCE(NULLIF(scoped_queue.[task_name], N''), N'Task #')
          + CASE
                WHEN NULLIF(scoped_queue.[task_name], N'') IS NULL
                    THEN CONVERT(NVARCHAR(20), scoped_queue.[job_id])
                ELSE N' · #' + CONVERT(NVARCHAR(20), scoped_queue.[job_id])
            END AS [task_label]
    FROM scoped_queue
),
top_labels AS
(
    SELECT TOP (6) labeled.[task_label]
    FROM labeled
    GROUP BY labeled.[task_label]
    ORDER BY COUNT_BIG(DISTINCT labeled.[queue_id]) DESC, labeled.[task_label]
)
SELECT
    CONVERT(NVARCHAR(19), DATEADD(MINUTE, (DATEDIFF(MINUTE, @epoch, labeled.[event_time]) / @bucket_minutes) * @bucket_minutes, @epoch), 120) AS [stat_hour],
    labeled.[task_label],
    COUNT_BIG(DISTINCT labeled.[queue_id]) AS [assigned_task_count],
    COUNT_BIG(DISTINCT CASE
        WHEN LOWER(LTRIM(RTRIM(COALESCE(labeled.[queue_status], N'')))) IN (N'completed', N'compleated')
            THEN labeled.[queue_id]
    END) AS [completed_task_count]
FROM labeled
INNER JOIN top_labels
    ON top_labels.[task_label] = labeled.[task_label]
GROUP BY
    DATEADD(MINUTE, (DATEDIFF(MINUTE, @epoch, labeled.[event_time]) / @bucket_minutes) * @bucket_minutes, @epoch),
    labeled.[task_label]
ORDER BY [stat_hour], labeled.[task_label];

DROP TABLE #trend_state;
DROP TABLE #atomic_segment;
DROP TABLE #cut_point;
DROP TABLE #waiting_interval;
DROP TABLE #waiting_raw;
DROP TABLE #battery_interval;
DROP TABLE #execution_interval;
DROP TABLE #execution_raw;
DROP TABLE #active_robot;
