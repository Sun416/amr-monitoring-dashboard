/*
  Reconcile the latest successful DWD batch, then verify exact battery identity.
  This is intentionally batch-scoped; it is not a historical backfill.
*/
SET NOCOUNT ON;

DECLARE @latest_dwd_batch_id BIGINT;

SELECT @latest_dwd_batch_id = MAX(b.batch_id)
FROM DWD.etl_batch AS b
WHERE b.batch_status = N'SUCCESS';

IF @latest_dwd_batch_id IS NULL
BEGIN
    THROW 58901, N'No successful DWD batch is available for validation.', 1;
END;

EXEC DWD.sp_reconcile_robot_identity_for_batch
    @dwd_batch_id = @latest_dwd_batch_id;

SELECT
    @latest_dwd_batch_id AS latest_dwd_batch_id,
    COUNT_BIG(1) AS latest_batch_battery_row_count,
    SUM(CASE WHEN source_amr.id IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS unmapped_source_amr_count,
    SUM(CASE WHEN source_amr.id IS NOT NULL AND battery.robot_code <> source_amr.name THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS robot_code_mismatch_count
FROM DWD.fact_robot_battery AS battery
LEFT JOIN ODS.robot_battery_history AS source_battery
    ON source_battery.ods_row_id = battery.source_ods_row_id
LEFT JOIN ODS.MA_AMR AS source_amr
    ON source_amr.id = source_battery.amr_id
WHERE battery.dwd_batch_id = @latest_dwd_batch_id
  AND battery.source_schema = N'ODS'
  AND battery.source_table = N'robot_battery_history';

SELECT
    CASE WHEN OBJECT_DEFINITION(OBJECT_ID(N'DWS.sp_run_amr_historical_pipeline')) LIKE N'%sp_reconcile_robot_identity_for_batch%' THEN N'PRESENT' ELSE N'MISSING' END AS historical_pipeline_identity_step;
