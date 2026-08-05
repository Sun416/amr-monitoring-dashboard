USE [IOT2020];
GO

/*
    Priority repair for the newest WiFi rows.

    Use this to restore the monitoring dashboard without waiting for the full
    43+ million-row ascending historical scan to reach the newest records.

    This script does not change the persistent historical-repair watermark.
    Script 59 can therefore continue later and will safely skip rows already
    repaired here.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE
    @execute BIT = 1,                  -- First run: 0. After preview: change to 1.
    @recent_source_rows BIGINT = 1000000,
    @source_rows_per_batch INT = 100000,
    @refresh_dws_after_repair BIT = 1;

IF @execute NOT IN (0, 1)
BEGIN
    RAISERROR(N'@execute must be 0 or 1.', 16, 1);
    RETURN;
END;

IF @recent_source_rows < 10000 OR @recent_source_rows > 5000000
BEGIN
    RAISERROR(N'@recent_source_rows must be between 10,000 and 5,000,000.', 16, 1);
    RETURN;
END;

IF @source_rows_per_batch < 1000 OR @source_rows_per_batch > 500000
BEGIN
    RAISERROR(N'@source_rows_per_batch must be between 1,000 and 500,000.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'[ODS].[robot_wifi_history]', N'U') IS NULL
   OR OBJECT_ID(N'[DWD].[fact_robot_wifi]', N'U') IS NULL
   OR OBJECT_ID(N'[DWD].[etl_wifi_rssi_repair_hour_queue]', N'U') IS NULL
BEGIN
    RAISERROR(N'Missing ODS/DWD WiFi table or repair queue. Run scripts 58-60 first.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'[DWS].[sp_refresh_robot_wifi_hourly_repaired]', N'P') IS NULL
BEGIN
    RAISERROR(N'Missing DWS targeted refresh procedure. Run script 60 first.', 16, 1);
    RETURN;
END;

DECLARE
    @repair_name NVARCHAR(100) = N'FACT_ROBOT_WIFI_RSSI_V1',
    @upper_source_ods_row_id BIGINT,
    @lower_source_ods_row_id BIGINT,
    @range_start BIGINT,
    @range_end BIGINT,
    @rows_selected BIGINT = 0,
    @rows_updated BIGINT = 0,
    @total_rows_updated BIGINT = 0,
    @batch_number INT = 0,
    @lock_result INT,
    @error_message NVARCHAR(4000);

SELECT
    @upper_source_ods_row_id = ISNULL(MAX(fw.[source_ods_row_id]), 0)
FROM [DWD].[fact_robot_wifi] AS fw
WHERE fw.[source_schema] = N'ODS'
  AND fw.[source_table] = N'robot_wifi_history'
  AND fw.[source_ods_row_id] IS NOT NULL;

SET @lower_source_ods_row_id =
    CASE
        WHEN @upper_source_ods_row_id - @recent_source_rows + 1 > 1
            THEN @upper_source_ods_row_id - @recent_source_rows + 1
        ELSE 1
    END;

/* Pre-execution validation: inspect the exact newest range to be repaired. */
SELECT
    @execute AS [execute_requested],
    @lower_source_ods_row_id AS [source_range_start],
    @upper_source_ods_row_id AS [source_range_end],
    @recent_source_rows AS [requested_recent_source_rows],
    @source_rows_per_batch AS [source_rows_per_batch],
    @refresh_dws_after_repair AS [refresh_dws_after_repair];

SELECT
    COUNT_BIG(*) AS [rows_to_update],
    MIN(fw.[sample_time]) AS [first_sample_time],
    MAX(fw.[sample_time]) AS [last_sample_time],
    MIN(fw.[source_ods_row_id]) AS [first_source_ods_row_id],
    MAX(fw.[source_ods_row_id]) AS [last_source_ods_row_id]
FROM [ODS].[robot_wifi_history] AS ow
JOIN [DWD].[fact_robot_wifi] AS fw
    ON fw.[source_schema] = N'ODS'
   AND fw.[source_table] = N'robot_wifi_history'
   AND fw.[source_ods_row_id] = ow.[ods_row_id]
WHERE ow.[ods_row_id] >= @lower_source_ods_row_id
  AND ow.[ods_row_id] <= @upper_source_ods_row_id
  AND ow.[wifi_signal_level] IS NOT NULL
  AND TRY_CONVERT(DECIMAL(18,6), ow.[wifi_signal_level]) IS NOT NULL
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
WHERE ow.[ods_row_id] >= @lower_source_ods_row_id
  AND ow.[ods_row_id] <= @upper_source_ods_row_id
  AND ow.[wifi_signal_level] IS NOT NULL
  AND TRY_CONVERT(DECIMAL(18,6), ow.[wifi_signal_level]) IS NOT NULL
  AND fw.[rssi] IS NULL
ORDER BY fw.[source_ods_row_id] DESC;

IF @execute = 0
BEGIN
    SELECT
        N'PREVIEW_ONLY' AS [run_status],
        N'No rows were changed. Set @execute = 1 at the top of this file after reviewing the preview.' AS [run_message];
    RETURN;
END;

EXEC @lock_result = sys.sp_getapplock
    @Resource = N'DWD.WIFI_RSSI_REPAIR_PIPELINE',
    @LockMode = N'Exclusive',
    @LockOwner = N'Session',
    @LockTimeout = 0;

IF @lock_result < 0
BEGIN
    RAISERROR(N'Another WiFi RSSI repair or DWS refresh is running.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'tempdb..#recent_wifi_rssi_rows', N'U') IS NOT NULL
BEGIN
    DROP TABLE #recent_wifi_rssi_rows;
END;

CREATE TABLE #recent_wifi_rssi_rows (
    [wifi_fact_id] BIGINT NOT NULL,
    [new_rssi] DECIMAL(18,6) NOT NULL,
    [stat_hour] DATETIME2(0) NULL,
    [robot_code] NVARCHAR(100) NULL,
    PRIMARY KEY CLUSTERED ([wifi_fact_id])
);

IF OBJECT_ID(N'tempdb..#recent_wifi_rssi_hours', N'U') IS NOT NULL
BEGIN
    DROP TABLE #recent_wifi_rssi_hours;
END;

CREATE TABLE #recent_wifi_rssi_hours (
    [stat_hour] DATETIME2(0) NOT NULL,
    [robot_code] NVARCHAR(100) NOT NULL,
    PRIMARY KEY CLUSTERED ([stat_hour], [robot_code])
);

SET @range_start = @lower_source_ods_row_id;

BEGIN TRY
    WHILE @range_start <= @upper_source_ods_row_id
    BEGIN
        SET @range_end =
            CASE
                WHEN @range_start + CONVERT(BIGINT, @source_rows_per_batch) - 1
                     < @upper_source_ods_row_id
                    THEN @range_start + CONVERT(BIGINT, @source_rows_per_batch) - 1
                ELSE @upper_source_ods_row_id
            END;

        TRUNCATE TABLE #recent_wifi_rssi_rows;
        TRUNCATE TABLE #recent_wifi_rssi_hours;

        INSERT INTO #recent_wifi_rssi_rows (
            [wifi_fact_id],
            [new_rssi],
            [stat_hour],
            [robot_code]
        )
        SELECT
            fw.[wifi_fact_id],
            TRY_CONVERT(DECIMAL(18,6), ow.[wifi_signal_level]),
            CASE
                WHEN fw.[sample_time] IS NOT NULL
                    THEN DATEADD(HOUR, DATEDIFF(HOUR, 0, fw.[sample_time]), 0)
                ELSE NULL
            END,
            CASE
                WHEN fw.[sample_time] IS NOT NULL
                    THEN COALESCE(
                        NULLIF(fw.[robot_code], N''),
                        NULLIF(fw.[robot_id], N''),
                        N'UNKNOWN'
                    )
                ELSE NULL
            END
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

        INSERT INTO #recent_wifi_rssi_hours (
            [stat_hour],
            [robot_code]
        )
        SELECT DISTINCT
            rr.[stat_hour],
            rr.[robot_code]
        FROM #recent_wifi_rssi_rows AS rr
        WHERE rr.[stat_hour] IS NOT NULL
          AND rr.[robot_code] IS NOT NULL;

        BEGIN TRANSACTION;

        UPDATE q
        SET
            q.[is_processed] = 0,
            q.[last_queued_at] = SYSDATETIME(),
            q.[processed_at] = NULL
        FROM [DWD].[etl_wifi_rssi_repair_hour_queue] AS q
        JOIN #recent_wifi_rssi_hours AS rh
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
        FROM #recent_wifi_rssi_hours AS rh
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
        JOIN #recent_wifi_rssi_rows AS rr
            ON rr.[wifi_fact_id] = fw.[wifi_fact_id]
        WHERE fw.[rssi] IS NULL;

        SET @rows_updated = @@ROWCOUNT;

        COMMIT TRANSACTION;

        SET @total_rows_updated = @total_rows_updated + @rows_updated;
        SET @batch_number = @batch_number + 1;

        RAISERROR(
            N'Recent RSSI batch %d committed. Source range %I64d-%I64d, candidates %I64d, updated %I64d.',
            10,
            1,
            @batch_number,
            @range_start,
            @range_end,
            @rows_selected,
            @rows_updated
        ) WITH NOWAIT;

        SET @range_start = @range_end + 1;
    END;
END TRY
BEGIN CATCH
    SET @error_message = ERROR_MESSAGE();

    IF XACT_STATE() <> 0
    BEGIN
        ROLLBACK TRANSACTION;
    END;

    EXEC sys.sp_releaseapplock
        @Resource = N'DWD.WIFI_RSSI_REPAIR_PIPELINE',
        @LockOwner = N'Session';

    RAISERROR(N'Recent WiFi RSSI repair failed: %s', 16, 1, @error_message);
    RETURN;
END CATCH;

EXEC sys.sp_releaseapplock
    @Resource = N'DWD.WIFI_RSSI_REPAIR_PIPELINE',
    @LockOwner = N'Session';

SELECT
    N'DWD_REPAIR_SUCCESS' AS [run_status],
    @batch_number AS [batches_committed],
    @total_rows_updated AS [total_rows_updated],
    @lower_source_ods_row_id AS [source_range_start],
    @upper_source_ods_row_id AS [source_range_end];

IF @refresh_dws_after_repair = 1
BEGIN
    EXEC [DWS].[sp_refresh_robot_wifi_hourly_repaired]
        @execute = 1,
        @keys_per_batch = 500,
        @max_batches = 100;
END;
GO
