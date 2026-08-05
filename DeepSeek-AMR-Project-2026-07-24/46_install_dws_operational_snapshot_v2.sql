USE [IOT2020];
GO

/*
    Install the AMR operational snapshot used by the manually refreshed Web dashboard.

    Purpose
    -------
    The old fast snapshot was sourced from dbo.AMR_Currentdata. That table currently
    contains only nine old rows from 2024 and cannot represent the active fleet.

    This version keeps the Web read path on DWS, but refreshes the small DWS snapshot
    from the latest indexed rows in the operational history tables:

      dbo.MA_AMR
        + dbo.robot_status_history
        + dbo.robot_battery_history
        + dbo.robot_job_history
        + dbo.AMR_Robot_Mode
        -> DWS.dws_robot_current_snapshot

    It does not modify ODS/DWD history and does not replace the historical warehouse
    pipeline. The ODS/DWD/DWS historical synchronization remains a separate task.

    Online definition
    -----------------
    A robot is ONLINE when its latest status timestamp is within
    @online_anchor_minutes of the latest status timestamp in the whole source table.
    This is deliberately relative to the source-data anchor. The Web must also show
    that anchor so delayed source collection is not presented as real-time data.

    Safety
    ------
    - No DROP, TRUNCATE or broad DELETE is used.
    - Only rows matching the active MA_AMR robot_code are updated.
    - Missing active robot rows are inserted.
    - The refresh is transaction protected and application locked.
*/

/* Pre-execution validation: all required source indexes must exist. */
IF OBJECT_ID(N'[dbo].[MA_AMR]', N'U') IS NULL
   OR OBJECT_ID(N'[dbo].[AMR_Robot_Mode]', N'U') IS NULL
   OR OBJECT_ID(N'[dbo].[robot_status_history]', N'U') IS NULL
   OR OBJECT_ID(N'[dbo].[robot_battery_history]', N'U') IS NULL
   OR OBJECT_ID(N'[dbo].[robot_job_history]', N'U') IS NULL
   OR OBJECT_ID(N'[DWS].[dws_robot_current_snapshot]', N'U') IS NULL
   OR OBJECT_ID(N'[DWS].[etl_batch]', N'U') IS NULL
   OR OBJECT_ID(N'[DWS].[etl_load_log]', N'U') IS NULL
BEGIN
    RAISERROR(N'Missing one or more required AMR operational snapshot objects.', 16, 1);
    RETURN;
END;
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE [object_id] = OBJECT_ID(N'[dbo].[robot_status_history]')
      AND [name] = N'IX_status_performance'
)
   OR NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE [object_id] = OBJECT_ID(N'[dbo].[robot_battery_history]')
      AND [name] = N'IX_battery_performance'
)
   OR NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE [object_id] = OBJECT_ID(N'[dbo].[robot_job_history]')
      AND [name] = N'IX_job_performance'
)
BEGIN
    RAISERROR(N'Missing IX_status_performance, IX_battery_performance, or IX_job_performance.', 16, 1);
    RETURN;
END;
GO

/* Add source-backed operational fields without rebuilding the snapshot table. */
IF COL_LENGTH(N'DWS.dws_robot_current_snapshot', N'job_status') IS NULL
BEGIN
    ALTER TABLE [DWS].[dws_robot_current_snapshot]
    ADD [job_status] NVARCHAR(100) NULL;
END;
GO

IF COL_LENGTH(N'DWS.dws_robot_current_snapshot', N'charging_status') IS NULL
BEGIN
    ALTER TABLE [DWS].[dws_robot_current_snapshot]
    ADD [charging_status] NVARCHAR(100) NULL;
END;
GO

IF COL_LENGTH(N'DWS.dws_robot_current_snapshot', N'battery_voltage') IS NULL
BEGIN
    ALTER TABLE [DWS].[dws_robot_current_snapshot]
    ADD [battery_voltage] DECIMAL(18,6) NULL;
END;
GO

IF COL_LENGTH(N'DWS.dws_robot_current_snapshot', N'battery_current') IS NULL
BEGIN
    ALTER TABLE [DWS].[dws_robot_current_snapshot]
    ADD [battery_current] DECIMAL(18,6) NULL;
END;
GO

IF COL_LENGTH(N'DWS.dws_robot_current_snapshot', N'status_event_time') IS NULL
BEGIN
    ALTER TABLE [DWS].[dws_robot_current_snapshot]
    ADD [status_event_time] DATETIME2(3) NULL;
END;
GO

IF COL_LENGTH(N'DWS.dws_robot_current_snapshot', N'battery_event_time') IS NULL
BEGIN
    ALTER TABLE [DWS].[dws_robot_current_snapshot]
    ADD [battery_event_time] DATETIME2(3) NULL;
END;
GO

IF COL_LENGTH(N'DWS.dws_robot_current_snapshot', N'job_event_time') IS NULL
BEGIN
    ALTER TABLE [DWS].[dws_robot_current_snapshot]
    ADD [job_event_time] DATETIME2(3) NULL;
END;
GO

IF COL_LENGTH(N'DWS.dws_robot_current_snapshot', N'source_anchor_time') IS NULL
BEGIN
    ALTER TABLE [DWS].[dws_robot_current_snapshot]
    ADD [source_anchor_time] DATETIME2(3) NULL;
END;
GO

IF COL_LENGTH(N'DWS.dws_robot_current_snapshot', N'target_station_code') IS NULL
BEGIN
    ALTER TABLE [DWS].[dws_robot_current_snapshot]
    ADD [target_station_code] NVARCHAR(100) NULL;
END;
GO

CREATE OR ALTER PROCEDURE [DWS].[sp_refresh_robot_operational_snapshot_v2]
    @online_anchor_minutes INT = 5
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @online_anchor_minutes < 1 OR @online_anchor_minutes > 120
    BEGIN
        RAISERROR(N'online_anchor_minutes must be between 1 and 120.', 16, 1);
        RETURN;
    END;

    DECLARE
        @started_at DATETIME2(3) = SYSDATETIME(),
        @status_anchor DATETIME2(3),
        @batch_id BIGINT = NULL,
        @lock_result INT,
        @rows_updated BIGINT = 0,
        @rows_inserted BIGINT = 0,
        @error_message NVARCHAR(4000);

    EXEC @lock_result = sys.sp_getapplock
        @Resource = N'DWS.sp_refresh_robot_current_snapshot_fast.v2',
        @LockMode = N'Exclusive',
        @LockOwner = N'Session',
        @LockTimeout = 0;

    IF @lock_result < 0
    BEGIN
        RAISERROR(N'The AMR operational snapshot refresh is already running.', 16, 1);
        RETURN;
    END;

    BEGIN TRY
        SELECT TOP (1)
            @status_anchor = src.[pc_timestamp]
        FROM [dbo].[robot_status_history] AS src
        ORDER BY src.[id] DESC;

        IF @status_anchor IS NULL
        BEGIN
            RAISERROR(N'dbo.robot_status_history has no usable source-data anchor.', 16, 1);
        END;

        INSERT INTO [DWS].[etl_batch] (
            [batch_start_time],
            [batch_status],
            [error_message]
        )
        VALUES (
            @started_at,
            N'RUNNING',
            NULL
        );

        SET @batch_id = SCOPE_IDENTITY();

        CREATE TABLE #snapshot_stage (
            [robot_code] NVARCHAR(100) NOT NULL,
            [robot_id] NVARCHAR(100) NULL,
            [robot_name] NVARCHAR(200) NULL,
            [current_status] NVARCHAR(100) NULL,
            [current_mode] NVARCHAR(100) NULL,
            [online_status] NVARCHAR(50) NULL,
            [job_id] NVARCHAR(100) NULL,
            [subjob_id] NVARCHAR(100) NULL,
            [job_status] NVARCHAR(100) NULL,
            [map_code] NVARCHAR(100) NULL,
            [station_code] NVARCHAR(100) NULL,
            [target_station_code] NVARCHAR(100) NULL,
            [position_x] DECIMAL(18,6) NULL,
            [position_y] DECIMAL(18,6) NULL,
            [position_theta] DECIMAL(18,6) NULL,
            [speed_mps] DECIMAL(18,6) NULL,
            [battery_soc] DECIMAL(9,4) NULL,
            [battery_voltage] DECIMAL(18,6) NULL,
            [battery_current] DECIMAL(18,6) NULL,
            [charging_status] NVARCHAR(100) NULL,
            [error_code] NVARCHAR(100) NULL,
            [error_message] NVARCHAR(1000) NULL,
            [source_event_time] DATETIME2(3) NULL,
            [status_event_time] DATETIME2(3) NULL,
            [battery_event_time] DATETIME2(3) NULL,
            [job_event_time] DATETIME2(3) NULL,
            [source_anchor_time] DATETIME2(3) NULL,
            [source_snapshot_time] DATETIME2(3) NOT NULL,
            PRIMARY KEY ([robot_code])
        );

        INSERT INTO #snapshot_stage (
            [robot_code], [robot_id], [robot_name], [current_status], [current_mode],
            [online_status], [job_id], [subjob_id], [job_status], [map_code], [station_code],
            [target_station_code],
            [position_x], [position_y], [position_theta], [speed_mps], [battery_soc],
            [battery_voltage], [battery_current], [charging_status], [error_code],
            [error_message], [source_event_time], [status_event_time], [battery_event_time],
            [job_event_time], [source_anchor_time], [source_snapshot_time]
        )
        SELECT
            CONVERT(NVARCHAR(100), master_robot.[name]),
            CONVERT(NVARCHAR(100), master_robot.[id]),
            CONVERT(NVARCHAR(200), master_robot.[name]),
            NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), status_row.[robot_move_state]))), N''), N'-'),
            COALESCE(
                NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), mode_dictionary.[Mode_Detail]))), N''),
                CASE
                    WHEN status_row.[robot_mode] IS NULL THEN NULL
                    ELSE CONCAT(N'MODE_', CONVERT(NVARCHAR(30), status_row.[robot_mode]))
                END
            ),
            CASE
                WHEN status_row.[pc_timestamp] >= DATEADD(MINUTE, -@online_anchor_minutes, @status_anchor)
                 AND status_row.[pc_timestamp] <= DATEADD(MINUTE, 1, @status_anchor)
                    THEN N'ONLINE'
                ELSE N'OFFLINE'
            END,
            NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), job_row.[job_name]))), N''), N'-'),
            NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), job_row.[job_status]))), N''), N'-'),
            NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), job_row.[job_status]))), N''), N'-'),
            NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), status_row.[robot_current_map]))), N''), N'-'),
            COALESCE(
                NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), status_row.[robot_zone_name]))), N''), N'-'),
                NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), status_row.[robot_zone_id]))), N''), N'-'),
                NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), job_row.[poi_current]))), N''), N'-')
            ),
            NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), job_row.[poi_target]))), N''), N'-'),
            TRY_CONVERT(DECIMAL(18,6), status_row.[robot_position_x]),
            TRY_CONVERT(DECIMAL(18,6), status_row.[robot_position_y]),
            TRY_CONVERT(DECIMAL(18,6), status_row.[robot_orientation_z]),
            TRY_CONVERT(DECIMAL(18,6), status_row.[robot_speed]),
            TRY_CONVERT(DECIMAL(9,4), battery_row.[batt_level]),
            TRY_CONVERT(DECIMAL(18,6), battery_row.[batt_volt]),
            TRY_CONVERT(DECIMAL(18,6), battery_row.[batt_current]),
            NULLIF(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), battery_row.[batt_charge_status]))), N''), N'-'),
            TRY_CONVERT(NVARCHAR(100), status_row.[robot_emer_status]),
            NULL,
            status_row.[pc_timestamp],
            status_row.[pc_timestamp],
            battery_row.[pc_timestamp],
            job_row.[pc_timestamp],
            @status_anchor,
            @started_at
        FROM [dbo].[MA_AMR] AS master_robot
        OUTER APPLY (
            SELECT TOP (1)
                src.[pc_timestamp],
                src.[robot_speed],
                src.[robot_position_x],
                src.[robot_position_y],
                src.[robot_orientation_z],
                src.[robot_move_state],
                src.[robot_mode],
                src.[robot_emer_status],
                src.[robot_current_map],
                src.[robot_zone_id],
                src.[robot_zone_name]
            FROM [dbo].[robot_status_history] AS src
                WITH (INDEX([IX_status_performance]), FORCESEEK)
            WHERE src.[amr_id] = master_robot.[id]
            ORDER BY src.[pc_timestamp] DESC
        ) AS status_row
        OUTER APPLY (
            SELECT TOP (1)
                src.[pc_timestamp],
                src.[batt_level],
                src.[batt_volt],
                src.[batt_current],
                src.[batt_charge_status]
            FROM [dbo].[robot_battery_history] AS src
                WITH (INDEX([IX_battery_performance]), FORCESEEK)
            WHERE src.[amr_id] = master_robot.[id]
            ORDER BY src.[pc_timestamp] DESC
        ) AS battery_row
        OUTER APPLY (
            SELECT TOP (1)
                src.[pc_timestamp],
                src.[job_name],
                src.[job_status],
                src.[poi_current],
                src.[poi_target]
            FROM [dbo].[robot_job_history] AS src
                WITH (INDEX([IX_job_performance]), FORCESEEK)
            WHERE src.[amr_id] = master_robot.[id]
            ORDER BY src.[pc_timestamp] DESC
        ) AS job_row
        OUTER APPLY (
            SELECT TOP (1)
                mode_ref.[Mode_Detail]
            FROM [dbo].[AMR_Robot_Mode] AS mode_ref
            WHERE TRY_CONVERT(INT, mode_ref.[Mode_ID]) = status_row.[robot_mode]
            ORDER BY mode_ref.[Mode_ID]
        ) AS mode_dictionary
        WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y'
          AND NULLIF(LTRIM(RTRIM(master_robot.[name])), N'') IS NOT NULL
        OPTION (LOOP JOIN, FORCE ORDER, MAXDOP 1);

        IF NOT EXISTS (SELECT 1 FROM #snapshot_stage)
        BEGIN
            RAISERROR(N'No active MA_AMR rows were staged; refresh cancelled.', 16, 1);
        END;

        BEGIN TRANSACTION;

        UPDATE target_snapshot
        SET
            target_snapshot.[robot_id] = source_snapshot.[robot_id],
            target_snapshot.[robot_name] = source_snapshot.[robot_name],
            target_snapshot.[current_status] = source_snapshot.[current_status],
            target_snapshot.[current_mode] = source_snapshot.[current_mode],
            target_snapshot.[online_status] = source_snapshot.[online_status],
            target_snapshot.[job_id] = source_snapshot.[job_id],
            target_snapshot.[subjob_id] = source_snapshot.[subjob_id],
            target_snapshot.[job_status] = source_snapshot.[job_status],
            target_snapshot.[map_code] = source_snapshot.[map_code],
            target_snapshot.[station_code] = source_snapshot.[station_code],
            target_snapshot.[target_station_code] = source_snapshot.[target_station_code],
            target_snapshot.[position_x] = source_snapshot.[position_x],
            target_snapshot.[position_y] = source_snapshot.[position_y],
            target_snapshot.[position_theta] = source_snapshot.[position_theta],
            target_snapshot.[speed_mps] = source_snapshot.[speed_mps],
            target_snapshot.[battery_soc] = source_snapshot.[battery_soc],
            target_snapshot.[battery_voltage] = source_snapshot.[battery_voltage],
            target_snapshot.[battery_current] = source_snapshot.[battery_current],
            target_snapshot.[charging_status] = source_snapshot.[charging_status],
            target_snapshot.[error_code] = source_snapshot.[error_code],
            target_snapshot.[error_message] = source_snapshot.[error_message],
            target_snapshot.[source_event_time] = source_snapshot.[source_event_time],
            target_snapshot.[status_event_time] = source_snapshot.[status_event_time],
            target_snapshot.[battery_event_time] = source_snapshot.[battery_event_time],
            target_snapshot.[job_event_time] = source_snapshot.[job_event_time],
            target_snapshot.[source_anchor_time] = source_snapshot.[source_anchor_time],
            target_snapshot.[source_snapshot_time] = source_snapshot.[source_snapshot_time],
            target_snapshot.[dws_load_time] = @started_at,
            target_snapshot.[dws_batch_id] = @batch_id
        FROM [DWS].[dws_robot_current_snapshot] AS target_snapshot
        INNER JOIN #snapshot_stage AS source_snapshot
            ON source_snapshot.[robot_code] = target_snapshot.[robot_code];

        SET @rows_updated = @@ROWCOUNT;

        INSERT INTO [DWS].[dws_robot_current_snapshot] (
            [robot_code], [robot_id], [robot_name], [current_status], [current_mode],
            [online_status], [job_id], [subjob_id], [job_status], [map_code], [station_code],
            [target_station_code],
            [position_x], [position_y], [position_theta], [speed_mps], [battery_soc],
            [battery_voltage], [battery_current], [charging_status], [error_code],
            [error_message], [source_event_time], [status_event_time], [battery_event_time],
            [job_event_time], [source_anchor_time], [source_snapshot_time], [dws_batch_id]
        )
        SELECT
            source_snapshot.[robot_code], source_snapshot.[robot_id], source_snapshot.[robot_name],
            source_snapshot.[current_status], source_snapshot.[current_mode], source_snapshot.[online_status],
            source_snapshot.[job_id], source_snapshot.[subjob_id], source_snapshot.[job_status],
            source_snapshot.[map_code], source_snapshot.[station_code], source_snapshot.[target_station_code],
            source_snapshot.[position_x],
            source_snapshot.[position_y], source_snapshot.[position_theta], source_snapshot.[speed_mps],
            source_snapshot.[battery_soc], source_snapshot.[battery_voltage], source_snapshot.[battery_current],
            source_snapshot.[charging_status], source_snapshot.[error_code], source_snapshot.[error_message],
            source_snapshot.[source_event_time], source_snapshot.[status_event_time],
            source_snapshot.[battery_event_time], source_snapshot.[job_event_time],
            source_snapshot.[source_anchor_time], source_snapshot.[source_snapshot_time], @batch_id
        FROM #snapshot_stage AS source_snapshot
        WHERE NOT EXISTS (
            SELECT 1
            FROM [DWS].[dws_robot_current_snapshot] AS target_snapshot
            WHERE target_snapshot.[robot_code] = source_snapshot.[robot_code]
        );

        SET @rows_inserted = @@ROWCOUNT;

        INSERT INTO [DWS].[etl_load_log] (
            [batch_id], [target_schema], [target_table], [source_schema], [source_table],
            [load_mode], [affected_rows], [load_status], [error_message],
            [load_start_time], [load_end_time]
        )
        VALUES (
            @batch_id, N'DWS', N'dws_robot_current_snapshot', N'dbo', N'robot_*_history',
            N'OPERATIONAL_SNAPSHOT_V2', @rows_updated + @rows_inserted,
            N'SUCCESS', NULL, @started_at, SYSDATETIME()
        );

        UPDATE [DWS].[etl_batch]
        SET
            [batch_end_time] = SYSDATETIME(),
            [batch_status] = N'SUCCESS',
            [error_message] = NULL
        WHERE [batch_id] = @batch_id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SET @error_message = CONCAT(
            N'Error ', ERROR_NUMBER(), N', line ', ERROR_LINE(), N': ', ERROR_MESSAGE()
        );

        IF @batch_id IS NOT NULL
        BEGIN
            UPDATE [DWS].[etl_batch]
            SET
                [batch_end_time] = SYSDATETIME(),
                [batch_status] = N'FAILED',
                [error_message] = @error_message
            WHERE [batch_id] = @batch_id;
        END;

        EXEC sys.sp_releaseapplock
            @Resource = N'DWS.sp_refresh_robot_current_snapshot_fast.v2',
            @LockOwner = N'Session';

        RAISERROR(N'%s', 16, 1, @error_message);
        RETURN;
    END CATCH;

    EXEC sys.sp_releaseapplock
        @Resource = N'DWS.sp_refresh_robot_current_snapshot_fast.v2',
        @LockOwner = N'Session';

    SELECT
        @batch_id AS [batch_id],
        @started_at AS [started_at],
        SYSDATETIME() AS [finished_at],
        @status_anchor AS [source_anchor_time],
        @online_anchor_minutes AS [online_anchor_minutes],
        @rows_updated AS [rows_updated],
        @rows_inserted AS [rows_inserted];
END;
GO

/*
    Stable public entry point used by the Web and future Agent job.
    Keeping it as a small wrapper prevents the older 34 script from
    accidentally replacing the v2 operational snapshot implementation.
*/
CREATE OR ALTER PROCEDURE [DWS].[sp_refresh_robot_current_snapshot_fast]
    @online_anchor_minutes INT = 5
AS
BEGIN
    SET NOCOUNT ON;

    EXEC [DWS].[sp_refresh_robot_operational_snapshot_v2]
        @online_anchor_minutes = @online_anchor_minutes;
END;
GO

/*
    Preview after installation (read only):

    EXEC [DWS].[sp_refresh_robot_current_snapshot_fast]
        @online_anchor_minutes = 5;

    SELECT
        [robot_code], [current_status], [current_mode], [online_status],
        [job_id], [job_status], [battery_soc], [charging_status],
        [map_code], [station_code], [target_station_code], [position_x], [position_y],
        [status_event_time], [battery_event_time], [job_event_time],
        [source_anchor_time], [dws_load_time]
    FROM [DWS].[dws_robot_current_snapshot]
    ORDER BY [robot_code];
*/
