USE [IOT2020];
GO

/*
    Canonical Task Analytics time zone: Thailand local wall clock (UTC+07:00).

    Scope is deliberately limited to offset-aware task/queue sources:
      ODS.AMR_Queue.enqueued_at
      ODS.TA_AMR.start_time / end_time

    dbo and ODS are immutable source layers. This procedure changes only DWD
    derived fields, in small committed batches, and is idempotent.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

CREATE OR ALTER PROCEDURE [DWD].[sp_normalize_task_times_to_th]
    @batch_size INT = 10000,
    @max_batches INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @batch_size < 1000 OR @batch_size > 50000
    BEGIN
        THROW 58600, N'@batch_size must be between 1000 and 50000.', 1;
    END;

    IF @max_batches IS NOT NULL AND @max_batches < 1
    BEGIN
        THROW 58601, N'@max_batches must be NULL or at least 1.', 1;
    END;

    IF OBJECT_ID(N'[ODS].[AMR_Queue]', N'U') IS NULL
       OR OBJECT_ID(N'[ODS].[TA_AMR]', N'U') IS NULL
       OR OBJECT_ID(N'[DWD].[fact_amr_queue]', N'U') IS NULL
       OR OBJECT_ID(N'[DWD].[fact_robot_operation_event]', N'U') IS NULL
    BEGIN
        THROW 58602, N'Missing required ODS or DWD task tables.', 1;
    END;

    DECLARE
        @lock_result INT,
        @rows_affected INT,
        @batch_number INT = 0,
        @queue_rows_updated BIGINT = 0,
        @queue_event_rows_updated BIGINT = 0,
        @task_event_rows_updated BIGINT = 0;

    EXEC @lock_result = sys.sp_getapplock
        @Resource = N'DWD.sp_normalize_task_times_to_th',
        @LockMode = N'Exclusive',
        @LockOwner = N'Session',
        @LockTimeout = 0;

    IF @lock_result < 0
    BEGIN
        THROW 58603, N'Task time-zone normalization is already running.', 1;
    END;

    BEGIN TRY
        /* Queue fact: event_time and queue_start_time become Thailand local. */
        WHILE @max_batches IS NULL OR @batch_number < @max_batches
        BEGIN
            BEGIN TRANSACTION;

            ;WITH queue_candidate AS
            (
                SELECT TOP (@batch_size)
                    queue_fact.[queue_fact_id],
                    CONVERT(DATETIME2(3), SWITCHOFFSET(source_row.[enqueued_at], N'+07:00')) AS [expected_th_time]
                FROM [DWD].[fact_amr_queue] AS queue_fact
                INNER JOIN [ODS].[AMR_Queue] AS source_row
                    ON source_row.[ods_row_id] = queue_fact.[source_ods_row_id]
                WHERE queue_fact.[source_schema] = N'ODS'
                  AND queue_fact.[source_table] = N'AMR_Queue'
                  AND source_row.[enqueued_at] IS NOT NULL
                  AND
                  (
                      queue_fact.[event_time] IS NULL
                      OR queue_fact.[event_time] <> CONVERT(DATETIME2(3), SWITCHOFFSET(source_row.[enqueued_at], N'+07:00'))
                      OR queue_fact.[queue_start_time] IS NULL
                      OR queue_fact.[queue_start_time] <> CONVERT(DATETIME2(3), SWITCHOFFSET(source_row.[enqueued_at], N'+07:00'))
                  )
                ORDER BY queue_fact.[queue_fact_id]
            )
            UPDATE queue_fact
            SET
                queue_fact.[event_time] = candidate.[expected_th_time],
                queue_fact.[queue_start_time] = candidate.[expected_th_time]
            FROM [DWD].[fact_amr_queue] AS queue_fact
            INNER JOIN queue_candidate AS candidate
                ON candidate.[queue_fact_id] = queue_fact.[queue_fact_id];

            SET @rows_affected = @@ROWCOUNT;
            COMMIT TRANSACTION;

            SET @queue_rows_updated = @queue_rows_updated + @rows_affected;
            SET @batch_number = @batch_number + 1;

            IF @rows_affected = 0
            BEGIN
                BREAK;
            END;
        END;

        SET @batch_number = 0;

        /* Queue operation-event rows use the same source instant. */
        WHILE @max_batches IS NULL OR @batch_number < @max_batches
        BEGIN
            BEGIN TRANSACTION;

            ;WITH event_candidate AS
            (
                SELECT TOP (@batch_size)
                    event_row.[operation_event_fact_id],
                    CONVERT(DATETIME2(3), SWITCHOFFSET(source_row.[enqueued_at], N'+07:00')) AS [expected_th_time]
                FROM [DWD].[fact_robot_operation_event] AS event_row
                INNER JOIN [ODS].[AMR_Queue] AS source_row
                    ON source_row.[ods_row_id] = event_row.[source_ods_row_id]
                WHERE event_row.[source_schema] = N'ODS'
                  AND event_row.[source_table] = N'AMR_Queue'
                  AND event_row.[source_event_part] = N'QUEUE'
                  AND source_row.[enqueued_at] IS NOT NULL
                  AND
                  (
                      event_row.[event_time] <> CONVERT(DATETIME2(3), SWITCHOFFSET(source_row.[enqueued_at], N'+07:00'))
                      OR event_row.[source_event_time] <> CONVERT(DATETIME2(3), SWITCHOFFSET(source_row.[enqueued_at], N'+07:00'))
                  )
                ORDER BY event_row.[operation_event_fact_id]
            )
            UPDATE event_row
            SET
                event_row.[event_time] = candidate.[expected_th_time],
                event_row.[source_event_time] = candidate.[expected_th_time]
            FROM [DWD].[fact_robot_operation_event] AS event_row
            INNER JOIN event_candidate AS candidate
                ON candidate.[operation_event_fact_id] = event_row.[operation_event_fact_id];

            SET @rows_affected = @@ROWCOUNT;
            COMMIT TRANSACTION;

            SET @queue_event_rows_updated = @queue_event_rows_updated + @rows_affected;
            SET @batch_number = @batch_number + 1;

            IF @rows_affected = 0
            BEGIN
                BREAK;
            END;
        END;

        SET @batch_number = 0;

        /* TA_AMR operation-event rows use start_time or end_time by event part. */
        WHILE @max_batches IS NULL OR @batch_number < @max_batches
        BEGIN
            BEGIN TRANSACTION;

            ;WITH event_candidate AS
            (
                SELECT TOP (@batch_size)
                    event_row.[operation_event_fact_id],
                    CONVERT(DATETIME2(3), SWITCHOFFSET(
                        CASE event_row.[source_event_part]
                            WHEN N'START' THEN source_row.[start_time]
                            WHEN N'END' THEN source_row.[end_time]
                        END,
                        N'+07:00'
                    )) AS [expected_th_time]
                FROM [DWD].[fact_robot_operation_event] AS event_row
                INNER JOIN [ODS].[TA_AMR] AS source_row
                    ON source_row.[ods_row_id] = event_row.[source_ods_row_id]
                WHERE event_row.[source_schema] = N'ODS'
                  AND event_row.[source_table] = N'TA_AMR'
                  AND event_row.[source_event_part] IN (N'START', N'END')
                  AND CASE event_row.[source_event_part]
                          WHEN N'START' THEN source_row.[start_time]
                          WHEN N'END' THEN source_row.[end_time]
                      END IS NOT NULL
                  AND
                  (
                      event_row.[event_time] <> CONVERT(DATETIME2(3), SWITCHOFFSET(
                          CASE event_row.[source_event_part]
                              WHEN N'START' THEN source_row.[start_time]
                              WHEN N'END' THEN source_row.[end_time]
                          END,
                          N'+07:00'
                      ))
                      OR event_row.[source_event_time] <> CONVERT(DATETIME2(3), SWITCHOFFSET(
                          CASE event_row.[source_event_part]
                              WHEN N'START' THEN source_row.[start_time]
                              WHEN N'END' THEN source_row.[end_time]
                          END,
                          N'+07:00'
                      ))
                  )
                ORDER BY event_row.[operation_event_fact_id]
            )
            UPDATE event_row
            SET
                event_row.[event_time] = candidate.[expected_th_time],
                event_row.[source_event_time] = candidate.[expected_th_time]
            FROM [DWD].[fact_robot_operation_event] AS event_row
            INNER JOIN event_candidate AS candidate
                ON candidate.[operation_event_fact_id] = event_row.[operation_event_fact_id];

            SET @rows_affected = @@ROWCOUNT;
            COMMIT TRANSACTION;

            SET @task_event_rows_updated = @task_event_rows_updated + @rows_affected;
            SET @batch_number = @batch_number + 1;

            IF @rows_affected = 0
            BEGIN
                BREAK;
            END;
        END;

        /* The event-loader watermarks must use the same DWD local-time contract. */
        UPDATE watermark
        SET watermark.[last_event_time] = latest_event.[latest_event_time],
            watermark.[updated_at] = SYSDATETIME()
        FROM [DWD].[robot_event_watermark] AS watermark
        INNER JOIN
        (
            SELECT
                event_row.[source_schema],
                event_row.[source_table],
                MAX(event_row.[event_time]) AS [latest_event_time]
            FROM [DWD].[fact_robot_operation_event] AS event_row
            WHERE event_row.[source_schema] = N'ODS'
              AND event_row.[source_table] IN (N'AMR_Queue', N'TA_AMR')
            GROUP BY event_row.[source_schema], event_row.[source_table]
        ) AS latest_event
            ON latest_event.[source_schema] = watermark.[source_schema]
           AND latest_event.[source_table] = watermark.[source_table];

        EXEC sys.sp_releaseapplock
            @Resource = N'DWD.sp_normalize_task_times_to_th',
            @LockOwner = N'Session';

        SELECT
            @queue_rows_updated AS [queue_fact_rows_updated],
            @queue_event_rows_updated AS [queue_operation_event_rows_updated],
            @task_event_rows_updated AS [task_operation_event_rows_updated],
            N'Thailand local wall clock (UTC+07:00)' AS [time_contract];
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
        BEGIN
            ROLLBACK TRANSACTION;
        END;

        EXEC sys.sp_releaseapplock
            @Resource = N'DWD.sp_normalize_task_times_to_th',
            @LockOwner = N'Session';

        THROW;
    END CATCH;
END;
GO

/* Post-install verification only. */
SELECT
    schema_row.[name] AS [schema_name],
    procedure_row.[name] AS [procedure_name],
    procedure_row.[modify_date]
FROM sys.procedures AS procedure_row
INNER JOIN sys.schemas AS schema_row
    ON schema_row.[schema_id] = procedure_row.[schema_id]
WHERE schema_row.[name] = N'DWD'
  AND procedure_row.[name] = N'sp_normalize_task_times_to_th';
GO
