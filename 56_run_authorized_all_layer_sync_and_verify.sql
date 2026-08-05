USE [IOT2020];

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE
    @run_started_at DATETIME2(3) = SYSDATETIME(),
    @dwd_batch_before BIGINT = COALESCE((SELECT MAX(b.[batch_id]) FROM [DWD].[etl_batch] AS b), 0),
    @dws_batch_before BIGINT = COALESCE((SELECT MAX(b.[batch_id]) FROM [DWS].[etl_batch] AS b), 0);

IF OBJECT_ID(N'[DWS].[sp_refresh_robot_current_snapshot_fast]', N'P') IS NULL
BEGIN
    RAISERROR(N'Missing procedure: DWS.sp_refresh_robot_current_snapshot_fast.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'[DWS].[sp_run_amr_historical_pipeline]', N'P') IS NULL
BEGIN
    RAISERROR(N'Missing procedure: DWS.sp_run_amr_historical_pipeline.', 16, 1);
    RETURN;
END;

BEGIN TRY
    EXEC [DWS].[sp_refresh_robot_current_snapshot_fast];
    EXEC [DWS].[sp_run_amr_historical_pipeline];

    SELECT
        N'SUCCESS' AS [sync_status],
        @run_started_at AS [run_started_at],
        SYSDATETIME() AS [run_finished_at],
        DATEDIFF(SECOND, @run_started_at, SYSDATETIME()) AS [elapsed_seconds],
        N'ODS -> DWD -> DWS' AS [synchronized_layers];

    SELECT
        b.[batch_id],
        b.[batch_start_time],
        b.[batch_end_time],
        b.[batch_status],
        b.[error_message]
    FROM [DWD].[etl_batch] AS b
    WHERE b.[batch_id] > @dwd_batch_before
    ORDER BY b.[batch_id] DESC;

    SELECT
        b.[batch_id],
        b.[batch_start_time],
        b.[batch_end_time],
        b.[batch_status],
        b.[error_message]
    FROM [DWS].[etl_batch] AS b
    WHERE b.[batch_id] > @dws_batch_before
    ORDER BY b.[batch_id] DESC;

    SELECT
        w.[source_schema],
        w.[source_table],
        w.[target_schema],
        w.[target_table],
        w.[last_bigint_value],
        w.[last_datetime_value],
        w.[last_load_time]
    FROM [ODS].[etl_watermark] AS w
    WHERE w.[is_enabled] = 1
      AND w.[source_table] IN
      (
          N'robot_battery_history',
          N'robot_job_history',
          N'robot_status_history',
          N'robot_wifi_history'
      )
    ORDER BY w.[source_table];
END TRY
BEGIN CATCH
    SELECT
        N'FAILED' AS [sync_status],
        ERROR_NUMBER() AS [error_number],
        ERROR_LINE() AS [error_line],
        ERROR_MESSAGE() AS [error_message],
        @run_started_at AS [run_started_at],
        SYSDATETIME() AS [run_finished_at];

    THROW;
END CATCH;
