USE [IOT2020];
GO

/*
    Update three metrics in the existing DWS.dws_robot_job_daily table.

    No persistent table is created, deleted, or truncated.

    Metric definitions:
    - distinct_job_count:
        number of distinct AMR queue instances, using fact_amr_queue.queue_id.
    - completed_status_count:
        distinct queue instances that have a completed terminal status.
        Includes the observed misspelling "compleated".
    - failed_status_count:
        distinct queue instances that have an unsuccessful terminal status.
        Includes cancelled/canceled/failed/error/aborted.

    pending, in_progress, NULL, and blank are nonterminal and are not counted as
    completed or failed.

    Update grain: stat_date + robot_code.
    Only rows with matching queue outcome data are updated.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

/*
    Legacy safety guard:
    after script 41 introduces robot_mode_id, queue outcomes belong only to the
    reserved __ALL__/__ALL__ rows maintained by scripts 26 and 44. Re-running
    this old date+robot update would duplicate the same metrics across every
    type/mode detail row.
*/
IF COL_LENGTH(N'DWS.dws_robot_job_daily', N'robot_mode_id') IS NOT NULL
BEGIN
    RAISERROR(N'This legacy script is disabled after the type/mode upgrade. Use script 44 instead.', 16, 1);
    RETURN;
END;

/* Preview 1: impact totals before UPDATE. */
;WITH [queue_item] AS (
    SELECT
        CONVERT(DATE, q.[event_time]) AS [stat_date],
        COALESCE(
            NULLIF(LTRIM(RTRIM(q.[robot_code])), N''),
            NULLIF(LTRIM(RTRIM(q.[robot_id])), N''),
            N'UNKNOWN'
        ) AS [robot_code],
        NULLIF(LTRIM(RTRIM(q.[queue_id])), N'') AS [queue_id],
        MAX(
            CASE
                WHEN UPPER(LTRIM(RTRIM(COALESCE(q.[queue_status], N'')))) IN (
                    N'COMPLETED', N'COMPLEATED', N'COMPLETE', N'SUCCESS',
                    N'SUCCEEDED', N'DONE', N'FINISHED', N'完成', N'成功'
                ) THEN 1
                ELSE 0
            END
        ) AS [is_completed],
        MAX(
            CASE
                WHEN UPPER(LTRIM(RTRIM(COALESCE(q.[queue_status], N'')))) IN (
                    N'CANCELLED', N'CANCELED', N'FAILED', N'FAIL', N'ERROR',
                    N'ABORTED', N'取消', N'失败', N'异常'
                ) THEN 1
                ELSE 0
            END
        ) AS [is_unsuccessful]
    FROM [DWD].[fact_amr_queue] AS q
    WHERE q.[event_time] IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(q.[queue_id])), N'') IS NOT NULL
    GROUP BY
        CONVERT(DATE, q.[event_time]),
        COALESCE(
            NULLIF(LTRIM(RTRIM(q.[robot_code])), N''),
            NULLIF(LTRIM(RTRIM(q.[robot_id])), N'')                                                                                          ,
            N'UNKNOWN'
        ),
        NULLIF(LTRIM(RTRIM(q.[queue_id])), N'')
),
[queue_daily] AS (
    SELECT
        qi.[stat_date],
        qi.[robot_code],
        COUNT_BIG(*) AS [distinct_job_count],
        SUM(CONVERT(BIGINT, qi.[is_completed])) AS [completed_status_count],
        SUM(
            CASE
                WHEN qi.[is_completed] = 0 AND qi.[is_unsuccessful] = 1
                    THEN CONVERT(BIGINT, 1)
                ELSE CONVERT(BIGINT, 0)
            END
        ) AS [failed_status_count]
    FROM [queue_item] AS qi
    GROUP BY
        qi.[stat_date],
        qi.[robot_code]
)
SELECT
    COUNT_BIG(*) AS [matched_target_rows],
    SUM(qd.[distinct_job_count]) AS [candidate_distinct_job_count],
    SUM(qd.[completed_status_count]) AS [candidate_completed_status_count],
    SUM(qd.[failed_status_count]) AS [candidate_failed_status_count]
FROM [DWS].[dws_robot_job_daily] AS tgt
INNER JOIN [queue_daily] AS qd
    ON qd.[stat_date] = tgt.[stat_date]
   AND qd.[robot_code] = tgt.[robot_code];

/* Preview 2: exact target rows and before/after values. */
;WITH [queue_item] AS (
    SELECT
        CONVERT(DATE, q.[event_time]) AS [stat_date],
        COALESCE(
            NULLIF(LTRIM(RTRIM(q.[robot_code])), N''),
            NULLIF(LTRIM(RTRIM(q.[robot_id])), N''),
            N'UNKNOWN'
        ) AS [robot_code],
        NULLIF(LTRIM(RTRIM(q.[queue_id])), N'') AS [queue_id],
        MAX(CASE WHEN UPPER(LTRIM(RTRIM(COALESCE(q.[queue_status], N'')))) IN (
            N'COMPLETED', N'COMPLEATED', N'COMPLETE', N'SUCCESS', N'SUCCEEDED',
            N'DONE', N'FINISHED', N'完成', N'成功'
        ) THEN 1 ELSE 0 END) AS [is_completed],
        MAX(CASE WHEN UPPER(LTRIM(RTRIM(COALESCE(q.[queue_status], N'')))) IN (
            N'CANCELLED', N'CANCELED', N'FAILED', N'FAIL', N'ERROR', N'ABORTED',
            N'取消', N'失败', N'异常'
        ) THEN 1 ELSE 0 END) AS [is_unsuccessful]
    FROM [DWD].[fact_amr_queue] AS q
    WHERE q.[event_time] IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(q.[queue_id])), N'') IS NOT NULL
    GROUP BY
        CONVERT(DATE, q.[event_time]),
        COALESCE(
            NULLIF(LTRIM(RTRIM(q.[robot_code])), N''),
            NULLIF(LTRIM(RTRIM(q.[robot_id])), N''),
            N'UNKNOWN'
        ),
        NULLIF(LTRIM(RTRIM(q.[queue_id])), N'')
),
[queue_daily] AS (
    SELECT
        qi.[stat_date],
        qi.[robot_code],
        COUNT_BIG(*) AS [distinct_job_count],
        SUM(CONVERT(BIGINT, qi.[is_completed])) AS [completed_status_count],
        SUM(CASE WHEN qi.[is_completed] = 0 AND qi.[is_unsuccessful] = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [failed_status_count]
    FROM [queue_item] AS qi
    GROUP BY qi.[stat_date], qi.[robot_code]
)
SELECT
    tgt.[job_daily_id],
    tgt.[stat_date],
    tgt.[robot_code],
    tgt.[job_type_code],
    tgt.[distinct_job_count] AS [old_distinct_job_count],
    qd.[distinct_job_count] AS [new_distinct_job_count],
    tgt.[completed_status_count] AS [old_completed_status_count],
    qd.[completed_status_count] AS [new_completed_status_count],
    tgt.[failed_status_count] AS [old_failed_status_count],
    qd.[failed_status_count] AS [new_failed_status_count]
FROM [DWS].[dws_robot_job_daily] AS tgt
INNER JOIN [queue_daily] AS qd
    ON qd.[stat_date] = tgt.[stat_date]
   AND qd.[robot_code] = tgt.[robot_code]
ORDER BY tgt.[stat_date], tgt.[robot_code], tgt.[job_type_code];

/*
    Atomic repair UPDATE. SQL Server treats this single UPDATE as one atomic
    statement, so an explicit transaction block is unnecessary here.
*/
;WITH [queue_item] AS (
    SELECT
        CONVERT(DATE, q.[event_time]) AS [stat_date],
        COALESCE(
            NULLIF(LTRIM(RTRIM(q.[robot_code])), N''),
            NULLIF(LTRIM(RTRIM(q.[robot_id])), N''),
            N'UNKNOWN'
        ) AS [robot_code],
        NULLIF(LTRIM(RTRIM(q.[queue_id])), N'') AS [queue_id],
        MAX(CASE WHEN UPPER(LTRIM(RTRIM(COALESCE(q.[queue_status], N'')))) IN (
            N'COMPLETED', N'COMPLEATED', N'COMPLETE', N'SUCCESS', N'SUCCEEDED',
            N'DONE', N'FINISHED', N'完成', N'成功'
        ) THEN 1 ELSE 0 END) AS [is_completed],
        MAX(CASE WHEN UPPER(LTRIM(RTRIM(COALESCE(q.[queue_status], N'')))) IN (
            N'CANCELLED', N'CANCELED', N'FAILED', N'FAIL', N'ERROR', N'ABORTED',
            N'取消', N'失败', N'异常'
        ) THEN 1 ELSE 0 END) AS [is_unsuccessful]
    FROM [DWD].[fact_amr_queue] AS q
    WHERE q.[event_time] IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(q.[queue_id])), N'') IS NOT NULL
    GROUP BY
        CONVERT(DATE, q.[event_time]),
        COALESCE(
            NULLIF(LTRIM(RTRIM(q.[robot_code])), N''),
            NULLIF(LTRIM(RTRIM(q.[robot_id])), N''),
            N'UNKNOWN'
        ),
        NULLIF(LTRIM(RTRIM(q.[queue_id])), N'')
),
[queue_daily] AS (
    SELECT
        qi.[stat_date],
        qi.[robot_code],
        COUNT_BIG(*) AS [distinct_job_count],
        SUM(CONVERT(BIGINT, qi.[is_completed])) AS [completed_status_count],
        SUM(CASE WHEN qi.[is_completed] = 0 AND qi.[is_unsuccessful] = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [failed_status_count]
    FROM [queue_item] AS qi
    GROUP BY qi.[stat_date], qi.[robot_code]
)
UPDATE tgt
SET
    tgt.[distinct_job_count] = qd.[distinct_job_count],
    tgt.[completed_status_count] = qd.[completed_status_count],
    tgt.[failed_status_count] = qd.[failed_status_count],
    tgt.[dws_load_time] = SYSDATETIME()
FROM [DWS].[dws_robot_job_daily] AS tgt
INNER JOIN [queue_daily] AS qd
    ON qd.[stat_date] = tgt.[stat_date]
   AND qd.[robot_code] = tgt.[robot_code]
WHERE tgt.[distinct_job_count] <> qd.[distinct_job_count]
   OR tgt.[completed_status_count] <> qd.[completed_status_count]
   OR tgt.[failed_status_count] <> qd.[failed_status_count];

SELECT @@ROWCOUNT AS [rows_updated];

/* Post-update validation: mismatch_rows must be 0. */
;WITH [queue_item] AS (
    SELECT
        CONVERT(DATE, q.[event_time]) AS [stat_date],
        COALESCE(
            NULLIF(LTRIM(RTRIM(q.[robot_code])), N''),
            NULLIF(LTRIM(RTRIM(q.[robot_id])), N''),
            N'UNKNOWN'
        ) AS [robot_code],
        NULLIF(LTRIM(RTRIM(q.[queue_id])), N'') AS [queue_id],
        MAX(CASE WHEN UPPER(LTRIM(RTRIM(COALESCE(q.[queue_status], N'')))) IN (
            N'COMPLETED', N'COMPLEATED', N'COMPLETE', N'SUCCESS', N'SUCCEEDED',
            N'DONE', N'FINISHED', N'完成', N'成功'
        ) THEN 1 ELSE 0 END) AS [is_completed],
        MAX(CASE WHEN UPPER(LTRIM(RTRIM(COALESCE(q.[queue_status], N'')))) IN (
            N'CANCELLED', N'CANCELED', N'FAILED', N'FAIL', N'ERROR', N'ABORTED',
            N'取消', N'失败', N'异常'
        ) THEN 1 ELSE 0 END) AS [is_unsuccessful]
    FROM [DWD].[fact_amr_queue] AS q
    WHERE q.[event_time] IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(q.[queue_id])), N'') IS NOT NULL
    GROUP BY
        CONVERT(DATE, q.[event_time]),
        COALESCE(
            NULLIF(LTRIM(RTRIM(q.[robot_code])), N''),
            NULLIF(LTRIM(RTRIM(q.[robot_id])), N''),
            N'UNKNOWN'
        ),
        NULLIF(LTRIM(RTRIM(q.[queue_id])), N'')
),
[queue_daily] AS (
    SELECT
        qi.[stat_date],
        qi.[robot_code],
        COUNT_BIG(*) AS [distinct_job_count],
        SUM(CONVERT(BIGINT, qi.[is_completed])) AS [completed_status_count],
        SUM(CASE WHEN qi.[is_completed] = 0 AND qi.[is_unsuccessful] = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [failed_status_count]
    FROM [queue_item] AS qi
    GROUP BY qi.[stat_date], qi.[robot_code]
)
SELECT
    COUNT_BIG(*) AS [matched_rows],
    SUM(
        CASE
            WHEN tgt.[distinct_job_count] <> qd.[distinct_job_count]
              OR tgt.[completed_status_count] <> qd.[completed_status_count]
              OR tgt.[failed_status_count] <> qd.[failed_status_count]
                THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END
    ) AS [mismatch_rows],
    SUM(tgt.[distinct_job_count]) AS [updated_distinct_job_count],
    SUM(tgt.[completed_status_count]) AS [updated_completed_status_count],
    SUM(tgt.[failed_status_count]) AS [updated_failed_status_count]
FROM [DWS].[dws_robot_job_daily] AS tgt
INNER JOIN [queue_daily] AS qd
    ON qd.[stat_date] = tgt.[stat_date]
   AND qd.[robot_code] = tgt.[robot_code];
GO
