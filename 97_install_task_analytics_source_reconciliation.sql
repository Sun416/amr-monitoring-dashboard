USE [IOT2020];
GO

/*
    Task Analytics source reconciliation
    ====================================

    Purpose
      Keep the two approved Task Analytics sources current in ODS before DWD
      and DWS are refreshed:

        dbo.TA_AMR     -> ODS.TA_AMR
        dbo.AMR_Queue  -> ODS.AMR_Queue

    Why this is separate from the generic incremental loader
      - TA_AMR status/end_time can change after its start_time is first seen.
      - AMR_Queue status can change after it is enqueued.
      - The generic loader is append-only; this procedure reconciles the
        rolling Task Analytics serving horizon as well.

    Safety
      - no DELETE, TRUNCATE, or DROP;
      - only the supplied, maximum-31-day source window is reconciled;
      - existing ODS identity keys are retained;
      - changed ODS values are updated from dbo; missing source rows are added.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'IOT2020'
BEGIN
    THROW 59700, N'Expected database IOT2020.', 1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes AS index_row
    WHERE index_row.[object_id] = OBJECT_ID(N'[ODS].[TA_AMR]')
      AND index_row.[name] = N'IX_ODS_TA_AMR_id'
)
BEGIN
    CREATE NONCLUSTERED INDEX [IX_ODS_TA_AMR_id]
        ON [ODS].[TA_AMR] ([id]);
END;
GO

CREATE OR ALTER PROCEDURE [ODS].[sp_reconcile_task_analytics_source_window]
    @window_start DATETIME2(3),
    @window_end DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @window_start IS NULL
       OR @window_end IS NULL
       OR @window_end <= @window_start
    BEGIN
        THROW 59710, N'A valid Task Analytics source window is required.', 1;
    END;

    IF DATEDIFF(HOUR, @window_start, @window_end) > 31 * 24
    BEGIN
        THROW 59711, N'Task Analytics source reconciliation is limited to 31 days.', 1;
    END;

    IF OBJECT_ID(N'[ODS].[TA_AMR]', N'U') IS NULL
       OR OBJECT_ID(N'[ODS].[AMR_Queue]', N'U') IS NULL
    BEGIN
        THROW 59712, N'Required ODS Task Analytics source tables are missing.', 1;
    END;

    DECLARE
        @lock_result INT,
        @task_updated BIGINT = 0,
        @task_inserted BIGINT = 0,
        @queue_updated BIGINT = 0,
        @queue_inserted BIGINT = 0;

    EXEC @lock_result = sys.sp_getapplock
        @Resource = N'ODS.sp_reconcile_task_analytics_source_window',
        @LockMode = N'Exclusive',
        @LockOwner = N'Session',
        @LockTimeout = 0;

    IF @lock_result < 0
    BEGIN
        THROW 59713, N'Another Task Analytics source reconciliation is already running.', 1;
    END;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* A task is in scope when its execution interval overlaps the window. */
        UPDATE target
        SET
            target.[AMR_id] = source_row.[AMR_id],
            target.[queue_id] = source_row.[queue_id],
            target.[job_id] = source_row.[job_id],
            target.[subjob_id] = source_row.[subjob_id],
            target.[start_time] = source_row.[start_time],
            target.[end_time] = source_row.[end_time],
            target.[start_map] = source_row.[start_map],
            target.[start_zone] = source_row.[start_zone],
            target.[start_x] = source_row.[start_x],
            target.[start_y] = source_row.[start_y],
            target.[start_battery] = source_row.[start_battery],
            target.[end_battery] = source_row.[end_battery],
            target.[created_at] = source_row.[created_at],
            target.[updated_at] = source_row.[updated_at],
            target.[status] = source_row.[status],
            target.[immobility_count] = source_row.[immobility_count],
            target.[ods_load_time] = SYSDATETIME(),
            target.[ods_operation] = 'U'
        FROM [ODS].[TA_AMR] AS target
        INNER JOIN [dbo].[TA_AMR] AS source_row
            ON source_row.[id] = target.[id]
        WHERE CONVERT(DATETIME2(3), source_row.[start_time]) < @window_end
          AND
          (
              source_row.[end_time] IS NULL
              OR CONVERT(DATETIME2(3), source_row.[end_time]) >= @window_start
          )
          AND
          (
              ISNULL(target.[AMR_id], -1) <> ISNULL(source_row.[AMR_id], -1)
              OR ISNULL(target.[queue_id], -1) <> ISNULL(source_row.[queue_id], -1)
              OR ISNULL(target.[job_id], -1) <> ISNULL(source_row.[job_id], -1)
              OR ISNULL(target.[subjob_id], -1) <> ISNULL(source_row.[subjob_id], -1)
              OR ISNULL(CONVERT(NVARCHAR(33), target.[start_time], 127), N'') <> ISNULL(CONVERT(NVARCHAR(33), source_row.[start_time], 127), N'')
              OR ISNULL(CONVERT(NVARCHAR(33), target.[end_time], 127), N'') <> ISNULL(CONVERT(NVARCHAR(33), source_row.[end_time], 127), N'')
              OR ISNULL(target.[start_map], N'') <> ISNULL(source_row.[start_map], N'')
              OR ISNULL(target.[start_zone], N'') <> ISNULL(source_row.[start_zone], N'')
              OR ISNULL(target.[start_x], CONVERT(DECIMAL(9, 3), -999999)) <> ISNULL(source_row.[start_x], CONVERT(DECIMAL(9, 3), -999999))
              OR ISNULL(target.[start_y], CONVERT(DECIMAL(9, 3), -999999)) <> ISNULL(source_row.[start_y], CONVERT(DECIMAL(9, 3), -999999))
              OR ISNULL(target.[start_battery], -1) <> ISNULL(source_row.[start_battery], -1)
              OR ISNULL(target.[end_battery], -1) <> ISNULL(source_row.[end_battery], -1)
              OR ISNULL(CONVERT(NVARCHAR(33), target.[created_at], 127), N'') <> ISNULL(CONVERT(NVARCHAR(33), source_row.[created_at], 127), N'')
              OR ISNULL(CONVERT(NVARCHAR(33), target.[updated_at], 127), N'') <> ISNULL(CONVERT(NVARCHAR(33), source_row.[updated_at], 127), N'')
              OR ISNULL(CONVERT(NVARCHAR(100), target.[status]), N'') <> ISNULL(CONVERT(NVARCHAR(100), source_row.[status]), N'')
              OR ISNULL(target.[immobility_count], -1) <> ISNULL(source_row.[immobility_count], -1)
          );

        SET @task_updated = @@ROWCOUNT;

        INSERT INTO [ODS].[TA_AMR]
        (
            [id], [AMR_id], [queue_id], [job_id], [subjob_id], [start_time], [end_time],
            [start_map], [start_zone], [start_x], [start_y], [start_battery], [end_battery],
            [created_at], [updated_at], [status], [immobility_count], [ods_operation]
        )
        SELECT
            source_row.[id], source_row.[AMR_id], source_row.[queue_id], source_row.[job_id], source_row.[subjob_id],
            source_row.[start_time], source_row.[end_time], source_row.[start_map], source_row.[start_zone],
            source_row.[start_x], source_row.[start_y], source_row.[start_battery], source_row.[end_battery],
            source_row.[created_at], source_row.[updated_at], source_row.[status], source_row.[immobility_count], 'I'
        FROM [dbo].[TA_AMR] AS source_row
        WHERE CONVERT(DATETIME2(3), source_row.[start_time]) < @window_end
          AND
          (
              source_row.[end_time] IS NULL
              OR CONVERT(DATETIME2(3), source_row.[end_time]) >= @window_start
          )
          AND NOT EXISTS
          (
              SELECT 1
              FROM [ODS].[TA_AMR] AS target
              WHERE target.[id] = source_row.[id]
          );

        SET @task_inserted = @@ROWCOUNT;

        UPDATE target
        SET
            target.[job_id] = source_row.[job_id],
            target.[AMR_id] = source_row.[AMR_id],
            target.[current_subjob_id] = source_row.[current_subjob_id],
            target.[priority] = source_row.[priority],
            target.[status] = source_row.[status],
            target.[enqueued_at] = source_row.[enqueued_at],
            target.[project_id] = source_row.[project_id],
            target.[enqueued_by] = source_row.[enqueued_by],
            target.[esp_button_id] = source_row.[esp_button_id],
            target.[ods_load_time] = SYSDATETIME(),
            target.[ods_operation] = 'U'
        FROM [ODS].[AMR_Queue] AS target
        INNER JOIN [dbo].[AMR_Queue] AS source_row
            ON source_row.[id] = target.[id]
        WHERE CONVERT(DATETIME2(3), source_row.[enqueued_at]) >= @window_start
          AND CONVERT(DATETIME2(3), source_row.[enqueued_at]) < @window_end
          AND
          (
              ISNULL(target.[job_id], -1) <> ISNULL(source_row.[job_id], -1)
              OR ISNULL(target.[AMR_id], -1) <> ISNULL(source_row.[AMR_id], -1)
              OR ISNULL(target.[current_subjob_id], -1) <> ISNULL(source_row.[current_subjob_id], -1)
              OR ISNULL(target.[priority], -1) <> ISNULL(source_row.[priority], -1)
              OR ISNULL(CONVERT(NVARCHAR(100), target.[status]), N'') <> ISNULL(CONVERT(NVARCHAR(100), source_row.[status]), N'')
              OR ISNULL(CONVERT(NVARCHAR(33), target.[enqueued_at], 127), N'') <> ISNULL(CONVERT(NVARCHAR(33), source_row.[enqueued_at], 127), N'')
              OR ISNULL(target.[project_id], -1) <> ISNULL(source_row.[project_id], -1)
              OR ISNULL(target.[enqueued_by], -1) <> ISNULL(source_row.[enqueued_by], -1)
              OR ISNULL(target.[esp_button_id], -1) <> ISNULL(source_row.[esp_button_id], -1)
          );

        SET @queue_updated = @@ROWCOUNT;

        INSERT INTO [ODS].[AMR_Queue]
        (
            [id], [job_id], [AMR_id], [current_subjob_id], [priority], [status],
            [enqueued_at], [project_id], [enqueued_by], [esp_button_id], [ods_operation]
        )
        SELECT
            source_row.[id], source_row.[job_id], source_row.[AMR_id], source_row.[current_subjob_id],
            source_row.[priority], source_row.[status], source_row.[enqueued_at], source_row.[project_id],
            source_row.[enqueued_by], source_row.[esp_button_id], 'I'
        FROM [dbo].[AMR_Queue] AS source_row
        WHERE CONVERT(DATETIME2(3), source_row.[enqueued_at]) >= @window_start
          AND CONVERT(DATETIME2(3), source_row.[enqueued_at]) < @window_end
          AND NOT EXISTS
          (
              SELECT 1
              FROM [ODS].[AMR_Queue] AS target
              WHERE target.[id] = source_row.[id]
          );

        SET @queue_inserted = @@ROWCOUNT;

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
        @window_start AS [window_start],
        @window_end AS [window_end],
        @task_updated AS [ta_amr_updated_rows],
        @task_inserted AS [ta_amr_inserted_rows],
        @queue_updated AS [amr_queue_updated_rows],
        @queue_inserted AS [amr_queue_inserted_rows];
END;
GO
