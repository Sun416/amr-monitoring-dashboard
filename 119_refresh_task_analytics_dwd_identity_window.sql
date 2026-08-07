USE [IOT2020];

/*
    Repair Task Analytics robot identity for the DWD serving window.

    Why this script exists
    ----------------------
    DWD.fact_amr_queue rows written by the generic incremental loader
    (batches 47-50 and any newer batch) still carry the numeric MA_AMR id in
    robot_code. The installed DWD.sp_reconcile_robot_identity_for_batch
    procedure updates only dim_amr_robot and fact_robot_battery, so it cannot
    fix the queue fact. The Task Analytics serving path is normalized by
    DWD.sp_refresh_task_analytics_dwd_window (script 98), which rewrites the
    bounded DWD window from ODS with robot_code = dbo.MA_AMR.name and a new
    identity-reconciled dwd_batch_id.

    Scope
    -----
    - Read-only preview before the refresh (numeric codes that must clear).
    - One bounded DWD Task Analytics window refresh (at most 31 days).
    - Read-only validation after the refresh.

    This script changes DWD rows only; it never touches dbo, ODS or DWS.
    Reload the DWS leaderboards afterwards (82 + 100) and validate with 101.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'IOT2020'
BEGIN
    THROW 58900, N'Expected database IOT2020.', 1;
END;

IF OBJECT_ID(N'[DWD].[sp_refresh_task_analytics_dwd_window]', N'P') IS NULL
BEGIN
    THROW 58901, N'Missing procedure: DWD.sp_refresh_task_analytics_dwd_window. Install 98 first.', 1;
END;

DECLARE @window_end DATETIME2(3) = SYSDATETIME();
DECLARE @window_start DATETIME2(3) = DATEADD(DAY, -31, @window_end);

/* Phase 1: preview numeric robot_code rows that must clear in the window. */
SELECT
    N'BEFORE' AS [phase],
    queue_fact.[dwd_batch_id],
    COUNT_BIG(1) AS [numeric_robot_code_rows]
FROM [DWD].[fact_amr_queue] AS queue_fact
WHERE queue_fact.[event_time] >= @window_start
  AND queue_fact.[event_time] < @window_end
  AND TRY_CONVERT(INT, queue_fact.[robot_code]) IS NOT NULL
GROUP BY queue_fact.[dwd_batch_id]
ORDER BY queue_fact.[dwd_batch_id];

SELECT
    N'BEFORE' AS [phase],
    event_row.[source_table],
    COUNT_BIG(1) AS [numeric_robot_code_rows]
FROM [DWD].[fact_robot_operation_event] AS event_row
WHERE event_row.[event_time] >= @window_start
  AND event_row.[event_time] < @window_end
  AND TRY_CONVERT(INT, event_row.[robot_code]) IS NOT NULL
GROUP BY event_row.[source_table]
ORDER BY event_row.[source_table];

/* Phase 2: normalize the DWD Task Analytics window (own transaction + app lock). */
EXEC [DWD].[sp_refresh_task_analytics_dwd_window]
    @window_start = @window_start,
    @window_end = @window_end;

/* Phase 3: validation - every count below must be 0 for the window. */
SELECT
    N'AFTER' AS [phase],
    queue_fact.[dwd_batch_id],
    COUNT_BIG(1) AS [numeric_robot_code_rows]
FROM [DWD].[fact_amr_queue] AS queue_fact
WHERE queue_fact.[event_time] >= @window_start
  AND queue_fact.[event_time] < @window_end
  AND TRY_CONVERT(INT, queue_fact.[robot_code]) IS NOT NULL
GROUP BY queue_fact.[dwd_batch_id]
ORDER BY queue_fact.[dwd_batch_id];

SELECT
    N'AFTER' AS [phase],
    event_row.[source_table],
    COUNT_BIG(1) AS [numeric_robot_code_rows]
FROM [DWD].[fact_robot_operation_event] AS event_row
WHERE event_row.[event_time] >= @window_start
  AND event_row.[event_time] < @window_end
  AND TRY_CONVERT(INT, event_row.[robot_code]) IS NOT NULL
GROUP BY event_row.[source_table]
ORDER BY event_row.[source_table];

/* Identity sample: reconciled rows resolve to display names. */
SELECT TOP (20)
    queue_fact.[dwd_batch_id],
    queue_fact.[queue_id],
    queue_fact.[robot_id],
    queue_fact.[robot_code],
    master_robot.[name] AS [ma_amr_name],
    queue_fact.[event_time]
FROM [DWD].[fact_amr_queue] AS queue_fact
LEFT JOIN [dbo].[MA_AMR] AS master_robot
    ON master_robot.[id] = TRY_CONVERT(INT, queue_fact.[robot_id])
WHERE queue_fact.[event_time] >= @window_start
  AND queue_fact.[event_time] < @window_end
  AND queue_fact.[robot_id] IS NOT NULL
ORDER BY queue_fact.[event_time] DESC;
