/*
  No business-data change. Acquires the same DWS refresh lock only for this transaction,
  reports whether another session owns it, then rolls back to release it.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @lock_result INT;

BEGIN TRANSACTION;

EXEC @lock_result = sys.sp_getapplock
    @Resource = N'DWS.sp_load_dws_core_upsert',
    @LockMode = N'Exclusive',
    @LockOwner = N'Transaction',
    @LockTimeout = 0;

SELECT
    @lock_result AS application_lock_result,
    CASE
        WHEN @lock_result >= 0 THEN N'NO_OTHER_REFRESH_HOLDS_THE_LOCK'
        ELSE N'ANOTHER_REFRESH_STILL_HOLDS_THE_LOCK'
    END AS application_lock_status;

ROLLBACK TRANSACTION;
