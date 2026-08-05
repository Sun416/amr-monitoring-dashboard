USE [IOT2020];
GO

/*
    Install the future incremental enrichment process for DWD.fact_robot_job.

    The control row is initialized to the current DWD maximum source row id.
    Therefore installing this script will not silently start a 40+ million row
    history repair. Historical rows are handled separately by script 43.

    DataGrip: reload this file from disk, select the whole file, and execute the
    selection. Do not execute only the statement at the current cursor.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

/*
    Use separate dynamic batches so DataGrip cannot split IF...BEGIN and so the
    seed statement is compiled only after the control table exists.
*/
DECLARE @watermark_table_sql NVARCHAR(MAX) = CASE
    WHEN OBJECT_ID(N'[DWD].[etl_robot_job_mode_watermark]', N'U') IS NULL
        THEN N'CREATE TABLE [DWD].[etl_robot_job_mode_watermark] (
            [pipeline_name] SYSNAME NOT NULL,
            [last_incremental_source_ods_row_id] BIGINT NOT NULL,
            [last_backfill_source_ods_row_id] BIGINT NOT NULL
                CONSTRAINT [DF_DWD_job_mode_wm_backfill] DEFAULT (0),
            [last_incremental_success_time] DATETIME2(3) NULL,
            [last_backfill_success_time] DATETIME2(3) NULL,
            [last_error_message] NVARCHAR(4000) NULL,
            [update_time] DATETIME2(3) NOT NULL
                CONSTRAINT [DF_DWD_job_mode_wm_update_time] DEFAULT SYSDATETIME(),
            CONSTRAINT [PK_DWD_etl_robot_job_mode_watermark]
                PRIMARY KEY CLUSTERED ([pipeline_name])
        );'
    ELSE N''
END;

EXEC sys.sp_executesql @watermark_table_sql;

DECLARE @watermark_seed_sql NVARCHAR(MAX) = N'
IF NOT EXISTS (
    SELECT 1
    FROM [DWD].[etl_robot_job_mode_watermark] AS w
    WHERE w.[pipeline_name] = N''robot_job_type_mode''
)
BEGIN
    DECLARE @initial_source_ods_row_id BIGINT;

    SELECT
        @initial_source_ods_row_id = ISNULL(MAX(j.[source_ods_row_id]), 0)
    FROM [DWD].[fact_robot_job] AS j
    WHERE j.[source_schema] = N''ODS''
      AND j.[source_table] = N''robot_job_history'';

    INSERT INTO [DWD].[etl_robot_job_mode_watermark] (
        [pipeline_name],
        [last_incremental_source_ods_row_id],
        [last_backfill_source_ods_row_id],
        [last_incremental_success_time],
        [last_backfill_success_time],
        [last_error_message]
    )
    VALUES (
        N''robot_job_type_mode'',
        @initial_source_ods_row_id,
        0,
        NULL,
        NULL,
        NULL
    );
END;';

EXEC sys.sp_executesql @watermark_seed_sql;
GO

CREATE OR ALTER PROCEDURE [DWD].[sp_enrich_robot_job_type_mode_incremental]
    @batch_size INT = 100000,
    @replay_rows BIGINT = 100000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @pipeline_name SYSNAME = N'robot_job_type_mode',
        @lock_result INT,
        @watermark BIGINT,
        @start_after BIGINT,
        @upper_bound BIGINT,
        @cursor BIGINT,
        @batch_max BIGINT,
        @read_rows INT,
        @updated_rows INT,
        @total_updated BIGINT = 0,
        @error_message NVARCHAR(4000);

    IF @batch_size < 1 OR @batch_size > 1000000
    BEGIN
        RAISERROR(N'@batch_size must be between 1 and 1000000.', 16, 1);
        RETURN;
    END;

    IF @replay_rows < 0
    BEGIN
        RAISERROR(N'@replay_rows cannot be negative.', 16, 1);
        RETURN;
    END;

    IF OBJECT_ID(N'[ODS].[robot_job_history]', N'U') IS NULL
       OR OBJECT_ID(N'[ODS].[robot_status_history]', N'U') IS NULL
       OR OBJECT_ID(N'[ODS].[AMR_Robot_Mode]', N'U') IS NULL
       OR OBJECT_ID(N'[DWD].[fact_robot_job]', N'U') IS NULL
       OR OBJECT_ID(N'[DWD].[etl_robot_job_mode_watermark]', N'U') IS NULL
    BEGIN
        RAISERROR(N'Required robot job/mode object is missing. Run scripts 40-42 in order.', 16, 1);
        RETURN;
    END;

    IF COL_LENGTH(N'DWD.fact_robot_job', N'robot_mode_id') IS NULL
       OR COL_LENGTH(N'DWD.fact_robot_job', N'robot_mode_detail') IS NULL
       OR COL_LENGTH(N'DWD.fact_robot_job', N'source_status_ods_row_id') IS NULL
    BEGIN
        RAISERROR(N'DWD mode columns are missing. Run script 41 first.', 16, 1);
        RETURN;
    END;

    IF NOT EXISTS (
        SELECT 1
        FROM sys.indexes AS i
        WHERE i.[object_id] = OBJECT_ID(N'[ODS].[robot_status_history]')
          AND i.[name] = N'IX_ODS_robot_status_history_amr_time'
    )
    BEGIN
        RAISERROR(N'Required ODS status lookup index is missing. Finish script 41 first.', 16, 1);
        RETURN;
    END;

    EXEC @lock_result = sys.sp_getapplock
        @Resource = N'DWD.sp_enrich_robot_job_type_mode_incremental',
        @LockMode = N'Exclusive',
        @LockOwner = N'Session',
        @LockTimeout = 0;

    IF @lock_result < 0
    BEGIN
        RAISERROR(N'Robot job/mode enrichment is already running. Retry later.', 16, 1);
        RETURN;
    END;

    BEGIN TRY
        SELECT
            @watermark = w.[last_incremental_source_ods_row_id]
        FROM [DWD].[etl_robot_job_mode_watermark] AS w
        WHERE w.[pipeline_name] = @pipeline_name;

        IF @watermark IS NULL
        BEGIN
            RAISERROR(N'Robot job/mode watermark row is missing.', 16, 1);
        END;

        SET @start_after = CASE
            WHEN @watermark > @replay_rows THEN @watermark - @replay_rows
            ELSE 0
        END;

        SELECT
            @upper_bound = ISNULL(MAX(j.[source_ods_row_id]), @watermark)
        FROM [DWD].[fact_robot_job] AS j
        WHERE j.[source_schema] = N'ODS'
          AND j.[source_table] = N'robot_job_history';

        SET @cursor = @start_after;

        CREATE TABLE #job_mode_batch (
            [job_fact_id] BIGINT NOT NULL PRIMARY KEY,
            [source_ods_row_id] BIGINT NOT NULL,
            [job_type_code] NVARCHAR(100) NULL,
            [robot_mode_id] NVARCHAR(100) NULL,
            [robot_mode_detail] NVARCHAR(200) NULL,
            [source_status_ods_row_id] BIGINT NULL
        );

        WHILE @cursor < @upper_bound
        BEGIN
            TRUNCATE TABLE #job_mode_batch;

            INSERT INTO #job_mode_batch (
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
                    WHEN NULLIF(LTRIM(RTRIM(j.[job_name])), N'') IS NULL THEN NULL
                    WHEN UPPER(LTRIM(RTRIM(j.[job_name]))) IN (N'-', N'NULL', N'UNDEFINED') THEN NULL
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
            WHERE f.[source_schema] = N'ODS'
              AND f.[source_table] = N'robot_job_history'
              AND f.[source_ods_row_id] > @cursor
              AND f.[source_ods_row_id] <= @upper_bound
            ORDER BY f.[source_ods_row_id];

            SET @read_rows = @@ROWCOUNT;

            IF @read_rows = 0
                BREAK;

            SELECT
                @batch_max = MAX(b.[source_ods_row_id])
            FROM #job_mode_batch AS b;

            UPDATE f
            SET
                f.[job_type_code] = b.[job_type_code],
                f.[robot_mode_id] = b.[robot_mode_id],
                f.[robot_mode_detail] = b.[robot_mode_detail],
                f.[source_status_ods_row_id] = b.[source_status_ods_row_id],
                f.[dwd_load_time] = SYSDATETIME()
            FROM [DWD].[fact_robot_job] AS f
            INNER JOIN #job_mode_batch AS b
                ON b.[job_fact_id] = f.[job_fact_id]
            WHERE ISNULL(f.[job_type_code], N'') <> ISNULL(b.[job_type_code], N'')
               OR ISNULL(f.[robot_mode_id], N'') <> ISNULL(b.[robot_mode_id], N'')
               OR ISNULL(f.[robot_mode_detail], N'') <> ISNULL(b.[robot_mode_detail], N'')
               OR ISNULL(f.[source_status_ods_row_id], -1) <> ISNULL(b.[source_status_ods_row_id], -1);

            SET @updated_rows = @@ROWCOUNT;
            SET @total_updated += @updated_rows;
            SET @cursor = @batch_max;

            RAISERROR(
                N'Robot job/mode incremental batch finished. Cursor = %I64d, rows read = %d, rows updated = %d.',
                10,
                1,
                @cursor,
                @read_rows,
                @updated_rows
            ) WITH NOWAIT;
        END;

        UPDATE [DWD].[etl_robot_job_mode_watermark]
        SET
            [last_incremental_source_ods_row_id] = @upper_bound,
            [last_incremental_success_time] = SYSDATETIME(),
            [last_error_message] = NULL,
            [update_time] = SYSDATETIME()
        WHERE [pipeline_name] = @pipeline_name;

        EXEC sys.sp_releaseapplock
            @Resource = N'DWD.sp_enrich_robot_job_type_mode_incremental',
            @LockOwner = N'Session';

        SELECT
            @start_after AS [processed_after_source_ods_row_id],
            @upper_bound AS [processed_through_source_ods_row_id],
            @total_updated AS [rows_updated],
            SYSDATETIME() AS [completion_time];
    END TRY
    BEGIN CATCH
        SET @error_message = ERROR_MESSAGE();

        UPDATE [DWD].[etl_robot_job_mode_watermark]
        SET
            [last_error_message] = @error_message,
            [update_time] = SYSDATETIME()
        WHERE [pipeline_name] = @pipeline_name;

        EXEC sys.sp_releaseapplock
            @Resource = N'DWD.sp_enrich_robot_job_type_mode_incremental',
            @LockOwner = N'Session';

        RAISERROR(N'Robot job/mode incremental enrichment failed: %s', 16, 1, @error_message);
        RETURN;
    END CATCH;
END;
GO

SELECT
    w.[pipeline_name],
    w.[last_incremental_source_ods_row_id],
    w.[last_backfill_source_ods_row_id],
    w.[last_incremental_success_time],
    w.[last_backfill_success_time],
    w.[last_error_message],
    w.[update_time]
FROM [DWD].[etl_robot_job_mode_watermark] AS w
WHERE w.[pipeline_name] = N'robot_job_type_mode';
GO
