/*
    Task Analytics hourly leaderboard load
    ======================================

    Source: DWD.fact_amr_queue with DWD Calling Box and task enrichment.
    Serving target: DWS hourly leaderboards only.

    Scope: the most recent 30 complete/start-of-current calendar hours.
    Calling Box scope: every queue row with a non-NULL calling_box_id. There is
    deliberately no enqueued_by filter.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @window_end DATETIME2(3) = DATEADD(HOUR, DATEDIFF(HOUR, 0, SYSDATETIME()) + 1, 0);
DECLARE @window_start DATETIME2(3) = DATEADD(DAY, -30, @window_end);

IF OBJECT_ID(N'[DWS].[dws_robot_calling_box_hourly]', N'U') IS NULL
   OR OBJECT_ID(N'[DWS].[dws_robot_assigned_task_hourly]', N'U') IS NULL
BEGIN
    THROW 58401, N'Install the Task Analytics hourly leaderboard schema before loading it.', 1;
END;

BEGIN TRY
    BEGIN TRANSACTION;

    DELETE FROM [DWS].[dws_robot_calling_box_hourly]
    WHERE [stat_hour] >= @window_start
      AND [stat_hour] < @window_end;

    INSERT INTO [DWS].[dws_robot_calling_box_hourly]
    (
        [stat_hour], [robot_code], [robot_id], [calling_box_id], [calling_box_name], [calling_box_label],
        [calling_box_count], [first_called_at], [last_called_at]
    )
    SELECT
        DATEADD(HOUR, DATEDIFF(HOUR, 0, queue_fact.[event_time]), 0),
        queue_fact.[robot_code],
        queue_fact.[robot_id],
        queue_fact.[calling_box_id],
        MAX(queue_fact.[calling_box_name]),
        COALESCE(MAX(NULLIF(queue_fact.[calling_box_name], N'')), N'Calling Box #')
            + CASE
                WHEN MAX(NULLIF(queue_fact.[calling_box_name], N'')) IS NULL
                    THEN CONVERT(NVARCHAR(20), queue_fact.[calling_box_id])
                ELSE N' · #' + CONVERT(NVARCHAR(20), queue_fact.[calling_box_id])
              END,
        COUNT_BIG(DISTINCT queue_fact.[queue_id]),
        MIN(queue_fact.[event_time]),
        MAX(queue_fact.[event_time])
    FROM [DWD].[fact_amr_queue] AS queue_fact
    WHERE queue_fact.[event_time] >= @window_start
      AND queue_fact.[event_time] < @window_end
      AND queue_fact.[calling_box_id] IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(queue_fact.[robot_code])), N'') IS NOT NULL
    GROUP BY
        DATEADD(HOUR, DATEDIFF(HOUR, 0, queue_fact.[event_time]), 0),
        queue_fact.[robot_code],
        queue_fact.[robot_id],
        queue_fact.[calling_box_id];

    DELETE FROM [DWS].[dws_robot_assigned_task_hourly]
    WHERE [stat_hour] >= @window_start
      AND [stat_hour] < @window_end;

    INSERT INTO [DWS].[dws_robot_assigned_task_hourly]
    (
        [stat_hour], [robot_code], [robot_id], [job_id], [task_name], [task_label],
        [assigned_task_count], [completed_task_count], [first_assigned_at], [last_assigned_at]
    )
    SELECT
        DATEADD(HOUR, DATEDIFF(HOUR, 0, queue_fact.[event_time]), 0),
        queue_fact.[robot_code],
        queue_fact.[robot_id],
        TRY_CONVERT(INT, queue_fact.[job_id]),
        MAX(task_dim.[task_name]),
        COALESCE(MAX(NULLIF(task_dim.[task_name], N'')), N'Task #')
            + CASE
                WHEN MAX(NULLIF(task_dim.[task_name], N'')) IS NULL
                    THEN CONVERT(NVARCHAR(20), TRY_CONVERT(INT, queue_fact.[job_id]))
                ELSE N' · #' + CONVERT(NVARCHAR(20), TRY_CONVERT(INT, queue_fact.[job_id]))
              END,
        COUNT_BIG(DISTINCT queue_fact.[queue_id]),
        COUNT_BIG(DISTINCT CASE
            WHEN LOWER(LTRIM(RTRIM(COALESCE(queue_fact.[queue_status], N'')))) IN (N'completed', N'compleated')
                THEN queue_fact.[queue_id]
        END),
        MIN(queue_fact.[event_time]),
        MAX(queue_fact.[event_time])
    FROM [DWD].[fact_amr_queue] AS queue_fact
    LEFT JOIN [DWD].[dim_amr_task] AS task_dim
        ON task_dim.[job_id] = TRY_CONVERT(INT, queue_fact.[job_id])
    WHERE queue_fact.[event_time] >= @window_start
      AND queue_fact.[event_time] < @window_end
      AND TRY_CONVERT(INT, queue_fact.[job_id]) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(queue_fact.[robot_code])), N'') IS NOT NULL
    GROUP BY
        DATEADD(HOUR, DATEDIFF(HOUR, 0, queue_fact.[event_time]), 0),
        queue_fact.[robot_code],
        queue_fact.[robot_id],
        TRY_CONVERT(INT, queue_fact.[job_id]);

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
    BEGIN
        ROLLBACK TRANSACTION;
    END;

    THROW;
END CATCH;

SELECT
    N'DWS.dws_robot_calling_box_hourly' AS [table_name],
    COUNT_BIG(1) AS [row_count],
    MIN([stat_hour]) AS [first_stat_hour],
    MAX([stat_hour]) AS [last_stat_hour],
    MAX([dws_load_time]) AS [latest_dws_load_time]
FROM [DWS].[dws_robot_calling_box_hourly]
WHERE [stat_hour] >= @window_start
  AND [stat_hour] < @window_end
UNION ALL
SELECT
    N'DWS.dws_robot_assigned_task_hourly',
    COUNT_BIG(1),
    MIN([stat_hour]),
    MAX([stat_hour]),
    MAX([dws_load_time])
FROM [DWS].[dws_robot_assigned_task_hourly]
WHERE [stat_hour] >= @window_start
  AND [stat_hour] < @window_end;
