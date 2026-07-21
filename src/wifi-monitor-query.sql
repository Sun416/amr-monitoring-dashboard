SET NOCOUNT ON;

/*
    Operational WiFi bridge for the manual-refresh Web dashboard.

    DWS.dws_robot_wifi_hourly currently contains NULL RSSI values, so the Web
    reads a bounded window from the indexed source table instead of scanning ODS.
    The window is capped at 24 hours to keep each manual refresh predictable.

    wifi_signal_level = 0 is reported as a zero-signal sample.
    wifi_signal_level <= -70 is reported as a weak-signal sample.
*/

DECLARE
    @wifi_window_hours INT = CASE
        WHEN @hours < 1 THEN 1
        WHEN @hours > 24 THEN 24
        ELSE @hours
    END,
    @wifi_anchor_time DATETIME2(3);

SELECT
    m.[id] AS [master_robot_id],
    m.[name] AS [robot_code],
    latest_wifi.[pc_timestamp] AS [latest_wifi_time],
    latest_wifi.[wifi_signal_level] AS [current_rssi],
    latest_wifi.[wifi_quality] AS [current_wifi_quality],
    latest_wifi.[wifi_ap_connected] AS [current_wifi_ap]
INTO #wifi_anchor
FROM [dbo].[MA_AMR] AS m
OUTER APPLY (
    SELECT TOP (1)
        h.[pc_timestamp],
        h.[wifi_signal_level],
        h.[wifi_quality],
        h.[wifi_ap_connected]
    FROM [dbo].[robot_wifi_history] AS h WITH (INDEX([IX_wifi_performance]))
    WHERE h.[amr_id] = m.[id]
    ORDER BY h.[pc_timestamp] DESC
) AS latest_wifi
WHERE UPPER(LTRIM(RTRIM(COALESCE(m.[is_active], N'')))) = N'Y';

SELECT
    @wifi_anchor_time = MAX(a.[latest_wifi_time])
FROM #wifi_anchor AS a;

SELECT
    a.[master_robot_id],
    a.[robot_code],
    h.[pc_timestamp],
    h.[wifi_signal_level],
    h.[wifi_quality],
    h.[wifi_ap_connected]
INTO #wifi_recent
FROM #wifi_anchor AS a
INNER JOIN [dbo].[robot_wifi_history] AS h WITH (INDEX([IX_wifi_performance]))
    ON h.[amr_id] = a.[master_robot_id]
   AND h.[pc_timestamp] > DATEADD(HOUR, -@wifi_window_hours, @wifi_anchor_time)
   AND h.[pc_timestamp] <= @wifi_anchor_time;

CREATE CLUSTERED INDEX [IX_wifi_recent_robot_time]
    ON #wifi_recent ([master_robot_id], [pc_timestamp]);

/* Result 1: fleet WiFi summary. */
SELECT
    @wifi_window_hours AS [wifi_window_hours],
    @wifi_anchor_time AS [wifi_anchor_time],
    (SELECT COUNT_BIG(*) FROM #wifi_anchor) AS [active_robot_count],
    (SELECT COUNT_BIG(*) FROM #wifi_anchor AS a WHERE a.[latest_wifi_time] IS NOT NULL) AS [wifi_known_robot_count],
    (
        SELECT COUNT_BIG(*)
        FROM #wifi_anchor AS a
        WHERE a.[latest_wifi_time] >= DATEADD(MINUTE, -5, @wifi_anchor_time)
    ) AS [wifi_current_robot_count],
    (SELECT COUNT_BIG(*) FROM #wifi_recent) AS [wifi_sample_count],
    (
        SELECT COUNT_BIG(*)
        FROM #wifi_recent AS r
        WHERE r.[wifi_signal_level] = 0
    ) AS [zero_signal_sample_count],
    CAST(
        100.0 * (
            SELECT COUNT_BIG(*)
            FROM #wifi_recent AS r
            WHERE r.[wifi_signal_level] = 0
        ) / NULLIF((SELECT COUNT_BIG(*) FROM #wifi_recent), 0)
        AS DECIMAL(9, 2)
    ) AS [zero_signal_rate],
    (
        SELECT COUNT_BIG(*)
        FROM #wifi_recent AS r
        WHERE r.[wifi_signal_level] = 0
          AND (
                 NULLIF(LTRIM(RTRIM(r.[wifi_ap_connected])), N'') IS NULL
              OR LTRIM(RTRIM(r.[wifi_ap_connected])) = N'-'
          )
    ) AS [unattributed_zero_signal_count],
    CAST((
        SELECT AVG(CONVERT(DECIMAL(18, 4), r.[wifi_signal_level]))
        FROM #wifi_recent AS r
        WHERE r.[wifi_signal_level] < 0
    ) AS DECIMAL(18, 2)) AS [avg_valid_rssi],
    CAST((
        SELECT AVG(CONVERT(DECIMAL(18, 4), a.[current_rssi]))
        FROM #wifi_anchor AS a
        WHERE a.[current_rssi] < 0
          AND a.[latest_wifi_time] >= DATEADD(MINUTE, -5, @wifi_anchor_time)
    ) AS DECIMAL(18, 2)) AS [avg_current_rssi];

/* Result 2: one WiFi row per active robot. */
;WITH robot_stats AS (
    SELECT
        r.[master_robot_id],
        COUNT_BIG(*) AS [wifi_sample_count],
        SUM(CASE WHEN r.[wifi_signal_level] = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [zero_signal_sample_count],
        SUM(CASE
            WHEN r.[wifi_signal_level] = 0 OR r.[wifi_signal_level] <= -70
                THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END) AS [weak_signal_sample_count],
        AVG(CASE WHEN r.[wifi_signal_level] < 0 THEN CONVERT(DECIMAL(18, 4), r.[wifi_signal_level]) END) AS [avg_valid_rssi],
        MIN(CASE WHEN r.[wifi_signal_level] < 0 THEN r.[wifi_signal_level] END) AS [min_valid_rssi],
        MAX(CASE WHEN r.[wifi_signal_level] < 0 THEN r.[wifi_signal_level] END) AS [max_valid_rssi]
    FROM #wifi_recent AS r
    GROUP BY r.[master_robot_id]
)
SELECT
    a.[master_robot_id],
    a.[robot_code],
    a.[latest_wifi_time],
    CONVERT(BIT, CASE
        WHEN a.[latest_wifi_time] >= DATEADD(MINUTE, -5, @wifi_anchor_time) THEN 1
        ELSE 0
    END) AS [wifi_is_current],
    a.[current_rssi],
    a.[current_wifi_quality],
    NULLIF(LTRIM(RTRIM(a.[current_wifi_ap])), N'') AS [current_wifi_ap],
    ISNULL(s.[wifi_sample_count], 0) AS [wifi_sample_count],
    ISNULL(s.[zero_signal_sample_count], 0) AS [zero_signal_sample_count],
    CAST(
        100.0 * ISNULL(s.[zero_signal_sample_count], 0)
        / NULLIF(s.[wifi_sample_count], 0)
        AS DECIMAL(9, 2)
    ) AS [zero_signal_rate],
    ISNULL(s.[weak_signal_sample_count], 0) AS [weak_signal_sample_count],
    CAST(
        100.0 * ISNULL(s.[weak_signal_sample_count], 0)
        / NULLIF(s.[wifi_sample_count], 0)
        AS DECIMAL(9, 2)
    ) AS [weak_signal_rate],
    CAST(s.[avg_valid_rssi] AS DECIMAL(18, 2)) AS [avg_valid_rssi],
    s.[min_valid_rssi],
    s.[max_valid_rssi],
    dominant_ap.[wifi_ap] AS [dominant_wifi_ap],
    zero_ap.[wifi_ap] AS [highest_zero_signal_ap],
    zero_ap.[zero_signal_count] AS [highest_ap_zero_signal_count]
FROM #wifi_anchor AS a
LEFT JOIN robot_stats AS s
    ON s.[master_robot_id] = a.[master_robot_id]
OUTER APPLY (
    SELECT TOP (1)
        UPPER(REPLACE(LTRIM(RTRIM(r.[wifi_ap_connected])), N'-', N':')) AS [wifi_ap]
    FROM #wifi_recent AS r
    WHERE r.[master_robot_id] = a.[master_robot_id]
      AND NULLIF(LTRIM(RTRIM(r.[wifi_ap_connected])), N'') IS NOT NULL
      AND LTRIM(RTRIM(r.[wifi_ap_connected])) <> N'-'
    GROUP BY UPPER(REPLACE(LTRIM(RTRIM(r.[wifi_ap_connected])), N'-', N':'))
    ORDER BY COUNT_BIG(*) DESC
) AS dominant_ap
OUTER APPLY (
    SELECT TOP (1)
        UPPER(REPLACE(LTRIM(RTRIM(r.[wifi_ap_connected])), N'-', N':')) AS [wifi_ap],
        COUNT_BIG(*) AS [zero_signal_count]
    FROM #wifi_recent AS r
    WHERE r.[master_robot_id] = a.[master_robot_id]
      AND r.[wifi_signal_level] = 0
      AND NULLIF(LTRIM(RTRIM(r.[wifi_ap_connected])), N'') IS NOT NULL
      AND LTRIM(RTRIM(r.[wifi_ap_connected])) <> N'-'
    GROUP BY UPPER(REPLACE(LTRIM(RTRIM(r.[wifi_ap_connected])), N'-', N':'))
    ORDER BY COUNT_BIG(*) DESC
) AS zero_ap
ORDER BY
    CASE WHEN a.[latest_wifi_time] >= DATEADD(MINUTE, -5, @wifi_anchor_time) THEN 0 ELSE 1 END,
    a.[robot_code];

/* Result 3: access points with enough recent samples to compare. */
;WITH ap_stats AS (
    SELECT
        UPPER(REPLACE(LTRIM(RTRIM(r.[wifi_ap_connected])), N'-', N':')) AS [wifi_ap],
        COUNT_BIG(*) AS [wifi_sample_count],
        SUM(CASE WHEN r.[wifi_signal_level] = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [zero_signal_sample_count],
        SUM(CASE
            WHEN r.[wifi_signal_level] = 0 OR r.[wifi_signal_level] <= -70
                THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END) AS [weak_signal_sample_count],
        COUNT(DISTINCT r.[master_robot_id]) AS [affected_robot_count],
        AVG(CASE WHEN r.[wifi_signal_level] < 0 THEN CONVERT(DECIMAL(18, 4), r.[wifi_signal_level]) END) AS [avg_valid_rssi],
        MAX(r.[pc_timestamp]) AS [last_sample_time]
    FROM #wifi_recent AS r
    WHERE NULLIF(LTRIM(RTRIM(r.[wifi_ap_connected])), N'') IS NOT NULL
      AND LTRIM(RTRIM(r.[wifi_ap_connected])) <> N'-'
    GROUP BY UPPER(REPLACE(LTRIM(RTRIM(r.[wifi_ap_connected])), N'-', N':'))
    HAVING COUNT_BIG(*) >= 100
)
SELECT TOP (20)
    a.[wifi_ap],
    a.[wifi_sample_count],
    a.[zero_signal_sample_count],
    CAST(100.0 * a.[zero_signal_sample_count] / NULLIF(a.[wifi_sample_count], 0) AS DECIMAL(9, 2)) AS [zero_signal_rate],
    a.[weak_signal_sample_count],
    CAST(100.0 * a.[weak_signal_sample_count] / NULLIF(a.[wifi_sample_count], 0) AS DECIMAL(9, 2)) AS [weak_signal_rate],
    a.[affected_robot_count],
    CAST(a.[avg_valid_rssi] AS DECIMAL(18, 2)) AS [avg_valid_rssi],
    a.[last_sample_time],
    CASE
        WHEN 100.0 * a.[zero_signal_sample_count] / NULLIF(a.[wifi_sample_count], 0) >= 20 THEN N'CRITICAL'
        WHEN 100.0 * a.[zero_signal_sample_count] / NULLIF(a.[wifi_sample_count], 0) >= 5
          OR a.[avg_valid_rssi] <= -70 THEN N'WARNING'
        ELSE N'STABLE'
    END AS [risk_level]
FROM ap_stats AS a
ORDER BY
    CASE
        WHEN 100.0 * a.[zero_signal_sample_count] / NULLIF(a.[wifi_sample_count], 0) >= 20 THEN 1
        WHEN 100.0 * a.[zero_signal_sample_count] / NULLIF(a.[wifi_sample_count], 0) >= 5
          OR a.[avg_valid_rssi] <= -70 THEN 2
        ELSE 3
    END,
    100.0 * a.[zero_signal_sample_count] / NULLIF(a.[wifi_sample_count], 0) DESC,
    a.[zero_signal_sample_count] DESC;

/* Result 4: recent fleet WiFi trend from valid source RSSI. */
SELECT
    DATEADD(HOUR, DATEDIFF(HOUR, 0, r.[pc_timestamp]), 0) AS [stat_hour],
    COUNT_BIG(*) AS [sample_count],
    CAST(AVG(CASE WHEN r.[wifi_signal_level] < 0 THEN CONVERT(DECIMAL(18, 4), r.[wifi_signal_level]) END) AS DECIMAL(18, 2)) AS [avg_rssi],
    MIN(CASE WHEN r.[wifi_signal_level] < 0 THEN r.[wifi_signal_level] END) AS [min_rssi],
    MAX(CASE WHEN r.[wifi_signal_level] < 0 THEN r.[wifi_signal_level] END) AS [max_rssi],
    SUM(CASE WHEN r.[wifi_signal_level] = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [zero_signal_sample_count],
    CAST(
        100.0 * SUM(CASE WHEN r.[wifi_signal_level] = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        / NULLIF(COUNT_BIG(*), 0)
        AS DECIMAL(9, 2)
    ) AS [zero_signal_rate],
    SUM(CASE
        WHEN r.[wifi_signal_level] = 0 OR r.[wifi_signal_level] <= -70
            THEN CONVERT(BIGINT, 1)
        ELSE CONVERT(BIGINT, 0)
    END) AS [weak_signal_sample_count]
FROM #wifi_recent AS r
GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, r.[pc_timestamp]), 0)
ORDER BY [stat_hour];
