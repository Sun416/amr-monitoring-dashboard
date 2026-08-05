USE [IOT2020];
SET NOCOUNT ON;

/*
Read-only explanation of robot coverage for the 24-hour, 7-day and 30-day
Running-task WiFi analysis.
*/

DECLARE
    @job_anchor DATETIME2(3),
    @wifi_anchor DATETIME2(3),
    @analysis_anchor DATETIME2(3),
    @analysis_end DATETIME2(3);

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
SET @analysis_end = DATEADD(MILLISECOND, 1, @analysis_anchor);

CREATE TABLE #analysis_window (
    [window_hours] INT NOT NULL PRIMARY KEY,
    [window_label] NVARCHAR(20) NOT NULL
);

INSERT INTO #analysis_window ([window_hours], [window_label])
VALUES
    (24, N'24小时'),
    (168, N'7天'),
    (720, N'30天');

SELECT
    master_robot.[id] AS [master_robot_id],
    master_robot.[name] AS [robot_code]
INTO #robot_scope
FROM [dbo].[MA_AMR] AS master_robot
WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y';

CREATE UNIQUE CLUSTERED INDEX [IX_robot_scope]
    ON #robot_scope ([master_robot_id]);

;WITH ranked_running_job AS (
    SELECT
        analysis_window.[window_hours],
        analysis_window.[window_label],
        job_source.[ods_row_id],
        job_source.[amr_id],
        job_source.[pc_timestamp],
        job_source.[poi_target],
        ROW_NUMBER() OVER (
            PARTITION BY
                analysis_window.[window_hours],
                job_source.[amr_id],
                job_source.[pc_timestamp]
            ORDER BY job_source.[ods_row_id] DESC
        ) AS [row_rank]
    FROM #analysis_window AS analysis_window
    INNER JOIN [ODS].[robot_job_history] AS job_source
        ON job_source.[job_status] = N'Running'
       AND job_source.[pc_timestamp] >= DATEADD(
            HOUR,
            -analysis_window.[window_hours],
            @analysis_anchor
       )
       AND job_source.[pc_timestamp] < @analysis_end
    INNER JOIN #robot_scope AS robot_scope
        ON robot_scope.[master_robot_id] = job_source.[amr_id]
),
running_by_robot AS (
    SELECT
        ranked_job.[window_hours],
        ranked_job.[amr_id],
        COUNT_BIG(*) AS [running_timestamp_count],
        SUM(CASE
            WHEN NULLIF(LTRIM(RTRIM(ranked_job.[poi_target])), N'') IS NOT NULL
                THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END) AS [running_with_target_count]
    FROM ranked_running_job AS ranked_job
    WHERE ranked_job.[row_rank] = 1
    GROUP BY
        ranked_job.[window_hours],
        ranked_job.[amr_id]
),
matched_by_robot AS (
    SELECT
        ranked_job.[window_hours],
        ranked_job.[amr_id],
        COUNT_BIG(*) AS [exact_running_wifi_match_count]
    FROM ranked_running_job AS ranked_job
    CROSS APPLY (
        SELECT TOP (1)
            wifi_source.[ods_row_id]
        FROM [ODS].[robot_wifi_history] AS wifi_source
        WHERE wifi_source.[amr_id] = ranked_job.[amr_id]
          AND wifi_source.[pc_timestamp] = ranked_job.[pc_timestamp]
        ORDER BY wifi_source.[ods_row_id] DESC
    ) AS wifi_match
    WHERE ranked_job.[row_rank] = 1
      AND NULLIF(LTRIM(RTRIM(ranked_job.[poi_target])), N'') IS NOT NULL
    GROUP BY
        ranked_job.[window_hours],
        ranked_job.[amr_id]
)
SELECT
    analysis_window.[window_hours],
    analysis_window.[window_label],
    robot_scope.[robot_code],
    COALESCE(running_summary.[running_timestamp_count], 0) AS [running_timestamp_count],
    COALESCE(running_summary.[running_with_target_count], 0) AS [running_with_target_count],
    COALESCE(match_summary.[exact_running_wifi_match_count], 0) AS [exact_running_wifi_match_count],
    CASE
        WHEN COALESCE(match_summary.[exact_running_wifi_match_count], 0) > 0
            THEN N'INCLUDED'
        WHEN COALESCE(running_summary.[running_timestamp_count], 0) = 0
            THEN N'NO_RUNNING_STATUS_IN_WINDOW'
        WHEN COALESCE(running_summary.[running_with_target_count], 0) = 0
            THEN N'RUNNING_WITHOUT_TARGET_POI'
        ELSE N'RUNNING_WITHOUT_EXACT_WIFI_TIMESTAMP'
    END AS [coverage_reason]
FROM #analysis_window AS analysis_window
CROSS JOIN #robot_scope AS robot_scope
LEFT JOIN running_by_robot AS running_summary
    ON running_summary.[window_hours] = analysis_window.[window_hours]
   AND running_summary.[amr_id] = robot_scope.[master_robot_id]
LEFT JOIN matched_by_robot AS match_summary
    ON match_summary.[window_hours] = analysis_window.[window_hours]
   AND match_summary.[amr_id] = robot_scope.[master_robot_id]
ORDER BY
    analysis_window.[window_hours],
    CASE
        WHEN COALESCE(match_summary.[exact_running_wifi_match_count], 0) > 0 THEN 0
        ELSE 1
    END,
    robot_scope.[robot_code];

DROP TABLE #robot_scope;
DROP TABLE #analysis_window;

