/* Read-only validation for Task Analytics hourly leaderboards. */
SET NOCOUNT ON;

DECLARE @window_end DATETIME2(3) = DATEADD(HOUR, DATEDIFF(HOUR, 0, SYSDATETIME()) + 1, 0);
DECLARE @window_start DATETIME2(3) = DATEADD(DAY, -30, @window_end);

SELECT
    source_row.[table_name],
    source_row.[row_count],
    source_row.[first_stat_hour],
    source_row.[last_stat_hour],
    source_row.[latest_dws_load_time],
    CASE WHEN source_row.[duplicate_grains] = 0 THEN N'PASS' ELSE N'FAIL' END AS [grain_check]
FROM
(
    SELECT
        N'DWS.dws_robot_calling_box_hourly' AS [table_name],
        COUNT_BIG(1) AS [row_count],
        MIN([stat_hour]) AS [first_stat_hour],
        MAX([stat_hour]) AS [last_stat_hour],
        MAX([dws_load_time]) AS [latest_dws_load_time],
        COUNT_BIG(1) - COUNT_BIG(DISTINCT CONCAT(CONVERT(NVARCHAR(30), [stat_hour], 126), N'|', [robot_code], N'|', [calling_box_id])) AS [duplicate_grains]
    FROM [DWS].[dws_robot_calling_box_hourly]
    WHERE [stat_hour] >= @window_start
      AND [stat_hour] < @window_end

    UNION ALL

    SELECT
        N'DWS.dws_robot_assigned_task_hourly',
        COUNT_BIG(1),
        MIN([stat_hour]),
        MAX([stat_hour]),
        MAX([dws_load_time]),
        COUNT_BIG(1) - COUNT_BIG(DISTINCT CONCAT(CONVERT(NVARCHAR(30), [stat_hour], 126), N'|', [robot_code], N'|', [job_id]))
    FROM [DWS].[dws_robot_assigned_task_hourly]
    WHERE [stat_hour] >= @window_start
      AND [stat_hour] < @window_end
) AS source_row;

SELECT TOP (10)
    [stat_hour],
    [robot_code],
    [calling_box_label],
    [calling_box_count],
    [first_called_at],
    [last_called_at]
FROM [DWS].[dws_robot_calling_box_hourly]
WHERE [stat_hour] >= @window_start
  AND [stat_hour] < @window_end
ORDER BY [stat_hour] DESC, [calling_box_count] DESC, [calling_box_label];

SELECT TOP (10)
    [stat_hour],
    [robot_code],
    [task_label],
    [assigned_task_count],
    [completed_task_count],
    [first_assigned_at],
    [last_assigned_at]
FROM [DWS].[dws_robot_assigned_task_hourly]
WHERE [stat_hour] >= @window_start
  AND [stat_hour] < @window_end
ORDER BY [stat_hour] DESC, [assigned_task_count] DESC, [task_label];
