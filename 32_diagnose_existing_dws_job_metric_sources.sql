USE [IOT2020];
GO

/*
    Read-only diagnosis for updating three columns in the existing table:
    DWS.dws_robot_job_daily.distinct_job_count
    DWS.dws_robot_job_daily.completed_status_count
    DWS.dws_robot_job_daily.failed_status_count

    No table is created and no persistent data is modified.
*/

/* Result 1: AMR queue source completeness and date coverage. */
SELECT
    COUNT_BIG(*) AS [queue_rows],
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(q.[job_id])), N'') IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [null_or_blank_job_id_rows],
    COUNT(DISTINCT NULLIF(LTRIM(RTRIM(q.[job_id])), N'')) AS [distinct_job_id_count],
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(q.[queue_status])), N'') IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [null_or_blank_status_rows],
    SUM(CASE WHEN q.[event_time] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [null_event_time_rows],
    MIN(q.[event_time]) AS [min_event_time],
    MAX(q.[event_time]) AS [max_event_time]
FROM [DWD].[fact_amr_queue] AS q;

/* Result 2: most important result - actual queue status dictionary. */
SELECT TOP (100)
    COALESCE(NULLIF(LTRIM(RTRIM(q.[queue_status])), N''), N'(NULL/BLANK)') AS [queue_status],
    COUNT_BIG(*) AS [row_count],
    COUNT(DISTINCT NULLIF(LTRIM(RTRIM(q.[job_id])), N'')) AS [distinct_job_count]
FROM [DWD].[fact_amr_queue] AS q
GROUP BY COALESCE(NULLIF(LTRIM(RTRIM(q.[queue_status])), N''), N'(NULL/BLANK)')
ORDER BY [row_count] DESC, [queue_status];

/* Result 3: existing queue DWS metrics. */
SELECT
    COUNT_BIG(*) AS [queue_daily_rows],
    SUM(qd.[queue_count]) AS [queue_count],
    SUM(qd.[distinct_queue_count]) AS [distinct_queue_count],
    SUM(qd.[completed_status_count]) AS [completed_status_count],
    SUM(qd.[failed_status_count]) AS [failed_status_count],
    MIN(qd.[stat_date]) AS [min_stat_date],
    MAX(qd.[stat_date]) AS [max_stat_date]
FROM [DWS].[dws_amr_queue_daily] AS qd;

/* Result 4: determine whether dws_robot_job_daily has multiple rows per date+robot. */
SELECT
    COUNT_BIG(*) AS [duplicate_date_robot_groups],
    SUM(d.[rows_in_group]) AS [rows_in_duplicate_groups],
    MAX(d.[rows_in_group]) AS [max_rows_per_date_robot]
FROM (
    SELECT
        jd.[stat_date],
        jd.[robot_code],
        COUNT_BIG(*) AS [rows_in_group]
    FROM [DWS].[dws_robot_job_daily] AS jd
    GROUP BY
        jd.[stat_date],
        jd.[robot_code]
    HAVING COUNT_BIG(*) > 1
) AS d;

/* Result 5: current job DWS coverage and metric totals. */
SELECT
    COUNT_BIG(*) AS [job_daily_rows],
    SUM(jd.[job_count]) AS [job_count],
    SUM(jd.[distinct_job_count]) AS [distinct_job_count],
    SUM(jd.[completed_status_count]) AS [completed_status_count],
    SUM(jd.[failed_status_count]) AS [failed_status_count],
    MIN(jd.[stat_date]) AS [min_stat_date],
    MAX(jd.[stat_date]) AS [max_stat_date]
FROM [DWS].[dws_robot_job_daily] AS jd;

/*
    Result 6: date+robot coverage if queue metrics are used to update the existing
    dws_robot_job_daily rows. This is still read-only.
*/
;WITH [queue_daily] AS (
    SELECT
        CONVERT(DATE, q.[event_time]) AS [stat_date],
        COALESCE(
            NULLIF(LTRIM(RTRIM(q.[robot_code])), N''),
            NULLIF(LTRIM(RTRIM(q.[robot_id])), N''),
            N'UNKNOWN'
        ) AS [robot_code],
        COUNT_BIG(*) AS [queue_rows],
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(q.[job_id])), N'')) AS [distinct_job_count]
    FROM [DWD].[fact_amr_queue] AS q
    WHERE q.[event_time] IS NOT NULL
    GROUP BY
        CONVERT(DATE, q.[event_time]),
        COALESCE(
            NULLIF(LTRIM(RTRIM(q.[robot_code])), N''),
            NULLIF(LTRIM(RTRIM(q.[robot_id])), N''),
            N'UNKNOWN'
        )
),
[job_daily_keys] AS (
    SELECT DISTINCT
        jd.[stat_date],
        jd.[robot_code]
    FROM [DWS].[dws_robot_job_daily] AS jd
)
SELECT
    COUNT_BIG(*) AS [job_daily_date_robot_keys],
    SUM(CASE WHEN qd.[robot_code] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [matched_queue_keys],
    SUM(CASE WHEN qd.[robot_code] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [unmatched_queue_keys],
    SUM(COALESCE(qd.[distinct_job_count], 0)) AS [matched_distinct_job_count]
FROM [job_daily_keys] AS jk
LEFT JOIN [queue_daily] AS qd
    ON qd.[stat_date] = jk.[stat_date]
   AND qd.[robot_code] = jk.[robot_code];

/* Result 7: sample of the rows that could be updated later. */
;WITH [queue_daily] AS (
    SELECT
        CONVERT(DATE, q.[event_time]) AS [stat_date],
        COALESCE(
            NULLIF(LTRIM(RTRIM(q.[robot_code])), N''),
            NULLIF(LTRIM(RTRIM(q.[robot_id])), N''),
            N'UNKNOWN'
        ) AS [robot_code],
        COUNT_BIG(*) AS [queue_rows],
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(q.[job_id])), N'')) AS [candidate_distinct_job_count]
    FROM [DWD].[fact_amr_queue] AS q
    WHERE q.[event_time] IS NOT NULL
    GROUP BY
        CONVERT(DATE, q.[event_time]),
        COALESCE(
            NULLIF(LTRIM(RTRIM(q.[robot_code])), N''),
            NULLIF(LTRIM(RTRIM(q.[robot_id])), N''),
            N'UNKNOWN'
        )
)
SELECT TOP (100)
    jd.[job_daily_id],
    jd.[stat_date],
    jd.[robot_code],
    jd.[job_type_code],
    jd.[distinct_job_count] AS [current_distinct_job_count],
    qd.[candidate_distinct_job_count],
    jd.[completed_status_count] AS [current_completed_status_count],
    jd.[failed_status_count] AS [current_failed_status_count],
    qd.[queue_rows]
FROM [DWS].[dws_robot_job_daily] AS jd
LEFT JOIN [queue_daily] AS qd
    ON qd.[stat_date] = jd.[stat_date]
   AND qd.[robot_code] = jd.[robot_code]
ORDER BY
    jd.[stat_date] DESC,
    jd.[robot_code],
    jd.[job_type_code];
GO
