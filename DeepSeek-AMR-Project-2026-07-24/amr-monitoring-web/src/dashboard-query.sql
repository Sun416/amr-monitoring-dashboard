SET NOCOUNT ON;

DECLARE
    @database_now DATETIME2(3) = SYSDATETIME(),
    @battery_anchor DATETIME2(0),
    @status_anchor DATETIME2(0),
    @wifi_anchor DATETIME2(0),
    @job_anchor DATE,
    @queue_anchor DATE;

SELECT @battery_anchor = MAX(b.[stat_hour])
FROM [DWS].[dws_robot_battery_hourly] AS b;

SELECT @status_anchor = MAX(s.[stat_hour])
FROM [DWS].[dws_robot_status_hourly] AS s;

SELECT @wifi_anchor = MAX(w.[stat_hour])
FROM [DWS].[dws_robot_wifi_hourly] AS w;

SELECT @job_anchor = MAX(j.[stat_date])
FROM [DWS].[dws_robot_job_daily] AS j;

SELECT @queue_anchor = MAX(q.[stat_date])
FROM [DWS].[dws_amr_queue_daily] AS q;

/*
    Fleet scope:
    - dbo.MA_AMR is the authoritative robot master.
    - Only is_active = 'Y' is counted.
    - The operational DWS snapshot is joined by the exact MA_AMR name.
      Serial-number and numeric-id guessing is intentionally not used.
*/
SELECT
    master_robot.[id] AS [master_robot_id],
    master_robot.[name] AS [robot_code],
    master_robot.[name] AS [robot_name],
    master_robot.[serial_number] AS [robot_serial_number],
    master_robot.[status] AS [master_status],
    master_robot.[factory_id],
    master_robot.[max_battery],
    master_robot.[min_battery],
    master_robot.[updated_at] AS [master_updated_at],
    snapshot_row.[robot_code] AS [source_robot_code],
    snapshot_row.[robot_id] AS [source_robot_id],
    CONVERT(BIT, CASE WHEN snapshot_row.[current_snapshot_id] IS NULL THEN 0 ELSE 1 END) AS [has_current_snapshot],
    snapshot_row.[current_status],
    mode_reference.[Mode_ID] AS [current_mode_id],
    COALESCE(mode_reference.[Mode_Detail], snapshot_row.[current_mode]) AS [current_mode],
    snapshot_row.[current_mode] AS [source_current_mode],
    snapshot_row.[online_status],
    snapshot_row.[job_id],
    snapshot_row.[subjob_id],
    snapshot_row.[job_status],
    CONVERT(BIT, CASE
        WHEN UPPER(LTRIM(RTRIM(COALESCE(snapshot_row.[job_status], N''))))
                 IN (N'WORKING', N'RUNNING', N'IN PROGRESS', N'IN_PROGRESS', N'EXECUTING')
         AND UPPER(LTRIM(RTRIM(COALESCE(snapshot_row.[job_id], N''))))
                 NOT IN (N'', N'-', N'0', N'NULL', N'UNDEFINED', N'IDLE')
         AND snapshot_row.[job_event_time] >= DATEADD(MINUTE, -@online_anchor_minutes, snapshot_row.[source_anchor_time])
            THEN 1
        ELSE 0
    END) AS [is_active_job],
    snapshot_row.[map_code],
    snapshot_row.[station_code],
    snapshot_row.[target_station_code],
    snapshot_row.[position_x],
    snapshot_row.[position_y],
    snapshot_row.[position_theta],
    snapshot_row.[speed_mps],
    snapshot_row.[battery_soc],
    snapshot_row.[battery_voltage],
    snapshot_row.[battery_current],
    snapshot_row.[charging_status],
    snapshot_row.[error_code],
    snapshot_row.[error_message],
    snapshot_row.[source_event_time],
    snapshot_row.[status_event_time],
    snapshot_row.[battery_event_time],
    snapshot_row.[job_event_time],
    snapshot_row.[source_anchor_time],
    snapshot_row.[source_snapshot_time],
    snapshot_row.[dws_load_time]
INTO #robot_fleet
FROM [dbo].[MA_AMR] AS master_robot
LEFT JOIN [DWS].[dws_robot_current_snapshot] AS snapshot_row
    ON snapshot_row.[robot_code] = master_robot.[name]
OUTER APPLY (
    SELECT TOP (1)
        mode_dictionary.[Mode_ID],
        mode_dictionary.[Mode_Detail]
    FROM [dbo].[AMR_Robot_Mode] AS mode_dictionary
    WHERE LTRIM(RTRIM(mode_dictionary.[Mode_ID])) =
              REPLACE(LTRIM(RTRIM(COALESCE(snapshot_row.[current_mode], N''))), N'MODE_', N'')
       OR LTRIM(RTRIM(mode_dictionary.[Mode_Detail])) = LTRIM(RTRIM(snapshot_row.[current_mode]))
    ORDER BY
        CASE
            WHEN LTRIM(RTRIM(mode_dictionary.[Mode_ID])) =
                 REPLACE(LTRIM(RTRIM(COALESCE(snapshot_row.[current_mode], N''))), N'MODE_', N'')
                THEN 1
            ELSE 2
        END,
        TRY_CONVERT(INT, mode_dictionary.[Mode_ID]),
        mode_dictionary.[Mode_ID]
) AS mode_reference
WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y';

/* Result 1: active fleet metrics and source freshness. */
SELECT
    COUNT_BIG(1) AS [total_robot_count],
    (
        SELECT COUNT_BIG(1)
        FROM [dbo].[MA_AMR] AS commissioned_robot
        WHERE commissioned_robot.[factory_id] IS NOT NULL
          AND (
              UPPER(LTRIM(RTRIM(COALESCE(commissioned_robot.[is_active], N'')))) = N'Y'
              OR UPPER(LTRIM(RTRIM(COALESCE(commissioned_robot.[serial_number], N''))))
                    NOT IN (N'', N'UNDEFINED', N'NULL')
          )
    ) AS [commissioned_robot_count],
    SUM(CASE WHEN fleet.[has_current_snapshot] = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [snapshot_robot_count],
    SUM(CASE WHEN fleet.[has_current_snapshot] = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [missing_snapshot_robot_count],
    SUM(CASE WHEN fleet.[online_status] = N'ONLINE' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [online_robot_count],
    SUM(CASE WHEN fleet.[online_status] = N'OFFLINE' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [offline_robot_count],
    SUM(CASE WHEN fleet.[is_active_job] = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [active_job_robot_count],
    SUM(CASE
            WHEN UPPER(LTRIM(RTRIM(COALESCE(fleet.[error_message], N''))))
                 NOT IN (N'', N'-', N'NULL', N'UNDEFINED', N'NONE')
                THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END) AS [alarm_robot_count],
    SUM(CASE WHEN fleet.[battery_soc] BETWEEN 0 AND 20 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [low_battery_robot_count],
    CAST(AVG(CASE
                WHEN fleet.[battery_soc] BETWEEN 0 AND 100
                    THEN CONVERT(DECIMAL(18,6), fleet.[battery_soc])
            END) AS DECIMAL(18,2)) AS [avg_battery_soc],
    MAX(fleet.[source_event_time]) AS [latest_source_event_time],
    MAX(fleet.[source_anchor_time]) AS [source_anchor_time],
    DATEDIFF(MINUTE, MAX(fleet.[source_anchor_time]), @database_now) AS [source_anchor_lag_minutes],
    MAX(fleet.[source_snapshot_time]) AS [latest_source_snapshot_time],
    MAX(fleet.[dws_load_time]) AS [latest_dws_load_time],
    MAX(fleet.[master_updated_at]) AS [latest_master_update_time],
    @battery_anchor AS [battery_trend_anchor_time],
    @status_anchor AS [status_trend_anchor_time],
    @job_anchor AS [job_trend_anchor_date],
    @queue_anchor AS [queue_trend_anchor_date],
    @database_now AS [database_current_time]
FROM #robot_fleet AS fleet;

/* Result 2: active master list with one exact-name operational snapshot. */
SELECT TOP (500)
    fleet.[master_robot_id],
    fleet.[robot_code],
    fleet.[robot_name],
    fleet.[robot_serial_number],
    fleet.[master_status],
    fleet.[factory_id],
    fleet.[max_battery],
    fleet.[min_battery],
    fleet.[master_updated_at],
    fleet.[source_robot_code],
    fleet.[source_robot_id],
    fleet.[has_current_snapshot],
    fleet.[current_status],
    fleet.[current_mode_id],
    fleet.[current_mode],
    fleet.[source_current_mode],
    fleet.[online_status],
    fleet.[job_id],
    fleet.[subjob_id],
    fleet.[job_status],
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
    fleet.[dws_load_time]
FROM #robot_fleet AS fleet
ORDER BY fleet.[robot_name], fleet.[master_robot_id];

/* Result 3: latest known operating-state distribution. */
SELECT
    CASE
        WHEN fleet.[has_current_snapshot] = 0 THEN N'No Operational Snapshot'
        ELSE COALESCE(NULLIF(LTRIM(RTRIM(fleet.[current_status])), N''), N'Status Not Reported')
    END AS [status_name],
    COUNT_BIG(1) AS [robot_count]
FROM #robot_fleet AS fleet
GROUP BY
    CASE
        WHEN fleet.[has_current_snapshot] = 0 THEN N'No Operational Snapshot'
        ELSE COALESCE(NULLIF(LTRIM(RTRIM(fleet.[current_status])), N''), N'Status Not Reported')
    END
ORDER BY [robot_count] DESC, [status_name];

/* Result 4: latest known operating-mode distribution. */
SELECT
    CASE
        WHEN fleet.[has_current_snapshot] = 0 THEN N'No Operational Snapshot'
        ELSE COALESCE(NULLIF(LTRIM(RTRIM(fleet.[current_mode])), N''), N'Mode Not Reported')
    END AS [mode_name],
    COUNT_BIG(1) AS [robot_count]
FROM #robot_fleet AS fleet
GROUP BY
    CASE
        WHEN fleet.[has_current_snapshot] = 0 THEN N'No Operational Snapshot'
        ELSE COALESCE(NULLIF(LTRIM(RTRIM(fleet.[current_mode])), N''), N'Mode Not Reported')
    END
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
