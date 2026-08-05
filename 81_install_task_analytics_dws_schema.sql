USE [IOT2020];

/*
    Task Analytics DWD/DWS serving schema
    =====================================

    This installer creates only the durable serving schema. It does not delete
    source rows and it does not fabricate idle time from missing observations.

    The corresponding loader will use this precedence per robot-hour:
      1. executing subtask/job interval
      2. Charging
      3. Waiting for the first execution of an assigned queue
      4. No task (only when the hour is otherwise observed)
      5. Data unavailable (missing task/charging coverage)

    Web consumers must read the DWS tables below, never dbo/ODS/DWD directly.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'IOT2020'
BEGIN
    THROW 58100, N'Expected database IOT2020.', 1;
END;

IF SCHEMA_ID(N'DWD') IS NULL OR SCHEMA_ID(N'DWS') IS NULL
BEGIN
    THROW 58101, N'DWD and DWS schemas must already exist.', 1;
END;

BEGIN TRY
    BEGIN TRANSACTION;

    /* Calling Box attribution enters DWD before any DWS aggregate uses it. */
    IF COL_LENGTH(N'DWD.fact_amr_queue', N'calling_box_id') IS NULL
    BEGIN
        ALTER TABLE [DWD].[fact_amr_queue]
            ADD [calling_box_id] INT NULL;
    END;

    IF COL_LENGTH(N'DWD.fact_amr_queue', N'calling_box_name') IS NULL
    BEGIN
        ALTER TABLE [DWD].[fact_amr_queue]
            ADD [calling_box_name] NVARCHAR(200) NULL;
    END;

    IF OBJECT_ID(N'[DWD].[dim_amr_task]', N'U') IS NULL
    BEGIN
        CREATE TABLE [DWD].[dim_amr_task]
        (
            [job_id] INT NOT NULL,
            [project_id] INT NULL,
            [task_name] NVARCHAR(200) NULL,
            [source_created_time] DATETIME2(3) NULL,
            [source_updated_time] DATETIME2(3) NULL,
            [source_deleted_time] DATETIME2(3) NULL,
            [source_ods_row_id] BIGINT NULL,
            [source_ods_load_time] DATETIME2(3) NULL,
            [dwd_load_time] DATETIME2(3) NOT NULL
                CONSTRAINT [DF_dim_amr_task_dwd_load_time] DEFAULT SYSDATETIME(),
            CONSTRAINT [PK_dim_amr_task] PRIMARY KEY CLUSTERED ([job_id])
        );
    END;

    IF OBJECT_ID(N'[DWD].[dim_amr_calling_box]', N'U') IS NULL
    BEGIN
        CREATE TABLE [DWD].[dim_amr_calling_box]
        (
            [calling_box_id] INT NOT NULL,
            [esp_id] INT NULL,
            [calling_box_name] NVARCHAR(200) NULL,
            [button_position] INT NULL,
            [source_created_time] DATETIME2(3) NULL,
            [source_updated_time] DATETIME2(3) NULL,
            [source_deleted_time] DATETIME2(3) NULL,
            [source_ods_row_id] BIGINT NULL,
            [source_ods_load_time] DATETIME2(3) NULL,
            [dwd_load_time] DATETIME2(3) NOT NULL
                CONSTRAINT [DF_dim_amr_calling_box_dwd_load_time] DEFAULT SYSDATETIME(),
            CONSTRAINT [PK_dim_amr_calling_box] PRIMARY KEY CLUSTERED ([calling_box_id])
        );
    END;

    IF OBJECT_ID(N'[DWS].[dws_robot_task_hourly]', N'U') IS NULL
    BEGIN
        CREATE TABLE [DWS].[dws_robot_task_hourly]
        (
            [task_hourly_id] BIGINT IDENTITY(1, 1) NOT NULL,
            [stat_hour] DATETIME2(3) NOT NULL,
            [robot_code] NVARCHAR(100) NOT NULL,
            [robot_id] NVARCHAR(100) NULL,
            [accepted_queue_count] BIGINT NOT NULL,
            [task_started_count] BIGINT NOT NULL,
            [subtask_started_count] BIGINT NOT NULL,
            [task_completed_count] BIGINT NOT NULL,
            [executing_seconds] INT NOT NULL,
            [charging_seconds] INT NOT NULL,
            [waiting_seconds] INT NOT NULL,
            [no_task_seconds] INT NOT NULL,
            [data_unavailable_seconds] INT NOT NULL,
            [execution_overlap_seconds] INT NOT NULL,
            [first_source_event_time] DATETIME2(3) NULL,
            [last_source_event_time] DATETIME2(3) NULL,
            [dws_load_time] DATETIME2(3) NOT NULL
                CONSTRAINT [DF_dws_robot_task_hourly_load_time] DEFAULT SYSDATETIME(),
            [dws_batch_id] BIGINT NULL,
            CONSTRAINT [PK_dws_robot_task_hourly] PRIMARY KEY CLUSTERED ([task_hourly_id]),
            CONSTRAINT [CK_dws_robot_task_hourly_nonnegative] CHECK
            (
                [accepted_queue_count] >= 0
                AND [task_started_count] >= 0
                AND [subtask_started_count] >= 0
                AND [task_completed_count] >= 0
                AND [executing_seconds] >= 0
                AND [charging_seconds] >= 0
                AND [waiting_seconds] >= 0
                AND [no_task_seconds] >= 0
                AND [data_unavailable_seconds] >= 0
                AND [execution_overlap_seconds] >= 0
            )
        );
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.indexes AS index_row
        WHERE index_row.[object_id] = OBJECT_ID(N'[DWS].[dws_robot_task_hourly]')
          AND index_row.[name] = N'UX_dws_robot_task_hourly_robot_hour'
    )
    BEGIN
        CREATE UNIQUE NONCLUSTERED INDEX [UX_dws_robot_task_hourly_robot_hour]
            ON [DWS].[dws_robot_task_hourly] ([robot_code], [stat_hour]);
    END;

    IF OBJECT_ID(N'[DWS].[dws_robot_calling_box_daily]', N'U') IS NULL
    BEGIN
        CREATE TABLE [DWS].[dws_robot_calling_box_daily]
        (
            [calling_box_daily_id] BIGINT IDENTITY(1, 1) NOT NULL,
            [stat_date] DATE NOT NULL,
            [robot_code] NVARCHAR(100) NOT NULL,
            [robot_id] NVARCHAR(100) NULL,
            [calling_box_id] INT NOT NULL,
            [calling_box_name] NVARCHAR(200) NULL,
            [calling_box_label] NVARCHAR(260) NOT NULL,
            [calling_box_count] BIGINT NOT NULL,
            [first_called_at] DATETIME2(3) NULL,
            [last_called_at] DATETIME2(3) NULL,
            [dws_load_time] DATETIME2(3) NOT NULL
                CONSTRAINT [DF_dws_robot_calling_box_daily_load_time] DEFAULT SYSDATETIME(),
            [dws_batch_id] BIGINT NULL,
            CONSTRAINT [PK_dws_robot_calling_box_daily] PRIMARY KEY CLUSTERED ([calling_box_daily_id]),
            CONSTRAINT [CK_dws_robot_calling_box_daily_nonnegative] CHECK ([calling_box_count] >= 0)
        );
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.indexes AS index_row
        WHERE index_row.[object_id] = OBJECT_ID(N'[DWS].[dws_robot_calling_box_daily]')
          AND index_row.[name] = N'UX_dws_robot_calling_box_daily_grain'
    )
    BEGIN
        CREATE UNIQUE NONCLUSTERED INDEX [UX_dws_robot_calling_box_daily_grain]
            ON [DWS].[dws_robot_calling_box_daily] ([stat_date], [robot_code], [calling_box_id]);
    END;

    IF OBJECT_ID(N'[DWS].[dws_robot_assigned_task_daily]', N'U') IS NULL
    BEGIN
        CREATE TABLE [DWS].[dws_robot_assigned_task_daily]
        (
            [assigned_task_daily_id] BIGINT IDENTITY(1, 1) NOT NULL,
            [stat_date] DATE NOT NULL,
            [robot_code] NVARCHAR(100) NOT NULL,
            [robot_id] NVARCHAR(100) NULL,
            [job_id] INT NOT NULL,
            [task_name] NVARCHAR(200) NULL,
            [task_label] NVARCHAR(260) NOT NULL,
            [assigned_task_count] BIGINT NOT NULL,
            [completed_task_count] BIGINT NOT NULL,
            [first_assigned_at] DATETIME2(3) NULL,
            [last_assigned_at] DATETIME2(3) NULL,
            [dws_load_time] DATETIME2(3) NOT NULL
                CONSTRAINT [DF_dws_robot_assigned_task_daily_load_time] DEFAULT SYSDATETIME(),
            [dws_batch_id] BIGINT NULL,
            CONSTRAINT [PK_dws_robot_assigned_task_daily] PRIMARY KEY CLUSTERED ([assigned_task_daily_id]),
            CONSTRAINT [CK_dws_robot_assigned_task_daily_nonnegative] CHECK
            (
                [assigned_task_count] >= 0
                AND [completed_task_count] >= 0
            )
        );
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.indexes AS index_row
        WHERE index_row.[object_id] = OBJECT_ID(N'[DWS].[dws_robot_assigned_task_daily]')
          AND index_row.[name] = N'UX_dws_robot_assigned_task_daily_grain'
    )
    BEGIN
        CREATE UNIQUE NONCLUSTERED INDEX [UX_dws_robot_assigned_task_daily_grain]
            ON [DWS].[dws_robot_assigned_task_daily] ([stat_date], [robot_code], [job_id]);
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
