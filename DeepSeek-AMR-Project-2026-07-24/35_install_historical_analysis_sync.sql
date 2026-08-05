USE IOT2020;
GO

/*
    Install the slower historical-analysis pipeline.

    ODS procedure below refreshes enabled FULL_REPLACE / SNAPSHOT reference tables,
    excluding AMR_Currentdata and AMR_Robot_Mode because those two are owned by
    DWS.sp_refresh_robot_current_snapshot_fast.

    The master procedure then runs:
      1. ODS reference refresh
      2. ODS ID/TIME incremental append
      3. DWD load without the current snapshot
      4. DWS historical aggregates without the current snapshot
*/

CREATE OR ALTER PROCEDURE [ODS].[sp_load_reference_full_replace]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF OBJECT_ID(N'[ODS].[etl_watermark]', N'U') IS NULL
    BEGIN
        RAISERROR(N'Missing control table: ODS.etl_watermark.', 16, 1);
        RETURN;
    END;

    DECLARE
        @lock_result INT,
        @source_schema SYSNAME,
        @source_table SYSNAME,
        @target_schema SYSNAME,
        @target_table SYSNAME,
        @load_mode NVARCHAR(30),
        @source_object_id INT,
        @target_object_id INT,
        @insert_columns NVARCHAR(MAX),
        @select_columns NVARCHAR(MAX),
        @sql NVARCHAR(MAX),
        @rows_deleted BIGINT,
        @rows_inserted BIGINT,
        @error_message NVARCHAR(4000),
        @has_error BIT = 0;

    DECLARE @load_result TABLE (
        [source_table] SYSNAME NOT NULL,
        [target_table] SYSNAME NOT NULL,
        [load_mode] NVARCHAR(30) NOT NULL,
        [rows_deleted] BIGINT NOT NULL,
        [rows_inserted] BIGINT NOT NULL,
        [load_status] NVARCHAR(20) NOT NULL,
        [error_message] NVARCHAR(4000) NULL
    );

    EXEC @lock_result = sys.sp_getapplock
        @Resource = N'ODS.sp_load_reference_full_replace',
        @LockMode = N'Exclusive',
        @LockOwner = N'Session',
        @LockTimeout = 0;

    IF @lock_result < 0
    BEGIN
        RAISERROR(N'The ODS reference-table refresh is already running.', 16, 1);
        RETURN;
    END;

    DECLARE reference_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT
        w.[source_schema],
        w.[source_table],
        w.[target_schema],
        w.[target_table],
        w.[load_mode]
    FROM [ODS].[etl_watermark] AS w
    WHERE w.[is_enabled] = 1
      AND w.[source_schema] = N'dbo'
      AND w.[target_schema] = N'ODS'
      AND w.[load_mode] IN (N'FULL_REPLACE', N'SNAPSHOT')
      AND w.[source_table] NOT IN (N'AMR_Currentdata', N'AMR_Robot_Mode')
    ORDER BY w.[source_table];

    OPEN reference_cursor;
    FETCH NEXT FROM reference_cursor
    INTO @source_schema, @source_table, @target_schema, @target_table, @load_mode;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @rows_deleted = 0;
        SET @rows_inserted = 0;
        SET @error_message = NULL;
        SET @insert_columns = NULL;
        SET @select_columns = NULL;
        SET @source_object_id = OBJECT_ID(QUOTENAME(@source_schema) + N'.' + QUOTENAME(@source_table), N'U');
        SET @target_object_id = OBJECT_ID(QUOTENAME(@target_schema) + N'.' + QUOTENAME(@target_table), N'U');

        BEGIN TRY
            IF @source_object_id IS NULL OR @target_object_id IS NULL
            BEGIN
                RAISERROR(N'Source or target table is missing.', 16, 1);
            END;

            SELECT
                @insert_columns = STRING_AGG(
                    CONVERT(NVARCHAR(MAX), QUOTENAME(tc.[name])), N', '
                ) WITHIN GROUP (ORDER BY tc.[column_id]),
                @select_columns = STRING_AGG(
                    CONVERT(NVARCHAR(MAX), N'src.' + QUOTENAME(tc.[name])), N', '
                ) WITHIN GROUP (ORDER BY tc.[column_id])
            FROM sys.columns AS tc
            INNER JOIN sys.columns AS sc
                ON sc.[object_id] = @source_object_id
               AND sc.[name] = tc.[name]
            WHERE tc.[object_id] = @target_object_id
              AND tc.[is_computed] = 0
              AND tc.[name] NOT IN (
                    N'ods_row_id', N'ods_load_time', N'ods_batch_id',
                    N'ods_source_schema', N'ods_source_table',
                    N'ods_operation', N'ods_hash_value'
              );

            IF @insert_columns IS NULL OR @select_columns IS NULL
            BEGIN
                RAISERROR(N'No matching business columns between the source and ODS target.', 16, 1);
            END;

            SET @sql =
                N'DELETE tgt
                  FROM ' + QUOTENAME(@target_schema) + N'.' + QUOTENAME(@target_table) + N' AS tgt
                  WHERE tgt.[ods_source_schema] = @p_source_schema
                    AND tgt.[ods_source_table] = @p_source_table;
                  SET @p_rows_deleted = @@ROWCOUNT;

                  INSERT INTO ' + QUOTENAME(@target_schema) + N'.' + QUOTENAME(@target_table) + N' (
                      ' + @insert_columns + N',
                      [ods_load_time], [ods_batch_id], [ods_source_schema],
                      [ods_source_table], [ods_operation], [ods_hash_value]
                  )
                  SELECT
                      ' + @select_columns + N',
                      SYSDATETIME(), NULL, @p_source_schema, @p_source_table, N''R'', NULL
                  FROM ' + QUOTENAME(@source_schema) + N'.' + QUOTENAME(@source_table) + N' AS src;
                  SET @p_rows_inserted = @@ROWCOUNT;';

            BEGIN TRANSACTION;

            EXEC sys.sp_executesql
                @sql,
                N'@p_source_schema SYSNAME,
                  @p_source_table SYSNAME,
                  @p_rows_deleted BIGINT OUTPUT,
                  @p_rows_inserted BIGINT OUTPUT',
                @p_source_schema = @source_schema,
                @p_source_table = @source_table,
                @p_rows_deleted = @rows_deleted OUTPUT,
                @p_rows_inserted = @rows_inserted OUTPUT;

            UPDATE [ODS].[etl_watermark]
            SET
                [last_bigint_value] = NULL,
                [last_datetime_value] = NULL,
                [last_load_time] = SYSDATETIME()
            WHERE [source_schema] = @source_schema
              AND [source_table] = @source_table
              AND [target_schema] = @target_schema
              AND [target_table] = @target_table;

            COMMIT TRANSACTION;

            INSERT INTO @load_result
            VALUES (
                @source_table, @target_table, @load_mode,
                @rows_deleted, @rows_inserted, N'SUCCESS', NULL
            );
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0
                ROLLBACK TRANSACTION;

            SET @has_error = 1;
            SET @error_message = CONCAT(
                N'Error ', ERROR_NUMBER(), N', line ', ERROR_LINE(), N': ', ERROR_MESSAGE()
            );

            INSERT INTO @load_result
            VALUES (
                @source_table, @target_table, @load_mode,
                @rows_deleted, @rows_inserted, N'FAILED', @error_message
            );
        END CATCH;

        FETCH NEXT FROM reference_cursor
        INTO @source_schema, @source_table, @target_schema, @target_table, @load_mode;
    END;

    CLOSE reference_cursor;
    DEALLOCATE reference_cursor;

    EXEC sys.sp_releaseapplock
        @Resource = N'ODS.sp_load_reference_full_replace',
        @LockOwner = N'Session';

    SELECT
        [source_table], [target_table], [load_mode],
        [rows_deleted], [rows_inserted], [load_status], [error_message]
    FROM @load_result
    ORDER BY
        CASE [load_status] WHEN N'FAILED' THEN 1 ELSE 2 END,
        [source_table];

    IF @has_error = 1
    BEGIN
        RAISERROR(N'One or more ODS reference-table refreshes failed. Review the preceding result set.', 16, 1);
    END;
END;
GO

CREATE OR ALTER PROCEDURE [DWS].[sp_run_amr_historical_pipeline]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @lock_result INT;

    IF OBJECT_ID(N'[ODS].[sp_load_reference_full_replace]', N'P') IS NULL
       OR OBJECT_ID(N'[ODS].[sp_load_id_time_incremental]', N'P') IS NULL
       OR OBJECT_ID(N'[DWD].[sp_load_dwd_all_incremental]', N'P') IS NULL
       OR OBJECT_ID(N'[DWD].[sp_enrich_robot_job_type_mode_incremental]', N'P') IS NULL
       OR OBJECT_ID(N'[DWS].[sp_load_dws_core_upsert]', N'P') IS NULL
    BEGIN
        RAISERROR(N'Missing one or more historical-pipeline procedures. Install scripts 02, 21, 26, 42, and 35 first.', 16, 1);
        RETURN;
    END;

    EXEC @lock_result = sys.sp_getapplock
        @Resource = N'DWS.sp_run_amr_historical_pipeline',
        @LockMode = N'Exclusive',
        @LockOwner = N'Session',
        @LockTimeout = 0;

    IF @lock_result < 0
    BEGIN
        RAISERROR(N'The AMR historical-analysis pipeline is already running.', 16, 1);
        RETURN;
    END;

    BEGIN TRY
        EXEC [ODS].[sp_load_reference_full_replace];
        EXEC [ODS].[sp_load_id_time_incremental];
        EXEC [DWD].[sp_load_dwd_all_incremental]
            @include_current_snapshot = 0;
        EXEC [DWD].[sp_enrich_robot_job_type_mode_incremental];
        EXEC [DWS].[sp_load_dws_core_upsert]
            @include_current_snapshot = 0;

        EXEC sys.sp_releaseapplock
            @Resource = N'DWS.sp_run_amr_historical_pipeline',
            @LockOwner = N'Session';
    END TRY
    BEGIN CATCH
        EXEC sys.sp_releaseapplock
            @Resource = N'DWS.sp_run_amr_historical_pipeline',
            @LockOwner = N'Session';

        THROW;
    END CATCH;
END;
GO

/* Manual smoke test. This can take several minutes with the current full DWS aggregates. */
-- EXEC [DWS].[sp_run_amr_historical_pipeline];
GO
