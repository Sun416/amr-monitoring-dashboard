USE [IOT2020];
GO

/*
    Targeted ETL-audit repair only.
    Batch 402 was interrupted by the client-side 120-second request limit.
    Read-only checks verified that no DWS request or application lock remained.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* Preview: must return exactly one RUNNING row before the repair below. */
SELECT
    batch_row.[batch_id],
    batch_row.[batch_status],
    batch_row.[batch_start_time],
    batch_row.[batch_end_time],
    batch_row.[error_message]
FROM [DWS].[etl_batch] AS batch_row
WHERE batch_row.[batch_id] = 402
  AND batch_row.[batch_status] = N'RUNNING';
GO

BEGIN TRY
    BEGIN TRANSACTION;

    UPDATE [DWS].[etl_batch]
    SET
        [batch_status] = N'FAILED',
        [batch_end_time] = SYSDATETIME(),
        [error_message] = N'Client request timed out after 120 seconds; no active DWS refresh or application lock remained. Superseded by successful batch 403.'
    WHERE [batch_id] = 402
      AND [batch_status] = N'RUNNING';

    IF @@ROWCOUNT <> 1
    BEGIN
        THROW 58610, N'Expected exactly one interrupted RUNNING batch (402) to repair.', 1;
    END;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
    BEGIN
        ROLLBACK TRANSACTION;
    END;

    THROW;
END CATCH;
GO

SELECT
    batch_row.[batch_id],
    batch_row.[batch_status],
    batch_row.[batch_start_time],
    batch_row.[batch_end_time],
    batch_row.[error_message]
FROM [DWS].[etl_batch] AS batch_row
WHERE batch_row.[batch_id] IN (402, 403)
ORDER BY batch_row.[batch_id];
GO
