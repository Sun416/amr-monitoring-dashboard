SET NOCOUNT ON;

/*
    Read-only WiFi analysis for task rows whose job_status is Running.

    Association rule:
      ODS.robot_job_history.amr_id      = ODS.robot_wifi_history.amr_id
      ODS.robot_job_history.pc_timestamp = ODS.robot_wifi_history.pc_timestamp

    poi_target is the task destination. It must not be interpreted as the
    robot's measured physical position at the WiFi sample time.
*/

DECLARE
    @database_now DATETIME2(3) = SYSDATETIME(),
    @analysis_hours INT = CASE
        WHEN @hours < 1 THEN 1
        WHEN @hours > 720 THEN 720
        ELSE @hours
    END,
    @bucket_minutes INT,
    @job_anchor DATETIME2(3),
    @wifi_anchor DATETIME2(3),
    @analysis_anchor DATETIME2(3),
    @analysis_start DATETIME2(3),
    @analysis_end DATETIME2(3),
    @requested_analysis_start DATETIME2(3) = TRY_CONVERT(DATETIME2(3), @wifi_analysis_start, 126),
    @requested_analysis_end DATETIME2(3) = TRY_CONVERT(DATETIME2(3), @wifi_analysis_end, 126),
    @has_custom_window BIT = CASE
        WHEN @wifi_analysis_start IS NOT NULL AND @wifi_analysis_end IS NOT NULL THEN CONVERT(BIT, 1)
        ELSE CONVERT(BIT, 0)
    END,
    @weak_rssi_threshold INT = -67,
    @weak_time_bucket_minutes INT;

SET @bucket_minutes = CASE
    WHEN @analysis_hours <= 12 THEN 5
    WHEN @analysis_hours <= 24 THEN 10
    WHEN @analysis_hours <= 168 THEN 60
    ELSE 240
END;

SET @weak_time_bucket_minutes = CASE
    WHEN @analysis_hours <= 24 THEN 60
    WHEN @analysis_hours <= 168 THEN 240
    ELSE 1440
END;

SELECT
    master_robot.[id] AS [master_robot_id],
    master_robot.[name] AS [robot_code]
INTO #wifi_analysis_robot_scope
FROM [dbo].[MA_AMR] AS master_robot
WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y'
  AND (
      @robot_type = N'ALL'
      OR UPPER(LTRIM(RTRIM(master_robot.[name]))) LIKE @robot_type + N'%'
  );

CREATE UNIQUE CLUSTERED INDEX [IX_wifi_analysis_robot_scope]
    ON #wifi_analysis_robot_scope ([master_robot_id]);

SELECT @job_anchor = MAX(recent_job.[pc_timestamp])
FROM (
    SELECT TOP (1000)
        source_job.[pc_timestamp]
    FROM [ODS].[robot_job_history] AS source_job
    ORDER BY source_job.[ods_row_id] DESC
) AS recent_job;

SELECT @wifi_anchor = MAX(recent_wifi.[pc_timestamp])
FROM (
    SELECT TOP (1000)
        source_wifi.[pc_timestamp]
    FROM [ODS].[robot_wifi_history] AS source_wifi
    ORDER BY source_wifi.[ods_row_id] DESC
) AS recent_wifi;

SET @analysis_anchor = CASE
    WHEN @job_anchor IS NULL THEN @wifi_anchor
    WHEN @wifi_anchor IS NULL THEN @job_anchor
    WHEN @job_anchor <= @wifi_anchor THEN @job_anchor
    ELSE @wifi_anchor
END;

IF @has_custom_window = 1
   AND @requested_analysis_start IS NOT NULL
   AND @requested_analysis_end IS NOT NULL
   AND @requested_analysis_end > @requested_analysis_start
BEGIN
    SET @analysis_start = @requested_analysis_start;
    SET @analysis_end = DATEADD(MILLISECOND, 1, @requested_analysis_end);
END;
ELSE
BEGIN
    SET @analysis_start = DATEADD(HOUR, -@analysis_hours, @analysis_anchor);
    SET @analysis_end = DATEADD(MILLISECOND, 1, @analysis_anchor);
END;

;WITH ranked_running_job AS (
    SELECT
        job_source.[ods_row_id],
        job_source.[amr_id],
        job_source.[pc_timestamp],
        job_source.[poi_target],
        ROW_NUMBER() OVER (
            PARTITION BY job_source.[amr_id], job_source.[pc_timestamp]
            ORDER BY job_source.[ods_row_id] DESC
        ) AS [row_rank]
    FROM [ODS].[robot_job_history] AS job_source
    INNER JOIN #wifi_analysis_robot_scope AS scope
        ON scope.[master_robot_id] = job_source.[amr_id]
    WHERE @analysis_anchor IS NOT NULL
      AND job_source.[job_status] = N'Running'
      AND job_source.[pc_timestamp] >= @analysis_start
      AND job_source.[pc_timestamp] < @analysis_end
)
SELECT
    job_row.[amr_id],
    scope.[robot_code],
    job_row.[pc_timestamp],
    NULLIF(LTRIM(RTRIM(job_row.[poi_target])), N'') AS [poi_target],
    wifi_row.[wifi_signal_level],
    DATEADD(
        MINUTE,
        (DATEDIFF(MINUTE, CONVERT(DATETIME2(0), '20000101'), job_row.[pc_timestamp]) / @bucket_minutes) * @bucket_minutes,
        CONVERT(DATETIME2(0), '20000101')
    ) AS [bucket_start]
INTO #wifi_running_samples
FROM ranked_running_job AS job_row
CROSS APPLY (
    SELECT TOP (1)
        wifi_source.[wifi_signal_level]
    FROM [ODS].[robot_wifi_history] AS wifi_source
    WHERE wifi_source.[amr_id] = job_row.[amr_id]
      AND wifi_source.[pc_timestamp] = job_row.[pc_timestamp]
    ORDER BY wifi_source.[ods_row_id] DESC
) AS wifi_row
INNER JOIN #wifi_analysis_robot_scope AS scope
    ON scope.[master_robot_id] = job_row.[amr_id]
WHERE job_row.[row_rank] = 1
  AND NULLIF(LTRIM(RTRIM(job_row.[poi_target])), N'') IS NOT NULL;

CREATE INDEX [IX_wifi_running_samples_target_bucket]
    ON #wifi_running_samples ([poi_target], [bucket_start])
    INCLUDE ([amr_id], [robot_code], [pc_timestamp], [wifi_signal_level]);

CREATE INDEX [IX_wifi_running_samples_robot_poi_time]
    ON #wifi_running_samples ([robot_code], [poi_target], [pc_timestamp])
    INCLUDE ([wifi_signal_level]);

SELECT
    @database_now AS [database_current_time],
    @job_anchor AS [latest_job_time],
    @wifi_anchor AS [latest_wifi_time],
    @analysis_anchor AS [analysis_anchor_time],
    DATEDIFF(MINUTE, @analysis_anchor, @database_now) AS [source_age_minutes],
    @analysis_hours AS [analysis_window_hours],
    @analysis_start AS [analysis_start_time],
    DATEADD(MILLISECOND, -1, @analysis_end) AS [analysis_end_time],
    @has_custom_window AS [is_custom_window],
    @bucket_minutes AS [bucket_minutes],
    CONVERT(INT, NULL) AS [source_sample_limit],
    COUNT_BIG(*) AS [running_matched_sample_count],
    COUNT_BIG(DISTINCT running_sample.[amr_id]) AS [robot_count],
    COUNT_BIG(DISTINCT running_sample.[poi_target]) AS [target_count],
    SUM(CASE
        WHEN running_sample.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [valid_signal_sample_count],
    SUM(CASE
        WHEN running_sample.[wifi_signal_level] = 0 THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [zero_signal_sample_count],
    SUM(CASE
        WHEN running_sample.[wifi_signal_level] <= @weak_rssi_threshold
         AND running_sample.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [weak_signal_sample_count],
    CAST(
        100.0 * SUM(CASE
            WHEN running_sample.[wifi_signal_level] <= @weak_rssi_threshold
             AND running_sample.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END) / NULLIF(SUM(CASE
            WHEN running_sample.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END), 0)
        AS DECIMAL(9, 2)
    ) AS [weak_signal_rate],
    CAST(AVG(CASE
        WHEN running_sample.[wifi_signal_level] < 0
            THEN CONVERT(DECIMAL(18, 4), running_sample.[wifi_signal_level])
    END) AS DECIMAL(18, 2)) AS [average_valid_rssi],
    MIN(CASE
        WHEN running_sample.[wifi_signal_level] < 0 THEN running_sample.[wifi_signal_level]
    END) AS [minimum_valid_rssi],
    MAX(CASE
        WHEN running_sample.[wifi_signal_level] < 0 THEN running_sample.[wifi_signal_level]
    END) AS [maximum_valid_rssi],
    MIN(running_sample.[pc_timestamp]) AS [first_sample_time],
    MAX(running_sample.[pc_timestamp]) AS [last_sample_time],
    DATEDIFF(MINUTE, MAX(running_sample.[pc_timestamp]), @database_now) AS [running_sample_age_minutes],
    CONVERT(BIT, CASE
        WHEN MAX(running_sample.[pc_timestamp]) IS NOT NULL
         AND DATEDIFF(MINUTE, MAX(running_sample.[pc_timestamp]), @database_now) <= @freshness_timeout_minutes
            THEN 1
        ELSE 0
    END) AS [is_current],
    CONVERT(BIT, CASE
        WHEN @analysis_anchor IS NOT NULL
         AND DATEDIFF(MINUTE, @analysis_anchor, @database_now) <= @freshness_timeout_minutes
            THEN 1
        ELSE 0
    END) AS [source_is_current],
    N'RUNNING_ONLY_EXACT_TIMESTAMP' AS [association_rule],
    @weak_rssi_threshold AS [weak_rssi_threshold]
FROM #wifi_running_samples AS running_sample;

SELECT
    running_sample.[robot_code],
    running_sample.[poi_target],
    running_sample.[bucket_start],
    COUNT_BIG(*) AS [sample_count],
    COUNT_BIG(DISTINCT running_sample.[amr_id]) AS [robot_count],
    SUM(CASE
        WHEN running_sample.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [valid_signal_sample_count],
    SUM(CASE
        WHEN running_sample.[wifi_signal_level] = 0 THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [zero_signal_sample_count],
    SUM(CASE
        WHEN running_sample.[wifi_signal_level] <= @weak_rssi_threshold
         AND running_sample.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [weak_signal_sample_count],
    CAST(AVG(CASE
        WHEN running_sample.[wifi_signal_level] < 0
            THEN CONVERT(DECIMAL(18, 4), running_sample.[wifi_signal_level])
    END) AS DECIMAL(18, 2)) AS [average_valid_rssi],
    MIN(CASE
        WHEN running_sample.[wifi_signal_level] < 0 THEN running_sample.[wifi_signal_level]
    END) AS [minimum_valid_rssi],
    MAX(CASE
        WHEN running_sample.[wifi_signal_level] < 0 THEN running_sample.[wifi_signal_level]
    END) AS [maximum_valid_rssi]
FROM #wifi_running_samples AS running_sample
GROUP BY
    running_sample.[robot_code],
    running_sample.[poi_target],
    running_sample.[bucket_start]
ORDER BY
    running_sample.[bucket_start],
    running_sample.[robot_code],
    running_sample.[poi_target];

SELECT
    running_sample.[poi_target],
    COUNT_BIG(*) AS [sample_count],
    COUNT_BIG(DISTINCT running_sample.[amr_id]) AS [robot_count],
    SUM(CASE
        WHEN running_sample.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [valid_signal_sample_count],
    SUM(CASE
        WHEN running_sample.[wifi_signal_level] = 0 THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [zero_signal_sample_count],
    SUM(CASE
        WHEN running_sample.[wifi_signal_level] <= @weak_rssi_threshold
         AND running_sample.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [weak_signal_sample_count],
    COUNT_BIG(DISTINCT CASE
        WHEN running_sample.[wifi_signal_level] <= @weak_rssi_threshold
         AND running_sample.[wifi_signal_level] < 0 THEN running_sample.[amr_id]
    END) AS [weak_robot_count],
    CAST(
        100.0 * SUM(CASE
            WHEN running_sample.[wifi_signal_level] <= @weak_rssi_threshold
             AND running_sample.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END) / NULLIF(SUM(CASE
            WHEN running_sample.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END), 0)
        AS DECIMAL(9, 2)
    ) AS [weak_signal_rate],
    CAST(
        100.0 * SUM(CASE
            WHEN running_sample.[wifi_signal_level] = 0 THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END) / NULLIF(COUNT_BIG(*), 0)
        AS DECIMAL(9, 2)
    ) AS [zero_signal_rate],
    CAST(AVG(CASE
        WHEN running_sample.[wifi_signal_level] < 0
            THEN CONVERT(DECIMAL(18, 4), running_sample.[wifi_signal_level])
    END) AS DECIMAL(18, 2)) AS [average_valid_rssi],
    MIN(CASE
        WHEN running_sample.[wifi_signal_level] < 0 THEN running_sample.[wifi_signal_level]
    END) AS [minimum_valid_rssi],
    MAX(CASE
        WHEN running_sample.[wifi_signal_level] < 0 THEN running_sample.[wifi_signal_level]
    END) AS [maximum_valid_rssi],
    MIN(running_sample.[pc_timestamp]) AS [first_sample_time],
    MAX(running_sample.[pc_timestamp]) AS [last_sample_time]
FROM #wifi_running_samples AS running_sample
GROUP BY running_sample.[poi_target]
ORDER BY
    [average_valid_rssi],
    [zero_signal_rate] DESC,
    [sample_count] DESC,
    running_sample.[poi_target];

SELECT
    running_sample.[robot_code],
    COUNT_BIG(*) AS [sample_count],
    COUNT_BIG(DISTINCT running_sample.[poi_target]) AS [target_count],
    SUM(CASE
        WHEN running_sample.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [valid_signal_sample_count],
    SUM(CASE
        WHEN running_sample.[wifi_signal_level] = 0 THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [zero_signal_sample_count],
    SUM(CASE
        WHEN running_sample.[wifi_signal_level] <= @weak_rssi_threshold
         AND running_sample.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [weak_signal_sample_count],
    COUNT_BIG(DISTINCT CASE
        WHEN running_sample.[wifi_signal_level] <= @weak_rssi_threshold
         AND running_sample.[wifi_signal_level] < 0 THEN running_sample.[poi_target]
    END) AS [weak_target_count],
    CAST(
        100.0 * SUM(CASE
            WHEN running_sample.[wifi_signal_level] <= @weak_rssi_threshold
             AND running_sample.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END) / NULLIF(SUM(CASE
            WHEN running_sample.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END), 0)
        AS DECIMAL(9, 2)
    ) AS [weak_signal_rate],
    CAST(AVG(CASE
        WHEN running_sample.[wifi_signal_level] < 0
            THEN CONVERT(DECIMAL(18, 4), running_sample.[wifi_signal_level])
    END) AS DECIMAL(18, 2)) AS [average_valid_rssi],
    MIN(CASE
        WHEN running_sample.[wifi_signal_level] < 0 THEN running_sample.[wifi_signal_level]
    END) AS [minimum_valid_rssi],
    MAX(CASE
        WHEN running_sample.[wifi_signal_level] < 0 THEN running_sample.[wifi_signal_level]
    END) AS [maximum_valid_rssi],
    MIN(running_sample.[pc_timestamp]) AS [first_sample_time],
    MAX(running_sample.[pc_timestamp]) AS [last_sample_time]
FROM #wifi_running_samples AS running_sample
GROUP BY running_sample.[robot_code]
ORDER BY
    [sample_count] DESC,
    running_sample.[robot_code];

SELECT
    running_sample.[robot_code],
    running_sample.[poi_target],
    COUNT_BIG(*) AS [sample_count],
    SUM(CASE
        WHEN running_sample.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [valid_signal_sample_count],
    SUM(CASE
        WHEN running_sample.[wifi_signal_level] = 0 THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [zero_signal_sample_count],
    SUM(CASE
        WHEN running_sample.[wifi_signal_level] <= @weak_rssi_threshold
         AND running_sample.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [weak_signal_sample_count],
    CAST(
        100.0 * SUM(CASE
            WHEN running_sample.[wifi_signal_level] <= @weak_rssi_threshold
             AND running_sample.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END) / NULLIF(SUM(CASE
            WHEN running_sample.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END), 0)
        AS DECIMAL(9, 2)
    ) AS [weak_signal_rate],
    CAST(AVG(CASE
        WHEN running_sample.[wifi_signal_level] < 0
            THEN CONVERT(DECIMAL(18, 4), running_sample.[wifi_signal_level])
    END) AS DECIMAL(18, 2)) AS [average_valid_rssi],
    MIN(CASE
        WHEN running_sample.[wifi_signal_level] < 0 THEN running_sample.[wifi_signal_level]
    END) AS [minimum_valid_rssi],
    MAX(CASE
        WHEN running_sample.[wifi_signal_level] < 0 THEN running_sample.[wifi_signal_level]
    END) AS [maximum_valid_rssi],
    MIN(running_sample.[pc_timestamp]) AS [first_sample_time],
    MAX(running_sample.[pc_timestamp]) AS [last_sample_time]
FROM #wifi_running_samples AS running_sample
GROUP BY
    running_sample.[robot_code],
    running_sample.[poi_target]
ORDER BY
    running_sample.[robot_code],
    [average_valid_rssi],
    [sample_count] DESC,
    running_sample.[poi_target];

;WITH ranked_minimum AS (
    SELECT
        running_sample.[robot_code],
        running_sample.[poi_target],
        running_sample.[pc_timestamp],
        running_sample.[wifi_signal_level],
        ROW_NUMBER() OVER (
            ORDER BY
                running_sample.[wifi_signal_level],
                running_sample.[pc_timestamp] DESC,
                running_sample.[robot_code],
                running_sample.[poi_target]
        ) AS [all_rank],
        ROW_NUMBER() OVER (
            PARTITION BY running_sample.[robot_code]
            ORDER BY
                running_sample.[wifi_signal_level],
                running_sample.[pc_timestamp] DESC,
                running_sample.[poi_target]
        ) AS [robot_rank],
        ROW_NUMBER() OVER (
            PARTITION BY running_sample.[poi_target]
            ORDER BY
                running_sample.[wifi_signal_level],
                running_sample.[pc_timestamp] DESC,
                running_sample.[robot_code]
        ) AS [target_rank],
        ROW_NUMBER() OVER (
            PARTITION BY running_sample.[robot_code], running_sample.[poi_target]
            ORDER BY
                running_sample.[wifi_signal_level],
                running_sample.[pc_timestamp] DESC
        ) AS [robot_target_rank]
    FROM #wifi_running_samples AS running_sample
    WHERE running_sample.[wifi_signal_level] < 0
),
minimum_by_scope AS (
    SELECT
        N'ALL' AS [scope_type],
        CONVERT(NVARCHAR(255), NULL) AS [scope_robot_code],
        CONVERT(NVARCHAR(255), NULL) AS [scope_poi_target],
        ranked.[robot_code] AS [minimum_robot_code],
        ranked.[poi_target] AS [minimum_poi_target],
        ranked.[pc_timestamp] AS [minimum_event_time],
        ranked.[wifi_signal_level] AS [minimum_rssi]
    FROM ranked_minimum AS ranked
    WHERE ranked.[all_rank] = 1

    UNION ALL

    SELECT
        N'ROBOT' AS [scope_type],
        CONVERT(NVARCHAR(255), ranked.[robot_code]) AS [scope_robot_code],
        CONVERT(NVARCHAR(255), NULL) AS [scope_poi_target],
        ranked.[robot_code] AS [minimum_robot_code],
        ranked.[poi_target] AS [minimum_poi_target],
        ranked.[pc_timestamp] AS [minimum_event_time],
        ranked.[wifi_signal_level] AS [minimum_rssi]
    FROM ranked_minimum AS ranked
    WHERE ranked.[robot_rank] = 1

    UNION ALL

    SELECT
        N'TARGET' AS [scope_type],
        CONVERT(NVARCHAR(255), NULL) AS [scope_robot_code],
        CONVERT(NVARCHAR(255), ranked.[poi_target]) AS [scope_poi_target],
        ranked.[robot_code] AS [minimum_robot_code],
        ranked.[poi_target] AS [minimum_poi_target],
        ranked.[pc_timestamp] AS [minimum_event_time],
        ranked.[wifi_signal_level] AS [minimum_rssi]
    FROM ranked_minimum AS ranked
    WHERE ranked.[target_rank] = 1

    UNION ALL

    SELECT
        N'ROBOT_TARGET' AS [scope_type],
        CONVERT(NVARCHAR(255), ranked.[robot_code]) AS [scope_robot_code],
        CONVERT(NVARCHAR(255), ranked.[poi_target]) AS [scope_poi_target],
        ranked.[robot_code] AS [minimum_robot_code],
        ranked.[poi_target] AS [minimum_poi_target],
        ranked.[pc_timestamp] AS [minimum_event_time],
        ranked.[wifi_signal_level] AS [minimum_rssi]
    FROM ranked_minimum AS ranked
    WHERE ranked.[robot_target_rank] = 1
)
SELECT
    minimum_scope.[scope_type],
    minimum_scope.[scope_robot_code],
    minimum_scope.[scope_poi_target],
    minimum_scope.[minimum_robot_code],
    minimum_scope.[minimum_poi_target],
    minimum_scope.[minimum_event_time],
    minimum_scope.[minimum_rssi]
FROM minimum_by_scope AS minimum_scope
ORDER BY
    CASE minimum_scope.[scope_type]
        WHEN N'ALL' THEN 1
        WHEN N'ROBOT' THEN 2
        WHEN N'TARGET' THEN 3
        ELSE 4
    END,
    minimum_scope.[scope_robot_code],
    minimum_scope.[scope_poi_target];

/*
    Weak-signal occurrence timeline. The bucket expands as the selected time
    window grows so the chart stays readable: hourly (<=24h), 4-hour (<=7d),
    then daily. Every returned row remains traceable to a robot and task target.
*/
SELECT
    running_sample.[robot_code],
    running_sample.[poi_target],
    DATEADD(
        MINUTE,
        (DATEDIFF(MINUTE, CONVERT(DATETIME2(0), '20000101'), running_sample.[pc_timestamp]) / @weak_time_bucket_minutes) * @weak_time_bucket_minutes,
        CONVERT(DATETIME2(0), '20000101')
    ) AS [bucket_start],
    COUNT_BIG(*) AS [weak_signal_sample_count],
    MIN(running_sample.[pc_timestamp]) AS [first_weak_time],
    MAX(running_sample.[pc_timestamp]) AS [last_weak_time],
    MIN(running_sample.[wifi_signal_level]) AS [minimum_rssi],
    MAX(running_sample.[wifi_signal_level]) AS [maximum_rssi]
FROM #wifi_running_samples AS running_sample
WHERE running_sample.[wifi_signal_level] <= @weak_rssi_threshold
  AND running_sample.[wifi_signal_level] < 0
GROUP BY
    running_sample.[robot_code],
    running_sample.[poi_target],
    DATEADD(
        MINUTE,
        (DATEDIFF(MINUTE, CONVERT(DATETIME2(0), '20000101'), running_sample.[pc_timestamp]) / @weak_time_bucket_minutes) * @weak_time_bucket_minutes,
        CONVERT(DATETIME2(0), '20000101')
    )
ORDER BY
    [bucket_start],
    running_sample.[robot_code],
    running_sample.[poi_target];

DROP TABLE #wifi_running_samples;
DROP TABLE #wifi_analysis_robot_scope;
