USE [IOT2020];
SET NOCOUNT ON;

/*
Read-only source profiling for the WiFi signal analysis panel.
No data or schema changes are performed.
*/

SELECT
    s.[name] AS [schema_name],
    o.[name] AS [table_name],
    c.[column_id],
    c.[name] AS [column_name],
    t.[name] AS [data_type],
    c.[max_length],
    c.[precision],
    c.[scale],
    c.[is_nullable]
FROM sys.objects AS o
INNER JOIN sys.schemas AS s
    ON s.[schema_id] = o.[schema_id]
INNER JOIN sys.columns AS c
    ON c.[object_id] = o.[object_id]
INNER JOIN sys.types AS t
    ON t.[user_type_id] = c.[user_type_id]
WHERE o.[type] = N'U'
  AND s.[name] = N'ODS'
  AND o.[name] IN (N'robot_job_history', N'robot_wifi_history')
ORDER BY
    o.[name],
    c.[column_id];

SELECT
    s.[name] AS [schema_name],
    o.[name] AS [table_name],
    i.[name] AS [index_name],
    i.[type_desc],
    i.[is_unique],
    ic.[key_ordinal],
    ic.[is_included_column],
    c.[name] AS [column_name]
FROM sys.objects AS o
INNER JOIN sys.schemas AS s
    ON s.[schema_id] = o.[schema_id]
INNER JOIN sys.indexes AS i
    ON i.[object_id] = o.[object_id]
INNER JOIN sys.index_columns AS ic
    ON ic.[object_id] = i.[object_id]
   AND ic.[index_id] = i.[index_id]
INNER JOIN sys.columns AS c
    ON c.[object_id] = ic.[object_id]
   AND c.[column_id] = ic.[column_id]
WHERE o.[type] = N'U'
  AND s.[name] = N'ODS'
  AND o.[name] IN (N'robot_job_history', N'robot_wifi_history')
ORDER BY
    o.[name],
    i.[index_id],
    ic.[key_ordinal],
    ic.[index_column_id];

DECLARE
    @job_anchor DATETIME2(3),
    @wifi_anchor DATETIME2(3);

SELECT TOP (20000)
    j.[ods_row_id],
    j.[id] AS [source_id],
    j.[amr_id],
    j.[pc_timestamp],
    j.[job_status],
    j.[poi_current],
    j.[poi_target],
    j.[job_name]
INTO #recent_job_sample
FROM [ODS].[robot_job_history] AS j
ORDER BY j.[ods_row_id] DESC;

CREATE INDEX [IX_recent_job_sample_amr_time]
    ON #recent_job_sample ([amr_id], [pc_timestamp] DESC)
    INCLUDE ([ods_row_id], [job_status], [poi_target]);

SELECT TOP (20000)
    w.[ods_row_id],
    w.[id] AS [source_id],
    w.[amr_id],
    w.[pc_timestamp],
    w.[wifi_signal_level]
INTO #recent_wifi_source
FROM [ODS].[robot_wifi_history] AS w
ORDER BY w.[ods_row_id] DESC;

CREATE INDEX [IX_recent_wifi_source_amr_time]
    ON #recent_wifi_source ([amr_id], [pc_timestamp] DESC)
    INCLUDE ([ods_row_id], [wifi_signal_level]);

SELECT @job_anchor = MAX(j.[pc_timestamp])
FROM #recent_job_sample AS j;

SELECT @wifi_anchor = MAX(w.[pc_timestamp])
FROM #recent_wifi_source AS w;

SELECT
    @job_anchor AS [latest_job_time],
    @wifi_anchor AS [latest_wifi_time],
    DATEDIFF(SECOND, @job_anchor, @wifi_anchor) AS [job_to_wifi_anchor_gap_seconds],
    SYSDATETIME() AS [database_current_time],
    DATEDIFF(MINUTE, @job_anchor, SYSDATETIME()) AS [job_age_minutes],
    DATEDIFF(MINUTE, @wifi_anchor, SYSDATETIME()) AS [wifi_age_minutes];

SELECT
    UPPER(LTRIM(RTRIM(COALESCE(j.[job_status], N'')))) AS [normalized_job_status],
    COUNT_BIG(*) AS [row_count],
    COUNT_BIG(DISTINCT j.[amr_id]) AS [robot_count],
    SUM(CASE
        WHEN NULLIF(LTRIM(RTRIM(j.[poi_target])), N'') IS NULL THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [missing_poi_target_count],
    MIN(j.[pc_timestamp]) AS [first_time],
    MAX(j.[pc_timestamp]) AS [latest_time]
FROM #recent_job_sample AS j
WHERE @job_anchor IS NOT NULL
  AND j.[pc_timestamp] > DATEADD(DAY, -1, @job_anchor)
  AND j.[pc_timestamp] <= @job_anchor
GROUP BY UPPER(LTRIM(RTRIM(COALESCE(j.[job_status], N''))))
ORDER BY [row_count] DESC;

SELECT
    COUNT_BIG(*) AS [wifi_row_count],
    COUNT_BIG(DISTINCT w.[amr_id]) AS [robot_count],
    SUM(CASE WHEN w.[wifi_signal_level] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS [null_signal_count],
    SUM(CASE WHEN w.[wifi_signal_level] = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS [zero_signal_count],
    SUM(CASE WHEN w.[wifi_signal_level] < 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS [negative_signal_count],
    MIN(w.[wifi_signal_level]) AS [minimum_signal_level],
    MAX(w.[wifi_signal_level]) AS [maximum_signal_level],
    CAST(AVG(CASE
        WHEN w.[wifi_signal_level] < 0 THEN CONVERT(DECIMAL(18, 4), w.[wifi_signal_level])
    END) AS DECIMAL(18, 2)) AS [average_negative_signal_level],
    MIN(w.[pc_timestamp]) AS [first_time],
    MAX(w.[pc_timestamp]) AS [latest_time]
FROM #recent_wifi_source AS w
WHERE @wifi_anchor IS NOT NULL
  AND w.[pc_timestamp] > DATEADD(DAY, -1, @wifi_anchor)
  AND w.[pc_timestamp] <= @wifi_anchor;

SELECT TOP (20)
    j.[amr_id],
    j.[pc_timestamp],
    j.[job_status],
    j.[poi_current],
    j.[poi_target],
    j.[job_name]
FROM #recent_job_sample AS j
WHERE @job_anchor IS NOT NULL
  AND j.[pc_timestamp] > DATEADD(HOUR, -2, @job_anchor)
ORDER BY
    j.[pc_timestamp] DESC,
    j.[amr_id];

SELECT TOP (1000)
    w.[ods_row_id],
    w.[amr_id],
    w.[pc_timestamp],
    w.[wifi_signal_level]
INTO #recent_wifi_sample
FROM #recent_wifi_source AS w
WHERE @wifi_anchor IS NOT NULL
  AND w.[pc_timestamp] > DATEADD(HOUR, -2, @wifi_anchor)
  AND w.[pc_timestamp] <= @wifi_anchor
ORDER BY
    w.[pc_timestamp] DESC,
    w.[ods_row_id] DESC;

SELECT
    COUNT_BIG(*) AS [sampled_wifi_count],
    SUM(CASE WHEN job_match.[ods_row_id] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS [matched_prior_job_within_120s_count],
    SUM(CASE
        WHEN UPPER(LTRIM(RTRIM(COALESCE(job_match.[job_status], N'')))) = N'RUNNING'
            THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [running_match_count],
    SUM(CASE
        WHEN job_match.[ods_row_id] IS NOT NULL
         AND NULLIF(LTRIM(RTRIM(job_match.[poi_target])), N'') IS NOT NULL
            THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [matched_with_poi_target_count],
    MIN(DATEDIFF(MILLISECOND, job_match.[pc_timestamp], w.[pc_timestamp])) AS [minimum_prior_gap_ms],
    MAX(DATEDIFF(MILLISECOND, job_match.[pc_timestamp], w.[pc_timestamp])) AS [maximum_prior_gap_ms],
    CAST(AVG(CONVERT(DECIMAL(18, 2),
        DATEDIFF(MILLISECOND, job_match.[pc_timestamp], w.[pc_timestamp])
    )) AS DECIMAL(18, 2)) AS [average_prior_gap_ms]
FROM #recent_wifi_sample AS w
OUTER APPLY (
    SELECT TOP (1)
        j.[ods_row_id],
        j.[pc_timestamp],
        j.[job_status],
        j.[poi_target]
    FROM #recent_job_sample AS j
    WHERE j.[amr_id] = w.[amr_id]
      AND j.[pc_timestamp] <= w.[pc_timestamp]
      AND j.[pc_timestamp] >= DATEADD(SECOND, -120, w.[pc_timestamp])
    ORDER BY
        j.[pc_timestamp] DESC,
        j.[ods_row_id] DESC
) AS job_match;

SELECT
    COUNT_BIG(*) AS [exact_robot_time_match_count],
    SUM(CASE
        WHEN job_row.[source_id] = wifi_row.[source_id] THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [same_source_id_count],
    SUM(CASE
        WHEN job_row.[source_id] <> wifi_row.[source_id] THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [different_source_id_count],
    COUNT_BIG(DISTINCT job_row.[source_id]) AS [distinct_job_source_id_count],
    COUNT_BIG(DISTINCT wifi_row.[source_id]) AS [distinct_wifi_source_id_count]
FROM #recent_job_sample AS job_row
INNER JOIN #recent_wifi_source AS wifi_row
    ON wifi_row.[amr_id] = job_row.[amr_id]
   AND wifi_row.[pc_timestamp] = job_row.[pc_timestamp];

SELECT
    UPPER(LTRIM(RTRIM(COALESCE(job_match.[job_status], N'')))) AS [matched_normalized_job_status],
    COUNT_BIG(*) AS [sample_count],
    COUNT_BIG(DISTINCT w.[amr_id]) AS [robot_count],
    SUM(CASE
        WHEN NULLIF(LTRIM(RTRIM(job_match.[poi_target])), N'') IS NULL THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [missing_poi_target_count],
    CAST(AVG(CONVERT(DECIMAL(18, 2),
        DATEDIFF(MILLISECOND, job_match.[pc_timestamp], w.[pc_timestamp])
    )) AS DECIMAL(18, 2)) AS [average_prior_gap_ms]
FROM #recent_wifi_sample AS w
OUTER APPLY (
    SELECT TOP (1)
        j.[ods_row_id],
        j.[pc_timestamp],
        j.[job_status],
        j.[poi_target]
    FROM #recent_job_sample AS j
    WHERE j.[amr_id] = w.[amr_id]
      AND j.[pc_timestamp] <= w.[pc_timestamp]
      AND j.[pc_timestamp] >= DATEADD(SECOND, -120, w.[pc_timestamp])
    ORDER BY
        j.[pc_timestamp] DESC,
        j.[ods_row_id] DESC
) AS job_match
GROUP BY UPPER(LTRIM(RTRIM(COALESCE(job_match.[job_status], N''))))
ORDER BY [sample_count] DESC;

DROP TABLE #recent_wifi_sample;
DROP TABLE #recent_wifi_source;
DROP TABLE #recent_job_sample;
