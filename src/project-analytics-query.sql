/*
  Project and Task Analytics API query.

  Analysis axis: project -> task -> robot. Only project and task are request
  filters; robot is a derived breakdown and drill-down dimension. Identity always resolves through
  DWD.fact_amr_queue.robot_id = dbo.MA_AMR.id, so a numeric robot_code left in
  DWD by an unreconciled batch cannot leak into the display name.

  Recordsets:
    0  summary of the analysis window
    1  project list (entry point of the whole view)
    2  task list within the selected project scope
    3  robot breakdown within the selected project/task scope
    4  hourly queue trend within the selected scope
    5  outcome breakdown (queue_status) within the selected scope
    6  recent queue records for evidence
    7  idle-time causes by derived robot for local display filtering
*/
SET NOCOUNT ON;

DECLARE @requested_start DATETIME2(0) = TRY_CONVERT(DATETIME2(0), REPLACE(@analysis_start_text, N'T', N' '));
DECLARE @requested_end DATETIME2(0) = TRY_CONVERT(DATETIME2(0), REPLACE(@analysis_end_text, N'T', N' '));
DECLARE @anchor DATETIME2(0);
DECLARE @project_ids_text NVARCHAR(MAX) = NULLIF(LTRIM(RTRIM(@project_ids_text_param)), N'');
DECLARE @job_ids_text NVARCHAR(MAX) = NULLIF(LTRIM(RTRIM(@job_ids_text_param)), N'');

DECLARE @selected_projects TABLE
(
    project_id INT NOT NULL PRIMARY KEY
);

DECLARE @selected_jobs TABLE
(
    job_id INT NOT NULL PRIMARY KEY
);

DECLARE @projects_xml XML = TRY_CONVERT(XML,
    CASE
        WHEN @project_ids_text IS NULL THEN N'<items />'
        ELSE N'<items><item>' + REPLACE(@project_ids_text, N',', N'</item><item>') + N'</item></items>'
    END
);

DECLARE @jobs_xml XML = TRY_CONVERT(XML,
    CASE
        WHEN @job_ids_text IS NULL THEN N'<items />'
        ELSE N'<items><item>' + REPLACE(@job_ids_text, N',', N'</item><item>') + N'</item></items>'
    END
);

INSERT INTO @selected_projects (project_id)
SELECT DISTINCT TRY_CONVERT(INT, LTRIM(RTRIM(split.value(N'.', N'NVARCHAR(100)'))))
FROM @projects_xml.nodes(N'/items/item') AS items(split)
WHERE TRY_CONVERT(INT, LTRIM(RTRIM(split.value(N'.', N'NVARCHAR(100)')))) IS NOT NULL;

INSERT INTO @selected_jobs (job_id)
SELECT DISTINCT TRY_CONVERT(INT, LTRIM(RTRIM(split.value(N'.', N'NVARCHAR(100)'))))
FROM @jobs_xml.nodes(N'/items/item') AS items(split)
WHERE TRY_CONVERT(INT, LTRIM(RTRIM(split.value(N'.', N'NVARCHAR(100)')))) IS NOT NULL;

SELECT @anchor = DATEADD(HOUR, 1, MAX(queue_fact.[stat_hour]))
FROM [DWS].[dws_robot_task_hourly] AS queue_fact;

IF @requested_start IS NULL AND @requested_end IS NULL
BEGIN
    SET @requested_end = ISNULL(@anchor, CAST(SYSDATETIME() AS DATETIME2(0)));
    SET @requested_start = DATEADD(HOUR, -24, @requested_end);
END;

IF @requested_start IS NULL OR @requested_end IS NULL OR @requested_end <= @requested_start
BEGIN
    THROW 51101, N'Project Analytics requires a valid start and end time.', 1;
END;

IF DATEDIFF(HOUR, @requested_start, @requested_end) > 2160
BEGIN
    THROW 51102, N'Project Analytics supports an analysis window of at most 90 days.', 1;
END;

/*
  Execution seconds come from ODS.TA_AMR, the only source that records a closed
  start_time/end_time pair per subjob run. DWD.fact_amr_queue.duration_seconds
  is NULL for every row in the current data, so it is not used.
*/
DECLARE @execution_by_queue TABLE
(
    queue_id BIGINT NOT NULL PRIMARY KEY,
    execution_seconds BIGINT NOT NULL,
    subjob_run_count BIGINT NOT NULL,
    subjob_success_count BIGINT NOT NULL,
    last_execution_time DATETIME2(0) NULL
);

INSERT INTO @execution_by_queue
(
    queue_id,
    execution_seconds,
    subjob_run_count,
    subjob_success_count,
    last_execution_time
)
SELECT
    task_run.[queue_id],
    SUM(CASE
            WHEN task_run.[end_time] IS NULL THEN 0
            ELSE DATEDIFF(SECOND, task_run.[start_time], task_run.[end_time])
        END),
    COUNT_BIG(1),
    SUM(CASE WHEN task_run.[status] = 'success' THEN 1 ELSE 0 END),
    CONVERT(DATETIME2(0), MAX(task_run.[start_time]))
FROM [ODS].[TA_AMR] AS task_run
WHERE task_run.[queue_id] IS NOT NULL
  AND task_run.[start_time] >= @requested_start
  AND task_run.[start_time] < @requested_end
GROUP BY task_run.[queue_id];

/*
  One shared scope table. Every recordset below reads from it, so the project,
  task and robot views can never disagree about which queue records they cover.
*/
DECLARE @scoped_queue TABLE
(
    queue_fact_id BIGINT NOT NULL PRIMARY KEY,
    queue_id NVARCHAR(100) NULL,
    event_time DATETIME2(0) NOT NULL,
    stat_hour DATETIME2(0) NOT NULL,
    project_id INT NULL,
    project_name NVARCHAR(200) NULL,
    job_id INT NULL,
    task_name NVARCHAR(200) NULL,
    robot_master_id INT NULL,
    robot_name NVARCHAR(100) NULL,
    queue_status NVARCHAR(100) NULL,
    calling_box_name NVARCHAR(200) NULL,
    execution_seconds BIGINT NOT NULL,
    subjob_run_count BIGINT NOT NULL,
    subjob_success_count BIGINT NOT NULL
);

INSERT INTO @scoped_queue
(
    queue_fact_id,
    queue_id,
    event_time,
    stat_hour,
    project_id,
    project_name,
    job_id,
    task_name,
    robot_master_id,
    robot_name,
    queue_status,
    calling_box_name,
    execution_seconds,
    subjob_run_count,
    subjob_success_count
)
SELECT
    queue_fact.[queue_fact_id],
    queue_fact.[queue_id],
    CONVERT(DATETIME2(0), queue_fact.[event_time]),
    DATEADD(HOUR, DATEDIFF(HOUR, 0, queue_fact.[event_time]), 0),
    TRY_CONVERT(INT, queue_fact.[project_id]),
    project_master.[name],
    TRY_CONVERT(INT, queue_fact.[job_id]),
    task_dimension.[task_name],
    robot_master.[id],
    robot_master.[name],
    queue_fact.[queue_status],
    queue_fact.[calling_box_name],
    ISNULL(execution_rollup.[execution_seconds], 0),
    ISNULL(execution_rollup.[subjob_run_count], 0),
    ISNULL(execution_rollup.[subjob_success_count], 0)
FROM [DWD].[fact_amr_queue] AS queue_fact
LEFT JOIN [dbo].[MA_AMR_Project] AS project_master
    ON project_master.[id] = TRY_CONVERT(INT, queue_fact.[project_id])
LEFT JOIN [DWD].[dim_amr_task] AS task_dimension
    ON task_dimension.[job_id] = TRY_CONVERT(INT, queue_fact.[job_id])
LEFT JOIN [dbo].[MA_AMR] AS robot_master
    ON robot_master.[id] = TRY_CONVERT(INT, queue_fact.[robot_id])
LEFT JOIN @execution_by_queue AS execution_rollup
    ON execution_rollup.[queue_id] = TRY_CONVERT(BIGINT, queue_fact.[queue_id])
WHERE queue_fact.[event_time] >= @requested_start
  AND queue_fact.[event_time] < @requested_end;

/* 0: window summary. */
SELECT
    CONVERT(NVARCHAR(19), @requested_start, 120) AS [analysis_start],
    CONVERT(NVARCHAR(19), @requested_end, 120) AS [analysis_end],
    CONVERT(NVARCHAR(19), @anchor, 120) AS [source_anchor],
    (SELECT COUNT(1) FROM @selected_projects) AS [selected_project_count],
    (SELECT COUNT(1) FROM @selected_jobs) AS [selected_job_count],
    COUNT_BIG(1) AS [queue_count],
    COUNT(DISTINCT scoped.[project_id]) AS [project_count],
    COUNT(DISTINCT scoped.[job_id]) AS [task_count],
    COUNT(DISTINCT scoped.[robot_master_id]) AS [robot_count],
    SUM(CASE WHEN scoped.[queue_status] = N'completed' THEN 1 ELSE 0 END) AS [completed_count],
    SUM(CASE WHEN scoped.[queue_status] IN (N'failed', N'cancelled', N'canceled') THEN 1 ELSE 0 END) AS [unsuccessful_count],
    SUM(CASE WHEN scoped.[queue_status] IN (N'in_progress', N'pending') THEN 1 ELSE 0 END) AS [open_count],
    SUM(scoped.[execution_seconds]) AS [execution_seconds],
    CONVERT(NVARCHAR(19), MAX(scoped.[event_time]), 120) AS [latest_event_time]
FROM @scoped_queue AS scoped
WHERE
(
    NOT EXISTS (SELECT 1 FROM @selected_projects)
    OR EXISTS (SELECT 1 FROM @selected_projects AS selected_project WHERE selected_project.[project_id] = scoped.[project_id])
)
AND
(
    NOT EXISTS (SELECT 1 FROM @selected_jobs)
    OR EXISTS (SELECT 1 FROM @selected_jobs AS selected_job WHERE selected_job.[job_id] = scoped.[job_id])
);

/* 1: project list. Always the full window, so the picker never hides a project. */
SELECT
    scoped.[project_id],
    ISNULL(scoped.[project_name], N'Unmapped project') AS [project_name],
    COUNT_BIG(1) AS [queue_count],
    COUNT(DISTINCT scoped.[job_id]) AS [task_count],
    COUNT(DISTINCT scoped.[robot_master_id]) AS [robot_count],
    SUM(CASE WHEN scoped.[queue_status] = N'completed' THEN 1 ELSE 0 END) AS [completed_count],
    SUM(CASE WHEN scoped.[queue_status] IN (N'failed', N'cancelled', N'canceled') THEN 1 ELSE 0 END) AS [unsuccessful_count],
    SUM(CASE WHEN scoped.[queue_status] IN (N'in_progress', N'pending') THEN 1 ELSE 0 END) AS [open_count],
    SUM(scoped.[execution_seconds]) AS [execution_seconds],
    CONVERT(NVARCHAR(19), MAX(scoped.[event_time]), 120) AS [latest_event_time]
FROM @scoped_queue AS scoped
GROUP BY scoped.[project_id], scoped.[project_name]
ORDER BY [queue_count] DESC, [project_name];

/* 2: task list within the selected project. */
SELECT
    scoped.[project_id],
    ISNULL(scoped.[project_name], N'Unmapped project') AS [project_name],
    scoped.[job_id],
    ISNULL(scoped.[task_name], CONCAT(N'Job ', scoped.[job_id])) AS [task_name],
    COUNT_BIG(1) AS [queue_count],
    COUNT(DISTINCT scoped.[robot_master_id]) AS [robot_count],
    SUM(CASE WHEN scoped.[queue_status] = N'completed' THEN 1 ELSE 0 END) AS [completed_count],
    SUM(CASE WHEN scoped.[queue_status] IN (N'failed', N'cancelled', N'canceled') THEN 1 ELSE 0 END) AS [unsuccessful_count],
    SUM(CASE WHEN scoped.[queue_status] IN (N'in_progress', N'pending') THEN 1 ELSE 0 END) AS [open_count],
    SUM(scoped.[execution_seconds]) AS [execution_seconds],
    SUM(scoped.[subjob_run_count]) AS [subjob_run_count],
    CASE
        WHEN SUM(CASE WHEN scoped.[execution_seconds] > 0 THEN 1 ELSE 0 END) = 0 THEN NULL
        ELSE SUM(scoped.[execution_seconds]) * 1.0
             / SUM(CASE WHEN scoped.[execution_seconds] > 0 THEN 1 ELSE 0 END)
    END AS [average_execution_seconds],
    CONVERT(NVARCHAR(19), MAX(scoped.[event_time]), 120) AS [latest_event_time]
FROM @scoped_queue AS scoped
WHERE
(
    NOT EXISTS (SELECT 1 FROM @selected_projects)
    OR EXISTS (SELECT 1 FROM @selected_projects AS selected_project WHERE selected_project.[project_id] = scoped.[project_id])
)
GROUP BY scoped.[project_id], scoped.[project_name], scoped.[job_id], scoped.[task_name]
ORDER BY [queue_count] DESC, [task_name];

/* 3: robot breakdown for the selected project and task. */
SELECT
    scoped.[robot_master_id],
    ISNULL(scoped.[robot_name], N'Unmapped robot') AS [robot_name],
    COUNT_BIG(1) AS [queue_count],
    COUNT(DISTINCT scoped.[job_id]) AS [task_count],
    SUM(CASE WHEN scoped.[queue_status] = N'completed' THEN 1 ELSE 0 END) AS [completed_count],
    SUM(CASE WHEN scoped.[queue_status] IN (N'failed', N'cancelled', N'canceled') THEN 1 ELSE 0 END) AS [unsuccessful_count],
    SUM(CASE WHEN scoped.[queue_status] IN (N'in_progress', N'pending') THEN 1 ELSE 0 END) AS [open_count],
    SUM(scoped.[execution_seconds]) AS [execution_seconds],
    CASE
        WHEN SUM(CASE WHEN scoped.[execution_seconds] > 0 THEN 1 ELSE 0 END) = 0 THEN NULL
        ELSE SUM(scoped.[execution_seconds]) * 1.0
             / SUM(CASE WHEN scoped.[execution_seconds] > 0 THEN 1 ELSE 0 END)
    END AS [average_execution_seconds],
    CONVERT(NVARCHAR(19), MAX(scoped.[event_time]), 120) AS [latest_event_time]
FROM @scoped_queue AS scoped
WHERE
(
    NOT EXISTS (SELECT 1 FROM @selected_projects)
    OR EXISTS (SELECT 1 FROM @selected_projects AS selected_project WHERE selected_project.[project_id] = scoped.[project_id])
)
AND
(
    NOT EXISTS (SELECT 1 FROM @selected_jobs)
    OR EXISTS (SELECT 1 FROM @selected_jobs AS selected_job WHERE selected_job.[job_id] = scoped.[job_id])
)
GROUP BY scoped.[robot_master_id], scoped.[robot_name]
ORDER BY [queue_count] DESC, [robot_name];

/* 4: hourly trend for the selected scope, split by robot. */
SELECT
    CONVERT(NVARCHAR(19), scoped.[stat_hour], 120) AS [stat_hour],
    ISNULL(scoped.[robot_name], N'Unmapped robot') AS [robot_name],
    COUNT_BIG(1) AS [queue_count],
    SUM(CASE WHEN scoped.[queue_status] = N'completed' THEN 1 ELSE 0 END) AS [completed_count],
    SUM(CASE WHEN scoped.[queue_status] IN (N'failed', N'cancelled', N'canceled') THEN 1 ELSE 0 END) AS [unsuccessful_count],
    SUM(scoped.[execution_seconds]) AS [execution_seconds]
FROM @scoped_queue AS scoped
WHERE
(
    NOT EXISTS (SELECT 1 FROM @selected_projects)
    OR EXISTS (SELECT 1 FROM @selected_projects AS selected_project WHERE selected_project.[project_id] = scoped.[project_id])
)
AND
(
    NOT EXISTS (SELECT 1 FROM @selected_jobs)
    OR EXISTS (SELECT 1 FROM @selected_jobs AS selected_job WHERE selected_job.[job_id] = scoped.[job_id])
)
GROUP BY scoped.[stat_hour], scoped.[robot_name]
ORDER BY [stat_hour], [robot_name];

/* 5: recorded outcome breakdown for the selected scope. */
SELECT
    ISNULL(scoped.[queue_status], N'unknown') AS [queue_status],
    COUNT_BIG(1) AS [queue_count],
    COUNT(DISTINCT scoped.[robot_master_id]) AS [robot_count],
    COUNT(DISTINCT scoped.[job_id]) AS [task_count],
    CONVERT(NVARCHAR(19), MAX(scoped.[event_time]), 120) AS [latest_event_time]
FROM @scoped_queue AS scoped
WHERE
(
    NOT EXISTS (SELECT 1 FROM @selected_projects)
    OR EXISTS (SELECT 1 FROM @selected_projects AS selected_project WHERE selected_project.[project_id] = scoped.[project_id])
)
AND
(
    NOT EXISTS (SELECT 1 FROM @selected_jobs)
    OR EXISTS (SELECT 1 FROM @selected_jobs AS selected_job WHERE selected_job.[job_id] = scoped.[job_id])
)
GROUP BY scoped.[queue_status]
ORDER BY [queue_count] DESC;

/* 6: latest queue records as evidence, bounded to 100 rows. */
SELECT TOP (100)
    scoped.[queue_id],
    CONVERT(NVARCHAR(19), scoped.[event_time], 120) AS [event_time],
    ISNULL(scoped.[project_name], N'Unmapped project') AS [project_name],
    ISNULL(scoped.[task_name], CONCAT(N'Job ', scoped.[job_id])) AS [task_name],
    ISNULL(scoped.[robot_name], N'Unmapped robot') AS [robot_name],
    scoped.[queue_status],
    scoped.[calling_box_name],
    scoped.[execution_seconds],
    scoped.[subjob_run_count],
    scoped.[subjob_success_count]
FROM @scoped_queue AS scoped
WHERE
(
    NOT EXISTS (SELECT 1 FROM @selected_projects)
    OR EXISTS (SELECT 1 FROM @selected_projects AS selected_project WHERE selected_project.[project_id] = scoped.[project_id])
)
AND
(
    NOT EXISTS (SELECT 1 FROM @selected_jobs)
    OR EXISTS (SELECT 1 FROM @selected_jobs AS selected_job WHERE selected_job.[job_id] = scoped.[job_id])
)
ORDER BY scoped.[event_time] DESC;

/*
    Idle-time causes for the robots that carried the selected scope.

    The source is DWS.dws_robot_task_hourly (robot + hour grain). Only robots
    that appear in the scoped queue set are counted, so the chart describes
    "how the robots of this project spent their non-executing time", never a
    project-level aggregate that the telemetry schema cannot support.
*/
DECLARE @idle_start DATETIME2(0) = DATEADD
(
    HOUR,
    DATEDIFF(HOUR, 0, @requested_start)
        + CASE
            WHEN @requested_start > DATEADD(HOUR, DATEDIFF(HOUR, 0, @requested_start), 0) THEN 1
            ELSE 0
          END,
    0
);
DECLARE @idle_end DATETIME2(0) = DATEADD(HOUR, DATEDIFF(HOUR, 0, @requested_end), 0);

SELECT
    h.[robot_code] AS [robot_name],
    SUM(h.[no_task_seconds]) AS [no_task_seconds],
    SUM(h.[waiting_seconds]) AS [waiting_seconds],
    SUM(h.[charging_seconds]) AS [charging_seconds],
    SUM(h.[executing_seconds]) AS [executing_seconds]
FROM [DWS].[dws_robot_task_hourly] AS h
WHERE h.[stat_hour] >= @idle_start
  AND h.[stat_hour] < @idle_end
  AND EXISTS
  (
      SELECT 1
      FROM @scoped_queue AS scoped
      WHERE scoped.[robot_name] = h.[robot_code]
        AND
        (
            NOT EXISTS (SELECT 1 FROM @selected_projects)
            OR EXISTS (SELECT 1 FROM @selected_projects AS selected_project WHERE selected_project.[project_id] = scoped.[project_id])
        )
        AND
        (
            NOT EXISTS (SELECT 1 FROM @selected_jobs)
            OR EXISTS (SELECT 1 FROM @selected_jobs AS selected_job WHERE selected_job.[job_id] = scoped.[job_id])
        )
  )
GROUP BY h.[robot_code]
ORDER BY h.[robot_code];
