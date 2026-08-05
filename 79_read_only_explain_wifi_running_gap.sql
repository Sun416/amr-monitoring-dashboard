/*
    Purpose: explain why the Running-task WiFi view has no samples.
    Scope: read-only diagnostics against ODS source mirrors.
    Grain: robot + task event timestamp; WiFi association requires the exact
           same robot and pc_timestamp, as used by the Web page.
*/
SET NOCOUNT ON;

DECLARE @database_now DATETIME2(3) = SYSDATETIME();
DECLARE @analysis_start DATETIME2(3) = DATEADD(HOUR, -24, @database_now);

/* 1. Source freshness for the two required event streams. */
SELECT
    @database_now AS [database_current_time],
    @analysis_start AS [analysis_start_time],
    MAX(job_source.[pc_timestamp]) AS [latest_job_time],
    MAX(wifi_source.[pc_timestamp]) AS [latest_wifi_time]
FROM [ODS].[robot_job_history] AS job_source
FULL OUTER JOIN [ODS].[robot_wifi_history] AS wifi_source
    ON 1 = 0;

/* 2. Actual task-state values in the selected 24-hour window. */
SELECT
    COALESCE(NULLIF(LTRIM(RTRIM(job_source.[job_status])), N''), N'(blank)') AS [job_status],
    COUNT_BIG(*) AS [job_event_count],
    COUNT_BIG(DISTINCT job_source.[amr_id]) AS [robot_count],
    MIN(job_source.[pc_timestamp]) AS [first_event_time],
    MAX(job_source.[pc_timestamp]) AS [last_event_time]
FROM [ODS].[robot_job_history] AS job_source
WHERE job_source.[pc_timestamp] >= @analysis_start
  AND job_source.[pc_timestamp] < @database_now
GROUP BY COALESCE(NULLIF(LTRIM(RTRIM(job_source.[job_status])), N''), N'(blank)')
ORDER BY [job_event_count] DESC, [job_status];

/* 3. Running jobs must also have a nonblank target POI before plotting. */
SELECT
    COUNT_BIG(*) AS [running_job_event_count],
    COUNT_BIG(DISTINCT job_source.[amr_id]) AS [running_robot_count],
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(job_source.[poi_target])), N'') IS NOT NULL THEN 1 ELSE 0 END) AS [running_with_target_poi_count],
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(job_source.[poi_target])), N'') IS NULL THEN 1 ELSE 0 END) AS [running_without_target_poi_count],
    MIN(job_source.[pc_timestamp]) AS [first_running_time],
    MAX(job_source.[pc_timestamp]) AS [last_running_time]
FROM [ODS].[robot_job_history] AS job_source
WHERE job_source.[job_status] = N'Running'
  AND job_source.[pc_timestamp] >= @analysis_start
  AND job_source.[pc_timestamp] < @database_now;

/* 4. Exact robot + timestamp WiFi association used by the Web analysis. */
;WITH [running_jobs] AS (
    SELECT
        job_source.[amr_id],
        job_source.[pc_timestamp],
        NULLIF(LTRIM(RTRIM(job_source.[poi_target])), N'') AS [poi_target]
    FROM [ODS].[robot_job_history] AS job_source
    WHERE job_source.[job_status] = N'Running'
      AND job_source.[pc_timestamp] >= @analysis_start
      AND job_source.[pc_timestamp] < @database_now
),
[running_jobs_with_wifi_match] AS (
    SELECT
        running_job.[amr_id],
        running_job.[pc_timestamp],
        running_job.[poi_target],
        CASE
            WHEN EXISTS (
                SELECT 1
                FROM [ODS].[robot_wifi_history] AS wifi_source
                WHERE wifi_source.[amr_id] = running_job.[amr_id]
                  AND wifi_source.[pc_timestamp] = running_job.[pc_timestamp]
            ) THEN 1
            ELSE 0
        END AS [has_exact_wifi_match]
    FROM [running_jobs] AS running_job
)
SELECT
    COUNT_BIG(*) AS [running_job_event_count],
    SUM(CASE WHEN running_job.[poi_target] IS NOT NULL THEN 1 ELSE 0 END) AS [running_with_target_poi_count],
    SUM(CASE WHEN running_job.[poi_target] IS NOT NULL
                   AND running_job.[has_exact_wifi_match] = 1
             THEN 1 ELSE 0 END) AS [exact_wifi_matched_running_poi_count],
    SUM(CASE WHEN running_job.[poi_target] IS NOT NULL
                   AND running_job.[has_exact_wifi_match] = 0
             THEN 1 ELSE 0 END) AS [no_exact_wifi_match_count]
FROM [running_jobs_with_wifi_match] AS running_job;

/* 5. Inspect the individual Running events excluded from the chart. */
;WITH [running_jobs] AS (
    SELECT
        job_source.[amr_id],
        job_source.[pc_timestamp],
        NULLIF(LTRIM(RTRIM(job_source.[poi_target])), N'') AS [poi_target]
    FROM [ODS].[robot_job_history] AS job_source
    WHERE job_source.[job_status] = N'Running'
      AND job_source.[pc_timestamp] >= @analysis_start
      AND job_source.[pc_timestamp] < @database_now
)
SELECT
    running_job.[amr_id],
    master_amr.[name] AS [robot_code],
    running_job.[pc_timestamp] AS [running_event_time],
    running_job.[poi_target],
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM [ODS].[robot_wifi_history] AS wifi_source
            WHERE wifi_source.[amr_id] = running_job.[amr_id]
              AND wifi_source.[pc_timestamp] = running_job.[pc_timestamp]
        ) THEN CAST(1 AS BIT)
        ELSE CAST(0 AS BIT)
    END AS [has_exact_wifi_match],
    nearest_wifi.[pc_timestamp] AS [nearest_wifi_time],
    nearest_wifi.[wifi_signal_level] AS [nearest_wifi_signal_level],
    DATEDIFF_BIG(MILLISECOND, running_job.[pc_timestamp], nearest_wifi.[pc_timestamp]) AS [nearest_wifi_offset_ms]
FROM [running_jobs] AS running_job
LEFT JOIN [dbo].[MA_AMR] AS master_amr
    ON master_amr.[id] = running_job.[amr_id]
OUTER APPLY (
    SELECT TOP (1)
        wifi_source.[pc_timestamp],
        wifi_source.[wifi_signal_level]
    FROM [ODS].[robot_wifi_history] AS wifi_source
    WHERE wifi_source.[amr_id] = running_job.[amr_id]
    ORDER BY
        ABS(DATEDIFF_BIG(MILLISECOND, running_job.[pc_timestamp], wifi_source.[pc_timestamp])),
        wifi_source.[pc_timestamp]
) AS nearest_wifi
ORDER BY running_job.[pc_timestamp] DESC;
