/*
    Read-only preview for the unified AMR event audit.

    Scope:
      - latest 5,000 ODS.AMR_Queue rows;
      - latest 5,000 ODS.TA_AMR rows;
      - all ODS.MA_AMR_Project_Assignment rows.

    No persistent objects or source rows are changed.
*/

SET NOCOUNT ON;

IF DB_NAME() <> N'IOT2020'
BEGIN
    THROW 55100, N'Expected database IOT2020.', 1;
END;

DECLARE @bootstrap_rows INT = 5000;

CREATE TABLE #queue_source (
    [ods_row_id] BIGINT NOT NULL PRIMARY KEY
);

CREATE TABLE #task_source (
    [ods_row_id] BIGINT NOT NULL PRIMARY KEY
);

CREATE TABLE #assignment_source (
    [ods_row_id] BIGINT NOT NULL PRIMARY KEY
);

INSERT INTO #queue_source ([ods_row_id])
SELECT selected.[ods_row_id]
FROM (
    SELECT TOP (@bootstrap_rows)
        source_row.[ods_row_id]
    FROM [ODS].[AMR_Queue] AS source_row
    ORDER BY source_row.[ods_row_id] DESC
) AS selected;

INSERT INTO #task_source ([ods_row_id])
SELECT selected.[ods_row_id]
FROM (
    SELECT TOP (@bootstrap_rows)
        source_row.[ods_row_id]
    FROM [ODS].[TA_AMR] AS source_row
    ORDER BY source_row.[ods_row_id] DESC
) AS selected;

INSERT INTO #assignment_source ([ods_row_id])
SELECT source_row.[ods_row_id]
FROM [ODS].[MA_AMR_Project_Assignment] AS source_row;

SELECT
    N'ODS.AMR_Queue' AS [source_object],
    COUNT_BIG(1) AS [selected_source_rows],
    SUM(CASE WHEN queue_row.[enqueued_at] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS [candidate_event_rows],
    SUM(CASE WHEN queue_row.[enqueued_at] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS [missing_event_time_rows],
    SUM(CASE WHEN queue_row.[AMR_id] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS [unattributed_robot_rows],
    MIN(queue_row.[ods_row_id]) AS [first_ods_row_id],
    MAX(queue_row.[ods_row_id]) AS [last_ods_row_id],
    MIN(queue_row.[enqueued_at]) AS [first_event_time],
    MAX(queue_row.[enqueued_at]) AS [latest_event_time]
FROM #queue_source AS selected
INNER JOIN [ODS].[AMR_Queue] AS queue_row
    ON queue_row.[ods_row_id] = selected.[ods_row_id]
UNION ALL
SELECT
    N'ODS.TA_AMR.START',
    COUNT_BIG(1),
    SUM(CASE WHEN task_row.[start_time] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    SUM(CASE WHEN task_row.[start_time] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    SUM(CASE WHEN task_row.[AMR_id] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    MIN(task_row.[ods_row_id]),
    MAX(task_row.[ods_row_id]),
    MIN(task_row.[start_time]),
    MAX(task_row.[start_time])
FROM #task_source AS selected
INNER JOIN [ODS].[TA_AMR] AS task_row
    ON task_row.[ods_row_id] = selected.[ods_row_id]
UNION ALL
SELECT
    N'ODS.TA_AMR.END',
    COUNT_BIG(1),
    SUM(CASE WHEN task_row.[end_time] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    SUM(CASE WHEN task_row.[end_time] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    SUM(CASE WHEN task_row.[AMR_id] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    MIN(task_row.[ods_row_id]),
    MAX(task_row.[ods_row_id]),
    MIN(task_row.[end_time]),
    MAX(task_row.[end_time])
FROM #task_source AS selected
INNER JOIN [ODS].[TA_AMR] AS task_row
    ON task_row.[ods_row_id] = selected.[ods_row_id]
UNION ALL
SELECT
    N'ODS.MA_AMR_Project_Assignment.START',
    COUNT_BIG(1),
    SUM(CASE WHEN assignment_row.[start_time] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    SUM(CASE WHEN assignment_row.[start_time] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    SUM(CASE WHEN assignment_row.[amr_id] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    MIN(assignment_row.[ods_row_id]),
    MAX(assignment_row.[ods_row_id]),
    MIN(assignment_row.[start_time]),
    MAX(assignment_row.[start_time])
FROM #assignment_source AS selected
INNER JOIN [ODS].[MA_AMR_Project_Assignment] AS assignment_row
    ON assignment_row.[ods_row_id] = selected.[ods_row_id]
UNION ALL
SELECT
    N'ODS.MA_AMR_Project_Assignment.END',
    COUNT_BIG(1),
    SUM(CASE WHEN assignment_row.[end_time] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    SUM(CASE WHEN assignment_row.[end_time] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    SUM(CASE WHEN assignment_row.[amr_id] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    MIN(assignment_row.[ods_row_id]),
    MAX(assignment_row.[ods_row_id]),
    MIN(assignment_row.[end_time]),
    MAX(assignment_row.[end_time])
FROM #assignment_source AS selected
INNER JOIN [ODS].[MA_AMR_Project_Assignment] AS assignment_row
    ON assignment_row.[ods_row_id] = selected.[ods_row_id]
ORDER BY [source_object];

SELECT TOP (20)
    queue_row.[ods_row_id],
    queue_row.[id] AS [queue_id],
    queue_row.[job_id],
    queue_row.[current_subjob_id],
    queue_row.[AMR_id] AS [recorded_robot_id],
    master_robot.[name] AS [recorded_robot_code],
    queue_row.[project_id],
    queue_row.[priority],
    queue_row.[status],
    queue_row.[enqueued_at],
    queue_row.[ods_load_time]
FROM #queue_source AS selected
INNER JOIN [ODS].[AMR_Queue] AS queue_row
    ON queue_row.[ods_row_id] = selected.[ods_row_id]
LEFT JOIN [dbo].[MA_AMR] AS master_robot
    ON master_robot.[id] = queue_row.[AMR_id]
ORDER BY queue_row.[ods_row_id] DESC;

