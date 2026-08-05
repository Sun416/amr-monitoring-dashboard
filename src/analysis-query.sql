SET NOCOUNT ON;

/*
    Read-only evidence query for the transparent rule engine.

    Result 1: one workload row per enabled robot.
    Result 2: one status-history coverage row per enabled robot.
    Result 3: source capability/readiness checks.
    Result 8: unified operation-event coverage by source and event type.

    Workload uses only the __ALL__ DWS rollup to avoid double counting
    job type and operating-mode detail rows.
*/

DECLARE
    @database_now DATETIME2(3) = SYSDATETIME(),
    @job_anchor DATE,
    @status_anchor DATETIME2(0),
    @queue_anchor DATETIME2(3),
    @task_anchor DATETIMEOFFSET,
    @battery_anchor DATETIME2(3),
    @task_sample_limit INT = 50000;

SELECT
    master_robot.[id] AS [master_robot_id],
    master_robot.[name] AS [robot_code],
    CASE
        WHEN UPPER(LTRIM(RTRIM(master_robot.[name]))) LIKE N'AMR%' THEN N'AMR'
        WHEN UPPER(LTRIM(RTRIM(master_robot.[name]))) LIKE N'AMB%' THEN N'AMB'
        ELSE N'OTHER'
    END AS [robot_type]
INTO #analysis_robot_scope
FROM [dbo].[MA_AMR] AS master_robot
WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y'
  AND (
      @robot_type = N'ALL'
      OR UPPER(LTRIM(RTRIM(master_robot.[name]))) LIKE @robot_type + N'%'
  );

CREATE UNIQUE CLUSTERED INDEX [IX_analysis_robot_scope]
    ON #analysis_robot_scope ([master_robot_id]);

SELECT
    @job_anchor = MAX(job_daily.[stat_date])
FROM [DWS].[dws_robot_job_daily] AS job_daily
WHERE job_daily.[job_type_code] = N'__ALL__'
  AND job_daily.[robot_mode_id] = N'__ALL__'
  AND EXISTS (
      SELECT 1
      FROM #analysis_robot_scope AS scope
      WHERE job_daily.[robot_code] = scope.[robot_code]
         OR job_daily.[robot_code] = CONVERT(NVARCHAR(100), scope.[master_robot_id])
  );

SELECT
    scope.[master_robot_id],
    scope.[robot_code],
    scope.[robot_type],
    ISNULL(SUM(job_daily.[distinct_job_count]), 0) AS [assigned_task_count],
    ISNULL(SUM(job_daily.[completed_status_count]), 0) AS [completed_task_count],
    ISNULL(SUM(job_daily.[failed_status_count]), 0) AS [unsuccessful_task_count],
    MIN(job_daily.[stat_date]) AS [first_workload_date],
    MAX(job_daily.[stat_date]) AS [latest_workload_date]
FROM #analysis_robot_scope AS scope
LEFT JOIN [DWS].[dws_robot_job_daily] AS job_daily
    ON (
           job_daily.[robot_code] = scope.[robot_code]
        OR job_daily.[robot_code] = CONVERT(NVARCHAR(100), scope.[master_robot_id])
    )
   AND job_daily.[job_type_code] = N'__ALL__'
   AND job_daily.[robot_mode_id] = N'__ALL__'
   AND @job_anchor IS NOT NULL
   AND job_daily.[stat_date] >= DATEADD(DAY, 1 - @days, @job_anchor)
   AND job_daily.[stat_date] < DATEADD(DAY, 1, @job_anchor)
GROUP BY
    scope.[master_robot_id],
    scope.[robot_code],
    scope.[robot_type]
ORDER BY
    scope.[robot_type],
    [assigned_task_count] DESC,
    scope.[robot_code];

SELECT
    @status_anchor = MAX(status_hour.[stat_hour])
FROM [DWS].[dws_robot_status_hourly] AS status_hour
WHERE EXISTS (
    SELECT 1
    FROM #analysis_robot_scope AS scope
    WHERE status_hour.[robot_code] = scope.[robot_code]
       OR status_hour.[robot_code] = CONVERT(NVARCHAR(100), scope.[master_robot_id])
);

SELECT
    scope.[master_robot_id],
    scope.[robot_code],
    ISNULL(SUM(status_hour.[sample_count]), 0) AS [status_sample_count],
    ISNULL(SUM(status_hour.[online_sample_count]), 0) AS [online_sample_count],
    ISNULL(SUM(status_hour.[error_sample_count]), 0) AS [error_sample_count],
    CAST(
        SUM(
            CASE
                WHEN status_hour.[avg_speed_mps] IS NOT NULL
                    THEN status_hour.[avg_speed_mps] * status_hour.[sample_count]
                ELSE 0
            END
        ) / NULLIF(SUM(
            CASE WHEN status_hour.[avg_speed_mps] IS NOT NULL THEN status_hour.[sample_count] ELSE 0 END
        ), 0)
        AS DECIMAL(18, 4)
    ) AS [weighted_avg_speed_mps],
    MAX(status_hour.[stat_hour]) AS [latest_status_hour]
FROM #analysis_robot_scope AS scope
LEFT JOIN [DWS].[dws_robot_status_hourly] AS status_hour
    ON (
           status_hour.[robot_code] = scope.[robot_code]
        OR status_hour.[robot_code] = CONVERT(NVARCHAR(100), scope.[master_robot_id])
    )
   AND @status_anchor IS NOT NULL
   AND status_hour.[stat_hour] >= DATEADD(HOUR, 1 - @hours, @status_anchor)
   AND status_hour.[stat_hour] <= @status_anchor
GROUP BY
    scope.[master_robot_id],
    scope.[robot_code]
ORDER BY scope.[robot_code];

SELECT
    @queue_anchor = MAX(queue_fact.[event_time])
FROM [DWD].[fact_amr_queue] AS queue_fact
WHERE EXISTS (
    SELECT 1
    FROM #analysis_robot_scope AS scope
    WHERE queue_fact.[robot_code] = scope.[robot_code]
       OR queue_fact.[robot_id] = CONVERT(NVARCHAR(100), scope.[master_robot_id])
);

SELECT
    @database_now AS [database_current_time],
    @job_anchor AS [workload_anchor_date],
    @status_anchor AS [status_history_anchor_time],
    @queue_anchor AS [queue_history_anchor_time],
    (
        SELECT COUNT_BIG(1)
        FROM [DWD].[fact_amr_queue] AS queue_fact
        WHERE @queue_anchor IS NOT NULL
          AND queue_fact.[event_time] >= DATEADD(DAY, -@days, @queue_anchor)
          AND queue_fact.[event_time] <= @queue_anchor
          AND EXISTS (
              SELECT 1
              FROM #analysis_robot_scope AS scope
              WHERE queue_fact.[robot_code] = scope.[robot_code]
                 OR queue_fact.[robot_id] = CONVERT(NVARCHAR(100), scope.[master_robot_id])
          )
    ) AS [queue_row_count],
    (
        SELECT COUNT_BIG(1)
        FROM [DWD].[fact_amr_queue] AS queue_fact
        WHERE @queue_anchor IS NOT NULL
          AND queue_fact.[event_time] >= DATEADD(DAY, -@days, @queue_anchor)
          AND queue_fact.[event_time] <= @queue_anchor
          AND queue_fact.[duration_seconds] IS NOT NULL
          AND EXISTS (
              SELECT 1
              FROM #analysis_robot_scope AS scope
              WHERE queue_fact.[robot_code] = scope.[robot_code]
                 OR queue_fact.[robot_id] = CONVERT(NVARCHAR(100), scope.[master_robot_id])
          )
    ) AS [queue_duration_row_count],
    (
        SELECT COUNT_BIG(1)
        FROM [DWD].[fact_amr_subjob] AS subjob_fact
        WHERE EXISTS (
            SELECT 1
            FROM #analysis_robot_scope AS scope
            WHERE subjob_fact.[robot_code] = scope.[robot_code]
               OR subjob_fact.[robot_id] = CONVERT(NVARCHAR(100), scope.[master_robot_id])
        )
    ) AS [subjob_row_count],
    (
        SELECT COUNT_BIG(1)
        FROM [dbo].[MA_AMR_Project_Assignment] AS assignment
        WHERE EXISTS (
            SELECT 1
            FROM #analysis_robot_scope AS scope
            WHERE scope.[master_robot_id] = assignment.[amr_id]
        )
    ) AS [dispatch_assignment_row_count],
    (
        SELECT COUNT_BIG(1)
        FROM [sys].[columns] AS column_info
        INNER JOIN [sys].[tables] AS table_info
            ON table_info.[object_id] = column_info.[object_id]
        INNER JOIN [sys].[schemas] AS schema_info
            ON schema_info.[schema_id] = table_info.[schema_id]
        WHERE schema_info.[name] = N'DWD'
          AND table_info.[name] = N'fact_dispatch_decision_candidate'
          AND column_info.[name] IN (
              N'decision_id',
              N'task_id',
              N'robot_id',
              N'eligibility_result',
              N'total_score',
              N'selected_flag',
              N'rejection_reason_code'
          )
    ) AS [dispatch_audit_field_count],
    (
        SELECT ISNULL(SUM(partition_stats.[row_count]), 0)
        FROM [sys].[tables] AS table_info
        INNER JOIN [sys].[schemas] AS schema_info
            ON schema_info.[schema_id] = table_info.[schema_id]
        INNER JOIN [sys].[dm_db_partition_stats] AS partition_stats
            ON partition_stats.[object_id] = table_info.[object_id]
           AND partition_stats.[index_id] IN (0, 1)
        WHERE schema_info.[name] = N'DWD'
          AND table_info.[name] = N'fact_dispatch_decision_candidate'
    ) AS [dispatch_audit_row_count],
    (
        SELECT COUNT_BIG(1)
        FROM [DWD].[fact_robot_operation_event] AS operation_event
    ) AS [operation_event_row_count],
    (
        SELECT COUNT_BIG(operation_event.[robot_id])
        FROM [DWD].[fact_robot_operation_event] AS operation_event
    ) AS [operation_event_robot_attributed_count],
    (
        SELECT MAX(operation_event.[event_time])
        FROM [DWD].[fact_robot_operation_event] AS operation_event
    ) AS [operation_event_latest_time],
    (
        SELECT COUNT_BIG(1)
        FROM [DWD].[robot_event_watermark] AS watermark
    ) AS [audit_watermark_source_count],
    (
        SELECT COUNT_BIG(1)
        FROM [DWD].[robot_event_watermark] AS watermark
        INNER JOIN (
            SELECT
                N'ODS' AS [source_schema],
                N'AMR_Queue' AS [source_table],
                MAX(source_row.[ods_row_id]) AS [source_max_ods_row_id]
            FROM [ODS].[AMR_Queue] AS source_row
            UNION ALL
            SELECT
                N'ODS',
                N'TA_AMR',
                MAX(source_row.[ods_row_id])
            FROM [ODS].[TA_AMR] AS source_row
            UNION ALL
            SELECT
                N'ODS',
                N'MA_AMR_Project_Assignment',
                MAX(source_row.[ods_row_id])
            FROM [ODS].[MA_AMR_Project_Assignment] AS source_row
        ) AS source_anchor
            ON source_anchor.[source_schema] = watermark.[source_schema]
           AND source_anchor.[source_table] = watermark.[source_table]
        WHERE watermark.[last_ods_row_id] >= source_anchor.[source_max_ods_row_id]
    ) AS [audit_sources_current_count],
    (
        SELECT COUNT_BIG(1)
        FROM [DWD].[fact_robot_incident] AS incident
    ) AS [incident_row_count],
    (
        SELECT COUNT_BIG(1)
        FROM [DWD].[fact_robot_incident_evidence] AS incident_evidence
    ) AS [incident_evidence_row_count];

/*
    Bounded recent task evidence:
    - TA_AMR has a clustered key on id but no leading start_time index.
    - Read only the newest 50,000 rows, then apply the requested time window.
    - AMR_Subjob_Analyze.limit is treated as a configured duration limit in
      milliseconds. The Web labels this assumption explicitly.
*/
SELECT TOP (@task_sample_limit)
    task.[id] AS [task_execution_id],
    scope.[master_robot_id],
    scope.[robot_code],
    scope.[robot_type],
    task.[queue_id],
    task.[job_id],
    task.[subjob_id],
    ISNULL(task.[subjob_id], -1) AS [normalized_subjob_id],
    task.[start_time],
    task.[end_time],
    task.[status]
INTO #analysis_recent_task
FROM [dbo].[TA_AMR] AS task
INNER JOIN #analysis_robot_scope AS scope
    ON scope.[master_robot_id] = task.[AMR_id]
ORDER BY task.[id] DESC;

CREATE UNIQUE CLUSTERED INDEX [IX_analysis_recent_task]
    ON #analysis_recent_task ([task_execution_id]);

CREATE NONCLUSTERED INDEX [IX_analysis_recent_task_robot_time]
    ON #analysis_recent_task ([master_robot_id], [start_time]);

SELECT @task_anchor = MAX(recent_task.[start_time])
FROM #analysis_recent_task AS recent_task;

;WITH reference_ranked AS (
    SELECT
        reference.[job_id],
        ISNULL(reference.[subjob_id], -1) AS [normalized_subjob_id],
        reference.[limit] AS [duration_limit_milliseconds],
        ROW_NUMBER() OVER (
            PARTITION BY reference.[job_id], ISNULL(reference.[subjob_id], -1)
            ORDER BY reference.[id] DESC
        ) AS [reference_rank]
    FROM [dbo].[AMR_Subjob_Analyze] AS reference
)
SELECT
    reference_ranked.[job_id],
    reference_ranked.[normalized_subjob_id],
    reference_ranked.[duration_limit_milliseconds]
INTO #analysis_duration_reference
FROM reference_ranked
WHERE reference_ranked.[reference_rank] = 1;

CREATE UNIQUE CLUSTERED INDEX [IX_analysis_duration_reference]
    ON #analysis_duration_reference ([job_id], [normalized_subjob_id]);

SELECT
    recent_task.[master_robot_id],
    recent_task.[robot_code],
    recent_task.[robot_type],
    COUNT_BIG(1) AS [task_execution_count],
    SUM(
        CASE
            WHEN recent_task.[start_time] IS NOT NULL
             AND recent_task.[end_time] IS NOT NULL
             AND recent_task.[end_time] >= recent_task.[start_time]
                THEN CONVERT(BIGINT, 1)
            ELSE 0
        END
    ) AS [duration_complete_count],
    SUM(
        CASE
            WHEN recent_task.[start_time] IS NOT NULL
             AND recent_task.[end_time] IS NOT NULL
             AND recent_task.[end_time] >= recent_task.[start_time]
             AND duration_reference.[duration_limit_milliseconds] > 0
                THEN CONVERT(BIGINT, 1)
            ELSE 0
        END
    ) AS [duration_reference_count],
    SUM(
        CASE
            WHEN recent_task.[start_time] IS NOT NULL
             AND recent_task.[end_time] IS NOT NULL
             AND recent_task.[end_time] >= recent_task.[start_time]
             AND duration_reference.[duration_limit_milliseconds] > 0
             AND DATEDIFF_BIG(MILLISECOND, recent_task.[start_time], recent_task.[end_time])
                 <= duration_reference.[duration_limit_milliseconds]
                THEN CONVERT(BIGINT, 1)
            ELSE 0
        END
    ) AS [on_time_count],
    CAST(
        100.0 * SUM(
            CASE
                WHEN recent_task.[start_time] IS NOT NULL
                 AND recent_task.[end_time] IS NOT NULL
                 AND recent_task.[end_time] >= recent_task.[start_time]
                 AND duration_reference.[duration_limit_milliseconds] > 0
                 AND DATEDIFF_BIG(MILLISECOND, recent_task.[start_time], recent_task.[end_time])
                     <= duration_reference.[duration_limit_milliseconds]
                    THEN CONVERT(BIGINT, 1)
                ELSE 0
            END
        )
        / NULLIF(SUM(
            CASE
                WHEN recent_task.[start_time] IS NOT NULL
                 AND recent_task.[end_time] IS NOT NULL
                 AND recent_task.[end_time] >= recent_task.[start_time]
                 AND duration_reference.[duration_limit_milliseconds] > 0
                    THEN CONVERT(BIGINT, 1)
                ELSE 0
            END
        ), 0)
        AS DECIMAL(9, 2)
    ) AS [on_time_rate_percent],
    CAST(AVG(
        CASE
            WHEN recent_task.[start_time] IS NOT NULL
             AND recent_task.[end_time] IS NOT NULL
             AND recent_task.[end_time] >= recent_task.[start_time]
                THEN CONVERT(DECIMAL(18, 3), DATEDIFF_BIG(MILLISECOND, recent_task.[start_time], recent_task.[end_time]) / 1000.0)
        END
    ) AS DECIMAL(18, 2)) AS [avg_actual_duration_seconds],
    MAX(
        CASE
            WHEN recent_task.[start_time] IS NOT NULL
             AND recent_task.[end_time] IS NOT NULL
             AND recent_task.[end_time] >= recent_task.[start_time]
                THEN DATEDIFF_BIG(SECOND, recent_task.[start_time], recent_task.[end_time])
        END
    ) AS [max_actual_duration_seconds],
    SUM(
        CASE
            WHEN recent_task.[start_time] IS NOT NULL
             AND recent_task.[end_time] IS NOT NULL
             AND recent_task.[end_time] >= recent_task.[start_time]
             AND DATEDIFF_BIG(SECOND, recent_task.[start_time], recent_task.[end_time]) > 3600
                THEN CONVERT(BIGINT, 1)
            ELSE 0
        END
    ) AS [over_1_hour_duration_count],
    MIN(recent_task.[start_time]) AS [first_task_time],
    MAX(recent_task.[start_time]) AS [last_task_time],
    @task_anchor AS [task_anchor_time],
    @task_sample_limit AS [task_sample_limit],
    CASE
        WHEN (SELECT COUNT_BIG(1) FROM #analysis_recent_task) >= @task_sample_limit
         AND (SELECT MIN(sampled_task.[start_time]) FROM #analysis_recent_task AS sampled_task) > DATEADD(DAY, -@days, @task_anchor)
            THEN CONVERT(BIT, 1)
        ELSE CONVERT(BIT, 0)
    END AS [window_truncated]
FROM #analysis_recent_task AS recent_task
LEFT JOIN #analysis_duration_reference AS duration_reference
    ON duration_reference.[job_id] = recent_task.[job_id]
   AND duration_reference.[normalized_subjob_id] = recent_task.[normalized_subjob_id]
WHERE @task_anchor IS NOT NULL
  AND recent_task.[start_time] >= DATEADD(DAY, -@days, @task_anchor)
  AND recent_task.[start_time] <= @task_anchor
GROUP BY
    recent_task.[master_robot_id],
    recent_task.[robot_code],
    recent_task.[robot_type]
ORDER BY recent_task.[robot_code];

/*
    Queue wait is derived from the original queue enqueue time to the linked
    TA_AMR execution start. This is not the same as DWD.duration_seconds, which
    is currently empty.
*/
SELECT
    recent_task.[master_robot_id],
    recent_task.[robot_code],
    recent_task.[robot_type],
    COUNT_BIG(1) AS [linked_queue_count],
    CAST(AVG(CONVERT(DECIMAL(18, 3), DATEDIFF_BIG(MILLISECOND, queue_source.[enqueued_at], recent_task.[start_time]) / 1000.0)) AS DECIMAL(18, 2)) AS [avg_queue_wait_seconds],
    MAX(DATEDIFF_BIG(SECOND, queue_source.[enqueued_at], recent_task.[start_time])) AS [max_queue_wait_seconds],
    SUM(
        CASE
            WHEN DATEDIFF_BIG(SECOND, queue_source.[enqueued_at], recent_task.[start_time]) > 300
                THEN CONVERT(BIGINT, 1)
            ELSE 0
        END
    ) AS [over_5_minute_queue_count]
FROM #analysis_recent_task AS recent_task
INNER JOIN [dbo].[AMR_Queue] AS queue_source
    ON queue_source.[id] = recent_task.[queue_id]
WHERE @task_anchor IS NOT NULL
  AND recent_task.[start_time] >= DATEADD(DAY, -@days, @task_anchor)
  AND recent_task.[start_time] <= @task_anchor
  AND queue_source.[enqueued_at] IS NOT NULL
  AND recent_task.[start_time] >= queue_source.[enqueued_at]
GROUP BY
    recent_task.[master_robot_id],
    recent_task.[robot_code],
    recent_task.[robot_type]
ORDER BY recent_task.[robot_code];

/*
    Time-weighted battery share:
    - intervals are capped at five minutes;
    - long gaps do not count as observed time;
    - coverage percent is returned beside the >60% share.
*/
SELECT @battery_anchor = MAX(latest_sample.[pc_timestamp])
FROM #analysis_robot_scope AS scope
OUTER APPLY (
    SELECT TOP (1)
        battery_source.[pc_timestamp]
    FROM [dbo].[robot_battery_history] AS battery_source WITH (INDEX([IX_battery_performance]))
    WHERE battery_source.[amr_id] = scope.[master_robot_id]
    ORDER BY battery_source.[pc_timestamp] DESC
) AS latest_sample;

;WITH battery_samples AS (
    SELECT
        scope.[master_robot_id],
        scope.[robot_code],
        scope.[robot_type],
        battery_source.[pc_timestamp],
        battery_source.[batt_level],
        LEAD(battery_source.[pc_timestamp]) OVER (
            PARTITION BY battery_source.[amr_id]
            ORDER BY battery_source.[pc_timestamp]
        ) AS [next_sample_time]
    FROM #analysis_robot_scope AS scope
    INNER JOIN [dbo].[robot_battery_history] AS battery_source WITH (INDEX([IX_battery_performance]))
        ON battery_source.[amr_id] = scope.[master_robot_id]
    WHERE @battery_anchor IS NOT NULL
      AND battery_source.[pc_timestamp] >= DATEADD(HOUR, -@hours, @battery_anchor)
      AND battery_source.[pc_timestamp] <= @battery_anchor
),
battery_intervals AS (
    SELECT
        battery_samples.[master_robot_id],
        battery_samples.[robot_code],
        battery_samples.[robot_type],
        battery_samples.[pc_timestamp],
        battery_samples.[batt_level],
        CASE
            WHEN battery_samples.[next_sample_time] IS NULL THEN CONVERT(BIGINT, 0)
            WHEN battery_samples.[next_sample_time] <= battery_samples.[pc_timestamp] THEN CONVERT(BIGINT, 0)
            WHEN DATEDIFF_BIG(SECOND, battery_samples.[pc_timestamp], battery_samples.[next_sample_time]) > 300 THEN CONVERT(BIGINT, 0)
            ELSE DATEDIFF_BIG(SECOND, battery_samples.[pc_timestamp], battery_samples.[next_sample_time])
        END AS [observed_seconds]
    FROM battery_samples
)
SELECT
    battery_intervals.[master_robot_id],
    battery_intervals.[robot_code],
    battery_intervals.[robot_type],
    COUNT_BIG(1) AS [sample_count],
    SUM(battery_intervals.[observed_seconds]) AS [observed_seconds],
    SUM(
        CASE WHEN battery_intervals.[batt_level] > 60 THEN battery_intervals.[observed_seconds] ELSE 0 END
    ) AS [above_60_seconds],
    CAST(
        100.0 * SUM(CASE WHEN battery_intervals.[batt_level] > 60 THEN battery_intervals.[observed_seconds] ELSE 0 END)
        / NULLIF(SUM(battery_intervals.[observed_seconds]), 0)
        AS DECIMAL(9, 2)
    ) AS [above_60_time_share_percent],
    CAST(
        100.0 * SUM(battery_intervals.[observed_seconds])
        / NULLIF(CONVERT(DECIMAL(18, 3), @hours) * 3600.0, 0)
        AS DECIMAL(9, 2)
    ) AS [window_coverage_percent],
    MIN(battery_intervals.[pc_timestamp]) AS [first_sample_time],
    MAX(battery_intervals.[pc_timestamp]) AS [last_sample_time],
    @battery_anchor AS [battery_anchor_time]
FROM battery_intervals
GROUP BY
    battery_intervals.[master_robot_id],
    battery_intervals.[robot_code],
    battery_intervals.[robot_type]
HAVING SUM(battery_intervals.[observed_seconds]) > 0
ORDER BY battery_intervals.[robot_code];

/*
    Existing segment evidence can time named subjobs. It cannot identify route
    congestion or loading dwell without route/occupancy and station event data.
*/
SELECT
    recent_task.[master_robot_id],
    recent_task.[robot_code],
    recent_task.[robot_type],
    subjob_type.[name] AS [subjob_type_name],
    subjob.[name] AS [subjob_name],
    COUNT_BIG(1) AS [completed_segment_count],
    CAST(
        AVG(CONVERT(DECIMAL(18, 3), DATEDIFF_BIG(MILLISECOND, recent_task.[start_time], recent_task.[end_time]) / 1000.0))
        AS DECIMAL(18, 2)
    ) AS [avg_segment_duration_seconds],
    MAX(DATEDIFF_BIG(SECOND, recent_task.[start_time], recent_task.[end_time])) AS [max_segment_duration_seconds]
FROM #analysis_recent_task AS recent_task
INNER JOIN [dbo].[MA_AMR_Subjob] AS subjob
    ON subjob.[id] = recent_task.[subjob_id]
LEFT JOIN [dbo].[MA_AMR_Subjob_Type] AS subjob_type
    ON subjob_type.[id] = subjob.[type_id]
WHERE @task_anchor IS NOT NULL
  AND recent_task.[start_time] >= DATEADD(DAY, -@days, @task_anchor)
  AND recent_task.[start_time] <= @task_anchor
  AND recent_task.[end_time] IS NOT NULL
  AND recent_task.[end_time] >= recent_task.[start_time]
GROUP BY
    recent_task.[master_robot_id],
    recent_task.[robot_code],
    recent_task.[robot_type],
    subjob_type.[name],
    subjob.[name]
ORDER BY
    recent_task.[robot_code],
    [completed_segment_count] DESC,
    subjob.[name];

SELECT
    coverage.[source_schema],
    coverage.[source_table],
    coverage.[event_category],
    coverage.[event_type],
    coverage.[event_count],
    coverage.[robot_attributed_event_count],
    coverage.[first_event_time],
    coverage.[latest_event_time],
    coverage.[latest_load_time]
FROM [DWS].[v_robot_event_audit_coverage] AS coverage
ORDER BY
    coverage.[source_schema],
    coverage.[source_table],
    coverage.[event_category],
    coverage.[event_type];
