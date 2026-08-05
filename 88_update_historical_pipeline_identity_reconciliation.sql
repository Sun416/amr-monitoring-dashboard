/* Reinstall only the historical pipeline procedure after installing script 87. */
CREATE OR ALTER PROCEDURE DWS.sp_run_amr_historical_pipeline
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @lock_result INT,
        @latest_dwd_batch_id BIGINT;

    IF OBJECT_ID(N'ODS.sp_load_reference_full_replace', N'P') IS NULL
       OR OBJECT_ID(N'ODS.sp_load_id_time_incremental', N'P') IS NULL
       OR OBJECT_ID(N'DWD.sp_load_dwd_all_incremental', N'P') IS NULL
       OR OBJECT_ID(N'DWD.sp_reconcile_robot_identity_for_batch', N'P') IS NULL
       OR OBJECT_ID(N'DWD.sp_enrich_robot_job_type_mode_incremental', N'P') IS NULL
       OR OBJECT_ID(N'DWS.sp_load_dws_core_upsert', N'P') IS NULL
    BEGIN
        RAISERROR(N'Missing one or more historical-pipeline procedures. Install scripts 02, 21, 26, 35, 42, and 87 first.', 16, 1);
        RETURN;
    END;

    EXEC @lock_result = sys.sp_getapplock
        @Resource = N'DWS.sp_run_amr_historical_pipeline',
        @LockMode = N'Exclusive',
        @LockOwner = N'Session',
        @LockTimeout = 0;

    IF @lock_result < 0
    BEGIN
        RAISERROR(N'The AMR historical-analysis pipeline is already running.', 16, 1);
        RETURN;
    END;

    BEGIN TRY
        EXEC ODS.sp_load_reference_full_replace;
        EXEC ODS.sp_load_id_time_incremental;
        EXEC DWD.sp_load_dwd_all_incremental
            @include_current_snapshot = 0;

        SELECT @latest_dwd_batch_id = MAX(b.batch_id)
        FROM DWD.etl_batch AS b
        WHERE b.batch_status = N'SUCCESS';

        EXEC DWD.sp_reconcile_robot_identity_for_batch
            @dwd_batch_id = @latest_dwd_batch_id;
        EXEC DWD.sp_enrich_robot_job_type_mode_incremental;
        EXEC DWS.sp_load_dws_core_upsert
            @include_current_snapshot = 0;

        EXEC sys.sp_releaseapplock
            @Resource = N'DWS.sp_run_amr_historical_pipeline',
            @LockOwner = N'Session';
    END TRY
    BEGIN CATCH
        EXEC sys.sp_releaseapplock
            @Resource = N'DWS.sp_run_amr_historical_pipeline',
            @LockOwner = N'Session';

        THROW;
    END CATCH;
END;
