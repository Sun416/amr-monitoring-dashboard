USE [IOT2020];
GO

/*
    Install a targeted DWS refresh for robot-hours queued by the DWD RSSI
    historical repair.

    Safety:
      - Installing this script does not change DWS business rows.
      - The installed procedure defaults to @execute = 0.
      - Only queued robot_code + stat_hour keys are recalculated.
      - No business-table DELETE/TRUNCATE, MERGE, or full-table aggregation
        is used. TRUNCATE is used only for local temporary work tables.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'[DWD].[fact_robot_wifi]', N'U') IS NULL
BEGIN
    RAISERROR(N'Missing source table: DWD.fact_robot_wifi.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'[DWD].[etl_wifi_rssi_repair_hour_queue]', N'U') IS NULL
BEGIN
    RAISERROR(N'Missing repair queue. Run 59_install_dwd_wifi_rssi_batched_backfill.sql first.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'[DWS].[dws_robot_wifi_hourly]', N'U') IS NULL
   OR OBJECT_ID(N'[DWS].[etl_batch]', N'U') IS NULL
   OR OBJECT_ID(N'[DWS].[etl_load_log]', N'U') IS NULL
BEGIN
    RAISERROR(N'Missing DWS WiFi target or DWS ETL log tables.', 16, 1);
    RETURN;
END;
GO

CREATE OR ALTER PROCEDURE [DWS].[sp_refresh_robot_wifi_hourly_repaired]
    @execute BIT = 0,
    @keys_per_batch INT = 500,
    @max_batches INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @repair_name NVARCHAR(100) = N'FACT_ROBOT_WIFI_RSSI_V1',
        @batch_id BIGINT = NULL,
        @batch_number INT = 0,
        @key_count INT = 0,
        @missing_aggregate_count INT = 0,
        @rows_updated BIGINT = 0,
        @rows_inserted BIGINT = 0,
        @batch_rows_updated BIGINT = 0,
        @batch_rows_inserted BIGINT = 0,
        @affected_rows BIGINT = 0,
        @run_started_at DATETIME2(3) = SYSDATETIME(),
        @lock_result INT,
        @error_message NVARCHAR(4000);

    IF @keys_per_batch < 1 OR @keys_per_batch > 5000
    BEGIN
        RAISERROR(N'@keys_per_batch must be between 1 and 5,000.', 16, 1);
        RETURN;
    END;

    IF @max_batches < 1 OR @max_batches > 1000
    BEGIN
        RAISERROR(N'@max_batches must be between 1 and 1,000.', 16, 1);
        RETURN;
    END;

    IF OBJECT_ID(N'[DWD].[etl_wifi_rssi_repair_hour_queue]', N'U') IS NULL
       OR OBJECT_ID(N'[DWD].[fact_robot_wifi]', N'U') IS NULL
       OR OBJECT_ID(N'[DWS].[dws_robot_wifi_hourly]', N'U') IS NULL
    BEGIN
        RAISERROR(N'The repair queue, DWD WiFi fact, or DWS WiFi table is missing.', 16, 1);
        RETURN;
    END;

    /* Pre-execution preview. */
    SELECT
        @execute AS [execute_requested],
        COUNT_BIG(*) AS [pending_robot_hours],
        MIN(q.[stat_hour]) AS [first_pending_hour],
        MAX(q.[stat_hour]) AS [last_pending_hour],
        @keys_per_batch AS [keys_per_batch],
        @max_batches AS [max_batches]
    FROM [DWD].[etl_wifi_rssi_repair_hour_queue] AS q
    WHERE q.[repair_name] = @repair_name
      AND q.[is_processed] = 0;

    SELECT TOP (20)
        q.[stat_hour],
        q.[robot_code],
        q.[first_queued_at],
        q.[last_queued_at]
    FROM [DWD].[etl_wifi_rssi_repair_hour_queue] AS q
    WHERE q.[repair_name] = @repair_name
      AND q.[is_processed] = 0
    ORDER BY
        q.[stat_hour],
        q.[robot_code];

    IF @execute = 0
    BEGIN
        SELECT
            N'PREVIEW_ONLY' AS [run_status],
            N'No DWS business rows were changed. Execute with @execute = 1 after reviewing the pending keys.' AS [run_message];
        RETURN;
    END;

    IF NOT EXISTS (
        SELECT 1
        FROM [DWD].[etl_wifi_rssi_repair_hour_queue] AS q
        WHERE q.[repair_name] = @repair_name
          AND q.[is_processed] = 0
    )
    BEGIN
        SELECT
            N'NO_PENDING_KEYS' AS [run_status],
            N'The DWS repair queue is already empty.' AS [run_message];
        RETURN;
    END;

    EXEC @lock_result = sys.sp_getapplock
        @Resource = N'DWD.WIFI_RSSI_REPAIR_PIPELINE',
        @LockMode = N'Exclusive',
        @LockOwner = N'Session',
        @LockTimeout = 0;

    IF @lock_result < 0
    BEGIN
        RAISERROR(N'The DWD RSSI repair or another targeted DWS refresh is currently running.', 16, 1);
        RETURN;
    END;

    BEGIN TRY
    INSERT INTO [DWS].[etl_batch] (
        [batch_start_time],
        [batch_end_time],
        [batch_status],
        [error_message]
    )
    VALUES (
        @run_started_at,
        NULL,
        N'RUNNING',
        NULL
    );

    SET @batch_id = SCOPE_IDENTITY();

    IF OBJECT_ID(N'tempdb..#wifi_hour_keys', N'U') IS NOT NULL
    BEGIN
        DROP TABLE #wifi_hour_keys;
    END;

    CREATE TABLE #wifi_hour_keys (
        [stat_hour] DATETIME2(0) NOT NULL,
        [robot_code] NVARCHAR(100) NOT NULL,
        PRIMARY KEY CLUSTERED ([robot_code], [stat_hour])
    );

    IF OBJECT_ID(N'tempdb..#wifi_hour_aggregate', N'U') IS NOT NULL
    BEGIN
        DROP TABLE #wifi_hour_aggregate;
    END;

    CREATE TABLE #wifi_hour_aggregate (
        [stat_hour] DATETIME2(0) NOT NULL,
        [robot_code] NVARCHAR(100) NOT NULL,
        [robot_id] NVARCHAR(100) NULL,
        [sample_count] BIGINT NOT NULL,
        [avg_rssi] DECIMAL(18,6) NULL,
        [min_rssi] DECIMAL(18,6) NULL,
        [max_rssi] DECIMAL(18,6) NULL,
        [weak_signal_sample_count] BIGINT NOT NULL,
        [first_sample_time] DATETIME2(3) NULL,
        [last_sample_time] DATETIME2(3) NULL,
        [source_min_fact_id] BIGINT NULL,
        [source_max_fact_id] BIGINT NULL,
        PRIMARY KEY CLUSTERED ([robot_code], [stat_hour])
    );

        WHILE @batch_number < @max_batches
        BEGIN
            TRUNCATE TABLE #wifi_hour_keys;
            TRUNCATE TABLE #wifi_hour_aggregate;
            SET @batch_rows_updated = 0;
            SET @batch_rows_inserted = 0;

            INSERT INTO #wifi_hour_keys (
                [stat_hour],
                [robot_code]
            )
            SELECT TOP (@keys_per_batch)
                q.[stat_hour],
                q.[robot_code]
            FROM [DWD].[etl_wifi_rssi_repair_hour_queue] AS q
            WHERE q.[repair_name] = @repair_name
              AND q.[is_processed] = 0
            ORDER BY
                q.[stat_hour],
                q.[robot_code];

            SET @key_count = @@ROWCOUNT;

            IF @key_count = 0
            BEGIN
                BREAK;
            END;

            /*
                Normal path: robot_code is present in DWD and can use the
                existing (robot_code, sample_time) index.
            */
            INSERT INTO #wifi_hour_aggregate (
                [stat_hour],
                [robot_code],
                [robot_id],
                [sample_count],
                [avg_rssi],
                [min_rssi],
                [max_rssi],
                [weak_signal_sample_count],
                [first_sample_time],
                [last_sample_time],
                [source_min_fact_id],
                [source_max_fact_id]
            )
            SELECT
                k.[stat_hour],
                k.[robot_code],
                MAX(fw.[robot_id]) AS [robot_id],
                COUNT_BIG(*) AS [sample_count],
                AVG(CASE WHEN fw.[rssi] < 0 THEN fw.[rssi] END) AS [avg_rssi],
                MIN(CASE WHEN fw.[rssi] < 0 THEN fw.[rssi] END) AS [min_rssi],
                MAX(CASE WHEN fw.[rssi] < 0 THEN fw.[rssi] END) AS [max_rssi],
                SUM(
                    CASE
                        WHEN fw.[rssi] = 0 THEN CONVERT(BIGINT, 1)
                        WHEN fw.[rssi] <= -70 THEN CONVERT(BIGINT, 1)
                        ELSE CONVERT(BIGINT, 0)
                    END
                ) AS [weak_signal_sample_count],
                MIN(fw.[sample_time]) AS [first_sample_time],
                MAX(fw.[sample_time]) AS [last_sample_time],
                MIN(fw.[wifi_fact_id]) AS [source_min_fact_id],
                MAX(fw.[wifi_fact_id]) AS [source_max_fact_id]
            FROM #wifi_hour_keys AS k
            JOIN [DWD].[fact_robot_wifi] AS fw
                ON fw.[robot_code] = k.[robot_code]
               AND fw.[sample_time] >= k.[stat_hour]
               AND fw.[sample_time] < DATEADD(HOUR, 1, k.[stat_hour])
            GROUP BY
                k.[stat_hour],
                k.[robot_code];

            /*
                Fallback path. It runs only for queued keys that have no row
                through the normal robot_code mapping.
            */
            INSERT INTO #wifi_hour_aggregate (
                [stat_hour],
                [robot_code],
                [robot_id],
                [sample_count],
                [avg_rssi],
                [min_rssi],
                [max_rssi],
                [weak_signal_sample_count],
                [first_sample_time],
                [last_sample_time],
                [source_min_fact_id],
                [source_max_fact_id]
            )
            SELECT
                k.[stat_hour],
                k.[robot_code],
                MAX(fw.[robot_id]) AS [robot_id],
                COUNT_BIG(*) AS [sample_count],
                AVG(CASE WHEN fw.[rssi] < 0 THEN fw.[rssi] END) AS [avg_rssi],
                MIN(CASE WHEN fw.[rssi] < 0 THEN fw.[rssi] END) AS [min_rssi],
                MAX(CASE WHEN fw.[rssi] < 0 THEN fw.[rssi] END) AS [max_rssi],
                SUM(
                    CASE
                        WHEN fw.[rssi] = 0 THEN CONVERT(BIGINT, 1)
                        WHEN fw.[rssi] <= -70 THEN CONVERT(BIGINT, 1)
                        ELSE CONVERT(BIGINT, 0)
                    END
                ) AS [weak_signal_sample_count],
                MIN(fw.[sample_time]) AS [first_sample_time],
                MAX(fw.[sample_time]) AS [last_sample_time],
                MIN(fw.[wifi_fact_id]) AS [source_min_fact_id],
                MAX(fw.[wifi_fact_id]) AS [source_max_fact_id]
            FROM #wifi_hour_keys AS k
            JOIN [DWD].[fact_robot_wifi] AS fw
                ON (fw.[robot_code] IS NULL OR fw.[robot_code] = N'')
               AND fw.[robot_id] = k.[robot_code]
               AND fw.[sample_time] >= k.[stat_hour]
               AND fw.[sample_time] < DATEADD(HOUR, 1, k.[stat_hour])
            WHERE NOT EXISTS (
                SELECT 1
                FROM #wifi_hour_aggregate AS a
                WHERE a.[robot_code] = k.[robot_code]
                  AND a.[stat_hour] = k.[stat_hour]
            )
            GROUP BY
                k.[stat_hour],
                k.[robot_code];

            INSERT INTO #wifi_hour_aggregate (
                [stat_hour],
                [robot_code],
                [robot_id],
                [sample_count],
                [avg_rssi],
                [min_rssi],
                [max_rssi],
                [weak_signal_sample_count],
                [first_sample_time],
                [last_sample_time],
                [source_min_fact_id],
                [source_max_fact_id]
            )
            SELECT
                k.[stat_hour],
                k.[robot_code],
                NULL AS [robot_id],
                COUNT_BIG(*) AS [sample_count],
                AVG(CASE WHEN fw.[rssi] < 0 THEN fw.[rssi] END) AS [avg_rssi],
                MIN(CASE WHEN fw.[rssi] < 0 THEN fw.[rssi] END) AS [min_rssi],
                MAX(CASE WHEN fw.[rssi] < 0 THEN fw.[rssi] END) AS [max_rssi],
                SUM(
                    CASE
                        WHEN fw.[rssi] = 0 THEN CONVERT(BIGINT, 1)
                        WHEN fw.[rssi] <= -70 THEN CONVERT(BIGINT, 1)
                        ELSE CONVERT(BIGINT, 0)
                    END
                ) AS [weak_signal_sample_count],
                MIN(fw.[sample_time]) AS [first_sample_time],
                MAX(fw.[sample_time]) AS [last_sample_time],
                MIN(fw.[wifi_fact_id]) AS [source_min_fact_id],
                MAX(fw.[wifi_fact_id]) AS [source_max_fact_id]
            FROM #wifi_hour_keys AS k
            JOIN [DWD].[fact_robot_wifi] AS fw
                ON (fw.[robot_code] IS NULL OR fw.[robot_code] = N'')
               AND (fw.[robot_id] IS NULL OR fw.[robot_id] = N'')
               AND fw.[sample_time] >= k.[stat_hour]
               AND fw.[sample_time] < DATEADD(HOUR, 1, k.[stat_hour])
            WHERE k.[robot_code] = N'UNKNOWN'
              AND NOT EXISTS (
                    SELECT 1
                    FROM #wifi_hour_aggregate AS a
                    WHERE a.[robot_code] = k.[robot_code]
                      AND a.[stat_hour] = k.[stat_hour]
              )
            GROUP BY
                k.[stat_hour],
                k.[robot_code];

            SELECT
                @missing_aggregate_count = COUNT(*)
            FROM #wifi_hour_keys AS k
            LEFT JOIN #wifi_hour_aggregate AS a
                ON a.[robot_code] = k.[robot_code]
               AND a.[stat_hour] = k.[stat_hour]
            WHERE a.[robot_code] IS NULL;

            IF @missing_aggregate_count > 0
            BEGIN
                RAISERROR(N'%d queued robot-hours could not be re-aggregated from DWD.', 16, 1, @missing_aggregate_count);
            END;

            BEGIN TRANSACTION;

            UPDATE tgt
            SET
                tgt.[robot_id] = src.[robot_id],
                tgt.[sample_count] = src.[sample_count],
                tgt.[avg_rssi] = src.[avg_rssi],
                tgt.[min_rssi] = src.[min_rssi],
                tgt.[max_rssi] = src.[max_rssi],
                tgt.[weak_signal_sample_count] = src.[weak_signal_sample_count],
                tgt.[first_sample_time] = src.[first_sample_time],
                tgt.[last_sample_time] = src.[last_sample_time],
                tgt.[source_min_fact_id] = src.[source_min_fact_id],
                tgt.[source_max_fact_id] = src.[source_max_fact_id],
                tgt.[dws_load_time] = SYSDATETIME(),
                tgt.[dws_batch_id] = @batch_id
            FROM [DWS].[dws_robot_wifi_hourly] AS tgt
            JOIN #wifi_hour_aggregate AS src
                ON src.[robot_code] = tgt.[robot_code]
               AND src.[stat_hour] = tgt.[stat_hour]
            WHERE tgt.[robot_code] = src.[robot_code]
              AND tgt.[stat_hour] = src.[stat_hour];

            SET @batch_rows_updated = @@ROWCOUNT;

            INSERT INTO [DWS].[dws_robot_wifi_hourly] (
                [stat_hour],
                [robot_code],
                [robot_id],
                [sample_count],
                [avg_rssi],
                [min_rssi],
                [max_rssi],
                [weak_signal_sample_count],
                [first_sample_time],
                [last_sample_time],
                [source_min_fact_id],
                [source_max_fact_id],
                [dws_load_time],
                [dws_batch_id]
            )
            SELECT
                src.[stat_hour],
                src.[robot_code],
                src.[robot_id],
                src.[sample_count],
                src.[avg_rssi],
                src.[min_rssi],
                src.[max_rssi],
                src.[weak_signal_sample_count],
                src.[first_sample_time],
                src.[last_sample_time],
                src.[source_min_fact_id],
                src.[source_max_fact_id],
                SYSDATETIME(),
                @batch_id
            FROM #wifi_hour_aggregate AS src
            WHERE NOT EXISTS (
                SELECT 1
                FROM [DWS].[dws_robot_wifi_hourly] AS tgt WITH (UPDLOCK, HOLDLOCK)
                WHERE tgt.[robot_code] = src.[robot_code]
                  AND tgt.[stat_hour] = src.[stat_hour]
            );

            SET @batch_rows_inserted = @@ROWCOUNT;

            UPDATE q
            SET
                q.[is_processed] = 1,
                q.[processed_at] = SYSDATETIME()
            FROM [DWD].[etl_wifi_rssi_repair_hour_queue] AS q
            JOIN #wifi_hour_keys AS k
                ON k.[robot_code] = q.[robot_code]
               AND k.[stat_hour] = q.[stat_hour]
            WHERE q.[repair_name] = @repair_name
              AND q.[is_processed] = 0;

            COMMIT TRANSACTION;

            SET @rows_updated = @rows_updated + @batch_rows_updated;
            SET @rows_inserted = @rows_inserted + @batch_rows_inserted;
            SET @batch_number = @batch_number + 1;

            RAISERROR(
                N'DWS WiFi targeted refresh batch %d committed, robot-hours %d.',
                10,
                1,
                @batch_number,
                @key_count
            ) WITH NOWAIT;
        END;

        SET @affected_rows = @rows_updated + @rows_inserted;

        INSERT INTO [DWS].[etl_load_log] (
            [batch_id],
            [target_schema],
            [target_table],
            [source_schema],
            [source_table],
            [load_mode],
            [affected_rows],
            [load_status],
            [error_message],
            [load_start_time],
            [load_end_time]
        )
        VALUES (
            @batch_id,
            N'DWS',
            N'dws_robot_wifi_hourly',
            N'DWD',
            N'fact_robot_wifi',
            N'TARGETED_REPAIR_UPSERT',
            @affected_rows,
            N'SUCCESS',
            NULL,
            @run_started_at,
            SYSDATETIME()
        );

        UPDATE b
        SET
            b.[batch_end_time] = SYSDATETIME(),
            b.[batch_status] = N'SUCCESS',
            b.[error_message] = NULL
        FROM [DWS].[etl_batch] AS b
        WHERE b.[batch_id] = @batch_id;
    END TRY
    BEGIN CATCH
        SET @error_message = ERROR_MESSAGE();

        IF XACT_STATE() <> 0
        BEGIN
            ROLLBACK TRANSACTION;
        END;

        IF @batch_id IS NOT NULL
        BEGIN
            UPDATE b
            SET
                b.[batch_end_time] = SYSDATETIME(),
                b.[batch_status] = N'FAILED',
                b.[error_message] = @error_message
            FROM [DWS].[etl_batch] AS b
            WHERE b.[batch_id] = @batch_id;

            INSERT INTO [DWS].[etl_load_log] (
                [batch_id],
                [target_schema],
                [target_table],
                [source_schema],
                [source_table],
                [load_mode],
                [affected_rows],
                [load_status],
                [error_message],
                [load_start_time],
                [load_end_time]
            )
            VALUES (
                @batch_id,
                N'DWS',
                N'dws_robot_wifi_hourly',
                N'DWD',
                N'fact_robot_wifi',
                N'TARGETED_REPAIR_UPSERT',
                @rows_updated + @rows_inserted,
                N'FAILED',
                @error_message,
                @run_started_at,
                SYSDATETIME()
            );
        END;

        EXEC sys.sp_releaseapplock
            @Resource = N'DWD.WIFI_RSSI_REPAIR_PIPELINE',
            @LockOwner = N'Session';

        RAISERROR(N'Targeted DWS WiFi refresh failed: %s', 16, 1, @error_message);
        RETURN;
    END CATCH;

    EXEC sys.sp_releaseapplock
        @Resource = N'DWD.WIFI_RSSI_REPAIR_PIPELINE',
        @LockOwner = N'Session';

    SELECT
        @batch_id AS [dws_batch_id],
        N'SUCCESS' AS [run_status],
        @batch_number AS [batches_committed],
        @rows_updated AS [rows_updated],
        @rows_inserted AS [rows_inserted],
        @affected_rows AS [affected_rows];

    SELECT
        COUNT_BIG(*) AS [pending_robot_hours]
    FROM [DWD].[etl_wifi_rssi_repair_hour_queue] AS q
    WHERE q.[repair_name] = @repair_name
      AND q.[is_processed] = 0;
END;
GO

SELECT
    CASE
        WHEN OBJECT_ID(N'[DWS].[sp_refresh_robot_wifi_hourly_repaired]', N'P') IS NOT NULL THEN 1
        ELSE 0
    END AS [targeted_refresh_procedure_installed];
GO

/*
    Manual execution examples:

    1. Preview:
       EXEC [DWS].[sp_refresh_robot_wifi_hourly_repaired]
           @execute = 0,
           @keys_per_batch = 500,
           @max_batches = 20;

    2. Execute at most 10,000 queued robot-hours:
       EXEC [DWS].[sp_refresh_robot_wifi_hourly_repaired]
           @execute = 1,
           @keys_per_batch = 500,
           @max_batches = 20;

    Re-run command 2 until pending_robot_hours becomes 0.
*/
