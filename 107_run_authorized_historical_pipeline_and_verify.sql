USE [IOT2020];

/*
  Authorized historical refresh only: ODS -> DWD -> DWS.
  It intentionally does not refresh DWS.dws_robot_current_snapshot.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE
    @run_started_at DATETIME2(3) = SYSDATETIME(),
    @dwd_batch_before BIGINT = COALESCE((SELECT MAX(batch_row.[batch_id]) FROM [DWD].[etl_batch] AS batch_row), 0),
    @dws_batch_before BIGINT = COALESCE((SELECT MAX(batch_row.[batch_id]) FROM [DWS].[etl_batch] AS batch_row), 0);

IF OBJECT_ID(N'[DWS].[sp_run_amr_historical_pipeline]', N'P') IS NULL
BEGIN
    THROW 58530, N'Missing procedure: DWS.sp_run_amr_historical_pipeline.', 1;
END;

EXEC [DWS].[sp_run_amr_historical_pipeline];

SELECT
    N'SUCCESS' AS [sync_status],
    @run_started_at AS [run_started_at],
    SYSDATETIME() AS [run_finished_at],
    DATEDIFF(SECOND, @run_started_at, SYSDATETIME()) AS [elapsed_seconds],
    N'ODS -> DWD -> DWS historical only' AS [synchronized_layers];

SELECT
    batch_row.[batch_id],
    batch_row.[batch_start_time],
    batch_row.[batch_end_time],
    batch_row.[batch_status],
    batch_row.[error_message]
FROM [DWD].[etl_batch] AS batch_row
WHERE batch_row.[batch_id] > @dwd_batch_before
ORDER BY batch_row.[batch_id] DESC;

SELECT
    batch_row.[batch_id],
    batch_row.[batch_start_time],
    batch_row.[batch_end_time],
    batch_row.[batch_status],
    batch_row.[error_message]
FROM [DWS].[etl_batch] AS batch_row
WHERE batch_row.[batch_id] > @dws_batch_before
ORDER BY batch_row.[batch_id] DESC;

SELECT
    watermark.[source_schema],
    watermark.[source_table],
    watermark.[target_schema],
    watermark.[target_table],
    watermark.[last_bigint_value],
    watermark.[last_datetime_value],
    watermark.[last_load_time]
FROM [ODS].[etl_watermark] AS watermark
WHERE watermark.[is_enabled] = 1
  AND watermark.[source_table] IN
  (
      N'robot_battery_history',
      N'robot_job_history',
      N'robot_status_history',
      N'robot_wifi_history'
  )
ORDER BY watermark.[source_table];
