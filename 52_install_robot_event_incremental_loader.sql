/*
    Installs the bounded, idempotent AMR operation-event loader.

    The procedure:
      - uses ODS ods_row_id as the incremental watermark;
      - processes each source in its own transaction;
      - serializes runs with sp_getapplock;
      - inserts only source events that are not already present;
      - skips rows without an event timestamp while still advancing the watermark.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'IOT2020'
BEGIN
    THROW 55200, N'Expected database IOT2020.', 1;
END;

IF OBJECT_ID(N'[DWD].[fact_robot_operation_event]', N'U') IS NULL
   OR OBJECT_ID(N'[DWD].[robot_event_watermark]', N'U') IS NULL
BEGIN
    THROW 55201, N'Run script 50_create_dispatch_and_operation_audit_contract.sql first.', 1;
END;

EXEC sys.sp_executesql N'
CREATE OR ALTER PROCEDURE [DWD].[sp_load_robot_operation_event_incremental]
    @batch_size INT = 5000,
    @bootstrap_rows INT = 5000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @batch_size < 1 OR @batch_size > 50000
    BEGIN
        THROW 55210, N''@batch_size must be between 1 and 50000.'', 1;
    END;

    IF @bootstrap_rows < 1 OR @bootstrap_rows > 500000
    BEGIN
        THROW 55211, N''@bootstrap_rows must be between 1 and 500000.'', 1;
    END;

    DECLARE
        @application_lock_result INT,
        @batch_id BIGINT = DATEDIFF_BIG(MILLISECOND, CONVERT(DATETIME2(3), N''2000-01-01T00:00:00''), SYSDATETIME()),
        @source_max_ods_row_id BIGINT,
        @last_ods_row_id BIGINT,
        @staged_source_rows BIGINT,
        @inserted_event_rows BIGINT,
        @last_event_time DATETIME2(3);

    DECLARE @load_result TABLE (
        [source_schema] SYSNAME NOT NULL,
        [source_table] SYSNAME NOT NULL,
        [batch_id] BIGINT NOT NULL,
        [previous_watermark] BIGINT NOT NULL,
        [current_watermark] BIGINT NOT NULL,
        [staged_source_rows] BIGINT NOT NULL,
        [inserted_event_rows] BIGINT NOT NULL,
        [last_event_time] DATETIME2(3) NULL
    );

    EXEC @application_lock_result = sys.sp_getapplock
        @Resource = N''DWD.sp_load_robot_operation_event_incremental'',
        @LockMode = N''Exclusive'',
        @LockOwner = N''Session'',
        @LockTimeout = 0;

    IF @application_lock_result < 0
    BEGIN
        THROW 55212, N''Another robot operation-event load is already running.'', 1;
    END;

    BEGIN TRY
        /* ODS.AMR_Queue -> one QUEUE_ENQUEUED event per source row. */
        SELECT @source_max_ods_row_id = ISNULL(MAX(source_row.[ods_row_id]), 0)
        FROM [ODS].[AMR_Queue] AS source_row;

        IF NOT EXISTS (
            SELECT 1
            FROM [DWD].[robot_event_watermark] AS watermark
            WHERE watermark.[source_schema] = N''ODS''
              AND watermark.[source_table] = N''AMR_Queue''
        )
        BEGIN
            INSERT INTO [DWD].[robot_event_watermark] (
                [source_schema],
                [source_table],
                [watermark_column],
                [last_ods_row_id],
                [updated_at]
            )
            VALUES (
                N''ODS'',
                N''AMR_Queue'',
                N''ods_row_id'',
                CASE
                    WHEN @source_max_ods_row_id > @bootstrap_rows
                        THEN @source_max_ods_row_id - @bootstrap_rows
                    ELSE 0
                END,
                SYSDATETIME()
            );
        END;

        SELECT @last_ods_row_id = watermark.[last_ods_row_id]
        FROM [DWD].[robot_event_watermark] AS watermark
        WHERE watermark.[source_schema] = N''ODS''
          AND watermark.[source_table] = N''AMR_Queue'';

        CREATE TABLE #queue_source (
            [ods_row_id] BIGINT NOT NULL PRIMARY KEY,
            [id] BIGINT NOT NULL,
            [job_id] INT NULL,
            [AMR_id] INT NULL,
            [current_subjob_id] INT NULL,
            [priority] INT NULL,
            [status] NVARCHAR(100) NULL,
            [enqueued_at] DATETIMEOFFSET NULL,
            [project_id] INT NULL,
            [ods_load_time] DATETIME2(3) NOT NULL
        );

        INSERT INTO #queue_source (
            [ods_row_id],
            [id],
            [job_id],
            [AMR_id],
            [current_subjob_id],
            [priority],
            [status],
            [enqueued_at],
            [project_id],
            [ods_load_time]
        )
        SELECT TOP (@batch_size)
            source_row.[ods_row_id],
            source_row.[id],
            source_row.[job_id],
            source_row.[AMR_id],
            source_row.[current_subjob_id],
            source_row.[priority],
            source_row.[status],
            source_row.[enqueued_at],
            source_row.[project_id],
            source_row.[ods_load_time]
        FROM [ODS].[AMR_Queue] AS source_row
        WHERE source_row.[ods_row_id] > @last_ods_row_id
        ORDER BY source_row.[ods_row_id];

        SELECT
            @staged_source_rows = COUNT_BIG(1),
            @source_max_ods_row_id = ISNULL(MAX(staged.[ods_row_id]), @last_ods_row_id)
        FROM #queue_source AS staged;

        BEGIN TRANSACTION;

        INSERT INTO [DWD].[fact_robot_operation_event] (
            [event_time],
            [event_category],
            [event_type],
            [event_status],
            [task_id],
            [queue_id],
            [job_id],
            [subjob_id],
            [robot_id],
            [robot_code],
            [project_id],
            [priority],
            [route_id],
            [route_segment_id],
            [station_code],
            [map_code],
            [position_x],
            [position_y],
            [battery_soc],
            [event_value],
            [event_value_numeric],
            [source_schema],
            [source_table],
            [source_ods_row_id],
            [source_event_part],
            [source_event_time],
            [source_ods_load_time],
            [dwd_batch_id]
        )
        SELECT
            CONVERT(DATETIME2(3), SWITCHOFFSET(staged.[enqueued_at], N''+07:00'')),
            N''DISPATCH'',
            N''QUEUE_ENQUEUED'',
            staged.[status],
            CONVERT(NVARCHAR(100), staged.[id]),
            CONVERT(NVARCHAR(100), staged.[id]),
            CONVERT(NVARCHAR(100), staged.[job_id]),
            CONVERT(NVARCHAR(100), staged.[current_subjob_id]),
            CONVERT(NVARCHAR(100), staged.[AMR_id]),
            master_robot.[name],
            CONVERT(NVARCHAR(100), staged.[project_id]),
            staged.[priority],
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            N''Queue record observed; robot is the value recorded on the source row, not proof of candidate evaluation.'',
            NULL,
            N''ODS'',
            N''AMR_Queue'',
            staged.[ods_row_id],
            N''QUEUE'',
            CONVERT(DATETIME2(3), SWITCHOFFSET(staged.[enqueued_at], N''+07:00'')),
            staged.[ods_load_time],
            @batch_id
        FROM #queue_source AS staged
        LEFT JOIN [dbo].[MA_AMR] AS master_robot
            ON master_robot.[id] = staged.[AMR_id]
        WHERE staged.[enqueued_at] IS NOT NULL
          AND NOT EXISTS (
              SELECT 1
              FROM [DWD].[fact_robot_operation_event] AS existing_event
              WHERE existing_event.[source_schema] = N''ODS''
                AND existing_event.[source_table] = N''AMR_Queue''
                AND existing_event.[source_ods_row_id] = staged.[ods_row_id]
                AND existing_event.[source_event_part] = N''QUEUE''
          );

        SET @inserted_event_rows = @@ROWCOUNT;

        SELECT @last_event_time = MAX(CONVERT(DATETIME2(3), SWITCHOFFSET(staged.[enqueued_at], N''+07:00'')))
        FROM #queue_source AS staged;

        IF @last_event_time IS NULL
        BEGIN
            SELECT @last_event_time = MAX(existing_event.[event_time])
            FROM [DWD].[fact_robot_operation_event] AS existing_event
            WHERE existing_event.[source_schema] = N''ODS''
              AND existing_event.[source_table] = N''AMR_Queue'';
        END;

        UPDATE watermark
        SET
            watermark.[last_ods_row_id] = @source_max_ods_row_id,
            watermark.[last_event_time] = COALESCE(@last_event_time, watermark.[last_event_time]),
            watermark.[last_success_time] = SYSDATETIME(),
            watermark.[last_batch_id] = @batch_id,
            watermark.[last_source_row_count] = @staged_source_rows,
            watermark.[last_inserted_event_count] = @inserted_event_rows,
            watermark.[updated_at] = SYSDATETIME()
        FROM [DWD].[robot_event_watermark] AS watermark
        WHERE watermark.[source_schema] = N''ODS''
          AND watermark.[source_table] = N''AMR_Queue'';

        COMMIT TRANSACTION;

        INSERT INTO @load_result
        VALUES (
            N''ODS'',
            N''AMR_Queue'',
            @batch_id,
            @last_ods_row_id,
            @source_max_ods_row_id,
            @staged_source_rows,
            @inserted_event_rows,
            @last_event_time
        );

        /* ODS.TA_AMR -> START and END events for each staged source row. */
        SELECT @source_max_ods_row_id = ISNULL(MAX(source_row.[ods_row_id]), 0)
        FROM [ODS].[TA_AMR] AS source_row;

        IF NOT EXISTS (
            SELECT 1
            FROM [DWD].[robot_event_watermark] AS watermark
            WHERE watermark.[source_schema] = N''ODS''
              AND watermark.[source_table] = N''TA_AMR''
        )
        BEGIN
            INSERT INTO [DWD].[robot_event_watermark] (
                [source_schema],
                [source_table],
                [watermark_column],
                [last_ods_row_id],
                [updated_at]
            )
            VALUES (
                N''ODS'',
                N''TA_AMR'',
                N''ods_row_id'',
                CASE
                    WHEN @source_max_ods_row_id > @bootstrap_rows
                        THEN @source_max_ods_row_id - @bootstrap_rows
                    ELSE 0
                END,
                SYSDATETIME()
            );
        END;

        SELECT @last_ods_row_id = watermark.[last_ods_row_id]
        FROM [DWD].[robot_event_watermark] AS watermark
        WHERE watermark.[source_schema] = N''ODS''
          AND watermark.[source_table] = N''TA_AMR'';

        CREATE TABLE #task_source (
            [ods_row_id] BIGINT NOT NULL PRIMARY KEY,
            [id] BIGINT NOT NULL,
            [AMR_id] INT NOT NULL,
            [queue_id] BIGINT NULL,
            [job_id] INT NULL,
            [subjob_id] INT NULL,
            [start_time] DATETIMEOFFSET NULL,
            [end_time] DATETIMEOFFSET NULL,
            [start_map] NVARCHAR(100) NULL,
            [start_zone] NVARCHAR(15) NULL,
            [start_x] DECIMAL(18, 6) NULL,
            [start_y] DECIMAL(18, 6) NULL,
            [start_battery] INT NULL,
            [end_battery] INT NULL,
            [status] VARCHAR(50) NULL,
            [ods_load_time] DATETIME2(3) NOT NULL
        );

        INSERT INTO #task_source (
            [ods_row_id],
            [id],
            [AMR_id],
            [queue_id],
            [job_id],
            [subjob_id],
            [start_time],
            [end_time],
            [start_map],
            [start_zone],
            [start_x],
            [start_y],
            [start_battery],
            [end_battery],
            [status],
            [ods_load_time]
        )
        SELECT TOP (@batch_size)
            source_row.[ods_row_id],
            source_row.[id],
            source_row.[AMR_id],
            source_row.[queue_id],
            source_row.[job_id],
            source_row.[subjob_id],
            source_row.[start_time],
            source_row.[end_time],
            source_row.[start_map],
            source_row.[start_zone],
            source_row.[start_x],
            source_row.[start_y],
            source_row.[start_battery],
            source_row.[end_battery],
            source_row.[status],
            source_row.[ods_load_time]
        FROM [ODS].[TA_AMR] AS source_row
        WHERE source_row.[ods_row_id] > @last_ods_row_id
        ORDER BY source_row.[ods_row_id];

        SELECT
            @staged_source_rows = COUNT_BIG(1),
            @source_max_ods_row_id = ISNULL(MAX(staged.[ods_row_id]), @last_ods_row_id)
        FROM #task_source AS staged;

        BEGIN TRANSACTION;

        INSERT INTO [DWD].[fact_robot_operation_event] (
            [event_time],
            [event_category],
            [event_type],
            [event_status],
            [task_id],
            [queue_id],
            [job_id],
            [subjob_id],
            [robot_id],
            [robot_code],
            [project_id],
            [priority],
            [route_id],
            [route_segment_id],
            [station_code],
            [map_code],
            [position_x],
            [position_y],
            [battery_soc],
            [event_value],
            [event_value_numeric],
            [source_schema],
            [source_table],
            [source_ods_row_id],
            [source_event_part],
            [source_event_time],
            [source_ods_load_time],
            [dwd_batch_id]
        )
        SELECT
            CONVERT(DATETIME2(3), SWITCHOFFSET(staged.[start_time], N''+07:00'')),
            N''TASK'',
            CASE WHEN staged.[subjob_id] IS NULL THEN N''JOB_STARTED'' ELSE N''SUBJOB_STARTED'' END,
            N''STARTED'',
            CONVERT(NVARCHAR(100), COALESCE(staged.[queue_id], staged.[id])),
            CONVERT(NVARCHAR(100), staged.[queue_id]),
            CONVERT(NVARCHAR(100), staged.[job_id]),
            CONVERT(NVARCHAR(100), staged.[subjob_id]),
            CONVERT(NVARCHAR(100), staged.[AMR_id]),
            master_robot.[name],
            NULL,
            NULL,
            NULL,
            NULL,
            staged.[start_zone],
            staged.[start_map],
            staged.[start_x],
            staged.[start_y],
            CONVERT(DECIMAL(9, 2), staged.[start_battery]),
            NULL,
            NULL,
            N''ODS'',
            N''TA_AMR'',
            staged.[ods_row_id],
            N''START'',
            CONVERT(DATETIME2(3), SWITCHOFFSET(staged.[start_time], N''+07:00'')),
            staged.[ods_load_time],
            @batch_id
        FROM #task_source AS staged
        LEFT JOIN [dbo].[MA_AMR] AS master_robot
            ON master_robot.[id] = staged.[AMR_id]
        WHERE staged.[start_time] IS NOT NULL
          AND NOT EXISTS (
              SELECT 1
              FROM [DWD].[fact_robot_operation_event] AS existing_event
              WHERE existing_event.[source_schema] = N''ODS''
                AND existing_event.[source_table] = N''TA_AMR''
                AND existing_event.[source_ods_row_id] = staged.[ods_row_id]
                AND existing_event.[source_event_part] = N''START''
          );

        SET @inserted_event_rows = @@ROWCOUNT;

        INSERT INTO [DWD].[fact_robot_operation_event] (
            [event_time],
            [event_category],
            [event_type],
            [event_status],
            [task_id],
            [queue_id],
            [job_id],
            [subjob_id],
            [robot_id],
            [robot_code],
            [project_id],
            [priority],
            [route_id],
            [route_segment_id],
            [station_code],
            [map_code],
            [position_x],
            [position_y],
            [battery_soc],
            [event_value],
            [event_value_numeric],
            [source_schema],
            [source_table],
            [source_ods_row_id],
            [source_event_part],
            [source_event_time],
            [source_ods_load_time],
            [dwd_batch_id]
        )
        SELECT
            CONVERT(DATETIME2(3), SWITCHOFFSET(staged.[end_time], N''+07:00'')),
            N''TASK'',
            CASE WHEN staged.[subjob_id] IS NULL THEN N''JOB_ENDED'' ELSE N''SUBJOB_ENDED'' END,
            CONVERT(NVARCHAR(100), staged.[status]),
            CONVERT(NVARCHAR(100), COALESCE(staged.[queue_id], staged.[id])),
            CONVERT(NVARCHAR(100), staged.[queue_id]),
            CONVERT(NVARCHAR(100), staged.[job_id]),
            CONVERT(NVARCHAR(100), staged.[subjob_id]),
            CONVERT(NVARCHAR(100), staged.[AMR_id]),
            master_robot.[name],
            NULL,
            NULL,
            NULL,
            NULL,
            staged.[start_zone],
            staged.[start_map],
            NULL,
            NULL,
            CONVERT(DECIMAL(9, 2), staged.[end_battery]),
            N''Duration seconds derived from source start_time and end_time.'',
            CASE
                WHEN staged.[start_time] IS NOT NULL
                    THEN CONVERT(DECIMAL(18, 6), DATEDIFF_BIG(MILLISECOND, staged.[start_time], staged.[end_time]) / 1000.0)
                ELSE NULL
            END,
            N''ODS'',
            N''TA_AMR'',
            staged.[ods_row_id],
            N''END'',
            CONVERT(DATETIME2(3), SWITCHOFFSET(staged.[end_time], N''+07:00'')),
            staged.[ods_load_time],
            @batch_id
        FROM #task_source AS staged
        LEFT JOIN [dbo].[MA_AMR] AS master_robot
            ON master_robot.[id] = staged.[AMR_id]
        WHERE staged.[end_time] IS NOT NULL
          AND NOT EXISTS (
              SELECT 1
              FROM [DWD].[fact_robot_operation_event] AS existing_event
              WHERE existing_event.[source_schema] = N''ODS''
                AND existing_event.[source_table] = N''TA_AMR''
                AND existing_event.[source_ods_row_id] = staged.[ods_row_id]
                AND existing_event.[source_event_part] = N''END''
          );

        SET @inserted_event_rows = @inserted_event_rows + @@ROWCOUNT;

        SELECT @last_event_time = MAX(event_time.[event_time])
        FROM (
            SELECT CONVERT(DATETIME2(3), SWITCHOFFSET(staged.[start_time], N''+07:00'')) AS [event_time]
            FROM #task_source AS staged
            WHERE staged.[start_time] IS NOT NULL
            UNION ALL
            SELECT CONVERT(DATETIME2(3), SWITCHOFFSET(staged.[end_time], N''+07:00''))
            FROM #task_source AS staged
            WHERE staged.[end_time] IS NOT NULL
        ) AS event_time;

        IF @last_event_time IS NULL
        BEGIN
            SELECT @last_event_time = MAX(existing_event.[event_time])
            FROM [DWD].[fact_robot_operation_event] AS existing_event
            WHERE existing_event.[source_schema] = N''ODS''
              AND existing_event.[source_table] = N''TA_AMR'';
        END;

        UPDATE watermark
        SET
            watermark.[last_ods_row_id] = @source_max_ods_row_id,
            watermark.[last_event_time] = COALESCE(@last_event_time, watermark.[last_event_time]),
            watermark.[last_success_time] = SYSDATETIME(),
            watermark.[last_batch_id] = @batch_id,
            watermark.[last_source_row_count] = @staged_source_rows,
            watermark.[last_inserted_event_count] = @inserted_event_rows,
            watermark.[updated_at] = SYSDATETIME()
        FROM [DWD].[robot_event_watermark] AS watermark
        WHERE watermark.[source_schema] = N''ODS''
          AND watermark.[source_table] = N''TA_AMR'';

        COMMIT TRANSACTION;

        INSERT INTO @load_result
        VALUES (
            N''ODS'',
            N''TA_AMR'',
            @batch_id,
            @last_ods_row_id,
            @source_max_ods_row_id,
            @staged_source_rows,
            @inserted_event_rows,
            @last_event_time
        );

        /* ODS.MA_AMR_Project_Assignment -> eligibility-window START and END. */
        SELECT @source_max_ods_row_id = ISNULL(MAX(source_row.[ods_row_id]), 0)
        FROM [ODS].[MA_AMR_Project_Assignment] AS source_row;

        IF NOT EXISTS (
            SELECT 1
            FROM [DWD].[robot_event_watermark] AS watermark
            WHERE watermark.[source_schema] = N''ODS''
              AND watermark.[source_table] = N''MA_AMR_Project_Assignment''
        )
        BEGIN
            INSERT INTO [DWD].[robot_event_watermark] (
                [source_schema],
                [source_table],
                [watermark_column],
                [last_ods_row_id],
                [updated_at]
            )
            VALUES (
                N''ODS'',
                N''MA_AMR_Project_Assignment'',
                N''ods_row_id'',
                CASE
                    WHEN @source_max_ods_row_id > @bootstrap_rows
                        THEN @source_max_ods_row_id - @bootstrap_rows
                    ELSE 0
                END,
                SYSDATETIME()
            );
        END;

        SELECT @last_ods_row_id = watermark.[last_ods_row_id]
        FROM [DWD].[robot_event_watermark] AS watermark
        WHERE watermark.[source_schema] = N''ODS''
          AND watermark.[source_table] = N''MA_AMR_Project_Assignment'';

        CREATE TABLE #assignment_source (
            [ods_row_id] BIGINT NOT NULL PRIMARY KEY,
            [id] BIGINT NOT NULL,
            [project_id] INT NOT NULL,
            [amr_id] INT NOT NULL,
            [start_time] DATETIME NULL,
            [end_time] DATETIME NULL,
            [is_active] CHAR(1) NULL,
            [ods_load_time] DATETIME2(3) NOT NULL
        );

        INSERT INTO #assignment_source (
            [ods_row_id],
            [id],
            [project_id],
            [amr_id],
            [start_time],
            [end_time],
            [is_active],
            [ods_load_time]
        )
        SELECT TOP (@batch_size)
            source_row.[ods_row_id],
            source_row.[id],
            source_row.[project_id],
            source_row.[amr_id],
            source_row.[start_time],
            source_row.[end_time],
            source_row.[is_active],
            source_row.[ods_load_time]
        FROM [ODS].[MA_AMR_Project_Assignment] AS source_row
        WHERE source_row.[ods_row_id] > @last_ods_row_id
        ORDER BY source_row.[ods_row_id];

        SELECT
            @staged_source_rows = COUNT_BIG(1),
            @source_max_ods_row_id = ISNULL(MAX(staged.[ods_row_id]), @last_ods_row_id)
        FROM #assignment_source AS staged;

        BEGIN TRANSACTION;

        INSERT INTO [DWD].[fact_robot_operation_event] (
            [event_time],
            [event_category],
            [event_type],
            [event_status],
            [task_id],
            [queue_id],
            [job_id],
            [subjob_id],
            [robot_id],
            [robot_code],
            [project_id],
            [priority],
            [route_id],
            [route_segment_id],
            [station_code],
            [map_code],
            [position_x],
            [position_y],
            [battery_soc],
            [event_value],
            [event_value_numeric],
            [source_schema],
            [source_table],
            [source_ods_row_id],
            [source_event_part],
            [source_event_time],
            [source_ods_load_time],
            [dwd_batch_id]
        )
        SELECT
            CONVERT(DATETIME2(3), staged.[start_time]),
            N''ELIGIBILITY'',
            N''PROJECT_ELIGIBILITY_STARTED'',
            CASE WHEN UPPER(LTRIM(RTRIM(staged.[is_active]))) = N''Y'' THEN N''ACTIVE'' ELSE N''INACTIVE'' END,
            NULL,
            NULL,
            NULL,
            NULL,
            CONVERT(NVARCHAR(100), staged.[amr_id]),
            master_robot.[name],
            CONVERT(NVARCHAR(100), staged.[project_id]),
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            N''Project eligibility window from MA_AMR_Project_Assignment.'',
            NULL,
            N''ODS'',
            N''MA_AMR_Project_Assignment'',
            staged.[ods_row_id],
            N''ELIGIBILITY_START'',
            CONVERT(DATETIME2(3), staged.[start_time]),
            staged.[ods_load_time],
            @batch_id
        FROM #assignment_source AS staged
        LEFT JOIN [dbo].[MA_AMR] AS master_robot
            ON master_robot.[id] = staged.[amr_id]
        WHERE staged.[start_time] IS NOT NULL
          AND NOT EXISTS (
              SELECT 1
              FROM [DWD].[fact_robot_operation_event] AS existing_event
              WHERE existing_event.[source_schema] = N''ODS''
                AND existing_event.[source_table] = N''MA_AMR_Project_Assignment''
                AND existing_event.[source_ods_row_id] = staged.[ods_row_id]
                AND existing_event.[source_event_part] = N''ELIGIBILITY_START''
          );

        SET @inserted_event_rows = @@ROWCOUNT;

        INSERT INTO [DWD].[fact_robot_operation_event] (
            [event_time],
            [event_category],
            [event_type],
            [event_status],
            [task_id],
            [queue_id],
            [job_id],
            [subjob_id],
            [robot_id],
            [robot_code],
            [project_id],
            [priority],
            [route_id],
            [route_segment_id],
            [station_code],
            [map_code],
            [position_x],
            [position_y],
            [battery_soc],
            [event_value],
            [event_value_numeric],
            [source_schema],
            [source_table],
            [source_ods_row_id],
            [source_event_part],
            [source_event_time],
            [source_ods_load_time],
            [dwd_batch_id]
        )
        SELECT
            CONVERT(DATETIME2(3), staged.[end_time]),
            N''ELIGIBILITY'',
            N''PROJECT_ELIGIBILITY_ENDED'',
            N''ENDED'',
            NULL,
            NULL,
            NULL,
            NULL,
            CONVERT(NVARCHAR(100), staged.[amr_id]),
            master_robot.[name],
            CONVERT(NVARCHAR(100), staged.[project_id]),
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            N''Project eligibility window end from MA_AMR_Project_Assignment.'',
            NULL,
            N''ODS'',
            N''MA_AMR_Project_Assignment'',
            staged.[ods_row_id],
            N''ELIGIBILITY_END'',
            CONVERT(DATETIME2(3), staged.[end_time]),
            staged.[ods_load_time],
            @batch_id
        FROM #assignment_source AS staged
        LEFT JOIN [dbo].[MA_AMR] AS master_robot
            ON master_robot.[id] = staged.[amr_id]
        WHERE staged.[end_time] IS NOT NULL
          AND NOT EXISTS (
              SELECT 1
              FROM [DWD].[fact_robot_operation_event] AS existing_event
              WHERE existing_event.[source_schema] = N''ODS''
                AND existing_event.[source_table] = N''MA_AMR_Project_Assignment''
                AND existing_event.[source_ods_row_id] = staged.[ods_row_id]
                AND existing_event.[source_event_part] = N''ELIGIBILITY_END''
          );

        SET @inserted_event_rows = @inserted_event_rows + @@ROWCOUNT;

        SELECT @last_event_time = MAX(event_time.[event_time])
        FROM (
            SELECT CONVERT(DATETIME2(3), staged.[start_time]) AS [event_time]
            FROM #assignment_source AS staged
            WHERE staged.[start_time] IS NOT NULL
            UNION ALL
            SELECT CONVERT(DATETIME2(3), staged.[end_time])
            FROM #assignment_source AS staged
            WHERE staged.[end_time] IS NOT NULL
        ) AS event_time;

        IF @last_event_time IS NULL
        BEGIN
            SELECT @last_event_time = MAX(existing_event.[event_time])
            FROM [DWD].[fact_robot_operation_event] AS existing_event
            WHERE existing_event.[source_schema] = N''ODS''
              AND existing_event.[source_table] = N''MA_AMR_Project_Assignment'';
        END;

        UPDATE watermark
        SET
            watermark.[last_ods_row_id] = @source_max_ods_row_id,
            watermark.[last_event_time] = COALESCE(@last_event_time, watermark.[last_event_time]),
            watermark.[last_success_time] = SYSDATETIME(),
            watermark.[last_batch_id] = @batch_id,
            watermark.[last_source_row_count] = @staged_source_rows,
            watermark.[last_inserted_event_count] = @inserted_event_rows,
            watermark.[updated_at] = SYSDATETIME()
        FROM [DWD].[robot_event_watermark] AS watermark
        WHERE watermark.[source_schema] = N''ODS''
          AND watermark.[source_table] = N''MA_AMR_Project_Assignment'';

        COMMIT TRANSACTION;

        INSERT INTO @load_result
        VALUES (
            N''ODS'',
            N''MA_AMR_Project_Assignment'',
            @batch_id,
            @last_ods_row_id,
            @source_max_ods_row_id,
            @staged_source_rows,
            @inserted_event_rows,
            @last_event_time
        );

        EXEC sys.sp_releaseapplock
            @Resource = N''DWD.sp_load_robot_operation_event_incremental'',
            @LockOwner = N''Session'';

        SELECT
            result.[source_schema],
            result.[source_table],
            result.[batch_id],
            result.[previous_watermark],
            result.[current_watermark],
            result.[staged_source_rows],
            result.[inserted_event_rows],
            result.[last_event_time]
        FROM @load_result AS result
        ORDER BY result.[source_schema], result.[source_table];
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
        BEGIN
            ROLLBACK TRANSACTION;
        END;

        EXEC sys.sp_releaseapplock
            @Resource = N''DWD.sp_load_robot_operation_event_incremental'',
            @LockOwner = N''Session'';

        THROW;
    END CATCH;
END;
';

SELECT
    schema_info.[name] AS [schema_name],
    procedure_info.[name] AS [procedure_name],
    procedure_info.[create_date],
    procedure_info.[modify_date]
FROM [sys].[procedures] AS procedure_info
INNER JOIN [sys].[schemas] AS schema_info
    ON schema_info.[schema_id] = procedure_info.[schema_id]
WHERE schema_info.[name] = N'DWD'
  AND procedure_info.[name] = N'sp_load_robot_operation_event_incremental';
