USE [IOT2020];
GO

/*
    Install and preview the resumable historical repair for DWD.fact_robot_job.

    Safety defaults:
      - The EXEC at the end uses @execute = 0 and changes no business data.
      - To start the real backfill, change only @execute to 1.
      - Every batch commits independently. Progress is saved after every batch,
        so a cancelled run can resume without deleting or rebuilding the table.
*/

/*
    DataGrip compatibility: keep the complete procedure definition inside one
    executable statement so current-statement parsing cannot split JOIN/ON.
*/
EXEC sys.sp_executesql N'CREATE OR ALTER PROCEDURE [DWD].[sp_backfill_robot_job_type_mode]
    @execute BIT = 0,
    @batch_size INT = 100000,
    @start_after_source_ods_row_id BIGINT = NULL,
    @end_at_source_ods_row_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @pipeline_name SYSNAME = N''robot_job_type_mode'',
        @lock_result INT,
        @saved_backfill_watermark BIGINT,
        @effective_start_after BIGINT,
        @effective_end_at BIGINT,
        @cursor BIGINT,
        @batch_max BIGINT,
        @read_rows INT,
        @updated_rows INT,
        @total_read BIGINT = 0,
        @total_updated BIGINT = 0,
        @started_at DATETIME2(3) = SYSDATETIME(),
        @error_message NVARCHAR(4000);

    IF @execute NOT IN (0, 1)
    BEGIN
        RAISERROR(N''@execute must be 0 or 1.'', 16, 1);
        RETURN;
    END;

    IF @batch_size < 1 OR @batch_size > 1000000
    BEGIN
        RAISERROR(N''@batch_size must be between 1 and 1000000.'', 16, 1);
        RETURN;
    END;

    IF OBJECT_ID(N''[ODS].[robot_job_history]'', N''U'') IS NULL
       OR OBJECT_ID(N''[ODS].[robot_status_history]'', N''U'') IS NULL
       OR OBJECT_ID(N''[ODS].[AMR_Robot_Mode]'', N''U'') IS NULL
       OR OBJECT_ID(N''[DWD].[fact_robot_job]'', N''U'') IS NULL
       OR OBJECT_ID(N''[DWD].[etl_robot_job_mode_watermark]'', N''U'') IS NULL
    BEGIN
        RAISERROR(N''Required object is missing. Run scripts 40, 41, and 42 first.'', 16, 1);
        RETURN;
    END;

    IF COL_LENGTH(N''DWD.fact_robot_job'', N''robot_mode_id'') IS NULL
       OR COL_LENGTH(N''DWD.fact_robot_job'', N''robot_mode_detail'') IS NULL
       OR COL_LENGTH(N''DWD.fact_robot_job'', N''source_status_ods_row_id'') IS NULL
    BEGIN
        RAISERROR(N''DWD mode columns are missing. Run script 41 first.'', 16, 1);
        RETURN;
    END;

    IF NOT EXISTS (
        SELECT 1
        FROM sys.indexes AS i
        WHERE i.[object_id] = OBJECT_ID(N''[ODS].[robot_status_history]'')
          AND i.[name] = N''IX_ODS_robot_status_history_amr_time''
    )
    BEGIN
        RAISERROR(N''Required ODS status lookup index is missing. Finish script 41 first.'', 16, 1);
        RETURN;
    END;

    SELECT
        @saved_backfill_watermark = w.[last_backfill_source_ods_row_id]
    FROM [DWD].[etl_robot_job_mode_watermark] AS w
    WHERE w.[pipeline_name] = @pipeline_name;

    IF @saved_backfill_watermark IS NULL
    BEGIN
        RAISERROR(N''Robot job/mode watermark row is missing.'', 16, 1);
        RETURN;
    END;

    SET @effective_start_after = COALESCE(
        @start_after_source_ods_row_id,
        @saved_backfill_watermark,
        0
    );

    IF @end_at_source_ods_row_id IS NULL
    BEGIN
        SELECT
            @effective_end_at = ISNULL(MAX(f.[source_ods_row_id]), @effective_start_after)
        FROM [DWD].[fact_robot_job] AS f
        WHERE f.[source_schema] = N''ODS''
          AND f.[source_table] = N''robot_job_history'';
    END;
    ELSE
    BEGIN
        SET @effective_end_at = @end_at_source_ods_row_id;
    END;

    /* Preview always appears before any update. */
    SELECT
        @execute AS [execute_flag],
        @batch_size AS [batch_size],
        @saved_backfill_watermark AS [saved_backfill_watermark],
        @effective_start_after AS [planned_start_after_source_ods_row_id],
        @effective_end_at AS [planned_end_at_source_ods_row_id],
        CASE
            WHEN @effective_end_at > @effective_start_after
                THEN @effective_end_at - @effective_start_after
            ELSE 0
        END AS [upper_bound_span_not_exact_row_count];

    SELECT TOP (100)
        f.[job_fact_id],
        f.[source_ods_row_id],
        f.[job_type_code] AS [current_job_type_code],
        CASE
            WHEN NULLIF(LTRIM(RTRIM(j.[job_name])), N'''') IS NULL THEN NULL
            WHEN UPPER(LTRIM(RTRIM(j.[job_name]))) IN (N''-'', N''NULL'', N''UNDEFINED'') THEN NULL
            ELSE LTRIM(RTRIM(j.[job_name]))
        END AS [proposed_job_type_code],
        f.[robot_mode_id] AS [current_robot_mode_id],
        CONVERT(NVARCHAR(100), s.[robot_mode]) AS [proposed_robot_mode_id],
        f.[robot_mode_detail] AS [current_robot_mode_detail],
        m.[Mode_Detail] AS [proposed_robot_mode_detail],
        s.[ods_row_id] AS [proposed_source_status_ods_row_id]
    FROM [DWD].[fact_robot_job] AS f
    INNER JOIN [ODS].[robot_job_history] AS j
        ON j.[ods_row_id] = f.[source_ods_row_id]
    OUTER APPLY (
        SELECT TOP (1)
            h.[ods_row_id],
            h.[robot_mode]
        FROM [ODS].[robot_status_history] AS h
        WHERE h.[amr_id] = j.[amr_id]
          AND h.[pc_timestamp] = j.[pc_timestamp]
        ORDER BY h.[ods_row_id] DESC
    ) AS s
    OUTER APPLY (
        SELECT TOP (1)
            d.[Mode_Detail]
        FROM [ODS].[AMR_Robot_Mode] AS d
        WHERE d.[Mode_ID] = CONVERT(NVARCHAR(100), s.[robot_mode])
        ORDER BY d.[ods_row_id] DESC
    ) AS m
    WHERE f.[source_schema] = N''ODS''
      AND f.[source_table] = N''robot_job_history''
      AND f.[source_ods_row_id] > @effective_start_after
      AND f.[source_ods_row_id] <= @effective_end_at
    ORDER BY f.[source_ods_row_id];

    IF @execute = 0
    BEGIN
        RAISERROR(N''Preview only. Set @execute = 1 to start the resumable historical backfill.'', 10, 1) WITH NOWAIT;
        RETURN;
    END;

    IF @effective_end_at <= @effective_start_after
    BEGIN
        RAISERROR(N''No historical source row remains in the selected range.'', 10, 1) WITH NOWAIT;
        RETURN;
    END;

    EXEC @lock_result = sys.sp_getapplock
        @Resource = N''DWD.sp_backfill_robot_job_type_mode'',
        @LockMode = N''Exclusive'',
        @LockOwner = N''Session'',
        @LockTimeout = 0;

    IF @lock_result < 0
    BEGIN
        RAISERROR(N''Robot job/mode historical backfill is already running.'', 16, 1);
        RETURN;
    END;

    BEGIN TRY
        SET @cursor = @effective_start_after;

        CREATE TABLE #job_mode_backfill_batch (
            [job_fact_id] BIGINT NOT NULL PRIMARY KEY,
            [source_ods_row_id] BIGINT NOT NULL,
            [job_type_code] NVARCHAR(100) NULL,
            [robot_mode_id] NVARCHAR(100) NULL,
            [robot_mode_detail] NVARCHAR(200) NULL,
            [source_status_ods_row_id] BIGINT NULL
        );

        WHILE @cursor < @effective_end_at
        BEGIN
            TRUNCATE TABLE #job_mode_backfill_batch;

            INSERT INTO #job_mode_backfill_batch (
                [job_fact_id],
                [source_ods_row_id],
                [job_type_code],
                [robot_mode_id],
                [robot_mode_detail],
                [source_status_ods_row_id]
            )
            SELECT TOP (@batch_size)
                f.[job_fact_id],
                f.[source_ods_row_id],
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(j.[job_name])), N'''') IS NULL THEN NULL
                    WHEN UPPER(LTRIM(RTRIM(j.[job_name]))) IN (N''-'', N''NULL'', N''UNDEFINED'') THEN NULL
                    ELSE LTRIM(RTRIM(j.[job_name]))
                END AS [job_type_code],
                CONVERT(NVARCHAR(100), s.[robot_mode]) AS [robot_mode_id],
                m.[Mode_Detail] AS [robot_mode_detail],
                s.[ods_row_id] AS [source_status_ods_row_id]
            FROM [DWD].[fact_robot_job] AS f
            INNER JOIN [ODS].[robot_job_history] AS j
                ON j.[ods_row_id] = f.[source_ods_row_id]
            OUTER APPLY (
                SELECT TOP (1)
                    h.[ods_row_id],
                    h.[robot_mode]
                FROM [ODS].[robot_status_history] AS h
                WHERE h.[amr_id] = j.[amr_id]
                  AND h.[pc_timestamp] = j.[pc_timestamp]
                ORDER BY h.[ods_row_id] DESC
            ) AS s
            OUTER APPLY (
                SELECT TOP (1)
                    d.[Mode_Detail]
                FROM [ODS].[AMR_Robot_Mode] AS d
                WHERE d.[Mode_ID] = CONVERT(NVARCHAR(100), s.[robot_mode])
                ORDER BY d.[ods_row_id] DESC
            ) AS m
            WHERE f.[source_schema] = N''ODS''
              AND f.[source_table] = N''robot_job_history''
              AND f.[source_ods_row_id] > @cursor
              AND f.[source_ods_row_id] <= @effective_end_at
            ORDER BY f.[source_ods_row_id];

            SET @read_rows = @@ROWCOUNT;

            IF @read_rows = 0
                BREAK;

            SELECT
                @batch_max = MAX(b.[source_ods_row_id])
            FROM #job_mode_backfill_batch AS b;

            UPDATE f
            SET
                f.[job_type_code] = b.[job_type_code],
                f.[robot_mode_id] = b.[robot_mode_id],
                f.[robot_mode_detail] = b.[robot_mode_detail],
                f.[source_status_ods_row_id] = b.[source_status_ods_row_id],
                f.[dwd_load_time] = SYSDATETIME()
            FROM [DWD].[fact_robot_job] AS f
            INNER JOIN #job_mode_backfill_batch AS b
                ON b.[job_fact_id] = f.[job_fact_id]
            WHERE ISNULL(f.[job_type_code], N'''') <> ISNULL(b.[job_type_code], N'''')
               OR ISNULL(f.[robot_mode_id], N'''') <> ISNULL(b.[robot_mode_id], N'''')
               OR ISNULL(f.[robot_mode_detail], N'''') <> ISNULL(b.[robot_mode_detail], N'''')
               OR ISNULL(f.[source_status_ods_row_id], -1) <> ISNULL(b.[source_status_ods_row_id], -1);

            SET @updated_rows = @@ROWCOUNT;
            SET @total_read += @read_rows;
            SET @total_updated += @updated_rows;
            SET @cursor = @batch_max;

            UPDATE [DWD].[etl_robot_job_mode_watermark]
            SET
                [last_backfill_source_ods_row_id] = CASE
                    WHEN [last_backfill_source_ods_row_id] < @batch_max THEN @batch_max
                    ELSE [last_backfill_source_ods_row_id]
                END,
                [last_backfill_success_time] = SYSDATETIME(),
                [last_error_message] = NULL,
                [update_time] = SYSDATETIME()
            WHERE [pipeline_name] = @pipeline_name;

            RAISERROR(
                N''Robot job/mode backfill batch finished. Cursor = %I64d, rows read = %d, rows updated = %d.'',
                10,
                1,
                @cursor,
                @read_rows,
                @updated_rows
            ) WITH NOWAIT;
        END;

        EXEC sys.sp_releaseapplock
            @Resource = N''DWD.sp_backfill_robot_job_type_mode'',
            @LockOwner = N''Session'';

        SELECT
            @effective_start_after AS [started_after_source_ods_row_id],
            @cursor AS [finished_through_source_ods_row_id],
            @total_read AS [rows_read],
            @total_updated AS [rows_updated],
            DATEDIFF(SECOND, @started_at, SYSDATETIME()) AS [elapsed_seconds];
    END TRY
    BEGIN CATCH
        SET @error_message = ERROR_MESSAGE();

        UPDATE [DWD].[etl_robot_job_mode_watermark]
        SET
            [last_error_message] = @error_message,
            [update_time] = SYSDATETIME()
        WHERE [pipeline_name] = @pipeline_name;

        EXEC sys.sp_releaseapplock
            @Resource = N''DWD.sp_backfill_robot_job_type_mode'',
            @LockOwner = N''Session'';

        RAISERROR(N''Robot job/mode historical backfill failed: %s'', 16, 1, @error_message);
        RETURN;
    END CATCH;
END;';
GO

/* Preview only. Change @execute from 0 to 1 when you are ready. */
EXEC [DWD].[sp_backfill_robot_job_type_mode]
    @execute = 0,
    @batch_size = 100000,
    @start_after_source_ods_row_id = NULL,
    @end_at_source_ods_row_id = NULL;
GO
