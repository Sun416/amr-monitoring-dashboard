/*
  Permanently reconcile robot identity after a DWD incremental batch.
  Uses ODS.MA_AMR.id = ODS.robot_battery_history.amr_id; no name/number guessing.
  It changes only the specified DWD batch and never changes dbo, ODS, or DWS rows.
*/
CREATE OR ALTER PROCEDURE DWD.sp_reconcile_robot_identity_for_batch
    @dwd_batch_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @dimension_rows_updated BIGINT = 0,
        @battery_rows_updated BIGINT = 0;

    IF @dwd_batch_id IS NULL
    BEGIN
        THROW 58701, N'@dwd_batch_id is required.', 1;
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM DWD.etl_batch AS b
        WHERE b.batch_id = @dwd_batch_id
          AND b.batch_status = N'SUCCESS'
    )
    BEGIN
        THROW 58702, N'The specified DWD batch does not exist or did not complete successfully.', 1;
    END;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE d
        SET
            d.robot_id = CONVERT(NVARCHAR(100), source_amr.id),
            d.robot_code = source_amr.name,
            d.robot_name = source_amr.name,
            d.is_enabled = CASE WHEN UPPER(LTRIM(RTRIM(COALESCE(source_amr.is_active, N'')))) = N'Y' THEN CONVERT(BIT, 1) ELSE CONVERT(BIT, 0) END
        FROM DWD.dim_amr_robot AS d
        INNER JOIN ODS.MA_AMR AS source_amr
            ON source_amr.ods_row_id = d.source_ods_row_id
        WHERE d.dwd_batch_id = @dwd_batch_id
          AND d.source_schema = N'ODS'
          AND d.source_table = N'MA_AMR'
          AND
          (
                ISNULL(d.robot_id, N'') <> CONVERT(NVARCHAR(100), source_amr.id)
             OR ISNULL(d.robot_code, N'') <> ISNULL(source_amr.name, N'')
             OR ISNULL(d.robot_name, N'') <> ISNULL(source_amr.name, N'')
             OR ISNULL(CONVERT(TINYINT, d.is_enabled), 0) <> CASE WHEN UPPER(LTRIM(RTRIM(COALESCE(source_amr.is_active, N'')))) = N'Y' THEN 1 ELSE 0 END
          );

        SET @dimension_rows_updated = @@ROWCOUNT;

        UPDATE battery
        SET
            battery.robot_id = CONVERT(NVARCHAR(100), source_battery.amr_id),
            battery.robot_code = source_amr.name
        FROM DWD.fact_robot_battery AS battery
        INNER JOIN ODS.robot_battery_history AS source_battery
            ON source_battery.ods_row_id = battery.source_ods_row_id
        INNER JOIN ODS.MA_AMR AS source_amr
            ON source_amr.id = source_battery.amr_id
        WHERE battery.dwd_batch_id = @dwd_batch_id
          AND battery.source_schema = N'ODS'
          AND battery.source_table = N'robot_battery_history'
          AND
          (
                ISNULL(battery.robot_id, N'') <> CONVERT(NVARCHAR(100), source_battery.amr_id)
             OR ISNULL(battery.robot_code, N'') <> ISNULL(source_amr.name, N'')
          );

        SET @battery_rows_updated = @@ROWCOUNT;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
        BEGIN
            ROLLBACK TRANSACTION;
        END;

        THROW;
    END CATCH;

    SELECT
        @dwd_batch_id AS dwd_batch_id,
        @dimension_rows_updated AS dimension_rows_updated,
        @battery_rows_updated AS battery_rows_updated;
END;
