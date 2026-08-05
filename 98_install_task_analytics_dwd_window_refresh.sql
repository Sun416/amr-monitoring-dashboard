USE [IOT2020];
GO

/*
    Task Analytics DWD window refresh
    =================================

    Approved source chain:
      dbo.TA_AMR / dbo.AMR_Queue
        -> ODS.TA_AMR / ODS.AMR_Queue
        -> DWD.fact_robot_operation_event / DWD.fact_amr_queue
        -> DWS Task Analytics aggregates

    This procedure refreshes one bounded serving window from ODS only. It
    corrects mutable task end/status and queue status values before DWS uses
    them. It never deletes source, ODS, or unrelated DWD facts.
*/

CREATE OR ALTER PROCEDURE [DWD].[sp_refresh_task_analytics_dwd_window]
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
        THROW 59810, N'A valid DWD Task Analytics window is required.', 1;
    END;

    IF DATEDIFF(HOUR, @window_start, @window_end) > 31 * 24
    BEGIN
        THROW 59811, N'DWD Task Analytics refresh is limited to 31 days.', 1;
    END;

    IF OBJECT_ID(N'[DWD].[fact_robot_operation_event]', N'U') IS NULL
       OR OBJECT_ID(N'[DWD].[fact_amr_queue]', N'U') IS NULL
       OR OBJECT_ID(N'[ODS].[TA_AMR]', N'U') IS NULL
       OR OBJECT_ID(N'[ODS].[AMR_Queue]', N'U') IS NULL
    BEGIN
        THROW 59812, N'Required ODS/DWD Task Analytics objects are missing.', 1;
    END;

    DECLARE
        @lock_result INT,
        @batch_id BIGINT = DATEDIFF_BIG(MILLISECOND, CONVERT(DATETIME2(3), N'2000-01-01T00:00:00'), SYSDATETIME()),
        @queue_updated BIGINT = 0,
        @queue_inserted BIGINT = 0,
        @events_deleted BIGINT = 0,
        @events_inserted BIGINT = 0;

    EXEC @lock_result = sys.sp_getapplock
        @Resource = N'DWD.sp_refresh_task_analytics_dwd_window',
        @LockMode = N'Exclusive',
        @LockOwner = N'Session',
        @LockTimeout = 0;

    IF @lock_result < 0
    BEGIN
        THROW 59813, N'Another Task Analytics DWD refresh is already running.', 1;
    END;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* Queue fact: preserve its fact key, replace only source-derived fields. */
        UPDATE queue_fact
        SET
            queue_fact.[queue_id] = CONVERT(NVARCHAR(100), source_row.[id]),
            queue_fact.[event_time] = CONVERT(DATETIME2(3), source_row.[enqueued_at]),
            queue_fact.[robot_id] = CONVERT(NVARCHAR(100), source_row.[AMR_id]),
            queue_fact.[robot_code] = robot.[name],
            queue_fact.[project_id] = CONVERT(NVARCHAR(100), source_row.[project_id]),
            queue_fact.[job_id] = CONVERT(NVARCHAR(100), source_row.[job_id]),
            queue_fact.[subjob_id] = CONVERT(NVARCHAR(100), source_row.[current_subjob_id]),
            queue_fact.[queue_status] = source_row.[status],
            queue_fact.[priority_value] = source_row.[priority],
            queue_fact.[queue_start_time] = CONVERT(DATETIME2(3), source_row.[enqueued_at]),
            queue_fact.[queue_end_time] = NULL,
            queue_fact.[duration_seconds] = NULL,
            queue_fact.[calling_box_id] = source_row.[esp_button_id],
            queue_fact.[calling_box_name] = calling_box.[calling_box_name],
            queue_fact.[source_ods_load_time] = source_row.[ods_load_time],
            queue_fact.[dwd_load_time] = SYSDATETIME(),
            queue_fact.[dwd_batch_id] = @batch_id,
            queue_fact.[dwd_hash_value] = HASHBYTES(N'SHA2_256', CONCAT(N'ODS|AMR_Queue|', source_row.[ods_row_id], N'|', source_row.[status], N'|', source_row.[esp_button_id]))
        FROM [DWD].[fact_amr_queue] AS queue_fact
        INNER JOIN [ODS].[AMR_Queue] AS source_row
            ON source_row.[ods_row_id] = queue_fact.[source_ods_row_id]
        LEFT JOIN [dbo].[MA_AMR] AS robot
            ON robot.[id] = source_row.[AMR_id]
        LEFT JOIN [DWD].[dim_amr_calling_box] AS calling_box
            ON calling_box.[calling_box_id] = source_row.[esp_button_id]
        WHERE queue_fact.[source_schema] = N'ODS'
          AND queue_fact.[source_table] = N'AMR_Queue'
          AND CONVERT(DATETIME2(3), source_row.[enqueued_at]) >= @window_start
          AND CONVERT(DATETIME2(3), source_row.[enqueued_at]) < @window_end;

        SET @queue_updated = @@ROWCOUNT;

        INSERT INTO [DWD].[fact_amr_queue]
        (
            [queue_id], [event_time], [robot_id], [robot_code], [project_id], [project_code],
            [job_id], [subjob_id], [queue_status], [priority_value], [start_station_code],
            [end_station_code], [queue_start_time], [queue_end_time], [duration_seconds],
            [source_schema], [source_table], [source_ods_row_id], [source_ods_load_time],
            [dwd_batch_id], [dwd_hash_value], [calling_box_id], [calling_box_name]
        )
        SELECT
            CONVERT(NVARCHAR(100), source_row.[id]),
            CONVERT(DATETIME2(3), source_row.[enqueued_at]),
            CONVERT(NVARCHAR(100), source_row.[AMR_id]),
            robot.[name],
            CONVERT(NVARCHAR(100), source_row.[project_id]),
            NULL,
            CONVERT(NVARCHAR(100), source_row.[job_id]),
            CONVERT(NVARCHAR(100), source_row.[current_subjob_id]),
            source_row.[status],
            source_row.[priority],
            NULL, NULL,
            CONVERT(DATETIME2(3), source_row.[enqueued_at]),
            NULL, NULL,
            N'ODS', N'AMR_Queue', source_row.[ods_row_id], source_row.[ods_load_time],
            @batch_id,
            HASHBYTES(N'SHA2_256', CONCAT(N'ODS|AMR_Queue|', source_row.[ods_row_id], N'|', source_row.[status], N'|', source_row.[esp_button_id])),
            source_row.[esp_button_id], calling_box.[calling_box_name]
        FROM [ODS].[AMR_Queue] AS source_row
        LEFT JOIN [dbo].[MA_AMR] AS robot
            ON robot.[id] = source_row.[AMR_id]
        LEFT JOIN [DWD].[dim_amr_calling_box] AS calling_box
            ON calling_box.[calling_box_id] = source_row.[esp_button_id]
        WHERE CONVERT(DATETIME2(3), source_row.[enqueued_at]) >= @window_start
          AND CONVERT(DATETIME2(3), source_row.[enqueued_at]) < @window_end
          AND NOT EXISTS
          (
              SELECT 1
              FROM [DWD].[fact_amr_queue] AS queue_fact
              WHERE queue_fact.[source_schema] = N'ODS'
                AND queue_fact.[source_table] = N'AMR_Queue'
                AND queue_fact.[source_ods_row_id] = source_row.[ods_row_id]
          );

        SET @queue_inserted = @@ROWCOUNT;

        /* Remove only derived event rows whose current source rows overlap the window. */
        DELETE event_row
        FROM [DWD].[fact_robot_operation_event] AS event_row
        INNER JOIN [ODS].[TA_AMR] AS source_row
            ON source_row.[ods_row_id] = event_row.[source_ods_row_id]
        WHERE event_row.[source_schema] = N'ODS'
          AND event_row.[source_table] = N'TA_AMR'
          AND CONVERT(DATETIME2(3), source_row.[start_time]) < @window_end
          AND
          (
              source_row.[end_time] IS NULL
              OR CONVERT(DATETIME2(3), source_row.[end_time]) >= @window_start
          );

        SET @events_deleted = @@ROWCOUNT;

        DELETE event_row
        FROM [DWD].[fact_robot_operation_event] AS event_row
        INNER JOIN [ODS].[AMR_Queue] AS source_row
            ON source_row.[ods_row_id] = event_row.[source_ods_row_id]
        WHERE event_row.[source_schema] = N'ODS'
          AND event_row.[source_table] = N'AMR_Queue'
          AND CONVERT(DATETIME2(3), source_row.[enqueued_at]) >= @window_start
          AND CONVERT(DATETIME2(3), source_row.[enqueued_at]) < @window_end;

        SET @events_deleted = @events_deleted + @@ROWCOUNT;

        INSERT INTO [DWD].[fact_robot_operation_event]
        (
            [event_time], [event_category], [event_type], [event_status], [task_id], [queue_id], [job_id], [subjob_id],
            [robot_id], [robot_code], [project_id], [priority], [route_id], [route_segment_id], [station_code], [map_code],
            [position_x], [position_y], [battery_soc], [event_value], [event_value_numeric],
            [source_schema], [source_table], [source_ods_row_id], [source_event_part], [source_event_time], [source_ods_load_time], [dwd_batch_id]
        )
        SELECT
            CONVERT(DATETIME2(3), source_row.[enqueued_at]),
            N'DISPATCH', N'QUEUE_ENQUEUED', source_row.[status],
            CONVERT(NVARCHAR(100), source_row.[id]), CONVERT(NVARCHAR(100), source_row.[id]),
            CONVERT(NVARCHAR(100), source_row.[job_id]), CONVERT(NVARCHAR(100), source_row.[current_subjob_id]),
            CONVERT(NVARCHAR(100), source_row.[AMR_id]), robot.[name], CONVERT(NVARCHAR(100), source_row.[project_id]),
            source_row.[priority], NULL, NULL, NULL, NULL, NULL, NULL, NULL,
            N'Queue record observed; assignment is the source-recorded robot, not candidate-evaluation evidence.', NULL,
            N'ODS', N'AMR_Queue', source_row.[ods_row_id], N'QUEUE', CONVERT(DATETIME2(3), source_row.[enqueued_at]), source_row.[ods_load_time], @batch_id
        FROM [ODS].[AMR_Queue] AS source_row
        LEFT JOIN [dbo].[MA_AMR] AS robot
            ON robot.[id] = source_row.[AMR_id]
        WHERE CONVERT(DATETIME2(3), source_row.[enqueued_at]) >= @window_start
          AND CONVERT(DATETIME2(3), source_row.[enqueued_at]) < @window_end;

        SET @events_inserted = @@ROWCOUNT;

        INSERT INTO [DWD].[fact_robot_operation_event]
        (
            [event_time], [event_category], [event_type], [event_status], [task_id], [queue_id], [job_id], [subjob_id],
            [robot_id], [robot_code], [project_id], [priority], [route_id], [route_segment_id], [station_code], [map_code],
            [position_x], [position_y], [battery_soc], [event_value], [event_value_numeric],
            [source_schema], [source_table], [source_ods_row_id], [source_event_part], [source_event_time], [source_ods_load_time], [dwd_batch_id]
        )
        SELECT
            CONVERT(DATETIME2(3), source_row.[start_time]), N'TASK',
            CASE WHEN source_row.[subjob_id] IS NULL THEN N'JOB_STARTED' ELSE N'SUBJOB_STARTED' END,
            N'STARTED', CONVERT(NVARCHAR(100), COALESCE(source_row.[queue_id], source_row.[id])), CONVERT(NVARCHAR(100), source_row.[queue_id]),
            CONVERT(NVARCHAR(100), source_row.[job_id]), CONVERT(NVARCHAR(100), source_row.[subjob_id]),
            CONVERT(NVARCHAR(100), source_row.[AMR_id]), robot.[name], NULL, NULL, NULL, NULL,
            source_row.[start_zone], source_row.[start_map], source_row.[start_x], source_row.[start_y], CONVERT(DECIMAL(9, 2), source_row.[start_battery]),
            NULL, NULL,
            N'ODS', N'TA_AMR', source_row.[ods_row_id], N'START', CONVERT(DATETIME2(3), source_row.[start_time]), source_row.[ods_load_time], @batch_id
        FROM [ODS].[TA_AMR] AS source_row
        LEFT JOIN [dbo].[MA_AMR] AS robot
            ON robot.[id] = source_row.[AMR_id]
        WHERE source_row.[start_time] IS NOT NULL
          AND CONVERT(DATETIME2(3), source_row.[start_time]) < @window_end
          AND
          (
              source_row.[end_time] IS NULL
              OR CONVERT(DATETIME2(3), source_row.[end_time]) >= @window_start
          );

        SET @events_inserted = @events_inserted + @@ROWCOUNT;

        INSERT INTO [DWD].[fact_robot_operation_event]
        (
            [event_time], [event_category], [event_type], [event_status], [task_id], [queue_id], [job_id], [subjob_id],
            [robot_id], [robot_code], [project_id], [priority], [route_id], [route_segment_id], [station_code], [map_code],
            [position_x], [position_y], [battery_soc], [event_value], [event_value_numeric],
            [source_schema], [source_table], [source_ods_row_id], [source_event_part], [source_event_time], [source_ods_load_time], [dwd_batch_id]
        )
        SELECT
            CONVERT(DATETIME2(3), source_row.[end_time]), N'TASK',
            CASE WHEN source_row.[subjob_id] IS NULL THEN N'JOB_ENDED' ELSE N'SUBJOB_ENDED' END,
            CONVERT(NVARCHAR(100), source_row.[status]), CONVERT(NVARCHAR(100), COALESCE(source_row.[queue_id], source_row.[id])), CONVERT(NVARCHAR(100), source_row.[queue_id]),
            CONVERT(NVARCHAR(100), source_row.[job_id]), CONVERT(NVARCHAR(100), source_row.[subjob_id]),
            CONVERT(NVARCHAR(100), source_row.[AMR_id]), robot.[name], NULL, NULL, NULL, NULL,
            source_row.[start_zone], source_row.[start_map], NULL, NULL, CONVERT(DECIMAL(9, 2), source_row.[end_battery]),
            N'Duration seconds derived from source start_time and end_time.',
            CASE WHEN source_row.[start_time] IS NOT NULL THEN CONVERT(DECIMAL(18, 6), DATEDIFF_BIG(MILLISECOND, source_row.[start_time], source_row.[end_time]) / 1000.0) ELSE NULL END,
            N'ODS', N'TA_AMR', source_row.[ods_row_id], N'END', CONVERT(DATETIME2(3), source_row.[end_time]), source_row.[ods_load_time], @batch_id
        FROM [ODS].[TA_AMR] AS source_row
        LEFT JOIN [dbo].[MA_AMR] AS robot
            ON robot.[id] = source_row.[AMR_id]
        WHERE source_row.[end_time] IS NOT NULL
          AND CONVERT(DATETIME2(3), source_row.[start_time]) < @window_end
          AND CONVERT(DATETIME2(3), source_row.[end_time]) >= @window_start;

        SET @events_inserted = @events_inserted + @@ROWCOUNT;

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
        @queue_updated AS [queue_fact_updated_rows],
        @queue_inserted AS [queue_fact_inserted_rows],
        @events_deleted AS [operation_events_replaced],
        @events_inserted AS [operation_events_inserted];
END;
GO
