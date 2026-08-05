SET NOCOUNT ON;

/*
    Non-snapshot DWS WiFi evidence for the Web dashboard.

    The DWS hourly table does not retain access-point identity, scan count,
    WiFi quality or raw sentinel RSSI values. Those unsupported current fields
    are returned as NULL. A WiFi aggregate is current only when its sample time,
    DWS load time and event-to-load lag all pass @freshness_timeout_minutes.
*/

DECLARE
    @database_now DATETIME2(3) = SYSDATETIME(),
    @wifi_window_hours INT = CASE
        WHEN @hours < 1 THEN 1
        WHEN @hours > 720 THEN 720
        ELSE @hours
    END,
    @wifi_anchor_time DATETIME2(3);

SELECT
    master_robot.[id] AS [master_robot_id],
    master_robot.[name] AS [robot_code],
    latest_wifi.[last_sample_time] AS [latest_wifi_time],
    latest_wifi.[dws_load_time] AS [wifi_dws_load_time],
    DATEDIFF(MINUTE, latest_wifi.[last_sample_time], @database_now) AS [wifi_data_age_minutes],
    DATEDIFF(MINUTE, latest_wifi.[dws_load_time], @database_now) AS [wifi_refresh_age_minutes],
    DATEDIFF(MINUTE, latest_wifi.[last_sample_time], latest_wifi.[dws_load_time]) AS [wifi_pipeline_lag_minutes],
    CASE
        WHEN latest_wifi.[last_sample_time] IS NULL OR latest_wifi.[dws_load_time] IS NULL THEN N'MISSING'
        WHEN DATEDIFF(MINUTE, latest_wifi.[dws_load_time], @database_now) > @freshness_timeout_minutes
            THEN N'DWS_REFRESH_TIMEOUT'
        WHEN DATEDIFF(MINUTE, latest_wifi.[last_sample_time], latest_wifi.[dws_load_time]) > @freshness_timeout_minutes
            THEN N'DWS_SOURCE_LAG'
        WHEN DATEDIFF(MINUTE, latest_wifi.[last_sample_time], @database_now) > @freshness_timeout_minutes
            THEN N'SOURCE_TIMEOUT'
        ELSE N'CURRENT'
    END AS [wifi_freshness_status],
    latest_wifi.[sample_count],
    latest_wifi.[avg_rssi],
    latest_wifi.[min_rssi],
    latest_wifi.[max_rssi],
    latest_wifi.[weak_signal_sample_count]
INTO #wifi_latest
FROM [dbo].[MA_AMR] AS master_robot
OUTER APPLY (
    SELECT TOP (1)
        wifi_hour.[sample_count],
        wifi_hour.[avg_rssi],
        wifi_hour.[min_rssi],
        wifi_hour.[max_rssi],
        wifi_hour.[weak_signal_sample_count],
        wifi_hour.[last_sample_time],
        wifi_hour.[dws_load_time],
        wifi_hour.[wifi_hourly_id]
    FROM [DWS].[dws_robot_wifi_hourly] AS wifi_hour
    WHERE wifi_hour.[robot_code] IN (
        master_robot.[name],
        CONVERT(NVARCHAR(100), master_robot.[id])
    )
    ORDER BY
        wifi_hour.[last_sample_time] DESC,
        wifi_hour.[dws_load_time] DESC,
        wifi_hour.[wifi_hourly_id] DESC
) AS latest_wifi
WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y'
  AND (
      @robot_type = N'ALL'
      OR UPPER(LTRIM(RTRIM(master_robot.[name]))) LIKE @robot_type + N'%'
  );

SELECT @wifi_anchor_time = MAX(wifi_row.[latest_wifi_time])
FROM #wifi_latest AS wifi_row;

/* Result 1: fleet DWS WiFi freshness and supported aggregate values. */
SELECT
    @wifi_window_hours AS [wifi_window_hours],
    @wifi_anchor_time AS [wifi_anchor_time],
    COUNT_BIG(1) AS [active_robot_count],
    SUM(CASE WHEN wifi_row.[latest_wifi_time] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS [wifi_known_robot_count],
    SUM(CASE WHEN wifi_row.[wifi_freshness_status] = N'CURRENT' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS [wifi_current_robot_count],
    SUM(CASE WHEN wifi_row.[wifi_freshness_status] <> N'CURRENT' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS [wifi_timed_out_robot_count],
    SUM(CASE WHEN wifi_row.[wifi_freshness_status] = N'CURRENT' THEN wifi_row.[sample_count] ELSE 0 END)
        AS [wifi_sample_count],
    CAST(NULL AS BIGINT) AS [zero_signal_sample_count],
    CAST(NULL AS DECIMAL(9,2)) AS [zero_signal_rate],
    CAST(NULL AS BIGINT) AS [unusable_rssi_sample_count],
    CAST(AVG(CASE
        WHEN wifi_row.[wifi_freshness_status] = N'CURRENT' THEN wifi_row.[avg_rssi]
    END) AS DECIMAL(18,2)) AS [avg_valid_rssi],
    CAST(AVG(CASE
        WHEN wifi_row.[wifi_freshness_status] = N'CURRENT' THEN wifi_row.[avg_rssi]
    END) AS DECIMAL(18,2)) AS [avg_current_rssi],
    MAX(wifi_row.[wifi_dws_load_time]) AS [latest_wifi_dws_load_time],
    @database_now AS [wifi_database_current_time]
FROM #wifi_latest AS wifi_row;

/* Result 2: one freshness-gated DWS WiFi row per active robot. */
SELECT
    wifi_row.[master_robot_id],
    wifi_row.[robot_code],
    wifi_row.[latest_wifi_time],
    CONVERT(BIT, CASE WHEN wifi_row.[wifi_freshness_status] = N'CURRENT' THEN 1 ELSE 0 END) AS [wifi_is_current],
    wifi_row.[wifi_freshness_status],
    wifi_row.[wifi_dws_load_time],
    wifi_row.[wifi_data_age_minutes],
    wifi_row.[wifi_refresh_age_minutes],
    wifi_row.[wifi_pipeline_lag_minutes],
    CASE WHEN wifi_row.[wifi_freshness_status] = N'CURRENT' THEN wifi_row.[avg_rssi] END AS [current_rssi],
    CAST(NULL AS DECIMAL(18,2)) AS [raw_current_rssi],
    CAST(NULL AS DECIMAL(18,2)) AS [current_wifi_quality],
    CAST(NULL AS NVARCHAR(200)) AS [current_wifi_ap],
    CAST(NULL AS INT) AS [current_wifi_count],
    CAST(NULL AS DECIMAL(18,2)) AS [current_scan_average_signal],
    CASE WHEN wifi_row.[wifi_freshness_status] = N'CURRENT' THEN wifi_row.[sample_count] ELSE 0 END AS [wifi_sample_count],
    CAST(NULL AS BIGINT) AS [zero_signal_sample_count],
    CAST(NULL AS DECIMAL(9,2)) AS [zero_signal_rate],
    CAST(NULL AS BIGINT) AS [unusable_rssi_sample_count],
    CASE
        WHEN wifi_row.[wifi_freshness_status] = N'CURRENT' THEN wifi_row.[weak_signal_sample_count]
        ELSE 0
    END AS [weak_signal_sample_count],
    CAST(
        100.0 * CASE
            WHEN wifi_row.[wifi_freshness_status] = N'CURRENT' THEN wifi_row.[weak_signal_sample_count]
            ELSE 0
        END / NULLIF(CASE
            WHEN wifi_row.[wifi_freshness_status] = N'CURRENT' THEN wifi_row.[sample_count]
            ELSE 0
        END, 0)
        AS DECIMAL(9,2)
    ) AS [weak_signal_rate],
    CASE WHEN wifi_row.[wifi_freshness_status] = N'CURRENT' THEN wifi_row.[avg_rssi] END AS [avg_valid_rssi],
    CASE WHEN wifi_row.[wifi_freshness_status] = N'CURRENT' THEN wifi_row.[min_rssi] END AS [min_valid_rssi],
    CASE WHEN wifi_row.[wifi_freshness_status] = N'CURRENT' THEN wifi_row.[max_rssi] END AS [max_valid_rssi],
    CAST(NULL AS NVARCHAR(200)) AS [dominant_wifi_ap],
    CAST(NULL AS NVARCHAR(200)) AS [highest_zero_signal_ap],
    CAST(NULL AS BIGINT) AS [highest_ap_zero_signal_count]
FROM #wifi_latest AS wifi_row
ORDER BY
    CASE WHEN wifi_row.[wifi_freshness_status] = N'CURRENT' THEN 0 ELSE 1 END,
    wifi_row.[robot_code];

/* Result 3: access-point analysis is not measurable from the DWS hourly schema. */
SELECT
    CAST(NULL AS NVARCHAR(200)) AS [wifi_ap],
    CAST(NULL AS BIGINT) AS [wifi_sample_count],
    CAST(NULL AS BIGINT) AS [zero_signal_sample_count],
    CAST(NULL AS DECIMAL(9,2)) AS [zero_signal_rate],
    CAST(NULL AS BIGINT) AS [weak_signal_sample_count],
    CAST(NULL AS DECIMAL(9,2)) AS [weak_signal_rate],
    CAST(NULL AS BIGINT) AS [affected_robot_count],
    CAST(NULL AS DECIMAL(18,2)) AS [avg_valid_rssi],
    CAST(NULL AS DATETIME2(3)) AS [last_sample_time],
    CAST(NULL AS NVARCHAR(30)) AS [risk_level]
WHERE 1 = 0;

/* Result 4: DWS WiFi hourly trend. */
SELECT
    wifi_hour.[stat_hour],
    SUM(wifi_hour.[sample_count]) AS [sample_count],
    CAST(
        SUM(CASE
                WHEN wifi_hour.[avg_rssi] IS NOT NULL
                    THEN wifi_hour.[avg_rssi] * CONVERT(DECIMAL(28,6), wifi_hour.[sample_count])
                ELSE CONVERT(DECIMAL(28,6), 0)
            END)
        / NULLIF(SUM(CASE WHEN wifi_hour.[avg_rssi] IS NOT NULL THEN wifi_hour.[sample_count] ELSE 0 END), 0)
        AS DECIMAL(18,2)
    ) AS [avg_valid_rssi],
    MIN(wifi_hour.[min_rssi]) AS [min_valid_rssi],
    MAX(wifi_hour.[max_rssi]) AS [max_valid_rssi],
    SUM(wifi_hour.[weak_signal_sample_count]) AS [weak_signal_sample_count],
    MAX(wifi_hour.[last_sample_time]) AS [last_sample_time]
FROM [DWS].[dws_robot_wifi_hourly] AS wifi_hour
WHERE @wifi_anchor_time IS NOT NULL
  AND wifi_hour.[stat_hour] > DATEADD(HOUR, -@wifi_window_hours, @wifi_anchor_time)
  AND wifi_hour.[stat_hour] <= @wifi_anchor_time
  AND EXISTS (
      SELECT 1
      FROM #wifi_latest AS selected_robot
      WHERE selected_robot.[robot_code] = wifi_hour.[robot_code]
         OR CONVERT(NVARCHAR(100), selected_robot.[master_robot_id]) = wifi_hour.[robot_code]
  )
GROUP BY wifi_hour.[stat_hour]
ORDER BY wifi_hour.[stat_hour];
