/*
    Task Analytics hourly leaderboard serving schema
    =================================================

    Purpose
      - Preserve the existing daily DWS leaderboards for day-level reporting.
      - Add hourly DWS grains so the Web can rank Calling Boxes and assigned
        tasks without counting data outside an hour-aligned analysis window.
      - The Web remains DWS-only; this script does not change source, ODS, or
        DWD business data.

    Grain
      DWS.dws_robot_calling_box_hourly:
        one robot + Calling Box + calendar hour.
      DWS.dws_robot_assigned_task_hourly:
        one robot + task + calendar hour.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    IF OBJECT_ID(N'[DWS].[dws_robot_calling_box_hourly]', N'U') IS NULL
    BEGIN
        CREATE TABLE [DWS].[dws_robot_calling_box_hourly]
        (
            [calling_box_hourly_id] BIGINT IDENTITY(1, 1) NOT NULL,
            [stat_hour] DATETIME2(3) NOT NULL,
            [robot_code] NVARCHAR(100) NOT NULL,
            [robot_id] NVARCHAR(100) NULL,
            [calling_box_id] INT NOT NULL,
            [calling_box_name] NVARCHAR(200) NULL,
            [calling_box_label] NVARCHAR(260) NOT NULL,
            [calling_box_count] BIGINT NOT NULL,
            [first_called_at] DATETIME2(3) NULL,
            [last_called_at] DATETIME2(3) NULL,
            [dws_load_time] DATETIME2(3) NOT NULL
                CONSTRAINT [DF_dws_robot_calling_box_hourly_load_time] DEFAULT SYSDATETIME(),
            [dws_batch_id] BIGINT NULL,
            CONSTRAINT [PK_dws_robot_calling_box_hourly] PRIMARY KEY CLUSTERED ([calling_box_hourly_id]),
            CONSTRAINT [CK_dws_robot_calling_box_hourly_nonnegative] CHECK ([calling_box_count] >= 0)
        );
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.indexes AS index_row
        WHERE index_row.[object_id] = OBJECT_ID(N'[DWS].[dws_robot_calling_box_hourly]', N'U')
          AND index_row.[name] = N'UX_dws_robot_calling_box_hourly_grain'
    )
    BEGIN
        CREATE UNIQUE NONCLUSTERED INDEX [UX_dws_robot_calling_box_hourly_grain]
            ON [DWS].[dws_robot_calling_box_hourly] ([stat_hour], [robot_code], [calling_box_id]);
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.indexes AS index_row
        WHERE index_row.[object_id] = OBJECT_ID(N'[DWS].[dws_robot_calling_box_hourly]', N'U')
          AND index_row.[name] = N'IX_dws_robot_calling_box_hourly_window'
    )
    BEGIN
        CREATE NONCLUSTERED INDEX [IX_dws_robot_calling_box_hourly_window]
            ON [DWS].[dws_robot_calling_box_hourly] ([stat_hour], [robot_code])
            INCLUDE ([calling_box_label], [calling_box_count], [first_called_at], [last_called_at]);
    END;

    IF OBJECT_ID(N'[DWS].[dws_robot_assigned_task_hourly]', N'U') IS NULL
    BEGIN
        CREATE TABLE [DWS].[dws_robot_assigned_task_hourly]
        (
            [assigned_task_hourly_id] BIGINT IDENTITY(1, 1) NOT NULL,
            [stat_hour] DATETIME2(3) NOT NULL,
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
                CONSTRAINT [DF_dws_robot_assigned_task_hourly_load_time] DEFAULT SYSDATETIME(),
            [dws_batch_id] BIGINT NULL,
            CONSTRAINT [PK_dws_robot_assigned_task_hourly] PRIMARY KEY CLUSTERED ([assigned_task_hourly_id]),
            CONSTRAINT [CK_dws_robot_assigned_task_hourly_nonnegative] CHECK
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
        WHERE index_row.[object_id] = OBJECT_ID(N'[DWS].[dws_robot_assigned_task_hourly]', N'U')
          AND index_row.[name] = N'UX_dws_robot_assigned_task_hourly_grain'
    )
    BEGIN
        CREATE UNIQUE NONCLUSTERED INDEX [UX_dws_robot_assigned_task_hourly_grain]
            ON [DWS].[dws_robot_assigned_task_hourly] ([stat_hour], [robot_code], [job_id]);
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.indexes AS index_row
        WHERE index_row.[object_id] = OBJECT_ID(N'[DWS].[dws_robot_assigned_task_hourly]', N'U')
          AND index_row.[name] = N'IX_dws_robot_assigned_task_hourly_window'
    )
    BEGIN
        CREATE NONCLUSTERED INDEX [IX_dws_robot_assigned_task_hourly_window]
            ON [DWS].[dws_robot_assigned_task_hourly] ([stat_hour], [robot_code])
            INCLUDE ([task_label], [assigned_task_count], [completed_task_count], [first_assigned_at], [last_assigned_at]);
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

SELECT
    schema_row.[name] AS [schema_name],
    table_row.[name] AS [table_name],
    table_row.[create_date],
    table_row.[modify_date]
FROM sys.tables AS table_row
INNER JOIN sys.schemas AS schema_row
    ON schema_row.[schema_id] = table_row.[schema_id]
WHERE schema_row.[name] = N'DWS'
  AND table_row.[name] IN (N'dws_robot_calling_box_hourly', N'dws_robot_assigned_task_hourly')
ORDER BY table_row.[name];
