USE IOT2020;
GO

/* Execute the fast path once, then verify row reconciliation and freshness. */
EXEC [DWS].[sp_refresh_robot_current_snapshot_fast];
GO

SELECT
    N'dbo.AMR_Currentdata' AS [table_name],
    COUNT_BIG(*) AS [row_count]
FROM [dbo].[AMR_Currentdata]
UNION ALL
SELECT N'ODS.AMR_Currentdata', COUNT_BIG(*)
FROM [ODS].[AMR_Currentdata]
UNION ALL
SELECT N'DWD.snap_amr_current_status', COUNT_BIG(*)
FROM [DWD].[snap_amr_current_status]
WHERE [source_schema] = N'ODS'
  AND [source_table] = N'AMR_Currentdata'
UNION ALL
SELECT N'DWS.dws_robot_current_snapshot', COUNT_BIG(*)
FROM [DWS].[dws_robot_current_snapshot];

SELECT
    COUNT_BIG(*) AS [dws_row_count],
    COUNT_BIG(CASE
        WHEN NULLIF(LTRIM(RTRIM([robot_code])), N'') IS NULL
          OR [robot_code] = N'UNKNOWN'
            THEN 1
    END) AS [blank_or_unknown_robot_code_count],
    COUNT_BIG(CASE
        WHEN [source_event_time] IS NULL THEN 1
    END) AS [null_source_event_time_count],
    MAX([source_event_time]) AS [latest_source_event_time],
    MAX([dws_load_time]) AS [latest_dws_load_time],
    DATEDIFF(SECOND, MAX([dws_load_time]), SYSDATETIME()) AS [seconds_since_dws_refresh]
FROM [DWS].[dws_robot_current_snapshot];

SELECT
    [robot_code],
    COUNT_BIG(*) AS [duplicate_row_count]
FROM [DWS].[dws_robot_current_snapshot]
GROUP BY [robot_code]
HAVING COUNT_BIG(*) > 1;

SELECT TOP (20)
    [robot_code], [robot_id], [current_status], [current_mode], [online_status],
    [job_id], [map_code], [station_code], [position_x], [position_y],
    [speed_mps], [battery_soc], [error_code], [source_event_time],
    [source_snapshot_time], [dws_load_time], [dws_batch_id]
FROM [DWS].[dws_robot_current_snapshot]
ORDER BY [robot_code];
GO

