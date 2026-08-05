USE [IOT2020];

/*
    Authorized refresh entry for the Web non-snapshot DWS path.

    Scope:
    - Runs the existing historical incremental pipeline: ODS -> DWD -> DWS.
    - Does NOT execute DWS.sp_refresh_robot_current_snapshot_fast.
    - Does NOT read from or write to DWS.dws_robot_current_snapshot.
    - Returns the new batch records and non-snapshot DWS freshness anchors.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE
    @run_started_at DATETIME2(3) = SYSDATETIME(),
    @dwd_batch_before BIGINT = COALESCE(
        (SELECT MAX(batch_source.[batch_id]) FROM [DWD].[etl_batch] AS batch_source),
        0
    ),
    @dws_batch_before BIGINT = COALESCE(
        (SELECT MAX(batch_source.[batch_id]) FROM [DWS].[etl_batch] AS batch_source),
        0
    );

IF OBJECT_ID(N'[DWS].[sp_run_amr_historical_pipeline]', N'P') IS NULL
BEGIN
    RAISERROR(N'Missing procedure: DWS.sp_run_amr_historical_pipeline.', 16, 1);
    RETURN;
END;

IF EXISTS
(
    SELECT 1
    FROM [DWD].[etl_batch] AS batch_source
    WHERE batch_source.[batch_status] = N'RUNNING'
      AND batch_source.[batch_start_time] >= DATEADD(HOUR, -2, @run_started_at)
)
OR EXISTS
(
    SELECT 1
    FROM [DWS].[etl_batch] AS batch_source
    WHERE batch_source.[batch_status] = N'RUNNING'
      AND batch_source.[batch_start_time] >= DATEADD(HOUR, -2, @run_started_at)
)
BEGIN
    RAISERROR(N'An ODS/DWD/DWS incremental load is already running. The refresh was not started.', 16, 1);
    RETURN;
END;

BEGIN TRY
    EXEC [DWS].[sp_run_amr_historical_pipeline];

    SELECT
        N'SUCCESS' AS [refresh_status],
        @run_started_at AS [run_started_at],
        SYSDATETIME() AS [run_finished_at],
        DATEDIFF(SECOND, @run_started_at, SYSDATETIME()) AS [elapsed_seconds],
        N'ODS -> DWD -> non-snapshot DWS' AS [refreshed_path],
        N'DWS current snapshot was not executed' AS [snapshot_boundary];

    SELECT
        batch_source.[batch_id],
        batch_source.[batch_start_time],
        batch_source.[batch_end_time],
        batch_source.[batch_status],
        batch_source.[error_message]
    FROM [DWD].[etl_batch] AS batch_source
    WHERE batch_source.[batch_id] > @dwd_batch_before
    ORDER BY batch_source.[batch_id] DESC;

    SELECT
        batch_source.[batch_id],
        batch_source.[batch_start_time],
        batch_source.[batch_end_time],
        batch_source.[batch_status],
        batch_source.[error_message]
    FROM [DWS].[etl_batch] AS batch_source
    WHERE batch_source.[batch_id] > @dws_batch_before
    ORDER BY batch_source.[batch_id] DESC;

    SELECT
        freshness.[table_name],
        freshness.[row_count],
        freshness.[latest_source_event_time],
        freshness.[latest_dws_load_time],
        DATEDIFF(MINUTE, freshness.[latest_dws_load_time], SYSDATETIME()) AS [dws_load_age_minutes]
    FROM
    (
        SELECT
            N'dws_robot_status_hourly' AS [table_name],
            COUNT_BIG(1) AS [row_count],
            MAX(status_hour.[last_status_time]) AS [latest_source_event_time],
            MAX(status_hour.[dws_load_time]) AS [latest_dws_load_time]
        FROM [DWS].[dws_robot_status_hourly] AS status_hour

        UNION ALL

        SELECT
            N'dws_robot_battery_hourly',
            COUNT_BIG(1),
            MAX(battery_hour.[last_sample_time]),
            MAX(battery_hour.[dws_load_time])
        FROM [DWS].[dws_robot_battery_hourly] AS battery_hour

        UNION ALL

        SELECT
            N'dws_robot_wifi_hourly',
            COUNT_BIG(1),
            MAX(wifi_hour.[last_sample_time]),
            MAX(wifi_hour.[dws_load_time])
        FROM [DWS].[dws_robot_wifi_hourly] AS wifi_hour
    ) AS freshness
    ORDER BY freshness.[table_name];
END TRY
BEGIN CATCH
    SELECT
        N'FAILED' AS [refresh_status],
        ERROR_NUMBER() AS [error_number],
        ERROR_LINE() AS [error_line],
        ERROR_MESSAGE() AS [error_message],
        @run_started_at AS [run_started_at],
        SYSDATETIME() AS [run_finished_at];

    THROW;
END CATCH;
