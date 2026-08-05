/*
  Repair one confirmed abandoned audit record after a client request timeout.
  Preconditions: script 92 reported no other holder of DWS.sp_load_dws_core_upsert.
  This updates only DWS.etl_batch.batch_id = 398; no business or aggregate rows change.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @lock_result INT;

BEGIN TRY
    BEGIN TRANSACTION;

    EXEC @lock_result = sys.sp_getapplock
        @Resource = N'DWS.sp_load_dws_core_upsert',
        @LockMode = N'Exclusive',
        @LockOwner = N'Transaction',
        @LockTimeout = 0;

    IF @lock_result < 0
    BEGIN
        THROW 59301, N'Another DWS refresh holds the application lock; batch 398 was not changed.', 1;
    END;

    SELECT
        b.batch_id,
        b.batch_start_time,
        b.batch_end_time,
        b.batch_status,
        b.error_message
    FROM DWS.etl_batch AS b
    WHERE b.batch_id = 398
      AND b.batch_status = N'RUNNING';

    UPDATE DWS.etl_batch
    SET
        batch_end_time = SYSDATETIME(),
        batch_status = N'FAILED',
        error_message = N'Client request timed out after 120 seconds; no active DWS refresh held the application lock during recovery check.'
    WHERE batch_id = 398
      AND batch_status = N'RUNNING';

    IF @@ROWCOUNT <> 1
    BEGIN
        THROW 59302, N'Expected exactly one running batch 398 record; no change was committed.', 1;
    END;

    SELECT
        b.batch_id,
        b.batch_start_time,
        b.batch_end_time,
        b.batch_status,
        b.error_message
    FROM DWS.etl_batch AS b
    WHERE b.batch_id = 398;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
    BEGIN
        ROLLBACK TRANSACTION;
    END;

    THROW;
END CATCH;
