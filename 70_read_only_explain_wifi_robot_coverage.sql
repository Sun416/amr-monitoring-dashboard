USE [IOT2020];
SET NOCOUNT ON;

/*
Read-only explanation of why an enabled robot is included or excluded from the
current 24-hour running-task WiFi analysis.

The limits match the current Web query and therefore explain the page as it is
implemented today.
*/

DECLARE
    @analysis_hours INT = 24,
    @source_sample_limit INT = 300000,
    @job_anchor DATETIME2(3),
    @wifi_anchor DATETIME2(3),
    @analysis_anchor DATETIME2(3);

SELECT
    master_robot.[id] AS [master_robot_id],
    master_robot.[name] AS [robot_code]
INTO #robot_scope
FROM [dbo].[MA_AMR] AS master_robot
WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y';

CREATE UNIQUE CLUSTERED INDEX [IX_robot_scope]
    ON #robot_scope ([master_robot_id]);

SELECT TOP (@source_sample_limit)
    source_job.[ods_row_id],
    source_job.[amr_id],
    source_job.[pc_timestamp],
    source_job.[job_status],
    source_job.[poi_target]
INTO #job_source
FROM [ODS].[robot_job_history] AS source_job
ORDER BY source_job.[ods_row_id] DESC;

SELECT TOP (@source_sample_limit)
    source_wifi.[ods_row_id],
    source_wifi.[amr_id],
    source_wifi.[pc_timestamp]
INTO #wifi_source
FROM [ODS].[robot_wifi_history] AS source_wifi
ORDER BY source_wifi.[ods_row_id] DESC;

CREATE INDEX [IX_job_source_amr_time]
    ON #job_source ([amr_id], [pc_timestamp])
    INCLUDE ([ods_row_id], [job_status], [poi_target]);

CREATE INDEX [IX_wifi_source_amr_time]
    ON #wifi_source ([amr_id], [pc_timestamp])
    INCLUDE ([ods_row_id]);

SELECT @job_anchor = MAX(job_source.[pc_timestamp])
FROM #job_source AS job_source;

SELECT @wifi_anchor = MAX(wifi_source.[pc_timestamp])
FROM #wifi_source AS wifi_source;

SET @analysis_anchor = CASE
    WHEN @job_anchor IS NULL THEN @wifi_anchor
    WHEN @wifi_anchor IS NULL THEN @job_anchor
    WHEN @job_anchor <= @wifi_anchor THEN @job_anchor
    ELSE @wifi_anchor
END;

;WITH job_by_robot AS (
    SELECT
        scope.[master_robot_id],
        COUNT_BIG(job_source.[ods_row_id]) AS [job_row_count],
        SUM(CASE
            WHEN UPPER(LTRIM(RTRIM(COALESCE(job_source.[job_status], N'')))) = N'RUNNING'
                THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END) AS [running_job_row_count],
        SUM(CASE
            WHEN UPPER(LTRIM(RTRIM(COALESCE(job_source.[job_status], N'')))) = N'RUNNING'
             AND NULLIF(LTRIM(RTRIM(job_source.[poi_target])), N'') IS NOT NULL
                THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END) AS [running_job_with_target_count]
    FROM #robot_scope AS scope
    LEFT JOIN #job_source AS job_source
        ON job_source.[amr_id] = scope.[master_robot_id]
       AND job_source.[pc_timestamp] > DATEADD(HOUR, -@analysis_hours, @analysis_anchor)
       AND job_source.[pc_timestamp] <= @analysis_anchor
    GROUP BY scope.[master_robot_id]
),
exact_running_match_by_robot AS (
    SELECT
        job_source.[amr_id] AS [master_robot_id],
        COUNT_BIG(*) AS [exact_running_wifi_match_count]
    FROM #job_source AS job_source
    INNER JOIN #wifi_source AS wifi_source
        ON wifi_source.[amr_id] = job_source.[amr_id]
       AND wifi_source.[pc_timestamp] = job_source.[pc_timestamp]
    WHERE job_source.[pc_timestamp] > DATEADD(HOUR, -@analysis_hours, @analysis_anchor)
      AND job_source.[pc_timestamp] <= @analysis_anchor
      AND UPPER(LTRIM(RTRIM(COALESCE(job_source.[job_status], N'')))) = N'RUNNING'
      AND NULLIF(LTRIM(RTRIM(job_source.[poi_target])), N'') IS NOT NULL
    GROUP BY job_source.[amr_id]
)
SELECT
    scope.[robot_code],
    job_summary.[job_row_count],
    job_summary.[running_job_row_count],
    job_summary.[running_job_with_target_count],
    COALESCE(exact_match.[exact_running_wifi_match_count], 0) AS [exact_running_wifi_match_count],
    CASE
        WHEN COALESCE(exact_match.[exact_running_wifi_match_count], 0) > 0
            THEN N'INCLUDED'
        WHEN job_summary.[job_row_count] = 0
            THEN N'NO_JOB_DATA_IN_WINDOW'
        WHEN job_summary.[running_job_row_count] = 0
            THEN N'NO_RUNNING_STATUS_IN_WINDOW'
        WHEN job_summary.[running_job_with_target_count] = 0
            THEN N'RUNNING_WITHOUT_TARGET_POI'
        ELSE N'RUNNING_WITHOUT_EXACT_WIFI_TIMESTAMP'
    END AS [coverage_reason]
FROM #robot_scope AS scope
INNER JOIN job_by_robot AS job_summary
    ON job_summary.[master_robot_id] = scope.[master_robot_id]
LEFT JOIN exact_running_match_by_robot AS exact_match
    ON exact_match.[master_robot_id] = scope.[master_robot_id]
ORDER BY
    CASE
        WHEN COALESCE(exact_match.[exact_running_wifi_match_count], 0) > 0 THEN 0
        ELSE 1
    END,
    scope.[robot_code];

SELECT
    @analysis_anchor AS [analysis_anchor_time],
    @analysis_hours AS [analysis_window_hours],
    @source_sample_limit AS [source_sample_limit];

DROP TABLE #wifi_source;
DROP TABLE #job_source;
DROP TABLE #robot_scope;

