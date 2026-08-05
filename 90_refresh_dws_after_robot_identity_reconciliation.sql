/*
  Rebuild DWS derived aggregates after exact robot identity reconciliation.
  Source and ODS tables are read-only in this script.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'DWS.sp_load_dws_core_upsert', N'P') IS NULL
BEGIN
    THROW 59001, N'Missing DWS.sp_load_dws_core_upsert.', 1;
END;

IF OBJECT_ID(N'DWD.sp_reconcile_robot_identity_for_batch', N'P') IS NULL
BEGIN
    THROW 59002, N'Missing DWD.sp_reconcile_robot_identity_for_batch.', 1;
END;

DECLARE @run_started_at DATETIME2(3) = SYSDATETIME();

EXEC DWS.sp_load_dws_core_upsert
    @include_current_snapshot = 0;

SELECT
    @run_started_at AS refresh_started_at,
    SYSDATETIME() AS refresh_finished_at,
    MAX(b.batch_id) AS latest_dws_batch_id,
    MAX(b.batch_end_time) AS latest_dws_batch_end_time,
    MAX(b.batch_status) AS latest_dws_batch_status
FROM DWS.etl_batch AS b
WHERE b.batch_start_time >= @run_started_at;

SELECT
    N'dws_robot_battery_hourly' AS dws_table,
    MAX(h.dws_load_time) AS latest_dws_load_time,
    COUNT_BIG(1) AS row_count
FROM DWS.dws_robot_battery_hourly AS h
UNION ALL
SELECT
    N'dws_robot_job_daily',
    MAX(h.dws_load_time),
    COUNT_BIG(1)
FROM DWS.dws_robot_job_daily AS h
UNION ALL
SELECT
    N'dws_amr_queue_daily',
    MAX(h.dws_load_time),
    COUNT_BIG(1)
FROM DWS.dws_amr_queue_daily AS h;
