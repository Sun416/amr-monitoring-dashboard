SET NOCOUNT ON;

DECLARE
    @database_now DATETIME2(3) = SYSDATETIME(),
    @battery_anchor DATETIME2(0),
    @status_anchor DATETIME2(0),
    @wifi_anchor DATETIME2(0),
    @job_anchor DATE,
    @queue_anchor DATE;

SELECT
    master_robot.[id] AS [master_robot_id],
    master_robot.[name] AS [robot_code],
    CASE
        WHEN UPPER(LTRIM(RTRIM(master_robot.[name]))) LIKE N'AMR%' THEN N'AMR'
        WHEN UPPER(LTRIM(RTRIM(master_robot.[name]))) LIKE N'AMB%' THEN N'AMB'
        ELSE N'OTHER'
    END AS [robot_type]
INTO #robot_scope
FROM [dbo].[MA_AMR] AS master_robot
WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y'
  AND (
      @robot_type = N'ALL'
      OR UPPER(LTRIM(RTRIM(master_robot.[name]))) LIKE @robot_type + N'%'
  );

CREATE UNIQUE CLUSTERED INDEX [IX_robot_scope_master_id]
    ON #robot_scope ([master_robot_id]);

SELECT scope_reference.[robot_reference]
INTO #robot_scope_reference
FROM (
    SELECT scope.[robot_code] AS [robot_reference]
    FROM #robot_scope AS scope
    UNION
    SELECT CONVERT(NVARCHAR(100), scope.[master_robot_id]) AS [robot_reference]
    FROM #robot_scope AS scope
) AS scope_reference;

CREATE UNIQUE CLUSTERED INDEX [IX_robot_scope_reference]
    ON #robot_scope_reference ([robot_reference]);

SELECT @battery_anchor = MAX(b.[stat_hour])
FROM [DWS].[dws_robot_battery_hourly] AS b
WHERE EXISTS (
    SELECT 1
    FROM #robot_scope_reference AS scope_reference
    WHERE scope_reference.[robot_reference] = b.[robot_code]
);

SELECT @status_anchor = MAX(s.[stat_hour])
FROM [DWS].[dws_robot_status_hourly] AS s
WHERE EXISTS (
    SELECT 1
    FROM #robot_scope_reference AS scope_reference
    WHERE scope_reference.[robot_reference] = s.[robot_code]
);

SELECT @wifi_anchor = MAX(w.[stat_hour])
FROM [DWS].[dws_robot_wifi_hourly] AS w
WHERE EXISTS (
    SELECT 1
    FROM #robot_scope_reference AS scope_reference
    WHERE scope_reference.[robot_reference] = w.[robot_code]
);

SELECT @job_anchor = MAX(j.[stat_date])
FROM [DWS].[dws_robot_job_daily] AS j
WHERE EXISTS (
    SELECT 1
    FROM #robot_scope_reference AS scope_reference
    WHERE scope_reference.[robot_reference] = j.[robot_code]
);

SELECT @queue_anchor = MAX(q.[stat_date])
FROM [DWS].[dws_amr_queue_daily] AS q
WHERE EXISTS (
    SELECT 1
    FROM #robot_scope_reference AS scope_reference
    WHERE scope_reference.[robot_reference] = q.[robot_code]
);

/*
    Fleet scope:
    - dbo.MA_AMR is the authoritative robot master.
    - Only is_active = 'Y' is counted.
    - Current monitoring evidence comes only from non-snapshot DWS aggregates.
    - Last-known values are suppressed unless their event time, DWS load time
      and event-to-load lag all pass @freshness_timeout_minutes.
    - The DWS hourly tables do not contain current position, current task ID,
      current operating-mode name or current business-status name. Those fields
      remain NULL instead of being backfilled from the operational snapshot.
*/
SELECT
    master_robot.[id] AS [master_robot_id],
    master_robot.[name] AS [robot_code],
    master_robot.[name] AS [robot_name],
    CASE
        WHEN UPPER(LTRIM(RTRIM(master_robot.[name]))) LIKE N'AMR%' THEN N'AMR'
        WHEN UPPER(LTRIM(RTRIM(master_robot.[name]))) LIKE N'AMB%' THEN N'AMB'
        ELSE N'OTHER'
    END AS [robot_type],
    master_robot.[serial_number] AS [robot_serial_number],
    master_robot.[status] AS [master_status],
    master_robot.[factory_id],
    master_robot.[max_battery],
    master_robot.[min_battery],
    master_robot.[updated_at] AS [master_updated_at],
    COALESCE(status_latest.[robot_code], battery_latest.[robot_code], wifi_latest.[robot_code]) AS [source_robot_code],
    COALESCE(status_latest.[robot_id], battery_latest.[robot_id], wifi_latest.[robot_id]) AS [source_robot_id],
    CONVERT(BIT, CASE WHEN status_latest.[status_hourly_id] IS NULL THEN 0 ELSE 1 END) AS [has_dws_status],
    CONVERT(BIT, CASE WHEN battery_latest.[battery_hourly_id] IS NULL THEN 0 ELSE 1 END) AS [has_dws_battery],
    CONVERT(BIT, CASE WHEN wifi_latest.[wifi_hourly_id] IS NULL THEN 0 ELSE 1 END) AS [has_dws_wifi],
    status_gate.[freshness_status] AS [data_freshness_status],
    status_gate.[freshness_status] AS [status_freshness_status],
    battery_gate.[freshness_status] AS [battery_freshness_status],
    wifi_gate.[freshness_status] AS [wifi_freshness_status],
    CAST(NULL AS NVARCHAR(100)) AS [current_status],
    CAST(NULL AS NVARCHAR(100)) AS [current_mode_id],
    CAST(NULL AS NVARCHAR(200)) AS [current_mode],
    CAST(NULL AS NVARCHAR(100)) AS [source_current_mode],
    CASE WHEN status_gate.[freshness_status] = N'CURRENT' THEN N'ONLINE' ELSE N'TIMEOUT' END AS [online_status],
    CAST(NULL AS NVARCHAR(100)) AS [job_id],
    CAST(NULL AS NVARCHAR(100)) AS [subjob_id],
    CAST(NULL AS NVARCHAR(100)) AS [job_status],
    CONVERT(BIT, 0) AS [current_task_supported],
    CONVERT(BIT, 0) AS [is_active_job],
    CAST(NULL AS NVARCHAR(100)) AS [map_code],
    CAST(NULL AS NVARCHAR(100)) AS [station_code],
    CAST(NULL AS NVARCHAR(100)) AS [target_station_code],
    CAST(NULL AS DECIMAL(18,6)) AS [position_x],
    CAST(NULL AS DECIMAL(18,6)) AS [position_y],
    CAST(NULL AS DECIMAL(18,6)) AS [position_theta],
    CASE
        WHEN status_gate.[freshness_status] = N'CURRENT' THEN status_latest.[avg_speed_mps]
    END AS [speed_mps],
    CASE
        WHEN battery_gate.[freshness_status] = N'CURRENT' THEN battery_latest.[avg_battery_soc]
    END AS [battery_soc],
    CASE
        WHEN battery_gate.[freshness_status] = N'CURRENT' THEN battery_latest.[avg_battery_voltage]
    END AS [battery_voltage],
    CASE
        WHEN battery_gate.[freshness_status] = N'CURRENT' THEN battery_latest.[avg_battery_current]
    END AS [battery_current],
    CAST(NULL AS NVARCHAR(100)) AS [charging_status],
    CAST(NULL AS NVARCHAR(100)) AS [error_code],
    CAST(NULL AS NVARCHAR(1000)) AS [error_message],
    event_anchor.[latest_event_time] AS [source_event_time],
    status_latest.[last_status_time] AS [status_event_time],
    battery_latest.[last_sample_time] AS [battery_event_time],
    job_latest.[last_job_start_time] AS [job_event_time],
    @database_now AS [source_anchor_time],
    CAST(NULL AS DATETIME2(3)) AS [source_snapshot_time],
    load_anchor.[latest_load_time] AS [dws_load_time],
    status_latest.[dws_load_time] AS [status_dws_load_time],
    battery_latest.[dws_load_time] AS [battery_dws_load_time],
    wifi_latest.[dws_load_time] AS [wifi_dws_load_time],
    status_gate.[data_age_minutes] AS [status_data_age_minutes],
    status_gate.[refresh_age_minutes] AS [status_refresh_age_minutes],
    status_gate.[pipeline_lag_minutes] AS [status_pipeline_lag_minutes],
    battery_gate.[data_age_minutes] AS [battery_data_age_minutes],
    battery_gate.[refresh_age_minutes] AS [battery_refresh_age_minutes],
    battery_gate.[pipeline_lag_minutes] AS [battery_pipeline_lag_minutes],
    wifi_gate.[data_age_minutes] AS [wifi_data_age_minutes],
    wifi_gate.[refresh_age_minutes] AS [wifi_refresh_age_minutes],
    wifi_gate.[pipeline_lag_minutes] AS [wifi_pipeline_lag_minutes],
    status_latest.[sample_count] AS [status_hour_sample_count],
    status_latest.[online_sample_count] AS [status_hour_online_sample_count],
    status_latest.[error_sample_count] AS [status_hour_error_sample_count],
    status_latest.[max_speed_mps] AS [status_hour_max_speed_mps],
    battery_latest.[sample_count] AS [battery_hour_sample_count],
    battery_latest.[min_battery_soc] AS [battery_hour_min_soc],
    battery_latest.[max_battery_soc] AS [battery_hour_max_soc],
    battery_latest.[charging_sample_count] AS [battery_hour_charging_sample_count],
    wifi_latest.[sample_count] AS [wifi_hour_sample_count],
    wifi_latest.[avg_rssi] AS [wifi_hour_avg_rssi],
    wifi_latest.[min_rssi] AS [wifi_hour_min_rssi],
    wifi_latest.[max_rssi] AS [wifi_hour_max_rssi],
    wifi_latest.[weak_signal_sample_count] AS [wifi_hour_weak_signal_sample_count]
INTO #robot_fleet
FROM [dbo].[MA_AMR] AS master_robot
INNER JOIN #robot_scope AS selected_scope
    ON selected_scope.[master_robot_id] = master_robot.[id]
OUTER APPLY (
    SELECT TOP (1)
        status_hour.[status_hourly_id],
        status_hour.[robot_code],
        status_hour.[robot_id],
        status_hour.[sample_count],
        status_hour.[online_sample_count],
        status_hour.[error_sample_count],
        status_hour.[avg_speed_mps],
        status_hour.[max_speed_mps],
        status_hour.[last_status_time],
        status_hour.[dws_load_time]
    FROM [DWS].[dws_robot_status_hourly] AS status_hour
    WHERE status_hour.[robot_code] IN (
        master_robot.[name],
        CONVERT(NVARCHAR(100), master_robot.[id])
    )
    ORDER BY
        status_hour.[last_status_time] DESC,
        status_hour.[dws_load_time] DESC,
        status_hour.[status_hourly_id] DESC
) AS status_latest
OUTER APPLY (
    SELECT TOP (1)
        battery_hour.[battery_hourly_id],
        battery_hour.[robot_code],
        battery_hour.[robot_id],
        battery_hour.[sample_count],
        battery_hour.[avg_battery_soc],
        battery_hour.[min_battery_soc],
        battery_hour.[max_battery_soc],
        battery_hour.[avg_battery_voltage],
        battery_hour.[avg_battery_current],
        battery_hour.[charging_sample_count],
        battery_hour.[last_sample_time],
        battery_hour.[dws_load_time]
    FROM [DWS].[dws_robot_battery_hourly] AS battery_hour
    WHERE battery_hour.[robot_code] IN (
        master_robot.[name],
        CONVERT(NVARCHAR(100), master_robot.[id])
    )
    ORDER BY
        battery_hour.[last_sample_time] DESC,
        battery_hour.[dws_load_time] DESC,
        battery_hour.[battery_hourly_id] DESC
) AS battery_latest
OUTER APPLY (
    SELECT TOP (1)
        wifi_hour.[wifi_hourly_id],
        wifi_hour.[robot_code],
        wifi_hour.[robot_id],
        wifi_hour.[sample_count],
        wifi_hour.[avg_rssi],
        wifi_hour.[min_rssi],
        wifi_hour.[max_rssi],
        wifi_hour.[weak_signal_sample_count],
        wifi_hour.[last_sample_time],
        wifi_hour.[dws_load_time]
    FROM [DWS].[dws_robot_wifi_hourly] AS wifi_hour
    WHERE wifi_hour.[robot_code] IN (
        master_robot.[name],
        CONVERT(NVARCHAR(100), master_robot.[id])
    )
    ORDER BY
        wifi_hour.[last_sample_time] DESC,
        wifi_hour.[dws_load_time] DESC,
        wifi_hour.[wifi_hourly_id] DESC
) AS wifi_latest
OUTER APPLY (
    SELECT TOP (1)
        job_daily.[last_job_start_time]
    FROM [DWS].[dws_robot_job_daily] AS job_daily
    WHERE job_daily.[robot_code] IN (
        master_robot.[name],
        CONVERT(NVARCHAR(100), master_robot.[id])
    )
    ORDER BY
        job_daily.[last_job_start_time] DESC,
        job_daily.[dws_load_time] DESC,
        job_daily.[job_daily_id] DESC
) AS job_latest
CROSS APPLY (
    SELECT
        DATEDIFF(MINUTE, status_latest.[last_status_time], @database_now) AS [data_age_minutes],
        DATEDIFF(MINUTE, status_latest.[dws_load_time], @database_now) AS [refresh_age_minutes],
        DATEDIFF(MINUTE, status_latest.[last_status_time], status_latest.[dws_load_time]) AS [pipeline_lag_minutes],
        CASE
            WHEN status_latest.[last_status_time] IS NULL OR status_latest.[dws_load_time] IS NULL THEN N'MISSING'
            WHEN DATEDIFF(MINUTE, status_latest.[dws_load_time], @database_now) > @freshness_timeout_minutes
                THEN N'DWS_REFRESH_TIMEOUT'
            WHEN DATEDIFF(MINUTE, status_latest.[last_status_time], status_latest.[dws_load_time]) > @freshness_timeout_minutes
                THEN N'DWS_SOURCE_LAG'
            WHEN DATEDIFF(MINUTE, status_latest.[last_status_time], @database_now) > @freshness_timeout_minutes
                THEN N'SOURCE_TIMEOUT'
            ELSE N'CURRENT'
        END AS [freshness_status]
) AS status_gate
CROSS APPLY (
    SELECT
        DATEDIFF(MINUTE, battery_latest.[last_sample_time], @database_now) AS [data_age_minutes],
        DATEDIFF(MINUTE, battery_latest.[dws_load_time], @database_now) AS [refresh_age_minutes],
        DATEDIFF(MINUTE, battery_latest.[last_sample_time], battery_latest.[dws_load_time]) AS [pipeline_lag_minutes],
        CASE
            WHEN battery_latest.[last_sample_time] IS NULL OR battery_latest.[dws_load_time] IS NULL THEN N'MISSING'
            WHEN DATEDIFF(MINUTE, battery_latest.[dws_load_time], @database_now) > @freshness_timeout_minutes
                THEN N'DWS_REFRESH_TIMEOUT'
            WHEN DATEDIFF(MINUTE, battery_latest.[last_sample_time], battery_latest.[dws_load_time]) > @freshness_timeout_minutes
                THEN N'DWS_SOURCE_LAG'
            WHEN DATEDIFF(MINUTE, battery_latest.[last_sample_time], @database_now) > @freshness_timeout_minutes
                THEN N'SOURCE_TIMEOUT'
            ELSE N'CURRENT'
        END AS [freshness_status]
) AS battery_gate
CROSS APPLY (
    SELECT
        DATEDIFF(MINUTE, wifi_latest.[last_sample_time], @database_now) AS [data_age_minutes],
        DATEDIFF(MINUTE, wifi_latest.[dws_load_time], @database_now) AS [refresh_age_minutes],
        DATEDIFF(MINUTE, wifi_latest.[last_sample_time], wifi_latest.[dws_load_time]) AS [pipeline_lag_minutes],
        CASE
            WHEN wifi_latest.[last_sample_time] IS NULL OR wifi_latest.[dws_load_time] IS NULL THEN N'MISSING'
            WHEN DATEDIFF(MINUTE, wifi_latest.[dws_load_time], @database_now) > @freshness_timeout_minutes
                THEN N'DWS_REFRESH_TIMEOUT'
            WHEN DATEDIFF(MINUTE, wifi_latest.[last_sample_time], wifi_latest.[dws_load_time]) > @freshness_timeout_minutes
                THEN N'DWS_SOURCE_LAG'
            WHEN DATEDIFF(MINUTE, wifi_latest.[last_sample_time], @database_now) > @freshness_timeout_minutes
                THEN N'SOURCE_TIMEOUT'
            ELSE N'CURRENT'
        END AS [freshness_status]
) AS wifi_gate
OUTER APPLY (
    SELECT MAX(event_time.[value]) AS [latest_event_time]
    FROM (VALUES
        (status_latest.[last_status_time]),
        (battery_latest.[last_sample_time]),
        (wifi_latest.[last_sample_time]),
        (job_latest.[last_job_start_time])
    ) AS event_time ([value])
) AS event_anchor
OUTER APPLY (
    SELECT MAX(load_time.[value]) AS [latest_load_time]
    FROM (VALUES
        (status_latest.[dws_load_time]),
        (battery_latest.[dws_load_time]),
        (wifi_latest.[dws_load_time])
    ) AS load_time ([value])
) AS load_anchor;

/* Result 1: active fleet metrics and source freshness. */
SELECT
    COUNT_BIG(1) AS [total_robot_count],
    (
        SELECT COUNT_BIG(1)
        FROM [dbo].[MA_AMR] AS commissioned_robot
        WHERE commissioned_robot.[factory_id] IS NOT NULL
          AND (
              @robot_type = N'ALL'
              OR UPPER(LTRIM(RTRIM(commissioned_robot.[name]))) LIKE @robot_type + N'%'
          )
          AND (
              UPPER(LTRIM(RTRIM(COALESCE(commissioned_robot.[is_active], N'')))) = N'Y'
              OR UPPER(LTRIM(RTRIM(COALESCE(commissioned_robot.[serial_number], N''))))
                    NOT IN (N'', N'UNDEFINED', N'NULL')
          )
    ) AS [commissioned_robot_count],
    SUM(CASE
            WHEN fleet.[has_dws_status] = 1 OR fleet.[has_dws_battery] = 1 OR fleet.[has_dws_wifi] = 1
                THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END) AS [dws_known_robot_count],
    SUM(CASE
            WHEN fleet.[data_freshness_status] = N'CURRENT' THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END) AS [current_data_robot_count],
    SUM(CASE
            WHEN fleet.[data_freshness_status] IN (N'DWS_REFRESH_TIMEOUT', N'DWS_SOURCE_LAG', N'SOURCE_TIMEOUT')
                THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END) AS [timed_out_robot_count],
    SUM(CASE
            WHEN fleet.[data_freshness_status] = N'MISSING' THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END) AS [missing_data_robot_count],
    SUM(CASE WHEN fleet.[online_status] = N'ONLINE' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [online_robot_count],
    SUM(CASE WHEN fleet.[online_status] = N'TIMEOUT' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [offline_robot_count],
    CAST(NULL AS BIGINT) AS [active_job_robot_count],
    CAST(NULL AS BIGINT) AS [alarm_robot_count],
    SUM(CASE WHEN fleet.[battery_soc] BETWEEN 0 AND 20 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [low_battery_robot_count],
    CAST(AVG(CASE
                WHEN fleet.[battery_soc] BETWEEN 0 AND 100
                    THEN CONVERT(DECIMAL(18,6), fleet.[battery_soc])
            END) AS DECIMAL(18,2)) AS [avg_battery_soc],
    MAX(fleet.[source_event_time]) AS [latest_source_event_time],
    MAX(fleet.[source_event_time]) AS [source_anchor_time],
    DATEDIFF(MINUTE, MAX(fleet.[source_event_time]), @database_now) AS [source_anchor_lag_minutes],
    CAST(NULL AS DATETIME2(3)) AS [latest_source_snapshot_time],
    MAX(fleet.[dws_load_time]) AS [latest_dws_load_time],
    DATEDIFF(MINUTE, MAX(fleet.[dws_load_time]), @database_now) AS [dws_refresh_lag_minutes],
    @freshness_timeout_minutes AS [freshness_timeout_minutes],
    N'DWS_NON_SNAPSHOT' AS [current_data_source],
    MAX(fleet.[master_updated_at]) AS [latest_master_update_time],
    @battery_anchor AS [battery_trend_anchor_time],
    @status_anchor AS [status_trend_anchor_time],
    @job_anchor AS [job_trend_anchor_date],
    @queue_anchor AS [queue_trend_anchor_date],
    @database_now AS [database_current_time]
FROM #robot_fleet AS fleet;

/* Result 2: active master list with freshness-gated non-snapshot DWS evidence. */
SELECT TOP (500)
    fleet.[master_robot_id],
    fleet.[robot_code],
    fleet.[robot_name],
    fleet.[robot_type],
    fleet.[robot_serial_number],
    fleet.[master_status],
    fleet.[factory_id],
    fleet.[max_battery],
    fleet.[min_battery],
    fleet.[master_updated_at],
    fleet.[source_robot_code],
    fleet.[source_robot_id],
    fleet.[has_dws_status],
    fleet.[has_dws_battery],
    fleet.[has_dws_wifi],
    fleet.[data_freshness_status],
    fleet.[status_freshness_status],
    fleet.[battery_freshness_status],
    fleet.[wifi_freshness_status],
    fleet.[current_status],
    fleet.[current_mode_id],
    fleet.[current_mode],
    fleet.[source_current_mode],
    fleet.[online_status],
    fleet.[job_id],
    fleet.[subjob_id],
    fleet.[job_status],
    fleet.[current_task_supported],
    fleet.[is_active_job],
    fleet.[map_code],
    fleet.[station_code],
    fleet.[target_station_code],
    fleet.[position_x],
    fleet.[position_y],
    fleet.[position_theta],
    fleet.[speed_mps],
    fleet.[battery_soc],
    fleet.[battery_voltage],
    fleet.[battery_current],
    fleet.[charging_status],
    fleet.[error_code],
    fleet.[error_message],
    fleet.[source_event_time],
    fleet.[status_event_time],
    fleet.[battery_event_time],
    fleet.[job_event_time],
    fleet.[source_anchor_time],
    fleet.[source_snapshot_time],
    fleet.[dws_load_time],
    fleet.[status_dws_load_time],
    fleet.[battery_dws_load_time],
    fleet.[wifi_dws_load_time],
    fleet.[status_data_age_minutes],
    fleet.[status_refresh_age_minutes],
    fleet.[status_pipeline_lag_minutes],
    fleet.[battery_data_age_minutes],
    fleet.[battery_refresh_age_minutes],
    fleet.[battery_pipeline_lag_minutes],
    fleet.[wifi_data_age_minutes],
    fleet.[wifi_refresh_age_minutes],
    fleet.[wifi_pipeline_lag_minutes],
    fleet.[status_hour_sample_count],
    fleet.[status_hour_online_sample_count],
    fleet.[status_hour_error_sample_count],
    fleet.[status_hour_max_speed_mps],
    fleet.[battery_hour_sample_count],
    fleet.[battery_hour_min_soc],
    fleet.[battery_hour_max_soc],
    fleet.[battery_hour_charging_sample_count],
    fleet.[wifi_hour_sample_count],
    fleet.[wifi_hour_avg_rssi],
    fleet.[wifi_hour_min_rssi],
    fleet.[wifi_hour_max_rssi],
    fleet.[wifi_hour_weak_signal_sample_count]
FROM #robot_fleet AS fleet
ORDER BY fleet.[robot_name], fleet.[master_robot_id];

/* Result 3: current DWS freshness status; no last-known operating state is reused. */
SELECT
    CASE
        WHEN fleet.[data_freshness_status] = N'CURRENT' THEN N'DWS Data Current'
        WHEN fleet.[data_freshness_status] = N'DWS_REFRESH_TIMEOUT' THEN N'DWS Refresh Timeout'
        WHEN fleet.[data_freshness_status] = N'DWS_SOURCE_LAG' THEN N'DWS Source Lag'
        WHEN fleet.[data_freshness_status] = N'SOURCE_TIMEOUT' THEN N'Source Data Timeout'
        ELSE N'DWS Data Missing'
    END AS [status_name],
    COUNT_BIG(1) AS [robot_count]
FROM #robot_fleet AS fleet
GROUP BY
    CASE
        WHEN fleet.[data_freshness_status] = N'CURRENT' THEN N'DWS Data Current'
        WHEN fleet.[data_freshness_status] = N'DWS_REFRESH_TIMEOUT' THEN N'DWS Refresh Timeout'
        WHEN fleet.[data_freshness_status] = N'DWS_SOURCE_LAG' THEN N'DWS Source Lag'
        WHEN fleet.[data_freshness_status] = N'SOURCE_TIMEOUT' THEN N'Source Data Timeout'
        ELSE N'DWS Data Missing'
    END
ORDER BY [robot_count] DESC, [status_name];

/* Result 4: operating mode is not present in the non-snapshot DWS hourly tables. */
SELECT
    N'Not provided by DWS hourly data' AS [mode_name],
    COUNT_BIG(1) AS [robot_count]
FROM #robot_fleet AS fleet
ORDER BY [robot_count] DESC, [mode_name];

/* Result 5: battery trend anchored to the latest available DWS hour. */
SELECT
    battery.[stat_hour],
    SUM(battery.[sample_count]) AS [sample_count],
    CAST(
        SUM(CASE
                WHEN battery.[avg_battery_soc] IS NOT NULL
                    THEN battery.[avg_battery_soc] * CONVERT(DECIMAL(28,6), battery.[sample_count])
                ELSE CONVERT(DECIMAL(28,6), 0)
            END)
        / NULLIF(SUM(CASE WHEN battery.[avg_battery_soc] IS NOT NULL THEN battery.[sample_count] ELSE 0 END), 0)
        AS DECIMAL(18,2)
    ) AS [avg_battery_soc],
    MIN(battery.[min_battery_soc]) AS [min_battery_soc],
    MAX(battery.[max_battery_soc]) AS [max_battery_soc],
    SUM(battery.[charging_sample_count]) AS [charging_sample_count]
FROM [DWS].[dws_robot_battery_hourly] AS battery
WHERE @battery_anchor IS NOT NULL
  AND battery.[stat_hour] >= DATEADD(HOUR, 1 - @hours, @battery_anchor)
  AND battery.[stat_hour] <= @battery_anchor
  AND (
      EXISTS (
          SELECT 1
          FROM #robot_scope_reference AS scope_reference
          WHERE scope_reference.[robot_reference] = battery.[robot_code]
      )
  )
GROUP BY battery.[stat_hour]
ORDER BY battery.[stat_hour];

/* Result 6: status trend anchored to the latest available DWS hour. */
SELECT
    status_hour.[stat_hour],
    SUM(status_hour.[sample_count]) AS [sample_count],
    SUM(status_hour.[online_sample_count]) AS [online_sample_count],
    SUM(status_hour.[error_sample_count]) AS [error_sample_count],
    CAST(
        SUM(CASE
                WHEN status_hour.[avg_speed_mps] IS NOT NULL
                    THEN status_hour.[avg_speed_mps] * CONVERT(DECIMAL(28,6), status_hour.[sample_count])
                ELSE CONVERT(DECIMAL(28,6), 0)
            END)
        / NULLIF(SUM(CASE WHEN status_hour.[avg_speed_mps] IS NOT NULL THEN status_hour.[sample_count] ELSE 0 END), 0)
        AS DECIMAL(18,3)
    ) AS [avg_speed_mps],
    MAX(status_hour.[max_speed_mps]) AS [max_speed_mps]
FROM [DWS].[dws_robot_status_hourly] AS status_hour
WHERE @status_anchor IS NOT NULL
  AND status_hour.[stat_hour] >= DATEADD(HOUR, 1 - @hours, @status_anchor)
  AND status_hour.[stat_hour] <= @status_anchor
  AND (
      EXISTS (
          SELECT 1
          FROM #robot_scope_reference AS scope_reference
          WHERE scope_reference.[robot_reference] = status_hour.[robot_code]
      )
  )
GROUP BY status_hour.[stat_hour]
ORDER BY status_hour.[stat_hour];

/* Result 7: DWS WiFi trend retained for compatibility with downstream consumers. */
SELECT
    wifi.[stat_hour],
    SUM(wifi.[sample_count]) AS [sample_count],
    CAST(
        SUM(CASE
                WHEN wifi.[avg_rssi] IS NOT NULL
                    THEN wifi.[avg_rssi] * CONVERT(DECIMAL(28,6), wifi.[sample_count])
                ELSE CONVERT(DECIMAL(28,6), 0)
            END)
        / NULLIF(SUM(CASE WHEN wifi.[avg_rssi] IS NOT NULL THEN wifi.[sample_count] ELSE 0 END), 0)
        AS DECIMAL(18,2)
    ) AS [avg_rssi],
    MIN(wifi.[min_rssi]) AS [min_rssi],
    MAX(wifi.[max_rssi]) AS [max_rssi],
    SUM(wifi.[weak_signal_sample_count]) AS [weak_signal_sample_count]
FROM [DWS].[dws_robot_wifi_hourly] AS wifi
WHERE @wifi_anchor IS NOT NULL
  AND wifi.[stat_hour] >= DATEADD(HOUR, 1 - @hours, @wifi_anchor)
  AND wifi.[stat_hour] <= @wifi_anchor
  AND (
      EXISTS (
          SELECT 1
          FROM #robot_scope_reference AS scope_reference
          WHERE scope_reference.[robot_reference] = wifi.[robot_code]
      )
  )
GROUP BY wifi.[stat_hour]
ORDER BY wifi.[stat_hour];

/* Result 8: daily job metrics anchored to the latest available DWS date. */
SELECT
    job_daily.[stat_date],
    SUM(job_daily.[job_count]) AS [job_count],
    SUM(job_daily.[distinct_job_count]) AS [distinct_job_count],
    SUM(job_daily.[completed_status_count]) AS [completed_status_count],
    SUM(job_daily.[failed_status_count]) AS [failed_status_count]
FROM [DWS].[dws_robot_job_daily] AS job_daily
WHERE @job_anchor IS NOT NULL
  AND job_daily.[stat_date] >= DATEADD(DAY, 1 - @days, @job_anchor)
  AND job_daily.[stat_date] <= @job_anchor
  AND (
      EXISTS (
          SELECT 1
          FROM #robot_scope_reference AS scope_reference
          WHERE scope_reference.[robot_reference] = job_daily.[robot_code]
      )
  )
GROUP BY job_daily.[stat_date]
ORDER BY job_daily.[stat_date];

/* Result 9: daily AMR queue metrics anchored to the latest available DWS date. */
SELECT
    queue_daily.[stat_date],
    SUM(queue_daily.[queue_count]) AS [queue_count],
    SUM(queue_daily.[distinct_queue_count]) AS [distinct_queue_count],
    SUM(queue_daily.[completed_status_count]) AS [completed_status_count],
    SUM(queue_daily.[failed_status_count]) AS [failed_status_count],
    CAST(AVG(queue_daily.[avg_duration_seconds]) AS DECIMAL(18,2)) AS [avg_duration_seconds]
FROM [DWS].[dws_amr_queue_daily] AS queue_daily
WHERE @queue_anchor IS NOT NULL
  AND queue_daily.[stat_date] >= DATEADD(DAY, 1 - @days, @queue_anchor)
  AND queue_daily.[stat_date] <= @queue_anchor
  AND (
      EXISTS (
          SELECT 1
          FROM #robot_scope_reference AS scope_reference
          WHERE scope_reference.[robot_reference] = queue_daily.[robot_code]
      )
  )
GROUP BY queue_daily.[stat_date]
ORDER BY queue_daily.[stat_date];

/*
    Result 10: unsuccessful queue outcomes by robot.
    The source records terminal outcome status but has no root-cause/message column.
    One row per queue is classified with the same success/failure logic used by the DWS rollup.
*/
;WITH queue_item AS (
    SELECT
        CONVERT(DATE, queue_fact.[event_time]) AS [stat_date],
        COALESCE(
            NULLIF(LTRIM(RTRIM(queue_fact.[robot_code])), N''),
            NULLIF(LTRIM(RTRIM(queue_fact.[robot_id])), N''),
            N'UNKNOWN'
        ) AS [robot_code],
        NULLIF(LTRIM(RTRIM(queue_fact.[queue_id])), N'') AS [queue_id],
        MAX(CASE
                WHEN UPPER(LTRIM(RTRIM(COALESCE(queue_fact.[queue_status], N'')))) IN (
                    N'COMPLETED', N'COMPLEATED', N'COMPLETE', N'SUCCESS', N'SUCCEEDED',
                    N'DONE', N'FINISHED', N'完成', N'成功'
                ) THEN 1
                ELSE 0
            END) AS [is_completed],
        MIN(CASE
                WHEN UPPER(LTRIM(RTRIM(COALESCE(queue_fact.[queue_status], N'')))) IN (N'ABORTED') THEN 1
                WHEN UPPER(LTRIM(RTRIM(COALESCE(queue_fact.[queue_status], N'')))) IN (N'ERROR', N'异常') THEN 2
                WHEN UPPER(LTRIM(RTRIM(COALESCE(queue_fact.[queue_status], N'')))) IN (N'FAILED', N'FAIL', N'失败') THEN 3
                WHEN UPPER(LTRIM(RTRIM(COALESCE(queue_fact.[queue_status], N'')))) IN (N'CANCELLED', N'CANCELED', N'取消') THEN 4
                ELSE 99
            END) AS [failure_rank],
        MAX(queue_fact.[event_time]) AS [latest_failure_time]
    FROM [DWD].[fact_amr_queue] AS queue_fact
    WHERE @queue_anchor IS NOT NULL
      AND queue_fact.[event_time] >= CONVERT(DATETIME2(3), DATEADD(DAY, 1 - @days, @queue_anchor))
      AND queue_fact.[event_time] <  CONVERT(DATETIME2(3), DATEADD(DAY, 1, @queue_anchor))
      AND NULLIF(LTRIM(RTRIM(queue_fact.[queue_id])), N'') IS NOT NULL
      AND EXISTS (
          SELECT 1
          FROM #robot_scope_reference AS scope_reference
          WHERE scope_reference.[robot_reference] = queue_fact.[robot_code]
      )
    GROUP BY
        CONVERT(DATE, queue_fact.[event_time]),
        COALESCE(
            NULLIF(LTRIM(RTRIM(queue_fact.[robot_code])), N''),
            NULLIF(LTRIM(RTRIM(queue_fact.[robot_id])), N''),
            N'UNKNOWN'
        ),
        NULLIF(LTRIM(RTRIM(queue_fact.[queue_id])), N'')
)
SELECT
    CASE queue_item.[failure_rank]
        WHEN 1 THEN N'ABORTED'
        WHEN 2 THEN N'ERROR'
        WHEN 3 THEN N'FAILED'
        WHEN 4 THEN N'CANCELLED'
        ELSE N'UNKNOWN'
    END AS [failure_outcome],
    COALESCE(master_robot.[name], queue_item.[robot_code]) AS [robot_code],
    queue_item.[robot_code] AS [source_robot_reference],
    COUNT_BIG(1) AS [failure_count],
    MAX(queue_item.[latest_failure_time]) AS [latest_failure_time]
FROM queue_item
LEFT JOIN [dbo].[MA_AMR] AS master_robot
    ON master_robot.[id] = TRY_CONVERT(INT, queue_item.[robot_code])
WHERE queue_item.[is_completed] = 0
  AND queue_item.[failure_rank] < 99
GROUP BY
    CASE queue_item.[failure_rank]
        WHEN 1 THEN N'ABORTED'
        WHEN 2 THEN N'ERROR'
        WHEN 3 THEN N'FAILED'
        WHEN 4 THEN N'CANCELLED'
        ELSE N'UNKNOWN'
    END,
    COALESCE(master_robot.[name], queue_item.[robot_code]),
    queue_item.[robot_code]
ORDER BY [failure_count] DESC, [failure_outcome], [robot_code];

/* Result 11: latest DWS batch health. */
SELECT TOP (10)
    batch.[batch_id],
    batch.[batch_start_time],
    batch.[batch_end_time],
    batch.[batch_status],
    batch.[error_message]
FROM [DWS].[etl_batch] AS batch
ORDER BY batch.[batch_id] DESC;
