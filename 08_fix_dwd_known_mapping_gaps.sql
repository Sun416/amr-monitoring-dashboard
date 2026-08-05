USE IOT2020;
GO

/*
    Fix known DWD mapping gaps before building DWS.

    Scope:
    1. Add DWD.fact_robot_status.speed_mps when the table already exists.
    2. Backfill DWD.fact_amr_queue.event_time / queue_start_time from ODS.AMR_Queue.enqueued_at.
    3. Backfill DWD.fact_robot_status.speed_mps from ODS.robot_status_history.robot_speed.
    4. Show diagnostics for still-unmapped source columns.

    This script does not delete rows and does not reset watermarks.
*/

/* 1. Source-column diagnostics for tables with known DWD null gaps. */
WITH target_sources AS (
    SELECT *
    FROM (VALUES
        (N'ODS', N'AMR_Queue',          N'DWD', N'fact_amr_queue'),
        (N'ODS', N'AMR_Subjob_Analyze', N'DWD', N'fact_amr_subjob'),
        (N'ODS', N'robot_job_history',  N'DWD', N'fact_robot_job'),
        (N'ODS', N'robot_status_history', N'DWD', N'fact_robot_status'),
        (N'ODS', N'AMR_Currentdata',    N'DWD', N'snap_amr_current_status'),
        (N'ODS', N'AMR_Robot_Mode',     N'DWD', N'snap_amr_current_status')
    ) AS v(source_schema, source_table, target_schema, target_table)
)
SELECT
    ts.source_schema,
    ts.source_table,
    ts.target_table,
    c.column_id,
    c.name AS source_column,
    ty.name AS data_type,
    CASE
        WHEN ty.name IN (N'nvarchar', N'nchar') AND c.max_length > 0 THEN c.max_length / 2
        ELSE c.max_length
    END AS max_length,
    c.precision,
    c.scale,
    c.is_nullable
FROM target_sources AS ts
JOIN sys.schemas AS s
    ON s.name = ts.source_schema
JOIN sys.tables AS t
    ON t.schema_id = s.schema_id
   AND t.name = ts.source_table
JOIN sys.columns AS c
    ON c.object_id = t.object_id
JOIN sys.types AS ty
    ON ty.user_type_id = c.user_type_id
ORDER BY
    ts.source_table,
    c.column_id;
GO

/* 2. Candidate mapping check. Missing rows in this result explain most DWD NULL fields. */
WITH expected_mapping AS (
    SELECT *
    FROM (VALUES
        (N'AMR_Queue', N'fact_amr_queue', N'event_time', N'enqueued_at'),
        (N'AMR_Queue', N'fact_amr_queue', N'queue_start_time', N'enqueued_at'),
        (N'AMR_Queue', N'fact_amr_queue', N'queue_status', N'status'),
        (N'AMR_Queue', N'fact_amr_queue', N'robot_id', N'AMR_id'),
        (N'AMR_Queue', N'fact_amr_queue', N'robot_code', N'AMR_id'),
        (N'robot_status_history', N'fact_robot_status', N'status_time', N'robot_datetime'),
        (N'robot_status_history', N'fact_robot_status', N'robot_id', N'amr_id'),
        (N'robot_status_history', N'fact_robot_status', N'robot_code', N'amr_id'),
        (N'robot_status_history', N'fact_robot_status', N'speed_mps', N'robot_speed'),
        (N'robot_job_history', N'fact_robot_job', N'job_start_time', N'robot_datetime'),
        (N'robot_job_history', N'fact_robot_job', N'robot_id', N'amr_id'),
        (N'robot_job_history', N'fact_robot_job', N'robot_code', N'amr_id'),
        (N'AMR_Subjob_Analyze', N'fact_amr_subjob', N'subjob_start_time', N'robot_datetime'),
        (N'AMR_Subjob_Analyze', N'fact_amr_subjob', N'robot_id', N'amr_id'),
        (N'AMR_Subjob_Analyze', N'fact_amr_subjob', N'robot_code', N'amr_id')
    ) AS v(source_table, target_table, target_column, expected_source_column)
)
SELECT
    em.source_table,
    em.target_table,
    em.target_column,
    em.expected_source_column,
    CASE WHEN c.column_id IS NULL THEN N'MISSING_IN_SOURCE' ELSE N'FOUND' END AS source_column_status,
    c.column_id,
    ty.name AS data_type
FROM expected_mapping AS em
LEFT JOIN sys.schemas AS s
    ON s.name = N'ODS'
LEFT JOIN sys.tables AS t
    ON t.schema_id = s.schema_id
   AND t.name = em.source_table
LEFT JOIN sys.columns AS c
    ON c.object_id = t.object_id
   AND LOWER(c.name) = LOWER(em.expected_source_column)
LEFT JOIN sys.types AS ty
    ON ty.user_type_id = c.user_type_id
ORDER BY
    em.source_table,
    em.target_column,
    em.expected_source_column;
GO

/* 3. Schema patch: DWS idle/travel calculations need robot speed in DWD. */
IF OBJECT_ID(N'[DWD].[fact_robot_status]', N'U') IS NOT NULL
   AND COL_LENGTH(N'DWD.fact_robot_status', N'speed_mps') IS NULL
BEGIN
    ALTER TABLE [DWD].[fact_robot_status]
    ADD [speed_mps] DECIMAL(18,6) NULL;
END;
GO

/* 4. Preview queue rows that can be repaired from ODS.AMR_Queue.enqueued_at. */
IF OBJECT_ID(N'[ODS].[AMR_Queue]', N'U') IS NOT NULL
   AND OBJECT_ID(N'[DWD].[fact_amr_queue]', N'U') IS NOT NULL
   AND COL_LENGTH(N'ODS.AMR_Queue', N'enqueued_at') IS NOT NULL
BEGIN
    EXEC sys.sp_executesql N'
SELECT
    N''queue_time_repair_preview'' AS check_name,
    COUNT_BIG(*) AS rows_to_update,
    MIN(tgt.source_ods_row_id) AS min_source_ods_row_id,
    MAX(tgt.source_ods_row_id) AS max_source_ods_row_id
FROM [DWD].[fact_amr_queue] AS tgt
JOIN [ODS].[AMR_Queue] AS src
    ON src.[ods_row_id] = tgt.[source_ods_row_id]
WHERE tgt.[source_schema] = N''ODS''
  AND tgt.[source_table] = N''AMR_Queue''
  AND (tgt.[event_time] IS NULL OR tgt.[queue_start_time] IS NULL)
  AND TRY_CONVERT(DATETIME2(3), SWITCHOFFSET(TRY_CONVERT(DATETIMEOFFSET(7), src.[enqueued_at]), N''+07:00'')) IS NOT NULL;
';
END;
GO

/* 5. Repair queue event_time and queue_start_time. */
IF OBJECT_ID(N'[ODS].[AMR_Queue]', N'U') IS NOT NULL
   AND OBJECT_ID(N'[DWD].[fact_amr_queue]', N'U') IS NOT NULL
   AND COL_LENGTH(N'ODS.AMR_Queue', N'enqueued_at') IS NOT NULL
BEGIN
    EXEC sys.sp_executesql N'
UPDATE tgt
SET
    [event_time] = COALESCE(tgt.[event_time], TRY_CONVERT(DATETIME2(3), SWITCHOFFSET(TRY_CONVERT(DATETIMEOFFSET(7), src.[enqueued_at]), N''+07:00''))),
    [queue_start_time] = COALESCE(tgt.[queue_start_time], TRY_CONVERT(DATETIME2(3), SWITCHOFFSET(TRY_CONVERT(DATETIMEOFFSET(7), src.[enqueued_at]), N''+07:00'')))
FROM [DWD].[fact_amr_queue] AS tgt
JOIN [ODS].[AMR_Queue] AS src
    ON src.[ods_row_id] = tgt.[source_ods_row_id]
WHERE tgt.[source_schema] = N''ODS''
  AND tgt.[source_table] = N''AMR_Queue''
  AND (tgt.[event_time] IS NULL OR tgt.[queue_start_time] IS NULL)
  AND TRY_CONVERT(DATETIME2(3), SWITCHOFFSET(TRY_CONVERT(DATETIMEOFFSET(7), src.[enqueued_at]), N''+07:00'')) IS NOT NULL;
';
END;
GO

/* 6. Preview status speed rows that can be repaired from ODS.robot_status_history.robot_speed. */
IF OBJECT_ID(N'[ODS].[robot_status_history]', N'U') IS NOT NULL
   AND OBJECT_ID(N'[DWD].[fact_robot_status]', N'U') IS NOT NULL
   AND COL_LENGTH(N'ODS.robot_status_history', N'robot_speed') IS NOT NULL
   AND COL_LENGTH(N'DWD.fact_robot_status', N'speed_mps') IS NOT NULL
BEGIN
    EXEC sys.sp_executesql N'
SELECT
    N''status_speed_repair_preview'' AS check_name,
    COUNT_BIG(*) AS rows_to_update,
    MIN(tgt.source_ods_row_id) AS min_source_ods_row_id,
    MAX(tgt.source_ods_row_id) AS max_source_ods_row_id
FROM [DWD].[fact_robot_status] AS tgt
JOIN [ODS].[robot_status_history] AS src
    ON src.[ods_row_id] = tgt.[source_ods_row_id]
WHERE tgt.[source_schema] = N''ODS''
  AND tgt.[source_table] = N''robot_status_history''
  AND tgt.[speed_mps] IS NULL
  AND TRY_CONVERT(DECIMAL(18,6), src.[robot_speed]) IS NOT NULL;
';
END;
GO

/* 7. Batched repair for status speed. This can touch many rows, so it is range-based. */
IF OBJECT_ID(N'[ODS].[robot_status_history]', N'U') IS NOT NULL
   AND OBJECT_ID(N'[DWD].[fact_robot_status]', N'U') IS NOT NULL
   AND COL_LENGTH(N'ODS.robot_status_history', N'robot_speed') IS NOT NULL
   AND COL_LENGTH(N'DWD.fact_robot_status', N'speed_mps') IS NOT NULL
BEGIN
    EXEC sys.sp_executesql N'
DECLARE
    @batch_size BIGINT = 500000,
    @range_start BIGINT,
    @range_end BIGINT,
    @max_source_ods_row_id BIGINT,
    @rows_updated INT,
    @batch_no INT = 0,
    @message NVARCHAR(4000);

SELECT
    @range_start = MIN(tgt.[source_ods_row_id]),
    @max_source_ods_row_id = MAX(tgt.[source_ods_row_id])
FROM [DWD].[fact_robot_status] AS tgt
JOIN [ODS].[robot_status_history] AS src
    ON src.[ods_row_id] = tgt.[source_ods_row_id]
WHERE tgt.[source_schema] = N''ODS''
  AND tgt.[source_table] = N''robot_status_history''
  AND tgt.[speed_mps] IS NULL
  AND TRY_CONVERT(DECIMAL(18,6), src.[robot_speed]) IS NOT NULL;

WHILE @range_start IS NOT NULL
  AND @range_start <= @max_source_ods_row_id
BEGIN
    SET @batch_no += 1;
    SET @range_end = @range_start + @batch_size - 1;

    UPDATE tgt
    SET
        [speed_mps] = TRY_CONVERT(DECIMAL(18,6), src.[robot_speed])
    FROM [DWD].[fact_robot_status] AS tgt
    JOIN [ODS].[robot_status_history] AS src
        ON src.[ods_row_id] = tgt.[source_ods_row_id]
    WHERE tgt.[source_schema] = N''ODS''
      AND tgt.[source_table] = N''robot_status_history''
      AND tgt.[source_ods_row_id] >= @range_start
      AND tgt.[source_ods_row_id] <= @range_end
      AND tgt.[speed_mps] IS NULL
      AND TRY_CONVERT(DECIMAL(18,6), src.[robot_speed]) IS NOT NULL;

    SET @rows_updated = @@ROWCOUNT;

    SET @message =
        N''Status speed repair batch '' + CONVERT(NVARCHAR(20), @batch_no) +
        N'' finished, range '' + CONVERT(NVARCHAR(30), @range_start) +
        N''-'' + CONVERT(NVARCHAR(30), @range_end) +
        N'', rows updated = '' + CONVERT(NVARCHAR(20), @rows_updated);

    RAISERROR(@message, 0, 1) WITH NOWAIT;

    SET @range_start = @range_end + 1;
END;
';
END;
GO

/* 8. Post-repair check. */
SELECT
    N'fact_amr_queue' AS table_name,
    COUNT_BIG(*) AS total_rows,
    SUM(CASE WHEN [event_time] IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS event_time_null_rows,
    SUM(CASE WHEN [queue_start_time] IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS queue_start_time_null_rows,
    MIN([event_time]) AS min_event_time,
    MAX([event_time]) AS max_event_time
FROM [DWD].[fact_amr_queue]
UNION ALL
SELECT
    N'fact_robot_status',
    COUNT_BIG(*),
    SUM(CASE WHEN [status_time] IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END),
    SUM(CASE WHEN COL_LENGTH(N'DWD.fact_robot_status', N'speed_mps') IS NOT NULL AND [speed_mps] IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END),
    MIN([status_time]),
    MAX([status_time])
FROM [DWD].[fact_robot_status];
GO
