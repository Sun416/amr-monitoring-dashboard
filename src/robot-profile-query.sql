SET NOCOUNT ON;

DECLARE
    @battery_anchor DATETIME2(0),
    @status_anchor DATETIME2(0),
    @wifi_anchor DATETIME2(3),
    @job_anchor DATE,
    @robot_key NVARCHAR(100) = CONVERT(NVARCHAR(100), @robot_id),
    @wifi_window_hours INT = CASE
        WHEN @hours < 1 THEN 1
        WHEN @hours > 24 THEN 24
        ELSE @hours
    END;

SELECT @battery_anchor = MAX(b.[stat_hour])
FROM [DWS].[dws_robot_battery_hourly] AS b;

SELECT @status_anchor = MAX(s.[stat_hour])
FROM [DWS].[dws_robot_status_hourly] AS s;

/*
    The current DWS WiFi rollup contains NULL RSSI aggregates. Match the fleet
    dashboard by anchoring a bounded, indexed read against the source history.
*/
SELECT @wifi_anchor = MAX(latest_wifi.[pc_timestamp])
FROM [dbo].[MA_AMR] AS m
OUTER APPLY (
    SELECT TOP (1)
        h.[pc_timestamp]
    FROM [dbo].[robot_wifi_history] AS h WITH (INDEX([IX_wifi_performance]))
    WHERE h.[amr_id] = m.[id]
    ORDER BY h.[pc_timestamp] DESC
) AS latest_wifi
WHERE UPPER(LTRIM(RTRIM(COALESCE(m.[is_active], N'')))) = N'Y';

SELECT @job_anchor = MAX(j.[stat_date])
FROM [DWS].[dws_robot_job_daily] AS j;

/* Result 1: selected active robot identity. */
SELECT
    m.[id] AS [master_robot_id],
    m.[name] AS [robot_code],
    m.[serial_number] AS [robot_serial_number],
    m.[status] AS [master_status],
    m.[factory_id],
    m.[max_battery],
    m.[min_battery],
    m.[updated_at] AS [master_updated_at]
FROM [dbo].[MA_AMR] AS m
WHERE m.[id] = @robot_id
  AND UPPER(LTRIM(RTRIM(COALESCE(m.[is_active], N'')))) = N'Y';

/* Result 2: selected robot battery history at hourly grain. */
SELECT
    b.[stat_hour],
    b.[sample_count],
    b.[avg_battery_soc],
    b.[min_battery_soc],
    b.[max_battery_soc],
    b.[avg_battery_voltage],
    b.[avg_battery_current],
    b.[avg_battery_power],
    b.[charging_sample_count],
    b.[first_sample_time],
    b.[last_sample_time]
FROM [DWS].[dws_robot_battery_hourly] AS b
WHERE @battery_anchor IS NOT NULL
  AND b.[robot_code] = @robot_key
  AND b.[stat_hour] >= DATEADD(HOUR, 1 - @hours, @battery_anchor)
  AND b.[stat_hour] <= @battery_anchor
ORDER BY b.[stat_hour];

/* Result 3: selected robot status history at hourly grain. */
SELECT
    s.[stat_hour],
    s.[sample_count],
    s.[online_sample_count],
    s.[error_sample_count],
    s.[avg_speed_mps],
    s.[max_speed_mps],
    s.[first_status_time],
    s.[last_status_time]
FROM [DWS].[dws_robot_status_hourly] AS s
WHERE @status_anchor IS NOT NULL
  AND s.[robot_code] = @robot_key
  AND s.[stat_hour] >= DATEADD(HOUR, 1 - @hours, @status_anchor)
  AND s.[stat_hour] <= @status_anchor
ORDER BY s.[stat_hour];

/* Result 4: selected robot WiFi history at hourly grain, capped at 24 hours. */
SELECT
    DATEADD(HOUR, DATEDIFF(HOUR, 0, h.[pc_timestamp]), 0) AS [stat_hour],
    COUNT_BIG(*) AS [sample_count],
    CAST(AVG(CASE WHEN h.[wifi_signal_level] < 0 THEN CONVERT(DECIMAL(18, 4), h.[wifi_signal_level]) END) AS DECIMAL(18, 2)) AS [avg_rssi],
    MIN(CASE WHEN h.[wifi_signal_level] < 0 THEN h.[wifi_signal_level] END) AS [min_rssi],
    MAX(CASE WHEN h.[wifi_signal_level] < 0 THEN h.[wifi_signal_level] END) AS [max_rssi],
    SUM(CASE WHEN h.[wifi_signal_level] = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [zero_signal_sample_count],
    CAST(
        100.0 * SUM(CASE WHEN h.[wifi_signal_level] = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        / NULLIF(COUNT_BIG(*), 0)
        AS DECIMAL(9, 2)
    ) AS [zero_signal_rate],
    SUM(CASE
        WHEN h.[wifi_signal_level] = 0 OR h.[wifi_signal_level] <= -70
            THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [weak_signal_sample_count],
    MIN(h.[pc_timestamp]) AS [first_sample_time],
    MAX(h.[pc_timestamp]) AS [last_sample_time]
FROM [dbo].[robot_wifi_history] AS h WITH (INDEX([IX_wifi_performance]))
WHERE @wifi_anchor IS NOT NULL
  AND h.[amr_id] = @robot_id
  AND h.[pc_timestamp] > DATEADD(HOUR, -@wifi_window_hours, @wifi_anchor)
  AND h.[pc_timestamp] <= @wifi_anchor
GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, h.[pc_timestamp]), 0)
ORDER BY [stat_hour];

/* Result 5: selected robot daily task totals. */
SELECT
    j.[stat_date],
    SUM(j.[job_count]) AS [job_count],
    SUM(j.[distinct_job_count]) AS [distinct_job_count],
    SUM(j.[completed_status_count]) AS [completed_status_count],
    SUM(j.[failed_status_count]) AS [failed_status_count],
    MIN(j.[first_job_start_time]) AS [first_job_start_time],
    MAX(j.[last_job_start_time]) AS [last_job_start_time]
FROM [DWS].[dws_robot_job_daily] AS j
WHERE @job_anchor IS NOT NULL
  AND j.[robot_code] = @robot_key
  AND j.[stat_date] >= DATEADD(DAY, 1 - @days, @job_anchor)
  AND j.[stat_date] <= @job_anchor
GROUP BY j.[stat_date]
ORDER BY j.[stat_date];

/* Result 6: selected robot task breakdown for exact lookup and export. */
SELECT
    CASE
        WHEN j.[job_type_code] = N'__ALL__' THEN N'ALL TASK OUTCOMES'
        ELSE COALESCE(NULLIF(LTRIM(RTRIM(j.[job_type_code])), N''), N'NOT_REPORTED')
    END AS [job_type_code],
    CASE
        WHEN j.[robot_mode_id] = N'__ALL__' THEN N'ALL MODES'
        ELSE COALESCE(NULLIF(LTRIM(RTRIM(j.[robot_mode_id])), N''), N'NOT_REPORTED')
    END AS [robot_mode_id],
    CASE
        WHEN j.[job_type_code] = N'__ALL__' AND j.[robot_mode_id] = N'__ALL__' THEN N'Queue outcomes across all task types'
        ELSE COALESCE(NULLIF(LTRIM(RTRIM(j.[robot_mode_detail])), N''), N'Not reported')
    END AS [robot_mode_detail],
    SUM(j.[job_count]) AS [job_count],
    SUM(j.[distinct_job_count]) AS [distinct_job_count],
    SUM(j.[completed_status_count]) AS [completed_status_count],
    SUM(j.[failed_status_count]) AS [failed_status_count],
    MAX(j.[last_job_start_time]) AS [latest_job_time]
FROM [DWS].[dws_robot_job_daily] AS j
WHERE @job_anchor IS NOT NULL
  AND j.[robot_code] = @robot_key
  AND j.[stat_date] >= DATEADD(DAY, 1 - @days, @job_anchor)
  AND j.[stat_date] <= @job_anchor
GROUP BY
    CASE
        WHEN j.[job_type_code] = N'__ALL__' THEN N'ALL TASK OUTCOMES'
        ELSE COALESCE(NULLIF(LTRIM(RTRIM(j.[job_type_code])), N''), N'NOT_REPORTED')
    END,
    CASE
        WHEN j.[robot_mode_id] = N'__ALL__' THEN N'ALL MODES'
        ELSE COALESCE(NULLIF(LTRIM(RTRIM(j.[robot_mode_id])), N''), N'NOT_REPORTED')
    END,
    CASE
        WHEN j.[job_type_code] = N'__ALL__' AND j.[robot_mode_id] = N'__ALL__' THEN N'Queue outcomes across all task types'
        ELSE COALESCE(NULLIF(LTRIM(RTRIM(j.[robot_mode_detail])), N''), N'Not reported')
    END
ORDER BY SUM(j.[job_count]) DESC, [job_type_code], [robot_mode_id];

/* Result 7: global anchors explain the selected time-window boundaries. */
SELECT
    @battery_anchor AS [battery_anchor_time],
    @status_anchor AS [status_anchor_time],
    @wifi_anchor AS [wifi_anchor_time],
    @wifi_window_hours AS [wifi_window_hours],
    @job_anchor AS [job_anchor_date],
    SYSDATETIME() AS [database_current_time];
