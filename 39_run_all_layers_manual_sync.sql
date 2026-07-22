USE [IOT2020];
GO



SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE
    @run_started_at DATETIME2(3) = SYSDATETIME(),
    @run_finished_at DATETIME2(3),
    @current_stage NVARCHAR(100) = N'PRECHECK',
    @error_message NVARCHAR(2048),
    @raised_message NVARCHAR(2048);

/* Pre-execution validation: fail before changing data if a dependency is missing. */
IF OBJECT_ID(N'[DWS].[sp_refresh_robot_current_snapshot_fast]', N'P') IS NULL
BEGIN
    RAISERROR(N'Missing procedure: DWS.sp_refresh_robot_current_snapshot_fast. Run 46_install_dws_operational_snapshot_v2.sql first.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'[ODS].[sp_load_reference_full_replace]', N'P') IS NULL
BEGIN
    RAISERROR(N'Missing procedure: ODS.sp_load_reference_full_replace. Run 35_install_historical_analysis_sync.sql first.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'[ODS].[sp_load_id_time_incremental]', N'P') IS NULL
BEGIN
    RAISERROR(N'Missing procedure: ODS.sp_load_id_time_incremental. Run 21_run_ods_id_time_incremental.sql first.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'[DWD].[sp_load_dwd_all_incremental]', N'P') IS NULL
BEGIN
    RAISERROR(N'Missing procedure: DWD.sp_load_dwd_all_incremental. Run 02_create_dwd_load_procedure.sql first.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'[DWS].[sp_load_dws_core_upsert]', N'P') IS NULL
BEGIN
    RAISERROR(N'Missing procedure: DWS.sp_load_dws_core_upsert. Run 26_load_dws_core_upsert.sql first.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'[DWS].[sp_run_amr_historical_pipeline]', N'P') IS NULL
BEGIN
    RAISERROR(N'Missing procedure: DWS.sp_run_amr_historical_pipeline. Run 35_install_historical_analysis_sync.sql first.', 16, 1);
    RETURN;
END;

BEGIN TRY
    /* Step 1: synchronize the lightweight current-state chain. */
    SET @current_stage = N'CURRENT_SNAPSHOT';

    EXEC [DWS].[sp_refresh_robot_current_snapshot_fast];

    /*
        Step 2: synchronize reference data, historical facts, and DWS aggregates.
        The historical procedure deliberately excludes the current snapshot because
        Step 1 has already refreshed it.
    */
    SET @current_stage = N'HISTORICAL_PIPELINE';

    EXEC [DWS].[sp_run_amr_historical_pipeline];

    SET @run_finished_at = SYSDATETIME();
    SET @current_stage = N'COMPLETED';

    /* Result 1: overall execution result. */
    SELECT
        N'SUCCESS' AS [sync_status],
        @run_started_at AS [run_started_at],
        @run_finished_at AS [run_finished_at],
        DATEDIFF(SECOND, @run_started_at, @run_finished_at) AS [elapsed_seconds],
        N'ODS -> DWD -> DWS' AS [synchronized_layers];

    /* Result 2: ODS enabled mappings and their latest watermarks. */
    SELECT
        w.[source_schema],
        w.[source_table],
        w.[target_schema],
        w.[target_table],
        w.[load_mode],
        w.[watermark_column],
        w.[last_bigint_value],
        w.[last_datetime_value],
        w.[last_load_time],
        w.[is_enabled]
    FROM [ODS].[etl_watermark] AS w
    WHERE w.[is_enabled] = 1
    ORDER BY
        w.[last_load_time] DESC,
        w.[source_schema],
        w.[source_table];

    /* Result 3: DWD batches created by this execution. */
    SELECT
        b.[batch_id],
        b.[batch_start_time],
        b.[batch_end_time],
        b.[batch_status],
        DATEDIFF(SECOND, b.[batch_start_time], b.[batch_end_time]) AS [elapsed_seconds],
        COALESCE(x.[load_count], 0) AS [load_count],
        COALESCE(x.[rows_inserted], 0) AS [rows_inserted],
        COALESCE(x.[rows_updated], 0) AS [rows_updated],
        COALESCE(x.[rows_deleted], 0) AS [rows_deleted],
        COALESCE(x.[failed_load_count], 0) AS [failed_load_count],
        b.[error_message]
    FROM [DWD].[etl_batch] AS b
    OUTER APPLY (
        SELECT
            COUNT_BIG(1) AS [load_count],
            SUM(COALESCE(l.[rows_inserted], 0)) AS [rows_inserted],
            SUM(COALESCE(l.[rows_updated], 0)) AS [rows_updated],
            SUM(COALESCE(l.[rows_deleted], 0)) AS [rows_deleted],
            SUM(CASE WHEN l.[load_status] = N'FAILED' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [failed_load_count]
        FROM [DWD].[etl_load_log] AS l
        WHERE l.[batch_id] = b.[batch_id]
    ) AS x
    WHERE b.[batch_start_time] >= @run_started_at
    ORDER BY b.[batch_id] DESC;

    /* Result 4: DWS batches created by this execution. */
    SELECT
        b.[batch_id],
        b.[batch_start_time],
        b.[batch_end_time],
        b.[batch_status],
        DATEDIFF(SECOND, b.[batch_start_time], b.[batch_end_time]) AS [elapsed_seconds],
        COALESCE(x.[load_count], 0) AS [load_count],
        COALESCE(x.[affected_rows], 0) AS [affected_rows],
        COALESCE(x.[failed_load_count], 0) AS [failed_load_count],
        b.[error_message]
    FROM [DWS].[etl_batch] AS b
    OUTER APPLY (
        SELECT
            COUNT_BIG(1) AS [load_count],
            SUM(COALESCE(l.[affected_rows], 0)) AS [affected_rows],
            SUM(CASE WHEN l.[load_status] = N'FAILED' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [failed_load_count]
        FROM [DWS].[etl_load_log] AS l
        WHERE l.[batch_id] = b.[batch_id]
    ) AS x
    WHERE b.[batch_start_time] >= @run_started_at
    ORDER BY b.[batch_id] DESC;

    /* Result 5: current dashboard snapshot freshness. */
    SELECT
        COUNT_BIG(1) AS [robot_row_count],
        MAX(s.[source_event_time]) AS [latest_source_event_time],
        MAX(s.[source_snapshot_time]) AS [latest_source_snapshot_time],
        MAX(s.[dws_load_time]) AS [latest_dws_load_time]
    FROM [DWS].[dws_robot_current_snapshot] AS s;

    /* Result 6: historical DWS table freshness. */
    SELECT
        N'dws_robot_battery_hourly' AS [table_name],
        COUNT_BIG(1) AS [row_count],
        MAX(b.[dws_load_time]) AS [latest_dws_load_time]
    FROM [DWS].[dws_robot_battery_hourly] AS b

    UNION ALL

    SELECT
        N'dws_robot_status_hourly',
        COUNT_BIG(1),
        MAX(s.[dws_load_time])
    FROM [DWS].[dws_robot_status_hourly] AS s

    UNION ALL

    SELECT
        N'dws_robot_wifi_hourly',
        COUNT_BIG(1),
        MAX(w.[dws_load_time])
    FROM [DWS].[dws_robot_wifi_hourly] AS w

    UNION ALL

    SELECT
        N'dws_robot_job_daily',
        COUNT_BIG(1),
        MAX(j.[dws_load_time])
    FROM [DWS].[dws_robot_job_daily] AS j

    UNION ALL

    SELECT
        N'dws_amr_queue_daily',
        COUNT_BIG(1),
        MAX(q.[dws_load_time])
    FROM [DWS].[dws_amr_queue_daily] AS q;

    /*
        Result 7: disabled non-IGNORE mappings that were not synchronized.
        An empty result is ideal. Review any returned rows before assuming that all
        expected business tables participate in the pipeline.
    */
    SELECT
        N'ODS' AS [warehouse_layer],
        w.[source_schema],
        w.[source_table],
        w.[target_schema],
        w.[target_table],
        w.[load_mode],
        w.[is_enabled]
    FROM [ODS].[etl_watermark] AS w
    WHERE w.[is_enabled] = 0
      AND w.[load_mode] <> N'IGNORE'

    UNION ALL

    SELECT
        N'DWD',
        w.[source_schema],
        w.[source_table],
        w.[target_schema],
        w.[target_table],
        w.[load_mode],
        w.[is_enabled]
    FROM [DWD].[etl_watermark] AS w
    WHERE w.[is_enabled] = 0
      AND w.[load_mode] <> N'IGNORE'
    ORDER BY
        [warehouse_layer],
        [source_schema],
        [source_table];
END TRY
BEGIN CATCH
    SET @run_finished_at = SYSDATETIME();
    SET @error_message = ERROR_MESSAGE();
    SET @raised_message =
        N'AMR all-layer synchronization failed at stage ['
        + @current_stage
        + N']. '
        + COALESCE(@error_message, N'Unknown error.');

    /* Return a readable failure summary before raising the error to DataGrip. */
    SELECT
        N'FAILED' AS [sync_status],
        @current_stage AS [failed_stage],
        @run_started_at AS [run_started_at],
        @run_finished_at AS [run_finished_at],
        DATEDIFF(SECOND, @run_started_at, @run_finished_at) AS [elapsed_seconds],
        ERROR_NUMBER() AS [error_number],
        ERROR_LINE() AS [error_line],
        @error_message AS [error_message];

    RAISERROR(N'%s', 16, 1, @raised_message);
    RETURN;
END CATCH;
GO
