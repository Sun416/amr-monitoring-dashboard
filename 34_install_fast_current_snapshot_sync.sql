USE IOT2020;
GO

/*
    Install the fast current-state pipeline used by the monitoring Web.

    Scope per execution:
      dbo.AMR_Currentdata + dbo.AMR_Robot_Mode
        -> matching ODS snapshot tables
        -> DWD.snap_amr_current_status
        -> DWS.dws_robot_current_snapshot

    Safety:
      - Refuses to replace a snapshot when either dbo source table is empty.
      - All business-table changes are one small transaction.
      - Deletes are restricted to the current-snapshot source or stale DWS keys.
      - An application lock prevents overlapping fast refreshes.
*/

/*
    Legacy implementation retained only for audit/rollback reference.
    The production entry point is installed by
    46_install_dws_operational_snapshot_v2.sql.
*/
CREATE OR ALTER PROCEDURE [DWS].[sp_refresh_robot_current_snapshot_legacy]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @started_at DATETIME2(3) = SYSDATETIME(),
        @lock_result INT,
        @dwd_batch_id BIGINT = NULL,
        @dws_batch_id BIGINT = NULL,
        @source_table SYSNAME,
        @source_object_id INT,
        @target_object_id INT,
        @business_insert_columns NVARCHAR(MAX),
        @business_select_columns NVARCHAR(MAX),
        @sql NVARCHAR(MAX),
        @source_rows BIGINT,
        @ods_rows_deleted BIGINT = 0,
        @ods_rows_inserted BIGINT = 0,
        @table_rows_deleted BIGINT,
        @table_rows_inserted BIGINT,
        @dwd_rows_deleted BIGINT = 0,
        @dwd_rows_inserted BIGINT = 0,
        @dws_rows_deleted BIGINT = 0,
        @dws_rows_updated BIGINT = 0,
        @dws_rows_inserted BIGINT = 0,
        @error_message NVARCHAR(4000);

    IF OBJECT_ID(N'[dbo].[AMR_Currentdata]', N'U') IS NULL
       OR OBJECT_ID(N'[dbo].[AMR_Robot_Mode]', N'U') IS NULL
       OR OBJECT_ID(N'[ODS].[AMR_Currentdata]', N'U') IS NULL
       OR OBJECT_ID(N'[ODS].[AMR_Robot_Mode]', N'U') IS NULL
       OR OBJECT_ID(N'[ODS].[etl_watermark]', N'U') IS NULL
       OR OBJECT_ID(N'[DWD].[snap_amr_current_status]', N'U') IS NULL
       OR OBJECT_ID(N'[DWD].[etl_batch]', N'U') IS NULL
       OR OBJECT_ID(N'[DWD].[etl_load_log]', N'U') IS NULL
       OR OBJECT_ID(N'[DWD].[etl_watermark]', N'U') IS NULL
       OR OBJECT_ID(N'[DWS].[dws_robot_current_snapshot]', N'U') IS NULL
       OR OBJECT_ID(N'[DWS].[etl_batch]', N'U') IS NULL
       OR OBJECT_ID(N'[DWS].[etl_load_log]', N'U') IS NULL
    BEGIN
        RAISERROR(N'Missing one or more current-snapshot source, target, or ETL control tables.', 16, 1);
        RETURN;
    END;

    EXEC @lock_result = sys.sp_getapplock
        @Resource = N'DWS.sp_refresh_robot_current_snapshot_fast',
        @LockMode = N'Exclusive',
        @LockOwner = N'Session',
        @LockTimeout = 0;

    IF @lock_result < 0
    BEGIN
        RAISERROR(N'The fast AMR current-snapshot refresh is already running.', 16, 1);
        RETURN;
    END;

    BEGIN TRY
        INSERT INTO [DWD].[etl_batch] ([batch_status])
        VALUES (N'RUNNING');

        SET @dwd_batch_id = SCOPE_IDENTITY();

        INSERT INTO [DWS].[etl_batch] (
            [batch_start_time],
            [batch_status],
            [error_message]
        )
        VALUES (
            @started_at,
            N'RUNNING',
            NULL
        );

        SET @dws_batch_id = SCOPE_IDENTITY();

        BEGIN TRANSACTION;

        DECLARE @snapshot_sources TABLE (
            [source_table] SYSNAME NOT NULL PRIMARY KEY
        );

        INSERT INTO @snapshot_sources ([source_table])
        VALUES
            (N'AMR_Currentdata'),
            (N'AMR_Robot_Mode');

        DECLARE snapshot_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT [source_table]
        FROM @snapshot_sources
        ORDER BY [source_table];

        OPEN snapshot_cursor;
        FETCH NEXT FROM snapshot_cursor INTO @source_table;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @source_object_id = OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(@source_table), N'U');
            SET @target_object_id = OBJECT_ID(QUOTENAME(N'ODS') + N'.' + QUOTENAME(@source_table), N'U');
            SET @business_insert_columns = NULL;
            SET @business_select_columns = NULL;
            SET @source_rows = 0;
            SET @table_rows_deleted = 0;
            SET @table_rows_inserted = 0;

            SET @sql = N'SELECT @p_source_rows = COUNT_BIG(*) FROM [dbo].' + QUOTENAME(@source_table) + N';';

            EXEC sys.sp_executesql
                @sql,
                N'@p_source_rows BIGINT OUTPUT',
                @p_source_rows = @source_rows OUTPUT;

            IF @source_rows = 0
            BEGIN
                SET @error_message = CONCAT(N'Refusing to replace ODS snapshot because dbo.', @source_table, N' is empty.');
                RAISERROR(N'%s', 16, 1, @error_message);
            END;

            SELECT
                @business_insert_columns = STRING_AGG(
                    CONVERT(NVARCHAR(MAX), QUOTENAME(tc.[name])), N', '
                ) WITHIN GROUP (ORDER BY tc.[column_id]),
                @business_select_columns = STRING_AGG(
                    CONVERT(NVARCHAR(MAX), N'src.' + QUOTENAME(tc.[name])), N', '
                ) WITHIN GROUP (ORDER BY tc.[column_id])
            FROM sys.columns AS tc
            INNER JOIN sys.columns AS sc
                ON sc.[object_id] = @source_object_id
               AND sc.[name] = tc.[name]
            WHERE tc.[object_id] = @target_object_id
              AND tc.[is_computed] = 0
              AND tc.[name] NOT IN (
                    N'ods_row_id',
                    N'ods_load_time',
                    N'ods_batch_id',
                    N'ods_source_schema',
                    N'ods_source_table',
                    N'ods_operation',
                    N'ods_hash_value'
              );

            IF @business_insert_columns IS NULL OR @business_select_columns IS NULL
            BEGIN
                SET @error_message = CONCAT(N'No matching business columns for dbo.', @source_table, N' -> ODS.', @source_table, N'.');
                RAISERROR(N'%s', 16, 1, @error_message);
            END;

            SET @sql =
                N'DELETE tgt
                  FROM [ODS].' + QUOTENAME(@source_table) + N' AS tgt
                  WHERE tgt.[ods_source_schema] = N''dbo''
                    AND tgt.[ods_source_table] = @p_source_table;
                  SET @p_rows_deleted = @@ROWCOUNT;

                  INSERT INTO [ODS].' + QUOTENAME(@source_table) + N' (
                      ' + @business_insert_columns + N',
                      [ods_load_time], [ods_batch_id], [ods_source_schema],
                      [ods_source_table], [ods_operation], [ods_hash_value]
                  )
                  SELECT
                      ' + @business_select_columns + N',
                      @p_load_time, NULL, N''dbo'', @p_source_table, N''S'', NULL
                  FROM [dbo].' + QUOTENAME(@source_table) + N' AS src;
                  SET @p_rows_inserted = @@ROWCOUNT;';

            EXEC sys.sp_executesql
                @sql,
                N'@p_source_table SYSNAME,
                  @p_load_time DATETIME2(3),
                  @p_rows_deleted BIGINT OUTPUT,
                  @p_rows_inserted BIGINT OUTPUT',
                @p_source_table = @source_table,
                @p_load_time = @started_at,
                @p_rows_deleted = @table_rows_deleted OUTPUT,
                @p_rows_inserted = @table_rows_inserted OUTPUT;

            SET @ods_rows_deleted += @table_rows_deleted;
            SET @ods_rows_inserted += @table_rows_inserted;

            UPDATE [ODS].[etl_watermark]
            SET
                [last_bigint_value] = NULL,
                [last_datetime_value] = NULL,
                [last_load_time] = @started_at
            WHERE [source_schema] = N'dbo'
              AND [source_table] = @source_table
              AND [target_schema] = N'ODS'
              AND [target_table] = @source_table;

            FETCH NEXT FROM snapshot_cursor INTO @source_table;
        END;

        CLOSE snapshot_cursor;
        DEALLOCATE snapshot_cursor;

        DELETE tgt
        FROM [DWD].[snap_amr_current_status] AS tgt
        WHERE tgt.[source_schema] = N'ODS'
          AND tgt.[source_table] = N'AMR_Currentdata';

        SET @dwd_rows_deleted = @@ROWCOUNT;

        INSERT INTO [DWD].[snap_amr_current_status] (
            [robot_id], [robot_code], [robot_name], [current_status], [current_mode],
            [online_status], [job_id], [subjob_id], [map_code], [station_code],
            [position_x], [position_y], [position_theta], [speed_mps], [battery_soc],
            [error_code], [error_message], [source_event_time], [source_schema],
            [source_table], [source_ods_row_id], [dwd_batch_id], [dwd_hash_value]
        )
        SELECT
            COALESCE(
                NULLIF(NULLIF(LTRIM(RTRIM(TRY_CONVERT(NVARCHAR(100), src.[Robot_Serial]))), N''), N'undefined'),
                TRY_CONVERT(NVARCHAR(100), src.[Robot_number])
            ),
            TRY_CONVERT(NVARCHAR(100), src.[Robot_number]),
            TRY_CONVERT(NVARCHAR(200), src.[Robot_number]),
            TRY_CONVERT(NVARCHAR(100), src.[Robot_MoveState]),
            COALESCE(
                TRY_CONVERT(NVARCHAR(100), mode_ref.[Mode_Detail]),
                TRY_CONVERT(NVARCHAR(100), src.[Robot_Mode])
            ),
            TRY_CONVERT(NVARCHAR(50), src.[Robot_Device_State]),
            TRY_CONVERT(NVARCHAR(100), src.[Job_Name]),
            NULL,
            TRY_CONVERT(NVARCHAR(100), src.[Robot_Current_Map]),
            TRY_CONVERT(NVARCHAR(100), src.[POI_Current]),
            TRY_CONVERT(DECIMAL(18,6), src.[Robot_Position_X]),
            TRY_CONVERT(DECIMAL(18,6), src.[Robot_Position_Y]),
            TRY_CONVERT(DECIMAL(18,6), src.[Robot_Orientation_Z]),
            TRY_CONVERT(DECIMAL(18,6), src.[Robot_Speed]),
            TRY_CONVERT(DECIMAL(9,4), src.[Batt_Level]),
            TRY_CONVERT(NVARCHAR(100), src.[Robot_Emer_Status]),
            NULL,
            TRY_CONVERT(DATETIME2(3), src.[Datetime]),
            N'ODS',
            N'AMR_Currentdata',
            TRY_CONVERT(BIGINT, src.[ods_row_id]),
            @dwd_batch_id,
            HASHBYTES(
                'SHA2_256',
                CONCAT(N'ODS|AMR_Currentdata|', TRY_CONVERT(NVARCHAR(50), src.[ods_row_id]))
            )
        FROM [ODS].[AMR_Currentdata] AS src
        OUTER APPLY (
            SELECT TOP (1)
                mode_source.[Mode_Detail]
            FROM [ODS].[AMR_Robot_Mode] AS mode_source
            WHERE mode_source.[Mode_ID] = src.[Robot_Mode]
            ORDER BY mode_source.[ods_row_id] DESC
        ) AS mode_ref;

        SET @dwd_rows_inserted = @@ROWCOUNT;

        IF @dwd_rows_inserted = 0
        BEGIN
            RAISERROR(N'DWD current snapshot would be empty; the transaction has been cancelled.', 16, 1);
        END;

        UPDATE [DWD].[etl_watermark]
        SET [last_load_time] = @started_at
        WHERE [source_schema] = N'ODS'
          AND [source_table] = N'AMR_Currentdata'
          AND [target_schema] = N'DWD'
          AND [target_table] = N'snap_amr_current_status';

        INSERT INTO [DWD].[etl_load_log] (
            [batch_id], [source_schema], [source_table], [target_schema], [target_table],
            [load_mode], [load_start_time], [load_end_time], [rows_inserted],
            [rows_updated], [rows_deleted], [load_status], [error_message]
        )
        VALUES (
            @dwd_batch_id, N'ODS', N'AMR_Currentdata', N'DWD', N'snap_amr_current_status',
            N'SNAPSHOT_FAST', @started_at, SYSDATETIME(), @dwd_rows_inserted,
            0, @dwd_rows_deleted, N'SUCCESS', NULL
        );

        CREATE TABLE #current_snapshot_stage (
            [robot_code] NVARCHAR(100) NOT NULL,
            [robot_id] NVARCHAR(100) NULL,
            [robot_name] NVARCHAR(200) NULL,
            [current_status] NVARCHAR(100) NULL,
            [current_mode] NVARCHAR(100) NULL,
            [online_status] NVARCHAR(50) NULL,
            [job_id] NVARCHAR(100) NULL,
            [subjob_id] NVARCHAR(100) NULL,
            [map_code] NVARCHAR(100) NULL,
            [station_code] NVARCHAR(100) NULL,
            [position_x] DECIMAL(18,6) NULL,
            [position_y] DECIMAL(18,6) NULL,
            [position_theta] DECIMAL(18,6) NULL,
            [speed_mps] DECIMAL(18,6) NULL,
            [battery_soc] DECIMAL(9,4) NULL,
            [error_code] NVARCHAR(100) NULL,
            [error_message] NVARCHAR(1000) NULL,
            [source_event_time] DATETIME2(3) NULL,
            [source_snapshot_time] DATETIME2(3) NOT NULL,
            PRIMARY KEY ([robot_code])
        );

        ;WITH ranked_snapshot AS (
            SELECT
                s.[robot_code], s.[robot_id], s.[robot_name], s.[current_status],
                s.[current_mode], s.[online_status], s.[job_id], s.[subjob_id],
                s.[map_code], s.[station_code], s.[position_x], s.[position_y],
                s.[position_theta], s.[speed_mps], s.[battery_soc], s.[error_code],
                s.[error_message], s.[source_event_time], s.[snapshot_time],
                ROW_NUMBER() OVER (
                    PARTITION BY s.[robot_code]
                    ORDER BY s.[snapshot_time] DESC, s.[snapshot_id] DESC
                ) AS [rn]
            FROM [DWD].[snap_amr_current_status] AS s
            WHERE s.[source_schema] = N'ODS'
              AND s.[source_table] = N'AMR_Currentdata'
              AND NULLIF(LTRIM(RTRIM(s.[robot_code])), N'') IS NOT NULL
        )
        INSERT INTO #current_snapshot_stage (
            [robot_code], [robot_id], [robot_name], [current_status], [current_mode],
            [online_status], [job_id], [subjob_id], [map_code], [station_code],
            [position_x], [position_y], [position_theta], [speed_mps], [battery_soc],
            [error_code], [error_message], [source_event_time], [source_snapshot_time]
        )
        SELECT
            rs.[robot_code], rs.[robot_id], rs.[robot_name], rs.[current_status], rs.[current_mode],
            rs.[online_status], rs.[job_id], rs.[subjob_id], rs.[map_code], rs.[station_code],
            rs.[position_x], rs.[position_y], rs.[position_theta], rs.[speed_mps], rs.[battery_soc],
            rs.[error_code], rs.[error_message], rs.[source_event_time], rs.[snapshot_time]
        FROM ranked_snapshot AS rs
        WHERE rs.[rn] = 1;

        IF NOT EXISTS (SELECT 1 FROM #current_snapshot_stage)
        BEGIN
            RAISERROR(N'DWS current snapshot staging is empty; the transaction has been cancelled.', 16, 1);
        END;

        DELETE tgt
        FROM [DWS].[dws_robot_current_snapshot] AS tgt
        WHERE NOT EXISTS (
            SELECT 1
            FROM #current_snapshot_stage AS src
            WHERE src.[robot_code] = tgt.[robot_code]
        );

        SET @dws_rows_deleted = @@ROWCOUNT;

        UPDATE tgt
        SET
            tgt.[robot_id] = src.[robot_id],
            tgt.[robot_name] = src.[robot_name],
            tgt.[current_status] = src.[current_status],
            tgt.[current_mode] = src.[current_mode],
            tgt.[online_status] = src.[online_status],
            tgt.[job_id] = src.[job_id],
            tgt.[subjob_id] = src.[subjob_id],
            tgt.[map_code] = src.[map_code],
            tgt.[station_code] = src.[station_code],
            tgt.[position_x] = src.[position_x],
            tgt.[position_y] = src.[position_y],
            tgt.[position_theta] = src.[position_theta],
            tgt.[speed_mps] = src.[speed_mps],
            tgt.[battery_soc] = src.[battery_soc],
            tgt.[error_code] = src.[error_code],
            tgt.[error_message] = src.[error_message],
            tgt.[source_event_time] = src.[source_event_time],
            tgt.[source_snapshot_time] = src.[source_snapshot_time],
            tgt.[dws_load_time] = SYSDATETIME(),
            tgt.[dws_batch_id] = @dws_batch_id
        FROM [DWS].[dws_robot_current_snapshot] AS tgt
        INNER JOIN #current_snapshot_stage AS src
            ON src.[robot_code] = tgt.[robot_code];

        SET @dws_rows_updated = @@ROWCOUNT;

        INSERT INTO [DWS].[dws_robot_current_snapshot] (
            [robot_code], [robot_id], [robot_name], [current_status], [current_mode],
            [online_status], [job_id], [subjob_id], [map_code], [station_code],
            [position_x], [position_y], [position_theta], [speed_mps], [battery_soc],
            [error_code], [error_message], [source_event_time], [source_snapshot_time],
            [dws_batch_id]
        )
        SELECT
            src.[robot_code], src.[robot_id], src.[robot_name], src.[current_status], src.[current_mode],
            src.[online_status], src.[job_id], src.[subjob_id], src.[map_code], src.[station_code],
            src.[position_x], src.[position_y], src.[position_theta], src.[speed_mps], src.[battery_soc],
            src.[error_code], src.[error_message], src.[source_event_time], src.[source_snapshot_time],
            @dws_batch_id
        FROM #current_snapshot_stage AS src
        WHERE NOT EXISTS (
            SELECT 1
            FROM [DWS].[dws_robot_current_snapshot] AS tgt
            WHERE tgt.[robot_code] = src.[robot_code]
        );

        SET @dws_rows_inserted = @@ROWCOUNT;

        INSERT INTO [DWS].[etl_load_log] (
            [batch_id], [target_schema], [target_table], [source_schema], [source_table],
            [load_mode], [affected_rows], [load_status], [error_message],
            [load_start_time], [load_end_time]
        )
        VALUES (
            @dws_batch_id, N'DWS', N'dws_robot_current_snapshot', N'DWD', N'snap_amr_current_status',
            N'UPSERT_SNAPSHOT_FAST', @dws_rows_deleted + @dws_rows_updated + @dws_rows_inserted,
            N'SUCCESS', NULL, @started_at, SYSDATETIME()
        );

        UPDATE [DWD].[etl_batch]
        SET
            [batch_end_time] = SYSDATETIME(),
            [batch_status] = N'SUCCESS',
            [error_message] = NULL
        WHERE [batch_id] = @dwd_batch_id;

        UPDATE [DWS].[etl_batch]
        SET
            [batch_end_time] = SYSDATETIME(),
            [batch_status] = N'SUCCESS',
            [error_message] = NULL
        WHERE [batch_id] = @dws_batch_id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'snapshot_cursor') >= 0
            CLOSE snapshot_cursor;

        IF CURSOR_STATUS('local', 'snapshot_cursor') > -3
            DEALLOCATE snapshot_cursor;

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SET @error_message = CONCAT(
            N'Error ', ERROR_NUMBER(), N', line ', ERROR_LINE(), N': ', ERROR_MESSAGE()
        );

        UPDATE [DWD].[etl_batch]
        SET
            [batch_end_time] = SYSDATETIME(),
            [batch_status] = N'FAILED',
            [error_message] = @error_message
        WHERE [batch_id] = @dwd_batch_id;

        UPDATE [DWS].[etl_batch]
        SET
            [batch_end_time] = SYSDATETIME(),
            [batch_status] = N'FAILED',
            [error_message] = @error_message
        WHERE [batch_id] = @dws_batch_id;

        EXEC sys.sp_releaseapplock
            @Resource = N'DWS.sp_refresh_robot_current_snapshot_fast',
            @LockOwner = N'Session';

        THROW;
    END CATCH;

    EXEC sys.sp_releaseapplock
        @Resource = N'DWS.sp_refresh_robot_current_snapshot_fast',
        @LockOwner = N'Session';

    SELECT
        @started_at AS [started_at],
        SYSDATETIME() AS [finished_at],
        DATEDIFF(MILLISECOND, @started_at, SYSDATETIME()) AS [elapsed_milliseconds],
        @ods_rows_deleted AS [ods_rows_deleted],
        @ods_rows_inserted AS [ods_rows_inserted],
        @dwd_rows_deleted AS [dwd_rows_deleted],
        @dwd_rows_inserted AS [dwd_rows_inserted],
        @dws_rows_deleted AS [dws_rows_deleted],
        @dws_rows_updated AS [dws_rows_updated],
        @dws_rows_inserted AS [dws_rows_inserted],
        @dwd_batch_id AS [dwd_batch_id],
        @dws_batch_id AS [dws_batch_id];
END;
GO

/* Legacy smoke test. Do not use this procedure for the monitoring Web. */
-- EXEC [DWS].[sp_refresh_robot_current_snapshot_legacy];
GO
