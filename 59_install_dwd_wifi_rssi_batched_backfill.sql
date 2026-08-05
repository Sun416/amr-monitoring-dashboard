USE [IOT2020];
GO

/*
    Install a resumable historical repair for DWD.fact_robot_wifi.rssi.

    Data mapping:
      ODS.robot_wifi_history.wifi_signal_level
          -> DWD.fact_robot_wifi.rssi

    Safety:
      - Installing this script does not update DWD business rows.
      - The installed procedure defaults to @execute = 0 (preview only).
      - Each executed scan range is committed in its own transaction.
      - Progress is persisted, so an interrupted run resumes from the last
        committed source_ods_row_id.
      - Every repaired robot-hour is queued for a targeted DWS refresh.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'[ODS].[robot_wifi_history]', N'U') IS NULL
BEGIN
    RAISERROR(N'Missing source table: ODS.robot_wifi_history.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'[DWD].[fact_robot_wifi]', N'U') IS NULL
BEGIN
    RAISERROR(N'Missing target table: DWD.fact_robot_wifi.', 16, 1);
    RETURN;
END;

IF COL_LENGTH(N'ODS.robot_wifi_history', N'ods_row_id') IS NULL
   OR COL_LENGTH(N'ODS.robot_wifi_history', N'wifi_signal_level') IS NULL
BEGIN
    RAISERROR(N'ODS.robot_wifi_history is missing ods_row_id or wifi_signal_level.', 16, 1);
    RETURN;
END;

IF COL_LENGTH(N'DWD.fact_robot_wifi', N'source_ods_row_id') IS NULL
   OR COL_LENGTH(N'DWD.fact_robot_wifi', N'rssi') IS NULL
BEGIN
    RAISERROR(N'DWD.fact_robot_wifi is missing source_ods_row_id or rssi.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'[DWD].[etl_wifi_rssi_repair_state]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[etl_wifi_rssi_repair_state] (
        [repair_name] NVARCHAR(100) NOT NULL,
        [last_source_ods_row_id] BIGINT NOT NULL,
        [upper_source_ods_row_id] BIGINT NOT NULL,
        [repair_status] NVARCHAR(30) NOT NULL,
        [total_rows_updated] BIGINT NOT NULL,
        [started_at] DATETIME2(3) NOT NULL,
        [last_batch_at] DATETIME2(3) NULL,
        [completed_at] DATETIME2(3) NULL,
        [error_message] NVARCHAR(4000) NULL,
        CONSTRAINT [PK_DWD_etl_wifi_rssi_repair_state]
            PRIMARY KEY CLUSTERED ([repair_name]),
        CONSTRAINT [CK_DWD_etl_wifi_rssi_repair_state_status]
            CHECK ([repair_status] IN (N'RUNNING', N'PARTIAL', N'COMPLETE', N'FAILED'))
    );
END;
GO

IF OBJECT_ID(N'[DWD].[etl_wifi_rssi_repair_hour_queue]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[etl_wifi_rssi_repair_hour_queue] (
        [repair_name] NVARCHAR(100) NOT NULL,
        [stat_hour] DATETIME2(0) NOT NULL,
        [robot_code] NVARCHAR(100) NOT NULL,
        [is_processed] BIT NOT NULL,
        [first_queued_at] DATETIME2(3) NOT NULL,
        [last_queued_at] DATETIME2(3) NOT NULL,
        [processed_at] DATETIME2(3) NULL,
        CONSTRAINT [PK_DWD_etl_wifi_rssi_repair_hour_queue]
            PRIMARY KEY CLUSTERED (
                [repair_name],
                [stat_hour],
                [robot_code]
            )
    );
END;
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes AS i
    WHERE i.[object_id] = OBJECT_ID(N'[DWD].[etl_wifi_rssi_repair_hour_queue]', N'U')
      AND i.[name] = N'IX_DWD_wifi_rssi_repair_hour_queue_pending'
)
BEGIN
    CREATE INDEX [IX_DWD_wifi_rssi_repair_hour_queue_pending]
        ON [DWD].[etl_wifi_rssi_repair_hour_queue] (
            [is_processed],
            [repair_name],
            [stat_hour],
            [robot_code]
        );
END;
GO

CREATE OR ALTER PROCEDURE [DWD].[sp_backfill_fact_robot_wifi_rssi]
    @execute BIT = 0,
    @source_rows_per_batch INT = 100000,
    @max_batches INT = 10
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @repair_name NVARCHAR(100) = N'FACT_ROBOT_WIFI_RSSI_V1',
        @mapping_candidate NVARCHAR(4000) =
            N'(N''rssi'', N''decimal18'', N''wifi_signal_level'', 20),',
        @last_source_ods_row_id BIGINT,
        @upper_source_ods_row_id BIGINT,
        @range_start BIGINT,
        @range_end BIGINT,
        @batch_number INT = 0,
        @rows_selected BIGINT = 0,
        @rows_updated BIGINT = 0,
        @run_rows_updated BIGINT = 0,
        @lock_result INT,
        @error_message NVARCHAR(4000);

    IF @source_rows_per_batch < 1000 OR @source_rows_per_batch > 500000
    BEGIN
        RAISERROR(N'@source_rows_per_batch must be between 1,000 and 500,000.', 16, 1);
        RETURN;
    END;

    IF @max_batches < 1 OR @max_batches > 1000
    BEGIN
        RAISERROR(N'@max_batches must be between 1 and 1,000.', 16, 1);
        RETURN;
    END;

    IF OBJECT_ID(N'[ODS].[robot_wifi_history]', N'U') IS NULL
       OR OBJECT_ID(N'[DWD].[fact_robot_wifi]', N'U') IS NULL
    BEGIN
        RAISERROR(N'The required ODS or DWD WiFi table is missing.', 16, 1);
        RETURN;
    END;

    IF OBJECT_ID(N'[DWD].[sp_load_dwd_all_incremental]', N'P') IS NULL
       OR CHARINDEX(
            @mapping_candidate,
            ISNULL(
                OBJECT_DEFINITION(
                    OBJECT_ID(N'[DWD].[sp_load_dwd_all_incremental]', N'P')
                ),
                N''
            )
       ) = 0
    BEGIN
        RAISERROR(N'Install 58_fix_dwd_wifi_rssi_future_mapping.sql before executing the historical repair.', 16, 1);
        RETURN;
    END;

    SELECT
        @upper_source_ods_row_id = ISNULL(MAX(fw.[source_ods_row_id]), 0)
    FROM [DWD].[fact_robot_wifi] AS fw
    WHERE fw.[source_schema] = N'ODS'
      AND fw.[source_table] = N'robot_wifi_history'
      AND fw.[source_ods_row_id] IS NOT NULL;

    SELECT
        @last_source_ods_row_id = rs.[last_source_ods_row_id],
        @upper_source_ods_row_id = rs.[upper_source_ods_row_id]
    FROM [DWD].[etl_wifi_rssi_repair_state] AS rs
    WHERE rs.[repair_name] = @repair_name;

    SET @last_source_ods_row_id = ISNULL(@last_source_ods_row_id, 0);
    SET @upper_source_ods_row_id = ISNULL(@upper_source_ods_row_id, 0);
    SET @range_start = @last_source_ods_row_id + 1;
    SET @range_end =
        CASE
            WHEN @range_start + CONVERT(BIGINT, @source_rows_per_batch) - 1
                 < @upper_source_ods_row_id
                THEN @range_start + CONVERT(BIGINT, @source_rows_per_batch) - 1
            ELSE @upper_source_ods_row_id
        END;

    /*
        Preview before any UPDATE.
        The candidate count is limited to the next source-ID range.
    */
    SELECT
        @repair_name AS [repair_name],
        @execute AS [execute_requested],
        @last_source_ods_row_id AS [last_committed_source_ods_row_id],
        @upper_source_ods_row_id AS [repair_upper_source_ods_row_id],
        @range_start AS [next_range_start],
        @range_end AS [next_range_end],
        @source_rows_per_batch AS [source_rows_per_batch],
        @max_batches AS [max_batches],
        CASE
            WHEN @last_source_ods_row_id >= @upper_source_ods_row_id THEN N'COMPLETE'
            ELSE N'PENDING'
        END AS [preview_status];

    IF @range_start <= @range_end
    BEGIN
        SELECT
            COUNT_BIG(*) AS [next_range_rows_to_update],
            MIN(fw.[source_ods_row_id]) AS [first_source_ods_row_id],
            MAX(fw.[source_ods_row_id]) AS [last_source_ods_row_id],
            MIN(fw.[sample_time]) AS [first_sample_time],
            MAX(fw.[sample_time]) AS [last_sample_time]
        FROM [ODS].[robot_wifi_history] AS ow
        JOIN [DWD].[fact_robot_wifi] AS fw
            ON fw.[source_schema] = N'ODS'
           AND fw.[source_table] = N'robot_wifi_history'
           AND fw.[source_ods_row_id] = ow.[ods_row_id]
        WHERE ow.[ods_row_id] >= @range_start
          AND ow.[ods_row_id] <= @range_end
          AND ow.[wifi_signal_level] IS NOT NULL
          AND fw.[rssi] IS NULL;

        SELECT TOP (20)
            fw.[wifi_fact_id],
            fw.[source_ods_row_id],
            fw.[robot_code],
            fw.[sample_time],
            fw.[rssi] AS [current_dwd_rssi],
            TRY_CONVERT(DECIMAL(18,6), ow.[wifi_signal_level]) AS [proposed_dwd_rssi]
        FROM [ODS].[robot_wifi_history] AS ow
        JOIN [DWD].[fact_robot_wifi] AS fw
            ON fw.[source_schema] = N'ODS'
           AND fw.[source_table] = N'robot_wifi_history'
           AND fw.[source_ods_row_id] = ow.[ods_row_id]
        WHERE ow.[ods_row_id] >= @range_start
          AND ow.[ods_row_id] <= @range_end
          AND ow.[wifi_signal_level] IS NOT NULL
          AND fw.[rssi] IS NULL
        ORDER BY fw.[source_ods_row_id];
    END;

    IF @execute = 0
    BEGIN
        SELECT
            N'PREVIEW_ONLY' AS [run_status],
            N'No DWD business rows were changed. Execute with @execute = 1 after reviewing the preview.' AS [run_message];
        RETURN;
    END;

    EXEC @lock_result = sys.sp_getapplock
        @Resource = N'DWD.WIFI_RSSI_REPAIR_PIPELINE',
        @LockMode = N'Exclusive',
        @LockOwner = N'Session',
        @LockTimeout = 0;

    IF @lock_result < 0
    BEGIN
        RAISERROR(N'Another WiFi RSSI backfill session is already running.', 16, 1);
        RETURN;
    END;

    IF NOT EXISTS (
        SELECT 1
        FROM [DWD].[etl_wifi_rssi_repair_state] AS rs
        WHERE rs.[repair_name] = @repair_name
    )
    BEGIN
        SELECT
            @upper_source_ods_row_id = ISNULL(MAX(fw.[source_ods_row_id]), 0)
        FROM [DWD].[fact_robot_wifi] AS fw
        WHERE fw.[source_schema] = N'ODS'
          AND fw.[source_table] = N'robot_wifi_history'
          AND fw.[source_ods_row_id] IS NOT NULL;

        BEGIN TRY
            BEGIN TRANSACTION;

            INSERT INTO [DWD].[etl_wifi_rssi_repair_state] (
                [repair_name],
                [last_source_ods_row_id],
                [upper_source_ods_row_id],
                [repair_status],
                [total_rows_updated],
                [started_at],
                [last_batch_at],
                [completed_at],
                [error_message]
            )
            VALUES (
                @repair_name,
                0,
                @upper_source_ods_row_id,
                N'RUNNING',
                0,
                SYSDATETIME(),
                NULL,
                NULL,
                NULL
            );

            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0
            BEGIN
                ROLLBACK TRANSACTION;
            END;

            SET @error_message = ERROR_MESSAGE();
            EXEC sys.sp_releaseapplock
                @Resource = N'DWD.WIFI_RSSI_REPAIR_PIPELINE',
                @LockOwner = N'Session';
            RAISERROR(N'Unable to initialize the repair state: %s', 16, 1, @error_message);
            RETURN;
        END CATCH;
    END;

    IF OBJECT_ID(N'tempdb..#wifi_rssi_repair_rows', N'U') IS NOT NULL
    BEGIN
        DROP TABLE #wifi_rssi_repair_rows;
    END;

    CREATE TABLE #wifi_rssi_repair_rows (
        [wifi_fact_id] BIGINT NOT NULL,
        [source_ods_row_id] BIGINT NOT NULL,
        [new_rssi] DECIMAL(18,6) NOT NULL,
        [stat_hour] DATETIME2(0) NULL,
        [robot_code] NVARCHAR(100) NULL,
        PRIMARY KEY CLUSTERED ([wifi_fact_id])
    );

    IF OBJECT_ID(N'tempdb..#wifi_rssi_repair_hours', N'U') IS NOT NULL
    BEGIN
        DROP TABLE #wifi_rssi_repair_hours;
    END;

    CREATE TABLE #wifi_rssi_repair_hours (
        [stat_hour] DATETIME2(0) NOT NULL,
        [robot_code] NVARCHAR(100) NOT NULL,
        PRIMARY KEY CLUSTERED ([stat_hour], [robot_code])
    );

    BEGIN TRY
        WHILE @batch_number < @max_batches
        BEGIN
            SELECT
                @last_source_ods_row_id = rs.[last_source_ods_row_id],
                @upper_source_ods_row_id = rs.[upper_source_ods_row_id]
            FROM [DWD].[etl_wifi_rssi_repair_state] AS rs
            WHERE rs.[repair_name] = @repair_name;

            IF @last_source_ods_row_id >= @upper_source_ods_row_id
            BEGIN
                UPDATE rs
                SET
                    rs.[repair_status] = N'COMPLETE',
                    rs.[completed_at] = COALESCE(rs.[completed_at], SYSDATETIME()),
                    rs.[error_message] = NULL
                FROM [DWD].[etl_wifi_rssi_repair_state] AS rs
                WHERE rs.[repair_name] = @repair_name
                  AND rs.[last_source_ods_row_id] >= rs.[upper_source_ods_row_id];
                BREAK;
            END;

            SET @range_start = @last_source_ods_row_id + 1;
            SET @range_end =
                CASE
                    WHEN @range_start + CONVERT(BIGINT, @source_rows_per_batch) - 1
                         < @upper_source_ods_row_id
                        THEN @range_start + CONVERT(BIGINT, @source_rows_per_batch) - 1
                    ELSE @upper_source_ods_row_id
                END;

            TRUNCATE TABLE #wifi_rssi_repair_rows;
            TRUNCATE TABLE #wifi_rssi_repair_hours;

            INSERT INTO #wifi_rssi_repair_rows (
                [wifi_fact_id],
                [source_ods_row_id],
                [new_rssi],
                [stat_hour],
                [robot_code]
            )
            SELECT
                fw.[wifi_fact_id],
                fw.[source_ods_row_id],
                TRY_CONVERT(DECIMAL(18,6), ow.[wifi_signal_level]) AS [new_rssi],
                CASE
                    WHEN fw.[sample_time] IS NOT NULL
                        THEN DATEADD(HOUR, DATEDIFF(HOUR, 0, fw.[sample_time]), 0)
                    ELSE NULL
                END AS [stat_hour],
                CASE
                    WHEN fw.[sample_time] IS NOT NULL
                        THEN COALESCE(
                            NULLIF(fw.[robot_code], N''),
                            NULLIF(fw.[robot_id], N''),
                            N'UNKNOWN'
                        )
                    ELSE NULL
                END AS [robot_code]
            FROM [ODS].[robot_wifi_history] AS ow
            JOIN [DWD].[fact_robot_wifi] AS fw
                ON fw.[source_schema] = N'ODS'
               AND fw.[source_table] = N'robot_wifi_history'
               AND fw.[source_ods_row_id] = ow.[ods_row_id]
            WHERE ow.[ods_row_id] >= @range_start
              AND ow.[ods_row_id] <= @range_end
              AND ow.[wifi_signal_level] IS NOT NULL
              AND TRY_CONVERT(DECIMAL(18,6), ow.[wifi_signal_level]) IS NOT NULL
              AND fw.[rssi] IS NULL;

            SET @rows_selected = @@ROWCOUNT;

            INSERT INTO #wifi_rssi_repair_hours (
                [stat_hour],
                [robot_code]
            )
            SELECT DISTINCT
                rr.[stat_hour],
                rr.[robot_code]
            FROM #wifi_rssi_repair_rows AS rr
            WHERE rr.[stat_hour] IS NOT NULL
              AND rr.[robot_code] IS NOT NULL;

            BEGIN TRANSACTION;

            UPDATE q
            SET
                q.[is_processed] = 0,
                q.[last_queued_at] = SYSDATETIME(),
                q.[processed_at] = NULL
            FROM [DWD].[etl_wifi_rssi_repair_hour_queue] AS q
            JOIN #wifi_rssi_repair_hours AS rh
                ON rh.[stat_hour] = q.[stat_hour]
               AND rh.[robot_code] = q.[robot_code]
            WHERE q.[repair_name] = @repair_name;

            INSERT INTO [DWD].[etl_wifi_rssi_repair_hour_queue] (
                [repair_name],
                [stat_hour],
                [robot_code],
                [is_processed],
                [first_queued_at],
                [last_queued_at],
                [processed_at]
            )
            SELECT
                @repair_name,
                rh.[stat_hour],
                rh.[robot_code],
                0,
                SYSDATETIME(),
                SYSDATETIME(),
                NULL
            FROM #wifi_rssi_repair_hours AS rh
            WHERE NOT EXISTS (
                SELECT 1
                FROM [DWD].[etl_wifi_rssi_repair_hour_queue] AS q WITH (UPDLOCK, HOLDLOCK)
                WHERE q.[repair_name] = @repair_name
                  AND q.[stat_hour] = rh.[stat_hour]
                  AND q.[robot_code] = rh.[robot_code]
            );

            UPDATE fw
            SET
                fw.[rssi] = rr.[new_rssi]
            FROM [DWD].[fact_robot_wifi] AS fw
            JOIN #wifi_rssi_repair_rows AS rr
                ON rr.[wifi_fact_id] = fw.[wifi_fact_id]
            WHERE fw.[rssi] IS NULL;

            SET @rows_updated = @@ROWCOUNT;
            SET @run_rows_updated = @run_rows_updated + @rows_updated;

            UPDATE rs
            SET
                rs.[last_source_ods_row_id] = @range_end,
                rs.[repair_status] =
                    CASE
                        WHEN @range_end >= rs.[upper_source_ods_row_id] THEN N'COMPLETE'
                        ELSE N'PARTIAL'
                    END,
                rs.[total_rows_updated] = rs.[total_rows_updated] + @rows_updated,
                rs.[last_batch_at] = SYSDATETIME(),
                rs.[completed_at] =
                    CASE
                        WHEN @range_end >= rs.[upper_source_ods_row_id] THEN SYSDATETIME()
                        ELSE NULL
                    END,
                rs.[error_message] = NULL
            FROM [DWD].[etl_wifi_rssi_repair_state] AS rs
            WHERE rs.[repair_name] = @repair_name;

            COMMIT TRANSACTION;

            SET @batch_number = @batch_number + 1;

            RAISERROR(
                N'WiFi RSSI repair batch %d committed. Source rows %I64d-%I64d, candidates %I64d, updated %I64d.',
                10,
                1,
                @batch_number,
                @range_start,
                @range_end,
                @rows_selected,
                @rows_updated
            ) WITH NOWAIT;
        END;
    END TRY
    BEGIN CATCH
        SET @error_message = ERROR_MESSAGE();

        IF XACT_STATE() <> 0
        BEGIN
            ROLLBACK TRANSACTION;
        END;

        UPDATE rs
        SET
            rs.[repair_status] = N'FAILED',
            rs.[last_batch_at] = SYSDATETIME(),
            rs.[error_message] = @error_message
        FROM [DWD].[etl_wifi_rssi_repair_state] AS rs
        WHERE rs.[repair_name] = @repair_name;

        EXEC sys.sp_releaseapplock
            @Resource = N'DWD.WIFI_RSSI_REPAIR_PIPELINE',
            @LockOwner = N'Session';

        RAISERROR(N'WiFi RSSI historical repair failed: %s', 16, 1, @error_message);
        RETURN;
    END CATCH;

    EXEC sys.sp_releaseapplock
        @Resource = N'DWD.WIFI_RSSI_REPAIR_PIPELINE',
        @LockOwner = N'Session';

    SELECT
        rs.[repair_name],
        rs.[last_source_ods_row_id],
        rs.[upper_source_ods_row_id],
        rs.[repair_status],
        rs.[total_rows_updated],
        @run_rows_updated AS [rows_updated_this_run],
        @batch_number AS [batches_committed_this_run],
        rs.[started_at],
        rs.[last_batch_at],
        rs.[completed_at],
        rs.[error_message]
    FROM [DWD].[etl_wifi_rssi_repair_state] AS rs
    WHERE rs.[repair_name] = @repair_name;

    SELECT
        COUNT_BIG(*) AS [pending_dws_robot_hours]
    FROM [DWD].[etl_wifi_rssi_repair_hour_queue] AS q
    WHERE q.[repair_name] = @repair_name
      AND q.[is_processed] = 0;
END;
GO

/*
    Installation verification only. No DWD business data is changed here.
*/
SELECT
    CASE
        WHEN OBJECT_ID(N'[DWD].[sp_backfill_fact_robot_wifi_rssi]', N'P') IS NOT NULL THEN 1
        ELSE 0
    END AS [repair_procedure_installed],
    CASE
        WHEN OBJECT_ID(N'[DWD].[etl_wifi_rssi_repair_state]', N'U') IS NOT NULL THEN 1
        ELSE 0
    END AS [repair_state_table_installed],
    CASE
        WHEN OBJECT_ID(N'[DWD].[etl_wifi_rssi_repair_hour_queue]', N'U') IS NOT NULL THEN 1
        ELSE 0
    END AS [repair_hour_queue_installed];
GO

/*
    Manual execution examples:

    1. Preview the next 100,000 source IDs:
       EXEC [DWD].[sp_backfill_fact_robot_wifi_rssi]
           @execute = 0,
           @source_rows_per_batch = 100000,
           @max_batches = 10;

    2. After reviewing the preview, commit at most 10 batches:
       EXEC [DWD].[sp_backfill_fact_robot_wifi_rssi]
           @execute = 1,
           @source_rows_per_batch = 100000,
           @max_batches = 10;

    Re-run command 2 until repair_status becomes COMPLETE.
*/
