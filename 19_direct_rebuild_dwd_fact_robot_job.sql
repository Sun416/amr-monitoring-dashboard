USE IOT2020;
GO

/*
    Direct rebuild for DWD.fact_robot_job from ODS.robot_job_history.

    Purpose:
    - Bypass DWD.sp_load_dwd_all_incremental because its current mapping/log shows
      robot_job_history -> fact_robot_job SUCCESS with rows_inserted = 0.
    - Refill DWD.fact_robot_job directly from ODS.robot_job_history.

    Scope:
    - Deletes only DWD.fact_robot_job rows where:
          source_schema = N'ODS'
      AND source_table  = N'robot_job_history'
    - Does not delete ODS data.
    - Does not drop or recreate DWD.fact_robot_job.

    Runtime:
    - ODS.robot_job_history has tens of millions of rows.
    - This script inserts in ods_row_id ranges to reduce single-statement pressure.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE
    @batch_size BIGINT = 500000,
    @delete_batch_size INT = 500000,
    @min_ods_row_id BIGINT,
    @max_ods_row_id BIGINT,
    @from_ods_row_id BIGINT,
    @to_ods_row_id BIGINT,
    @rows_this_batch BIGINT = 0,
    @rows_inserted_total BIGINT = 0,
    @rows_deleted_total BIGINT = 0,
    @deleted_this_batch INT = 1,
    @started_at DATETIME2(3) = SYSDATETIME(),
    @batch_id BIGINT = NULL,
    @message NVARCHAR(4000);

IF OBJECT_ID(N'[ODS].[robot_job_history]', N'U') IS NULL
BEGIN
    SELECT N'Missing source table: ODS.robot_job_history.' AS [message];
    RETURN;
END;

IF OBJECT_ID(N'[DWD].[fact_robot_job]', N'U') IS NULL
BEGIN
    SELECT N'Missing target table: DWD.fact_robot_job.' AS [message];
    RETURN;
END;

IF COL_LENGTH(N'ODS.robot_job_history', N'ods_row_id') IS NULL
BEGIN
    SELECT N'Missing required source column: ODS.robot_job_history.ods_row_id.' AS [message];
    RETURN;
END;

DECLARE @required_target_columns TABLE (
    column_name SYSNAME NOT NULL
);

INSERT INTO @required_target_columns (column_name)
VALUES
    (N'job_id'),
    (N'robot_id'),
    (N'robot_code'),
    (N'job_type_code'),
    (N'job_status'),
    (N'job_start_time'),
    (N'source_schema'),
    (N'source_table'),
    (N'source_ods_row_id'),
    (N'source_ods_load_time'),
    (N'dwd_batch_id'),
    (N'dwd_hash_value');

IF EXISTS (
    SELECT 1
    FROM @required_target_columns AS r
    LEFT JOIN sys.columns AS c
        ON c.object_id = OBJECT_ID(N'[DWD].[fact_robot_job]')
       AND c.name = r.column_name
    WHERE c.column_id IS NULL
)
BEGIN
    SELECT
        r.column_name AS missing_target_column
    FROM @required_target_columns AS r
    LEFT JOIN sys.columns AS c
        ON c.object_id = OBJECT_ID(N'[DWD].[fact_robot_job]')
       AND c.name = r.column_name
    WHERE c.column_id IS NULL
    ORDER BY r.column_name;

    RETURN;
END;

SELECT
    @min_ods_row_id = MIN(TRY_CONVERT(BIGINT, [ods_row_id])),
    @max_ods_row_id = MAX(TRY_CONVERT(BIGINT, [ods_row_id]))
FROM [ODS].[robot_job_history];

IF @max_ods_row_id IS NULL
BEGIN
    SELECT N'ODS.robot_job_history has no rows to load.' AS [message];
    RETURN;
END;

DECLARE
    /*
        robot_job_history.id and ods_row_id are history-row identifiers, not proven
        job-execution identifiers. Keep job_id NULL when no real job_id exists.
    */
    @job_id_expr NVARCHAR(MAX) = N'NULL',
    @robot_id_expr NVARCHAR(MAX) = N'NULL',
    @robot_code_expr NVARCHAR(MAX) = N'NULL',
    @job_type_code_expr NVARCHAR(MAX) = N'NULL',
    @job_status_expr NVARCHAR(MAX) = N'NULL',
    @job_start_time_expr NVARCHAR(MAX) = N'NULL',
    @job_end_time_expr NVARCHAR(MAX) = N'NULL',
    @duration_seconds_expr NVARCHAR(MAX) = N'NULL',
    @result_code_expr NVARCHAR(MAX) = N'NULL',
    @result_message_expr NVARCHAR(MAX) = N'NULL',
    @source_ods_load_time_expr NVARCHAR(MAX) = N'NULL';

IF COL_LENGTH(N'ODS.robot_job_history', N'job_id') IS NOT NULL SET @job_id_expr = N'TRY_CONVERT(NVARCHAR(100), src.[job_id])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'JobID') IS NOT NULL SET @job_id_expr = N'TRY_CONVERT(NVARCHAR(100), src.[JobID])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'task_id') IS NOT NULL SET @job_id_expr = N'TRY_CONVERT(NVARCHAR(100), src.[task_id])';

IF COL_LENGTH(N'ODS.robot_job_history', N'robot_id') IS NOT NULL SET @robot_id_expr = N'TRY_CONVERT(NVARCHAR(100), src.[robot_id])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'RobotID') IS NOT NULL SET @robot_id_expr = N'TRY_CONVERT(NVARCHAR(100), src.[RobotID])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'amr_id') IS NOT NULL SET @robot_id_expr = N'TRY_CONVERT(NVARCHAR(100), src.[amr_id])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'AMR_ID') IS NOT NULL SET @robot_id_expr = N'TRY_CONVERT(NVARCHAR(100), src.[AMR_ID])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'agv_id') IS NOT NULL SET @robot_id_expr = N'TRY_CONVERT(NVARCHAR(100), src.[agv_id])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'device_id') IS NOT NULL SET @robot_id_expr = N'TRY_CONVERT(NVARCHAR(100), src.[device_id])';

IF COL_LENGTH(N'ODS.robot_job_history', N'robot_code') IS NOT NULL SET @robot_code_expr = N'TRY_CONVERT(NVARCHAR(100), src.[robot_code])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'robot_no') IS NOT NULL SET @robot_code_expr = N'TRY_CONVERT(NVARCHAR(100), src.[robot_no])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'robot_sn') IS NOT NULL SET @robot_code_expr = N'TRY_CONVERT(NVARCHAR(100), src.[robot_sn])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'amr_id') IS NOT NULL SET @robot_code_expr = N'TRY_CONVERT(NVARCHAR(100), src.[amr_id])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'AMR_ID') IS NOT NULL SET @robot_code_expr = N'TRY_CONVERT(NVARCHAR(100), src.[AMR_ID])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'robot_id') IS NOT NULL SET @robot_code_expr = N'TRY_CONVERT(NVARCHAR(100), src.[robot_id])';

IF COL_LENGTH(N'ODS.robot_job_history', N'job_type_code') IS NOT NULL SET @job_type_code_expr = N'TRY_CONVERT(NVARCHAR(100), src.[job_type_code])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'job_type') IS NOT NULL SET @job_type_code_expr = N'TRY_CONVERT(NVARCHAR(100), src.[job_type])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'type') IS NOT NULL SET @job_type_code_expr = N'TRY_CONVERT(NVARCHAR(100), src.[type])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'job_name') IS NOT NULL SET @job_type_code_expr = N'NULLIF(NULLIF(LTRIM(RTRIM(TRY_CONVERT(NVARCHAR(100), src.[job_name]))), N''''), N''-'')';

IF COL_LENGTH(N'ODS.robot_job_history', N'job_status') IS NOT NULL SET @job_status_expr = N'TRY_CONVERT(NVARCHAR(100), src.[job_status])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'status') IS NOT NULL SET @job_status_expr = N'TRY_CONVERT(NVARCHAR(100), src.[status])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'state') IS NOT NULL SET @job_status_expr = N'TRY_CONVERT(NVARCHAR(100), src.[state])';

IF COL_LENGTH(N'ODS.robot_job_history', N'job_start_time') IS NOT NULL SET @job_start_time_expr = N'TRY_CONVERT(DATETIME2(3), src.[job_start_time])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'start_time') IS NOT NULL SET @job_start_time_expr = N'TRY_CONVERT(DATETIME2(3), src.[start_time])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'start_datetime') IS NOT NULL SET @job_start_time_expr = N'TRY_CONVERT(DATETIME2(3), src.[start_datetime])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'started_at') IS NOT NULL SET @job_start_time_expr = N'TRY_CONVERT(DATETIME2(3), src.[started_at])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'created_at') IS NOT NULL SET @job_start_time_expr = N'TRY_CONVERT(DATETIME2(3), src.[created_at])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'robot_datetime') IS NOT NULL SET @job_start_time_expr = N'TRY_CONVERT(DATETIME2(3), src.[robot_datetime])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'pc_timestamp') IS NOT NULL SET @job_start_time_expr = N'TRY_CONVERT(DATETIME2(3), src.[pc_timestamp])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'Date_Stamp') IS NOT NULL SET @job_start_time_expr = N'TRY_CONVERT(DATETIME2(3), src.[Date_Stamp])';

IF COL_LENGTH(N'ODS.robot_job_history', N'job_end_time') IS NOT NULL SET @job_end_time_expr = N'TRY_CONVERT(DATETIME2(3), src.[job_end_time])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'end_time') IS NOT NULL SET @job_end_time_expr = N'TRY_CONVERT(DATETIME2(3), src.[end_time])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'end_datetime') IS NOT NULL SET @job_end_time_expr = N'TRY_CONVERT(DATETIME2(3), src.[end_datetime])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'finished_at') IS NOT NULL SET @job_end_time_expr = N'TRY_CONVERT(DATETIME2(3), src.[finished_at])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'completed_at') IS NOT NULL SET @job_end_time_expr = N'TRY_CONVERT(DATETIME2(3), src.[completed_at])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'updated_at') IS NOT NULL SET @job_end_time_expr = N'TRY_CONVERT(DATETIME2(3), src.[updated_at])';

IF @job_start_time_expr <> N'NULL' AND @job_end_time_expr <> N'NULL'
BEGIN
    SET @duration_seconds_expr =
        N'CASE
              WHEN ' + @job_start_time_expr + N' IS NOT NULL
               AND ' + @job_end_time_expr + N' IS NOT NULL
                  THEN DATEDIFF(SECOND, ' + @job_start_time_expr + N', ' + @job_end_time_expr + N')
              ELSE NULL
          END';
END;

IF COL_LENGTH(N'ODS.robot_job_history', N'result_code') IS NOT NULL SET @result_code_expr = N'TRY_CONVERT(NVARCHAR(100), src.[result_code])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'error_code') IS NOT NULL SET @result_code_expr = N'TRY_CONVERT(NVARCHAR(100), src.[error_code])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'err_code') IS NOT NULL SET @result_code_expr = N'TRY_CONVERT(NVARCHAR(100), src.[err_code])';

IF COL_LENGTH(N'ODS.robot_job_history', N'result_message') IS NOT NULL SET @result_message_expr = N'TRY_CONVERT(NVARCHAR(1000), src.[result_message])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'error_message') IS NOT NULL SET @result_message_expr = N'TRY_CONVERT(NVARCHAR(1000), src.[error_message])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'err_msg') IS NOT NULL SET @result_message_expr = N'TRY_CONVERT(NVARCHAR(1000), src.[err_msg])';
ELSE IF COL_LENGTH(N'ODS.robot_job_history', N'message') IS NOT NULL SET @result_message_expr = N'TRY_CONVERT(NVARCHAR(1000), src.[message])';

IF COL_LENGTH(N'ODS.robot_job_history', N'ods_load_time') IS NOT NULL SET @source_ods_load_time_expr = N'TRY_CONVERT(DATETIME2(3), src.[ods_load_time])';

SELECT
    @min_ods_row_id AS min_ods_row_id,
    @max_ods_row_id AS max_ods_row_id,
    @batch_size AS insert_batch_size,
    @job_id_expr AS job_id_expr,
    @robot_id_expr AS robot_id_expr,
    @robot_code_expr AS robot_code_expr,
    @job_type_code_expr AS job_type_code_expr,
    @job_status_expr AS job_status_expr,
    @job_start_time_expr AS job_start_time_expr,
    @job_end_time_expr AS job_end_time_expr,
    @duration_seconds_expr AS duration_seconds_expr,
    @result_code_expr AS result_code_expr,
    @result_message_expr AS result_message_expr,
    @source_ods_load_time_expr AS source_ods_load_time_expr;

BEGIN TRY
    IF OBJECT_ID(N'[DWD].[etl_batch]', N'U') IS NOT NULL
    BEGIN
        INSERT INTO [DWD].[etl_batch] (batch_status)
        VALUES (N'RUNNING');

        SET @batch_id = CONVERT(BIGINT, SCOPE_IDENTITY());
    END;

    WHILE @deleted_this_batch > 0
    BEGIN
        DELETE TOP (@delete_batch_size)
        FROM [DWD].[fact_robot_job]
        WHERE [source_schema] = N'ODS'
          AND [source_table] = N'robot_job_history';

        SET @deleted_this_batch = @@ROWCOUNT;
        SET @rows_deleted_total = @rows_deleted_total + @deleted_this_batch;

        IF @deleted_this_batch > 0
        BEGIN
            SET @message = N'Deleted DWD.fact_robot_job rows = ' + CONVERT(NVARCHAR(30), @rows_deleted_total);
            RAISERROR(@message, 0, 1) WITH NOWAIT;
        END;
    END;

    SET @from_ods_row_id = @min_ods_row_id;

    WHILE @from_ods_row_id <= @max_ods_row_id
    BEGIN
        SET @to_ods_row_id = @from_ods_row_id + @batch_size - 1;

        DECLARE @insert_sql NVARCHAR(MAX);

        SET @insert_sql = N'
INSERT INTO [DWD].[fact_robot_job] (
    job_id,
    robot_id,
    robot_code,
    job_type_code,
    job_status,
    job_start_time,
    source_schema,
    source_table,
    source_ods_row_id,
    source_ods_load_time,
    dwd_batch_id,
    dwd_hash_value
)
SELECT
    ' + @job_id_expr + N',
    ' + @robot_id_expr + N',
    ' + @robot_code_expr + N',
    ' + @job_type_code_expr + N',
    ' + @job_status_expr + N',
    ' + @job_start_time_expr + N',
    N''ODS'',
    N''robot_job_history'',
    src.[ods_row_id],
    ' + @source_ods_load_time_expr + N',
    @p_batch_id,
    HASHBYTES(''SHA2_256'', CONCAT(N''ODS|robot_job_history|'', TRY_CONVERT(NVARCHAR(50), src.[ods_row_id])))
FROM [ODS].[robot_job_history] AS src
WHERE src.[ods_row_id] >= @p_from_ods_row_id
  AND src.[ods_row_id] <= @p_to_ods_row_id
  AND NOT EXISTS (
      SELECT 1
      FROM [DWD].[fact_robot_job] AS tgt
      WHERE tgt.[source_schema] = N''ODS''
        AND tgt.[source_table] = N''robot_job_history''
        AND tgt.[source_ods_row_id] = src.[ods_row_id]
  );

SET @p_rows_this_batch = @@ROWCOUNT;';

        SET @rows_this_batch = 0;

        EXEC sys.sp_executesql
            @insert_sql,
            N'@p_batch_id BIGINT,
              @p_from_ods_row_id BIGINT,
              @p_to_ods_row_id BIGINT,
              @p_rows_this_batch BIGINT OUTPUT',
            @p_batch_id = @batch_id,
            @p_from_ods_row_id = @from_ods_row_id,
            @p_to_ods_row_id = @to_ods_row_id,
            @p_rows_this_batch = @rows_this_batch OUTPUT;

        SET @rows_inserted_total = @rows_inserted_total + @rows_this_batch;

        SET @message =
            N'Inserted DWD.fact_robot_job rows = ' + CONVERT(NVARCHAR(30), @rows_inserted_total) +
            N', current ods_row_id range = ' + CONVERT(NVARCHAR(30), @from_ods_row_id) +
            N' - ' + CONVERT(NVARCHAR(30), @to_ods_row_id);
        RAISERROR(@message, 0, 1) WITH NOWAIT;

        SET @from_ods_row_id = @to_ods_row_id + 1;
    END;

    IF OBJECT_ID(N'[DWD].[etl_watermark]', N'U') IS NOT NULL
    BEGIN
        UPDATE [DWD].[etl_watermark]
        SET
            last_bigint_value = @max_ods_row_id,
            last_datetime_value = NULL,
            last_load_time = SYSDATETIME()
        WHERE source_schema = N'ODS'
          AND source_table = N'robot_job_history'
          AND target_schema = N'DWD'
          AND target_table = N'fact_robot_job';
    END;

    IF OBJECT_ID(N'[DWD].[etl_load_log]', N'U') IS NOT NULL
    BEGIN
        INSERT INTO [DWD].[etl_load_log] (
            batch_id,
            source_schema,
            source_table,
            target_schema,
            target_table,
            load_mode,
            load_start_time,
            load_end_time,
            rows_inserted,
            rows_updated,
            rows_deleted,
            load_status,
            error_message
        )
        VALUES (
            @batch_id,
            N'ODS',
            N'robot_job_history',
            N'DWD',
            N'fact_robot_job',
            N'DIRECT_REBUILD',
            @started_at,
            SYSDATETIME(),
            @rows_inserted_total,
            0,
            @rows_deleted_total,
            N'SUCCESS',
            NULL
        );
    END;

    IF @batch_id IS NOT NULL
    BEGIN
        UPDATE [DWD].[etl_batch]
        SET
            batch_end_time = SYSDATETIME(),
            batch_status = N'SUCCESS',
            error_message = NULL
        WHERE batch_id = @batch_id;
    END;
END TRY
BEGIN CATCH
    IF @batch_id IS NOT NULL
    BEGIN
        UPDATE [DWD].[etl_batch]
        SET
            batch_end_time = SYSDATETIME(),
            batch_status = N'FAILED',
            error_message = ERROR_MESSAGE()
        WHERE batch_id = @batch_id;
    END;

    SELECT
        ERROR_NUMBER() AS [error_number],
        ERROR_LINE() AS [error_line],
        ERROR_MESSAGE() AS [error_message],
        @rows_inserted_total AS rows_inserted_before_error,
        @rows_deleted_total AS rows_deleted_before_error;

    RETURN;
END CATCH;

SELECT
    src.source_rows,
    src.max_ods_row_id,
    tgt.target_rows,
    tgt.min_source_ods_row_id,
    tgt.max_source_ods_row_id,
    @rows_inserted_total AS rows_inserted_this_run,
    @rows_deleted_total AS rows_deleted_this_run,
    DATEDIFF(SECOND, @started_at, SYSDATETIME()) AS elapsed_seconds
FROM (
    SELECT
        COUNT_BIG(*) AS source_rows,
        MAX(TRY_CONVERT(BIGINT, [ods_row_id])) AS max_ods_row_id
    FROM [ODS].[robot_job_history]
) AS src
CROSS APPLY (
    SELECT
        COUNT_BIG(*) AS target_rows,
        MIN([source_ods_row_id]) AS min_source_ods_row_id,
        MAX([source_ods_row_id]) AS max_source_ods_row_id
    FROM [DWD].[fact_robot_job]
    WHERE [source_schema] = N'ODS'
      AND [source_table] = N'robot_job_history'
) AS tgt;

SELECT
    duplicate_source_row_count = COUNT_BIG(*)
FROM (
    SELECT
        [source_schema],
        [source_table],
        [source_ods_row_id]
    FROM [DWD].[fact_robot_job]
    WHERE [source_schema] = N'ODS'
      AND [source_table] = N'robot_job_history'
      AND [source_ods_row_id] IS NOT NULL
    GROUP BY
        [source_schema],
        [source_table],
        [source_ods_row_id]
    HAVING COUNT_BIG(*) > 1
) AS d;
GO
