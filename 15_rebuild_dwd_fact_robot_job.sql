USE IOT2020;
GO

/*
    Rebuild only DWD.fact_robot_job from ODS.robot_job_history.

    Default mode is DRY RUN.
    Set @execute = 1 only after reviewing the preview result.

    Why this script exists:
    - DWD.sp_load_dwd_all_incremental normally loads every enabled mapping.
    - This wrapper temporarily enables only:
          ODS.robot_job_history -> DWD.fact_robot_job
      then runs the existing DWD loader.

    Safety:
    - Does not DROP DWD.fact_robot_job.
    - Does not TRUNCATE DWD.fact_robot_job.
    - Deletes only rows whose source is ODS.robot_job_history.
    - Deletes in batches to reduce lock/log pressure.
    - Restores DWD.etl_watermark enabled-state after the rebuild.

    Expected runtime:
    - ODS.robot_job_history has tens of millions of rows, so this can take a long time.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @execute BIT = 1;              -- 0 = preview only, 1 = execute rebuild
DECLARE @delete_batch_size INT = 500000;

IF OBJECT_ID(N'[ODS].[robot_job_history]', N'U') IS NULL
BEGIN
    SELECT N'Missing source table: ODS.robot_job_history.' AS [error_message];
    RETURN;
END;

IF OBJECT_ID(N'[DWD].[fact_robot_job]', N'U') IS NULL
BEGIN
    SELECT N'Missing target table: DWD.fact_robot_job.' AS [error_message];
    RETURN;
END;

IF OBJECT_ID(N'[DWD].[etl_watermark]', N'U') IS NULL
BEGIN
    SELECT N'Missing control table: DWD.etl_watermark.' AS [error_message];
    RETURN;
END;

IF OBJECT_ID(N'[DWD].[sp_load_dwd_all_incremental]', N'P') IS NULL
BEGIN
    SELECT N'Missing loader procedure: DWD.sp_load_dwd_all_incremental.' AS [error_message];
    RETURN;
END;

IF NOT EXISTS (
    SELECT 1
    FROM [DWD].[etl_watermark]
    WHERE source_schema = N'ODS'
      AND source_table = N'robot_job_history'
      AND target_schema = N'DWD'
      AND target_table = N'fact_robot_job'
)
BEGIN
    SELECT N'Missing DWD.etl_watermark mapping: ODS.robot_job_history -> DWD.fact_robot_job.' AS [error_message];
    RETURN;
END;

/* 1. Pre-check: source/target size and current watermark. */
SELECT
    src.source_rows,
    src.min_ods_row_id,
    src.max_ods_row_id,
    tgt.target_rows,
    tgt.expected_source_rows_in_target,
    tgt.other_source_rows_in_target,
    wm.is_enabled AS current_is_enabled,
    wm.load_mode,
    wm.watermark_column,
    wm.last_bigint_value,
    wm.last_datetime_value,
    wm.last_load_time
FROM (
    SELECT
        COUNT_BIG(*) AS source_rows,
        MIN([ods_row_id]) AS min_ods_row_id,
        MAX([ods_row_id]) AS max_ods_row_id
    FROM [ODS].[robot_job_history]
) AS src
CROSS APPLY (
    SELECT
        COUNT_BIG(*) AS target_rows,
        SUM(CASE WHEN [source_schema] = N'ODS' AND [source_table] = N'robot_job_history' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS expected_source_rows_in_target,
        SUM(CASE WHEN [source_schema] <> N'ODS' OR [source_table] <> N'robot_job_history' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS other_source_rows_in_target
    FROM [DWD].[fact_robot_job]
) AS tgt
CROSS JOIN (
    SELECT TOP 1
        is_enabled,
        load_mode,
        watermark_column,
        last_bigint_value,
        last_datetime_value,
        last_load_time
    FROM [DWD].[etl_watermark]
    WHERE source_schema = N'ODS'
      AND source_table = N'robot_job_history'
      AND target_schema = N'DWD'
      AND target_table = N'fact_robot_job'
) AS wm;

/* 2. Required target columns. */
SELECT
    expected.column_name,
    CASE WHEN c.column_id IS NULL THEN 0 ELSE 1 END AS exists_in_fact_robot_job
FROM (
    VALUES
        (N'job_id'),
        (N'robot_id'),
        (N'robot_code'),
        (N'job_type_code'),
        (N'job_status'),
        (N'job_start_time'),
        (N'job_end_time'),
        (N'duration_seconds'),
        (N'result_code'),
        (N'result_message'),
        (N'source_schema'),
        (N'source_table'),
        (N'source_ods_row_id'),
        (N'source_ods_load_time'),
        (N'dwd_batch_id'),
        (N'dwd_hash_value')
) AS expected(column_name)
LEFT JOIN sys.columns AS c
    ON c.object_id = OBJECT_ID(N'[DWD].[fact_robot_job]')
   AND c.name = expected.column_name
ORDER BY expected.column_name;

/* 3. Candidate source columns actually present in ODS.robot_job_history. */
SELECT
    c.column_id,
    c.name AS source_column,
    ty.name AS data_type,
    c.max_length,
    c.precision,
    c.scale,
    c.is_nullable
FROM sys.columns AS c
JOIN sys.types AS ty
    ON ty.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID(N'[ODS].[robot_job_history]')
  AND (
         LOWER(c.name) IN (
             N'job_id',
             N'jobid',
             N'task_id',
             N'robot_id',
             N'robot_code',
             N'robot_sn',
             N'job_type_code',
             N'job_type',
             N'job_status',
             N'status',
             N'job_start_time',
             N'start_time',
             N'start_datetime',
             N'started_at',
             N'created_at',
             N'robot_datetime',
             N'pc_timestamp',
             N'job_end_time',
             N'end_time',
             N'end_datetime',
             N'finished_at',
             N'completed_at',
             N'updated_at',
             N'result_code',
             N'error_code',
             N'result_message',
             N'error_message'
         )
      OR LOWER(c.name) LIKE N'%job%'
      OR LOWER(c.name) LIKE N'%robot%'
      OR LOWER(c.name) LIKE N'%time%'
      OR LOWER(c.name) LIKE N'%date%'
      OR LOWER(c.name) LIKE N'%status%'
      OR LOWER(c.name) LIKE N'%result%'
      OR LOWER(c.name) LIKE N'%error%'
  )
ORDER BY c.column_id;

IF @execute = 0
BEGIN
    SELECT
        N'DRY_RUN_ONLY' AS execution_status,
        N'No data changed. If the preview is correct, set @execute = 1 and rerun this script.' AS message;
    RETURN;
END;

DECLARE
    @deleted_total BIGINT = 0,
    @deleted_this_batch INT = 1,
    @message NVARCHAR(4000),
    @started_at DATETIME2(3) = SYSDATETIME();

IF OBJECT_ID(N'tempdb..#wm_backup', N'U') IS NOT NULL
    DROP TABLE #wm_backup;

SELECT
    watermark_id,
    source_schema,
    source_table,
    target_schema,
    target_table,
    load_mode,
    watermark_column,
    last_bigint_value,
    last_datetime_value,
    last_load_time,
    is_enabled
INTO #wm_backup
FROM [DWD].[etl_watermark];

BEGIN TRY
    /*
        Temporarily leave only robot_job_history -> fact_robot_job enabled.
        The original enabled-state is restored after the rebuild.
    */
    UPDATE w
    SET is_enabled = CASE
            WHEN w.source_schema = N'ODS'
             AND w.source_table = N'robot_job_history'
             AND w.target_schema = N'DWD'
             AND w.target_table = N'fact_robot_job'
                THEN 1
            ELSE 0
        END
    FROM [DWD].[etl_watermark] AS w
    JOIN #wm_backup AS b
        ON b.watermark_id = w.watermark_id
    WHERE b.watermark_id IS NOT NULL;

    UPDATE [DWD].[etl_watermark]
    SET
        load_mode = N'ID_INCREMENT',
        watermark_column = N'ods_row_id',
        last_bigint_value = 0,
        last_datetime_value = NULL,
        last_load_time = NULL
    WHERE source_schema = N'ODS'
      AND source_table = N'robot_job_history'
      AND target_schema = N'DWD'
      AND target_table = N'fact_robot_job';

    RAISERROR(N'Start deleting existing DWD.fact_robot_job rows for source ODS.robot_job_history...', 0, 1) WITH NOWAIT;

    WHILE @deleted_this_batch > 0
    BEGIN
        DELETE TOP (@delete_batch_size)
        FROM [DWD].[fact_robot_job]
        WHERE [source_schema] = N'ODS'
          AND [source_table] = N'robot_job_history';

        SET @deleted_this_batch = @@ROWCOUNT;
        SET @deleted_total += @deleted_this_batch;

        IF @deleted_this_batch > 0
        BEGIN
            SET @message = N'Deleted rows so far from DWD.fact_robot_job = ' + CONVERT(NVARCHAR(30), @deleted_total);
            RAISERROR(@message, 0, 1) WITH NOWAIT;
        END;
    END;

    RAISERROR(N'Start reloading DWD.fact_robot_job from ODS.robot_job_history...', 0, 1) WITH NOWAIT;

    EXEC [DWD].[sp_load_dwd_all_incremental];

    DECLARE
        @new_last_bigint_value BIGINT,
        @new_last_datetime_value DATETIME2(3),
        @new_last_load_time DATETIME2(3);

    SELECT
        @new_last_bigint_value = last_bigint_value,
        @new_last_datetime_value = last_datetime_value,
        @new_last_load_time = last_load_time
    FROM [DWD].[etl_watermark]
    WHERE source_schema = N'ODS'
      AND source_table = N'robot_job_history'
      AND target_schema = N'DWD'
      AND target_table = N'fact_robot_job';

    /*
        Restore all watermark rows.
        For robot_job_history, keep the rebuilt high-water mark, but restore its original enabled-state.
    */
    UPDATE w
    SET
        w.load_mode = b.load_mode,
        w.watermark_column = b.watermark_column,
        w.last_bigint_value = CASE
            WHEN w.source_schema = N'ODS'
             AND w.source_table = N'robot_job_history'
             AND w.target_schema = N'DWD'
             AND w.target_table = N'fact_robot_job'
                THEN @new_last_bigint_value
            ELSE b.last_bigint_value
        END,
        w.last_datetime_value = CASE
            WHEN w.source_schema = N'ODS'
             AND w.source_table = N'robot_job_history'
             AND w.target_schema = N'DWD'
             AND w.target_table = N'fact_robot_job'
                THEN @new_last_datetime_value
            ELSE b.last_datetime_value
        END,
        w.last_load_time = CASE
            WHEN w.source_schema = N'ODS'
             AND w.source_table = N'robot_job_history'
             AND w.target_schema = N'DWD'
             AND w.target_table = N'fact_robot_job'
                THEN @new_last_load_time
            ELSE b.last_load_time
        END,
        w.is_enabled = b.is_enabled
    FROM [DWD].[etl_watermark] AS w
    JOIN #wm_backup AS b
        ON b.watermark_id = w.watermark_id
    WHERE b.watermark_id IS NOT NULL;

    RAISERROR(N'Rebuild finished. Running validation...', 0, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    IF OBJECT_ID(N'tempdb..#wm_backup', N'U') IS NOT NULL
    BEGIN
        UPDATE w
        SET
            w.load_mode = b.load_mode,
            w.watermark_column = b.watermark_column,
            w.last_bigint_value = b.last_bigint_value,
            w.last_datetime_value = b.last_datetime_value,
            w.last_load_time = b.last_load_time,
            w.is_enabled = b.is_enabled
        FROM [DWD].[etl_watermark] AS w
        JOIN #wm_backup AS b
            ON b.watermark_id = w.watermark_id
        WHERE b.watermark_id IS NOT NULL;
    END;

    SELECT
        ERROR_NUMBER() AS [error_number],
        ERROR_LINE() AS [error_line],
        ERROR_MESSAGE() AS [error_message];
    RETURN;
END CATCH;

/* 4. Post-check. */
SELECT
    src.source_rows,
    src.max_ods_row_id,
    tgt.target_rows,
    tgt.expected_source_rows_in_target,
    tgt.other_source_rows_in_target,
    wm.last_bigint_value,
    wm.last_load_time,
    DATEDIFF(SECOND, @started_at, SYSDATETIME()) AS elapsed_seconds
FROM (
    SELECT
        COUNT_BIG(*) AS source_rows,
        MAX([ods_row_id]) AS max_ods_row_id
    FROM [ODS].[robot_job_history]
) AS src
CROSS APPLY (
    SELECT
        COUNT_BIG(*) AS target_rows,
        SUM(CASE WHEN [source_schema] = N'ODS' AND [source_table] = N'robot_job_history' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS expected_source_rows_in_target,
        SUM(CASE WHEN [source_schema] <> N'ODS' OR [source_table] <> N'robot_job_history' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS other_source_rows_in_target
    FROM [DWD].[fact_robot_job]
) AS tgt
CROSS JOIN (
    SELECT TOP 1
        last_bigint_value,
        last_load_time
    FROM [DWD].[etl_watermark]
    WHERE source_schema = N'ODS'
      AND source_table = N'robot_job_history'
      AND target_schema = N'DWD'
      AND target_table = N'fact_robot_job'
) AS wm;

SELECT
    duplicate_source_row_count = COUNT_BIG(*)
FROM (
    SELECT
        source_schema,
        source_table,
        source_ods_row_id
    FROM [DWD].[fact_robot_job]
    WHERE source_ods_row_id IS NOT NULL
    GROUP BY
        source_schema,
        source_table,
        source_ods_row_id
    HAVING COUNT_BIG(*) > 1
) AS d;

SELECT TOP 20
    batch_id,
    source_table,
    target_table,
    load_mode,
    rows_inserted,
    rows_deleted,
    load_status,
    error_message
FROM [DWD].[etl_load_log]
WHERE source_schema = N'ODS'
  AND source_table = N'robot_job_history'
  AND target_schema = N'DWD'
  AND target_table = N'fact_robot_job'
ORDER BY batch_id DESC;
GO

