USE IOT2020;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/*
    Create the DWD incremental load procedure.

    Procedure:
      DWD.sp_load_dwd_all_incremental

    Notes:
      - Source is ODS, not dbo.
      - Watermark is managed by DWD.etl_watermark.
      - FULL_REPLACE and SNAPSHOT reload rows for one source table at a time.
      - ID_INCREMENT loads rows where source ods_row_id is greater than the saved watermark.
      - This is a conservative generic loader. It maps common column names when they exist
        and leaves non-matching DWD business fields as NULL for later refinement.
*/

/* Compatibility fix for the first DWD bootstrap script.
   DWD can preserve rows from multiple source tables, so these indexes should not be unique by robot_code only. */
IF OBJECT_ID(N'[DWD].[dim_amr_robot]', N'U') IS NOT NULL
   AND EXISTS (
        SELECT 1
        FROM sys.indexes
        WHERE object_id = OBJECT_ID(N'[DWD].[dim_amr_robot]')
          AND name = N'UX_DWD_dim_amr_robot_code'
   )
BEGIN
    DROP INDEX [UX_DWD_dim_amr_robot_code] ON [DWD].[dim_amr_robot];
END;
GO

IF OBJECT_ID(N'[DWD].[dim_amr_robot]', N'U') IS NOT NULL
   AND NOT EXISTS (
        SELECT 1
        FROM sys.indexes
        WHERE object_id = OBJECT_ID(N'[DWD].[dim_amr_robot]')
          AND name = N'IX_DWD_dim_amr_robot_code'
   )
BEGIN
    CREATE INDEX [IX_DWD_dim_amr_robot_code]
        ON [DWD].[dim_amr_robot] (robot_code, source_table)
        WHERE robot_code IS NOT NULL;
END;
GO

IF OBJECT_ID(N'[DWD].[snap_amr_current_status]', N'U') IS NOT NULL
   AND EXISTS (
        SELECT 1
        FROM sys.indexes
        WHERE object_id = OBJECT_ID(N'[DWD].[snap_amr_current_status]')
          AND name = N'UX_DWD_snap_amr_current_status_robot'
   )
BEGIN
    DROP INDEX [UX_DWD_snap_amr_current_status_robot] ON [DWD].[snap_amr_current_status];
END;
GO

IF OBJECT_ID(N'[DWD].[snap_amr_current_status]', N'U') IS NOT NULL
   AND NOT EXISTS (
        SELECT 1
        FROM sys.indexes
        WHERE object_id = OBJECT_ID(N'[DWD].[snap_amr_current_status]')
          AND name = N'IX_DWD_snap_amr_current_status_robot'
   )
BEGIN
    CREATE INDEX [IX_DWD_snap_amr_current_status_robot]
        ON [DWD].[snap_amr_current_status] (robot_code, source_table)
        WHERE robot_code IS NOT NULL;
END;
GO

IF OBJECT_ID(N'[DWD].[dim_amr_station]', N'U') IS NOT NULL
   AND EXISTS (
        SELECT 1
        FROM sys.indexes
        WHERE object_id = OBJECT_ID(N'[DWD].[dim_amr_station]')
          AND name = N'UX_DWD_dim_amr_station_code'
   )
BEGIN
    DROP INDEX [UX_DWD_dim_amr_station_code] ON [DWD].[dim_amr_station];
END;
GO

IF OBJECT_ID(N'[DWD].[dim_amr_station]', N'U') IS NOT NULL
   AND NOT EXISTS (
        SELECT 1
        FROM sys.indexes
        WHERE object_id = OBJECT_ID(N'[DWD].[dim_amr_station]')
          AND name = N'IX_DWD_dim_amr_station_code'
   )
BEGIN
    CREATE INDEX [IX_DWD_dim_amr_station_code]
        ON [DWD].[dim_amr_station] (station_code, source_table)
        WHERE station_code IS NOT NULL;
END;
GO

IF OBJECT_ID(N'[DWD].[fact_robot_status]', N'U') IS NOT NULL
   AND COL_LENGTH(N'DWD.fact_robot_status', N'speed_mps') IS NULL
BEGIN
    ALTER TABLE [DWD].[fact_robot_status]
    ADD [speed_mps] DECIMAL(18,6) NULL;
END;
GO

CREATE OR ALTER PROCEDURE [DWD].[sp_load_dwd_all_incremental]
    @include_current_snapshot BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @batch_id BIGINT,
        @lock_result INT,
        @has_error BIT = 0,
        @batch_error_message NVARCHAR(MAX) = NULL;

    EXEC @lock_result = sys.sp_getapplock
        @Resource = N'DWD.sp_load_dwd_all_incremental',
        @LockMode = N'Exclusive',
        @LockOwner = N'Session',
        @LockTimeout = 0;

    IF @lock_result < 0
    BEGIN
        THROW 52001, 'DWD load is already running. Please retry later.', 1;
    END;

    BEGIN TRY
        INSERT INTO [DWD].[etl_batch] (batch_status)
        VALUES (N'RUNNING');

        SET @batch_id = SCOPE_IDENTITY();

        DECLARE @candidate TABLE (
            target_column SYSNAME NOT NULL,
            target_type NVARCHAR(30) NOT NULL,
            candidate_name SYSNAME NOT NULL,
            priority INT NOT NULL
        );

        INSERT INTO @candidate (target_column, target_type, candidate_name, priority)
        VALUES
            (N'event_time', N'datetime', N'robot_datetime', 10),
            (N'event_time', N'datetime', N'event_time', 20),
            (N'event_time', N'datetime', N'sample_time', 30),
            (N'event_time', N'datetime', N'status_time', 40),
            (N'event_time', N'datetime', N'date_stamp', 50),
            (N'event_time', N'datetime', N'Date_Stamp', 60),
            (N'event_time', N'datetime', N'pc_timestamp', 70),
            (N'event_time', N'datetime', N'enqueued_at', 75),
            (N'event_time', N'datetime', N'created_at', 80),
            (N'event_time', N'datetime', N'create_time', 90),
            (N'event_time', N'datetime', N'updated_at', 100),
            (N'event_time', N'datetime', N'update_time', 110),
            (N'event_time', N'datetime', N'start_datetime', 120),
            (N'event_time', N'datetime', N'started_at', 130),

            (N'source_created_time', N'datetime', N'created_at', 10),
            (N'source_created_time', N'datetime', N'create_time', 20),
            (N'source_created_time', N'datetime', N'created_time', 30),
            (N'source_created_time', N'datetime', N'Date_Stamp', 40),
            (N'source_updated_time', N'datetime', N'updated_at', 10),
            (N'source_updated_time', N'datetime', N'update_time', 20),
            (N'source_updated_time', N'datetime', N'modified_at', 30),
            (N'source_updated_time', N'datetime', N'modify_time', 40),

            (N'robot_id', N'nvarchar100', N'robot_id', 10),
            (N'robot_id', N'nvarchar100', N'RobotID', 20),
            (N'robot_id', N'nvarchar100', N'amr_id', 30),
            (N'robot_id', N'nvarchar100', N'AMR_ID', 40),
            (N'robot_id', N'nvarchar100', N'agv_id', 50),
            (N'robot_id', N'nvarchar100', N'device_id', 60),
            (N'robot_code', N'nvarchar100', N'robot_code', 10),
            (N'robot_code', N'nvarchar100', N'robot_no', 20),
            (N'robot_code', N'nvarchar100', N'robot_sn', 30),
            (N'robot_code', N'nvarchar100', N'robot_id', 40),
            (N'robot_code', N'nvarchar100', N'RobotID', 50),
            (N'robot_code', N'nvarchar100', N'amr_id', 60),
            (N'robot_code', N'nvarchar100', N'AMR_ID', 70),
            (N'robot_code', N'nvarchar100', N'AMR', 80),
            (N'robot_name', N'nvarchar200', N'robot_name', 10),
            (N'robot_name', N'nvarchar200', N'amr_name', 20),
            (N'robot_name', N'nvarchar200', N'name', 30),
            (N'robot_type', N'nvarchar100', N'robot_type', 10),
            (N'robot_type', N'nvarchar100', N'amr_type', 20),
            (N'robot_type', N'nvarchar100', N'type', 30),
            (N'robot_model', N'nvarchar100', N'robot_model', 10),
            (N'robot_model', N'nvarchar100', N'model', 20),

            (N'factory_id', N'nvarchar100', N'factory_id', 10),
            (N'factory_id', N'nvarchar100', N'FactoryID', 20),
            (N'factory_code', N'nvarchar100', N'factory_code', 10),
            (N'factory_code', N'nvarchar100', N'factory_id', 20),
            (N'factory_code', N'nvarchar100', N'FactoryID', 30),
            (N'factory_code', N'nvarchar100', N'factory', 40),
            (N'factory_name', N'nvarchar200', N'factory_name', 10),
            (N'factory_name', N'nvarchar200', N'FactoryName', 20),
            (N'factory_name', N'nvarchar200', N'name', 30),
            (N'plant_id', N'nvarchar100', N'plant_id', 10),
            (N'plant_id', N'nvarchar100', N'PlantID', 20),
            (N'plant_code', N'nvarchar100', N'plant_code', 10),
            (N'plant_code', N'nvarchar100', N'plant_id', 20),
            (N'plant_code', N'nvarchar100', N'PlantID', 30),
            (N'plant_code', N'nvarchar100', N'plant', 40),
            (N'plant_name', N'nvarchar200', N'plant_name', 10),
            (N'plant_name', N'nvarchar200', N'PlantName', 20),
            (N'plant_name', N'nvarchar200', N'name', 30),
            (N'line_id', N'nvarchar100', N'line_id', 10),
            (N'line_id', N'nvarchar100', N'LineID', 20),
            (N'line_code', N'nvarchar100', N'line_code', 10),
            (N'line_code', N'nvarchar100', N'line_id', 20),
            (N'line_code', N'nvarchar100', N'LineID', 30),
            (N'line_code', N'nvarchar100', N'line', 40),
            (N'line_name', N'nvarchar200', N'line_name', 10),
            (N'line_name', N'nvarchar200', N'LineName', 20),
            (N'line_name', N'nvarchar200', N'name', 30),

            (N'station_id', N'nvarchar100', N'station_id', 10),
            (N'station_id', N'nvarchar100', N'StationID', 20),
            (N'station_code', N'nvarchar100', N'station_code', 10),
            (N'station_code', N'nvarchar100', N'station_id', 20),
            (N'station_code', N'nvarchar100', N'StationID', 30),
            (N'station_code', N'nvarchar100', N'location', 40),
            (N'station_name', N'nvarchar200', N'station_name', 10),
            (N'station_name', N'nvarchar200', N'StationName', 20),
            (N'station_name', N'nvarchar200', N'name', 30),
            (N'station_type', N'nvarchar100', N'station_type', 10),
            (N'station_type', N'nvarchar100', N'type', 20),

            (N'map_id', N'nvarchar100', N'map_id', 10),
            (N'map_code', N'nvarchar100', N'map_code', 10),
            (N'map_code', N'nvarchar100', N'map_id', 20),
            (N'map_code', N'nvarchar100', N'map', 30),
            (N'map_name', N'nvarchar200', N'map_name', 10),
            (N'map_name', N'nvarchar200', N'name', 20),
            (N'map_type', N'nvarchar100', N'map_type', 10),
            (N'map_type', N'nvarchar100', N'type', 20),
            (N'parent_map_code', N'nvarchar100', N'parent_map_code', 10),
            (N'parent_map_code', N'nvarchar100', N'parent_id', 20),
            (N'path_code', N'nvarchar100', N'path_code', 10),
            (N'path_code', N'nvarchar100', N'path_id', 20),
            (N'from_station_code', N'nvarchar100', N'from_station_code', 10),
            (N'from_station_code', N'nvarchar100', N'from_station_id', 20),
            (N'to_station_code', N'nvarchar100', N'to_station_code', 10),
            (N'to_station_code', N'nvarchar100', N'to_station_id', 20),
            (N'distance_m', N'decimal18', N'distance_m', 10),
            (N'distance_m', N'decimal18', N'distance', 20),

            (N'project_id', N'nvarchar100', N'project_id', 10),
            (N'project_id', N'nvarchar100', N'ProjectID', 20),
            (N'project_code', N'nvarchar100', N'project_code', 10),
            (N'project_code', N'nvarchar100', N'project_id', 20),
            (N'project_code', N'nvarchar100', N'ProjectID', 30),
            (N'project_name', N'nvarchar200', N'project_name', 10),
            (N'project_name', N'nvarchar200', N'ProjectName', 20),
            (N'project_name', N'nvarchar200', N'name', 30),
            (N'project_type', N'nvarchar100', N'project_type', 10),
            (N'project_type', N'nvarchar100', N'type', 20),
            (N'default_robot_code', N'nvarchar100', N'default_robot_code', 10),
            (N'default_robot_code', N'nvarchar100', N'robot_id', 20),
            (N'priority_value', N'int', N'priority', 10),
            (N'priority_value', N'int', N'priority_value', 20),

            (N'job_type_id', N'nvarchar100', N'job_type_id', 10),
            (N'job_type_code', N'nvarchar100', N'job_type_code', 10),
            (N'job_type_code', N'nvarchar100', N'job_type', 20),
            (N'job_type_code', N'nvarchar100', N'job_name', 30),
            (N'job_type_name', N'nvarchar200', N'job_type_name', 10),
            (N'subjob_type_id', N'nvarchar100', N'subjob_type_id', 10),
            (N'subjob_type_code', N'nvarchar100', N'subjob_type_code', 10),
            (N'subjob_type_code', N'nvarchar100', N'subjob_type', 20),
            (N'subjob_type_name', N'nvarchar200', N'subjob_type_name', 10),

            (N'queue_id', N'nvarchar100', N'queue_id', 10),
            (N'queue_id', N'nvarchar100', N'id', 20),
            (N'job_id', N'nvarchar100', N'job_id', 10),
            (N'job_id', N'nvarchar100', N'JobID', 20),
            (N'job_id', N'nvarchar100', N'task_id', 30),
            (N'subjob_id', N'nvarchar100', N'subjob_id', 10),
            (N'subjob_id', N'nvarchar100', N'sub_job_id', 20),
            (N'queue_status', N'nvarchar100', N'queue_status', 10),
            (N'queue_status', N'nvarchar100', N'status', 20),
            (N'subjob_status', N'nvarchar100', N'subjob_status', 10),
            (N'subjob_status', N'nvarchar100', N'status', 20),
            (N'job_status', N'nvarchar100', N'job_status', 10),
            (N'job_status', N'nvarchar100', N'status', 20),

            (N'robot_status', N'nvarchar100', N'robot_status', 10),
            (N'robot_status', N'nvarchar100', N'status', 20),
            (N'robot_status', N'nvarchar100', N'state', 30),
            (N'robot_mode', N'nvarchar100', N'robot_mode', 10),
            (N'robot_mode', N'nvarchar100', N'mode', 20),
            (N'current_status', N'nvarchar100', N'current_status', 10),
            (N'current_status', N'nvarchar100', N'robot_status', 20),
            (N'current_status', N'nvarchar100', N'status', 30),
            (N'current_mode', N'nvarchar100', N'current_mode', 10),
            (N'current_mode', N'nvarchar100', N'robot_mode', 20),
            (N'current_mode', N'nvarchar100', N'mode', 30),
            (N'online_status', N'nvarchar50', N'online_status', 10),
            (N'online_status', N'nvarchar50', N'online', 20),
            (N'online_status', N'nvarchar50', N'is_online', 30),
            (N'online_status', N'nvarchar50', N'connection_status', 40),
            (N'online_status', N'nvarchar50', N'connected', 50),

            (N'position_x', N'decimal18', N'position_x', 10),
            (N'position_x', N'decimal18', N'pos_x', 20),
            (N'position_x', N'decimal18', N'x', 30),
            (N'position_y', N'decimal18', N'position_y', 10),
            (N'position_y', N'decimal18', N'pos_y', 20),
            (N'position_y', N'decimal18', N'y', 30),
            (N'position_theta', N'decimal18', N'position_theta', 10),
            (N'position_theta', N'decimal18', N'theta', 20),
            (N'position_theta', N'decimal18', N'angle', 30),
            (N'speed_mps', N'decimal18', N'speed_mps', 10),
            (N'speed_mps', N'decimal18', N'robot_speed', 15),
            (N'speed_mps', N'decimal18', N'speed', 20),
            (N'speed_mps', N'decimal18', N'velocity', 30),

            (N'battery_soc', N'decimal9', N'battery_soc', 10),
            (N'battery_soc', N'decimal9', N'batt_level', 15),
            (N'battery_soc', N'decimal9', N'soc', 20),
            (N'battery_soc', N'decimal9', N'battery', 30),
            (N'battery_soc', N'decimal9', N'battery_level', 40),
            (N'battery_voltage', N'decimal18', N'battery_voltage', 10),
            (N'battery_voltage', N'decimal18', N'batt_volt', 15),
            (N'battery_voltage', N'decimal18', N'voltage', 20),
            (N'battery_current', N'decimal18', N'battery_current', 10),
            (N'battery_current', N'decimal18', N'batt_current', 15),
            (N'battery_current', N'decimal18', N'current', 20),
            (N'battery_power', N'decimal18', N'battery_power', 10),
            (N'battery_power', N'decimal18', N'power', 20),
            (N'charging_status', N'nvarchar100', N'charging_status', 10),
            (N'charging_status', N'nvarchar100', N'batt_charge_status', 15),
            (N'charging_status', N'nvarchar100', N'charge_status', 20),
            (N'battery_status', N'nvarchar100', N'battery_status', 10),

            (N'ssid', N'nvarchar200', N'ssid', 10),
            (N'bssid', N'nvarchar200', N'bssid', 10),
            (N'rssi', N'decimal18', N'rssi', 10),
            (N'rssi', N'decimal18', N'wifi_signal_level', 20),
            (N'signal_quality', N'decimal18', N'signal_quality', 10),
            (N'signal_quality', N'decimal18', N'wifi_quality', 20),
            (N'network_status', N'nvarchar100', N'network_status', 10),
            (N'network_status', N'nvarchar100', N'wifi_status', 20),

            (N'queue_start_time', N'datetime', N'queue_start_time', 10),
            (N'queue_start_time', N'datetime', N'enqueued_at', 15),
            (N'queue_start_time', N'datetime', N'queued_at', 18),
            (N'queue_start_time', N'datetime', N'start_time', 20),
            (N'queue_start_time', N'datetime', N'created_at', 30),
            (N'queue_end_time', N'datetime', N'queue_end_time', 10),
            (N'queue_end_time', N'datetime', N'end_time', 20),
            (N'queue_end_time', N'datetime', N'dequeued_at', 30),
            (N'queue_end_time', N'datetime', N'completed_at', 40),
            (N'queue_end_time', N'datetime', N'finished_at', 50),
            (N'subjob_start_time', N'datetime', N'subjob_start_time', 10),
            (N'subjob_start_time', N'datetime', N'start_time', 20),
            (N'subjob_start_time', N'datetime', N'start_datetime', 30),
            (N'subjob_start_time', N'datetime', N'started_at', 40),
            (N'subjob_start_time', N'datetime', N'created_at', 50),
            (N'subjob_start_time', N'datetime', N'robot_datetime', 60),
            (N'subjob_start_time', N'datetime', N'pc_timestamp', 70),
            (N'subjob_end_time', N'datetime', N'subjob_end_time', 10),
            (N'subjob_end_time', N'datetime', N'end_time', 20),
            (N'subjob_end_time', N'datetime', N'end_datetime', 30),
            (N'subjob_end_time', N'datetime', N'finished_at', 40),
            (N'subjob_end_time', N'datetime', N'completed_at', 50),
            (N'subjob_end_time', N'datetime', N'updated_at', 60),
            (N'job_start_time', N'datetime', N'job_start_time', 10),
            (N'job_start_time', N'datetime', N'start_time', 20),
            (N'job_start_time', N'datetime', N'start_datetime', 30),
            (N'job_start_time', N'datetime', N'started_at', 40),
            (N'job_start_time', N'datetime', N'created_at', 50),
            (N'job_start_time', N'datetime', N'robot_datetime', 60),
            (N'job_start_time', N'datetime', N'pc_timestamp', 70),
            (N'job_end_time', N'datetime', N'job_end_time', 10),
            (N'job_end_time', N'datetime', N'end_time', 20),
            (N'job_end_time', N'datetime', N'end_datetime', 30),
            (N'job_end_time', N'datetime', N'finished_at', 40),
            (N'job_end_time', N'datetime', N'completed_at', 50),
            (N'job_end_time', N'datetime', N'updated_at', 60),
            (N'status_time', N'datetime', N'status_time', 10),
            (N'status_time', N'datetime', N'robot_datetime', 20),
            (N'status_time', N'datetime', N'sample_time', 30),
            (N'status_time', N'datetime', N'pc_timestamp', 40),
            (N'sample_time', N'datetime', N'sample_time', 10),
            (N'sample_time', N'datetime', N'robot_datetime', 20),
            (N'sample_time', N'datetime', N'created_at', 30),
            (N'sample_time', N'datetime', N'pc_timestamp', 40),

            (N'result_code', N'nvarchar100', N'result_code', 10),
            (N'result_code', N'nvarchar100', N'error_code', 20),
            (N'result_message', N'nvarchar1000', N'result_message', 10),
            (N'result_message', N'nvarchar1000', N'error_message', 20),
            (N'error_code', N'nvarchar100', N'error_code', 10),
            (N'error_code', N'nvarchar100', N'err_code', 20),
            (N'error_message', N'nvarchar1000', N'error_message', 10),
            (N'error_message', N'nvarchar1000', N'err_msg', 20),
            (N'is_enabled', N'bit', N'is_enabled', 10),
            (N'is_enabled', N'bit', N'enabled', 20),
            (N'is_enabled', N'bit', N'is_active', 30);

        DECLARE
            @watermark_id BIGINT,
            @source_schema SYSNAME,
            @source_table SYSNAME,
            @target_schema SYSNAME,
            @target_table SYSNAME,
            @load_mode NVARCHAR(30),
            @watermark_column SYSNAME,
            @last_bigint_value BIGINT,
            @last_datetime_value DATETIME2(3),
            @source_object_id INT,
            @target_object_id INT,
            @source_full NVARCHAR(300),
            @target_full NVARCHAR(300),
            @insert_columns NVARCHAR(MAX),
            @select_columns NVARCHAR(MAX),
            @where_sql NVARCHAR(MAX),
            @delete_sql NVARCHAR(MAX),
            @insert_sql NVARCHAR(MAX),
            @max_sql NVARCHAR(MAX),
            @rows_inserted BIGINT,
            @rows_deleted BIGINT,
            @max_bigint BIGINT,
            @max_datetime DATETIME2(3),
            @load_start_time DATETIME2(3),
            @error_message NVARCHAR(MAX);

        DECLARE @expr TABLE (
            target_column SYSNAME NOT NULL PRIMARY KEY,
            expr NVARCHAR(MAX) NOT NULL
        );

        DECLARE wm_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT
            watermark_id,
            source_schema,
            source_table,
            target_schema,
            target_table,
            load_mode,
            watermark_column,
            last_bigint_value,
            last_datetime_value
        FROM [DWD].[etl_watermark]
        WHERE is_enabled = 1
          AND (
                @include_current_snapshot = 1
                OR target_table <> N'snap_amr_current_status'
              )
        ORDER BY
            target_table,
            source_table;

        OPEN wm_cursor;

        FETCH NEXT FROM wm_cursor
        INTO
            @watermark_id,
            @source_schema,
            @source_table,
            @target_schema,
            @target_table,
            @load_mode,
            @watermark_column,
            @last_bigint_value,
            @last_datetime_value;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @load_start_time = SYSDATETIME();
            SET @rows_inserted = 0;
            SET @rows_deleted = 0;
            SET @max_bigint = NULL;
            SET @max_datetime = NULL;
            SET @error_message = NULL;
            SET @source_full = QUOTENAME(@source_schema) + N'.' + QUOTENAME(@source_table);
            SET @target_full = QUOTENAME(@target_schema) + N'.' + QUOTENAME(@target_table);
            SET @source_object_id = OBJECT_ID(@source_full, N'U');
            SET @target_object_id = OBJECT_ID(@target_full, N'U');

            BEGIN TRY
                IF @source_object_id IS NULL
                BEGIN
                    INSERT INTO [DWD].[etl_load_log] (
                        batch_id, source_schema, source_table, target_schema, target_table,
                        load_mode, load_start_time, load_end_time, rows_inserted, rows_updated,
                        rows_deleted, load_status, error_message
                    )
                    VALUES (
                        @batch_id, @source_schema, @source_table, @target_schema, @target_table,
                        @load_mode, @load_start_time, SYSDATETIME(), 0, 0,
                        0, N'SKIPPED', N'Source table does not exist.'
                    );

                    FETCH NEXT FROM wm_cursor
                    INTO
                        @watermark_id,
                        @source_schema,
                        @source_table,
                        @target_schema,
                        @target_table,
                        @load_mode,
                        @watermark_column,
                        @last_bigint_value,
                        @last_datetime_value;

                    CONTINUE;
                END;

                IF @target_object_id IS NULL
                BEGIN
                    INSERT INTO [DWD].[etl_load_log] (
                        batch_id, source_schema, source_table, target_schema, target_table,
                        load_mode, load_start_time, load_end_time, rows_inserted, rows_updated,
                        rows_deleted, load_status, error_message
                    )
                    VALUES (
                        @batch_id, @source_schema, @source_table, @target_schema, @target_table,
                        @load_mode, @load_start_time, SYSDATETIME(), 0, 0,
                        0, N'SKIPPED', N'Target table does not exist.'
                    );

                    FETCH NEXT FROM wm_cursor
                    INTO
                        @watermark_id,
                        @source_schema,
                        @source_table,
                        @target_schema,
                        @target_table,
                        @load_mode,
                        @watermark_column,
                        @last_bigint_value,
                        @last_datetime_value;

                    CONTINUE;
                END;

                IF NOT EXISTS (
                    SELECT 1
                    FROM sys.columns
                    WHERE object_id = @source_object_id
                      AND name = N'ods_row_id'
                )
                BEGIN
                    THROW 52002, 'Source ODS table does not contain ods_row_id.', 1;
                END;

                DELETE e
                FROM @expr AS e
                WHERE e.target_column <> N'';

                INSERT INTO @expr (target_column, expr)
                SELECT
                    target_column,
                    expr
                FROM (
                    SELECT
                        c.target_column,
                        expr =
                            CASE c.target_type
                                WHEN N'datetime' THEN
                                    N'TRY_CONVERT(DATETIME2(3), src.' + QUOTENAME(sc.name) + N')'
                                WHEN N'bigint' THEN
                                    N'TRY_CONVERT(BIGINT, src.' + QUOTENAME(sc.name) + N')'
                                WHEN N'int' THEN
                                    N'TRY_CONVERT(INT, src.' + QUOTENAME(sc.name) + N')'
                                WHEN N'decimal18' THEN
                                    N'TRY_CONVERT(DECIMAL(18,6), src.' + QUOTENAME(sc.name) + N')'
                                WHEN N'decimal9' THEN
                                    N'TRY_CONVERT(DECIMAL(9,4), src.' + QUOTENAME(sc.name) + N')'
                                WHEN N'bit' THEN
                                    N'TRY_CONVERT(BIT, src.' + QUOTENAME(sc.name) + N')'
                                WHEN N'nvarchar50' THEN
                                    N'NULLIF(LTRIM(RTRIM(TRY_CONVERT(NVARCHAR(50), src.' + QUOTENAME(sc.name) + N'))), N'''')'
                                WHEN N'nvarchar200' THEN
                                    N'NULLIF(LTRIM(RTRIM(TRY_CONVERT(NVARCHAR(200), src.' + QUOTENAME(sc.name) + N'))), N'''')'
                                WHEN N'nvarchar1000' THEN
                                    N'NULLIF(LTRIM(RTRIM(TRY_CONVERT(NVARCHAR(1000), src.' + QUOTENAME(sc.name) + N'))), N'''')'
                                ELSE
                                    N'NULLIF(LTRIM(RTRIM(TRY_CONVERT(NVARCHAR(100), src.' + QUOTENAME(sc.name) + N'))), N'''')'
                            END,
                        rn = ROW_NUMBER() OVER (
                            PARTITION BY c.target_column
                            ORDER BY c.priority
                        )
                    FROM @candidate AS c
                    JOIN sys.columns AS sc
                        ON sc.object_id = @source_object_id
                       AND LOWER(sc.name) = LOWER(c.candidate_name)
                ) AS ranked
                WHERE rn = 1;

                DECLARE
                    @event_time NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'event_time'), N'NULL'),
                    @source_created_time NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'source_created_time'), N'NULL'),
                    @source_updated_time NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'source_updated_time'), N'NULL'),
                    @robot_id NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'robot_id'), N'NULL'),
                    @robot_code NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'robot_code'), N'NULL'),
                    @robot_name NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'robot_name'), N'NULL'),
                    @robot_type NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'robot_type'), N'NULL'),
                    @robot_model NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'robot_model'), N'NULL'),
                    @factory_id NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'factory_id'), N'NULL'),
                    @factory_code NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'factory_code'), N'NULL'),
                    @factory_name NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'factory_name'), N'NULL'),
                    @plant_id NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'plant_id'), N'NULL'),
                    @plant_code NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'plant_code'), N'NULL'),
                    @plant_name NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'plant_name'), N'NULL'),
                    @line_id NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'line_id'), N'NULL'),
                    @line_code NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'line_code'), N'NULL'),
                    @line_name NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'line_name'), N'NULL'),
                    @station_id NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'station_id'), N'NULL'),
                    @station_code NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'station_code'), N'NULL'),
                    @station_name NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'station_name'), N'NULL'),
                    @station_type NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'station_type'), N'NULL'),
                    @map_id NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'map_id'), N'NULL'),
                    @map_code NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'map_code'), N'NULL'),
                    @map_name NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'map_name'), N'NULL'),
                    @map_type NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'map_type'), N'NULL'),
                    @parent_map_code NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'parent_map_code'), N'NULL'),
                    @path_code NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'path_code'), N'NULL'),
                    @from_station_code NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'from_station_code'), N'NULL'),
                    @to_station_code NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'to_station_code'), N'NULL'),
                    @distance_m NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'distance_m'), N'NULL'),
                    @project_id NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'project_id'), N'NULL'),
                    @project_code NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'project_code'), N'NULL'),
                    @project_name NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'project_name'), N'NULL'),
                    @project_type NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'project_type'), N'NULL'),
                    @default_robot_code NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'default_robot_code'), N'NULL'),
                    @priority_value NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'priority_value'), N'NULL'),
                    @job_type_id NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'job_type_id'), N'NULL'),
                    @job_type_code NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'job_type_code'), N'NULL'),
                    @job_type_name NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'job_type_name'), N'NULL'),
                    @subjob_type_id NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'subjob_type_id'), N'NULL'),
                    @subjob_type_code NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'subjob_type_code'), N'NULL'),
                    @subjob_type_name NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'subjob_type_name'), N'NULL'),
                    @queue_id NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'queue_id'), N'NULL'),
                    @job_id NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'job_id'), N'NULL'),
                    @subjob_id NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'subjob_id'), N'NULL'),
                    @queue_status NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'queue_status'), N'NULL'),
                    @subjob_status NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'subjob_status'), N'NULL'),
                    @job_status NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'job_status'), N'NULL'),
                    @robot_status NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'robot_status'), N'NULL'),
                    @robot_mode NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'robot_mode'), N'NULL'),
                    @current_status NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'current_status'), N'NULL'),
                    @current_mode NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'current_mode'), N'NULL'),
                    @online_status NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'online_status'), N'NULL'),
                    @position_x NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'position_x'), N'NULL'),
                    @position_y NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'position_y'), N'NULL'),
                    @position_theta NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'position_theta'), N'NULL'),
                    @speed_mps NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'speed_mps'), N'NULL'),
                    @battery_soc NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'battery_soc'), N'NULL'),
                    @battery_voltage NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'battery_voltage'), N'NULL'),
                    @battery_current NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'battery_current'), N'NULL'),
                    @battery_power NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'battery_power'), N'NULL'),
                    @charging_status NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'charging_status'), N'NULL'),
                    @battery_status NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'battery_status'), N'NULL'),
                    @ssid NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'ssid'), N'NULL'),
                    @bssid NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'bssid'), N'NULL'),
                    @rssi NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'rssi'), N'NULL'),
                    @signal_quality NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'signal_quality'), N'NULL'),
                    @network_status NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'network_status'), N'NULL'),
                    @queue_start_time NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'queue_start_time'), N'NULL'),
                    @queue_end_time NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'queue_end_time'), N'NULL'),
                    @subjob_start_time NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'subjob_start_time'), N'NULL'),
                    @subjob_end_time NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'subjob_end_time'), N'NULL'),
                    @job_start_time NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'job_start_time'), N'NULL'),
                    @job_end_time NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'job_end_time'), N'NULL'),
                    @status_time NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'status_time'), N'NULL'),
                    @sample_time NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'sample_time'), N'NULL'),
                    @result_code NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'result_code'), N'NULL'),
                    @result_message NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'result_message'), N'NULL'),
                    @error_code NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'error_code'), N'NULL'),
                    @error_message_expr NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'error_message'), N'NULL'),
                    @is_enabled NVARCHAR(MAX) = COALESCE((SELECT expr FROM @expr WHERE target_column = N'is_enabled'), N'NULL');

                IF @battery_power = N'NULL'
                   AND @battery_voltage <> N'NULL'
                   AND @battery_current <> N'NULL'
                BEGIN
                    SET @battery_power = N'TRY_CONVERT(DECIMAL(18,6), (' + @battery_voltage + N') * (' + @battery_current + N'))';
                END;

                DECLARE
                    @queue_duration NVARCHAR(MAX) = CASE
                        WHEN @queue_start_time <> N'NULL' AND @queue_end_time <> N'NULL'
                            THEN N'DATEDIFF(SECOND, ' + @queue_start_time + N', ' + @queue_end_time + N')'
                        ELSE N'NULL'
                    END,
                    @subjob_duration NVARCHAR(MAX) = CASE
                        WHEN @subjob_start_time <> N'NULL' AND @subjob_end_time <> N'NULL'
                            THEN N'DATEDIFF(SECOND, ' + @subjob_start_time + N', ' + @subjob_end_time + N')'
                        ELSE N'NULL'
                    END,
                    @job_duration NVARCHAR(MAX) = CASE
                        WHEN @job_start_time <> N'NULL' AND @job_end_time <> N'NULL'
                            THEN N'DATEDIFF(SECOND, ' + @job_start_time + N', ' + @job_end_time + N')'
                        ELSE N'NULL'
                    END;

                SET @insert_columns = NULL;
                SET @select_columns = NULL;

                IF @target_table = N'dim_amr_robot'
                BEGIN
                    SET @insert_columns = N'
                        robot_id, robot_code, robot_name, robot_type, robot_model,
                        factory_code, plant_code, line_code, project_code, is_enabled,
                        source_created_time, source_updated_time, source_schema, source_table,
                        source_ods_row_id, dwd_batch_id, dwd_hash_value';

                    SET @select_columns =
                        @robot_id + N', ' + @robot_code + N', ' + @robot_name + N', ' + @robot_type + N', ' + @robot_model + N', ' +
                        @factory_code + N', ' + @plant_code + N', ' + @line_code + N', ' + @project_code + N', ' + @is_enabled + N', ' +
                        @source_created_time + N', ' + @source_updated_time + N', @p_source_schema, @p_source_table, ' +
                        N'TRY_CONVERT(BIGINT, src.[ods_row_id]), @p_batch_id, ' +
                        N'HASHBYTES(''SHA2_256'', CONCAT(@p_source_schema, N''|'', @p_source_table, N''|'', TRY_CONVERT(NVARCHAR(50), src.[ods_row_id])))';
                END;
                ELSE IF @target_table = N'dim_amr_factory_line'
                BEGIN
                    SET @insert_columns = N'
                        factory_id, factory_code, factory_name, plant_id, plant_code, plant_name,
                        line_id, line_code, line_name, is_enabled, source_created_time,
                        source_updated_time, source_schema, source_table, source_ods_row_id,
                        dwd_batch_id, dwd_hash_value';

                    SET @select_columns =
                        @factory_id + N', ' + @factory_code + N', ' + @factory_name + N', ' +
                        @plant_id + N', ' + @plant_code + N', ' + @plant_name + N', ' +
                        @line_id + N', ' + @line_code + N', ' + @line_name + N', ' + @is_enabled + N', ' +
                        @source_created_time + N', ' + @source_updated_time + N', @p_source_schema, @p_source_table, ' +
                        N'TRY_CONVERT(BIGINT, src.[ods_row_id]), @p_batch_id, ' +
                        N'HASHBYTES(''SHA2_256'', CONCAT(@p_source_schema, N''|'', @p_source_table, N''|'', TRY_CONVERT(NVARCHAR(50), src.[ods_row_id])))';
                END;
                ELSE IF @target_table = N'dim_amr_station'
                BEGIN
                    SET @insert_columns = N'
                        station_id, station_code, station_name, station_type, factory_code,
                        plant_code, line_code, map_code, position_x, position_y, position_theta,
                        is_enabled, source_created_time, source_updated_time, source_schema,
                        source_table, source_ods_row_id, dwd_batch_id, dwd_hash_value';

                    SET @select_columns =
                        @station_id + N', ' + @station_code + N', ' + @station_name + N', ' + @station_type + N', ' +
                        @factory_code + N', ' + @plant_code + N', ' + @line_code + N', ' + @map_code + N', ' +
                        @position_x + N', ' + @position_y + N', ' + @position_theta + N', ' + @is_enabled + N', ' +
                        @source_created_time + N', ' + @source_updated_time + N', @p_source_schema, @p_source_table, ' +
                        N'TRY_CONVERT(BIGINT, src.[ods_row_id]), @p_batch_id, ' +
                        N'HASHBYTES(''SHA2_256'', CONCAT(@p_source_schema, N''|'', @p_source_table, N''|'', TRY_CONVERT(NVARCHAR(50), src.[ods_row_id])))';
                END;
                ELSE IF @target_table = N'dim_amr_map'
                BEGIN
                    SET @insert_columns = N'
                        map_id, map_code, map_name, map_type, parent_map_code, factory_code,
                        plant_code, line_code, path_code, from_station_code, to_station_code,
                        distance_m, is_enabled, source_created_time, source_updated_time,
                        source_schema, source_table, source_ods_row_id, dwd_batch_id, dwd_hash_value';

                    SET @select_columns =
                        @map_id + N', ' + @map_code + N', ' + @map_name + N', ' + @map_type + N', ' + @parent_map_code + N', ' +
                        @factory_code + N', ' + @plant_code + N', ' + @line_code + N', ' + @path_code + N', ' +
                        @from_station_code + N', ' + @to_station_code + N', ' + @distance_m + N', ' + @is_enabled + N', ' +
                        @source_created_time + N', ' + @source_updated_time + N', @p_source_schema, @p_source_table, ' +
                        N'TRY_CONVERT(BIGINT, src.[ods_row_id]), @p_batch_id, ' +
                        N'HASHBYTES(''SHA2_256'', CONCAT(@p_source_schema, N''|'', @p_source_table, N''|'', TRY_CONVERT(NVARCHAR(50), src.[ods_row_id])))';
                END;
                ELSE IF @target_table = N'dim_amr_project'
                BEGIN
                    SET @insert_columns = N'
                        project_id, project_code, project_name, project_type, default_robot_code,
                        start_station_code, end_station_code, priority_value, is_enabled,
                        source_created_time, source_updated_time, source_schema, source_table,
                        source_ods_row_id, dwd_batch_id, dwd_hash_value';

                    SET @select_columns =
                        @project_id + N', ' + @project_code + N', ' + @project_name + N', ' + @project_type + N', ' +
                        @default_robot_code + N', ' + @from_station_code + N', ' + @to_station_code + N', ' +
                        @priority_value + N', ' + @is_enabled + N', ' + @source_created_time + N', ' + @source_updated_time +
                        N', @p_source_schema, @p_source_table, TRY_CONVERT(BIGINT, src.[ods_row_id]), @p_batch_id, ' +
                        N'HASHBYTES(''SHA2_256'', CONCAT(@p_source_schema, N''|'', @p_source_table, N''|'', TRY_CONVERT(NVARCHAR(50), src.[ods_row_id])))';
                END;
                ELSE IF @target_table = N'dim_amr_job_type'
                BEGIN
                    SET @insert_columns = N'
                        job_type_id, job_type_code, job_type_name, subjob_type_id, subjob_type_code,
                        subjob_type_name, is_enabled, source_created_time, source_updated_time,
                        source_schema, source_table, source_ods_row_id, dwd_batch_id, dwd_hash_value';

                    SET @select_columns =
                        @job_type_id + N', ' + @job_type_code + N', ' + @job_type_name + N', ' +
                        @subjob_type_id + N', ' + @subjob_type_code + N', ' + @subjob_type_name + N', ' +
                        @is_enabled + N', ' + @source_created_time + N', ' + @source_updated_time +
                        N', @p_source_schema, @p_source_table, TRY_CONVERT(BIGINT, src.[ods_row_id]), @p_batch_id, ' +
                        N'HASHBYTES(''SHA2_256'', CONCAT(@p_source_schema, N''|'', @p_source_table, N''|'', TRY_CONVERT(NVARCHAR(50), src.[ods_row_id])))';
                END;
                ELSE IF @target_table = N'fact_amr_raw_status'
                BEGIN
                    SET @insert_columns = N'
                        event_time, robot_id, robot_code, robot_name, robot_status, robot_mode,
                        job_id, subjob_id, map_code, station_code, position_x, position_y,
                        position_theta, speed_mps, battery_soc, battery_voltage, battery_current,
                        battery_power, online_status, error_code, error_message, source_schema,
                        source_table, source_ods_row_id, source_ods_load_time, dwd_batch_id, dwd_hash_value';

                    SET @select_columns =
                        @event_time + N', ' + @robot_id + N', ' + @robot_code + N', ' + @robot_name + N', ' +
                        @robot_status + N', ' + @robot_mode + N', ' + @job_id + N', ' + @subjob_id + N', ' +
                        @map_code + N', ' + @station_code + N', ' + @position_x + N', ' + @position_y + N', ' +
                        @position_theta + N', ' + @speed_mps + N', ' + @battery_soc + N', ' + @battery_voltage + N', ' +
                        @battery_current + N', ' + @battery_power + N', ' + @online_status + N', ' + @error_code + N', ' +
                        @error_message_expr + N', @p_source_schema, @p_source_table, TRY_CONVERT(BIGINT, src.[ods_row_id]), ' +
                        N'TRY_CONVERT(DATETIME2(3), src.[ods_load_time]), @p_batch_id, ' +
                        N'HASHBYTES(''SHA2_256'', CONCAT(@p_source_schema, N''|'', @p_source_table, N''|'', TRY_CONVERT(NVARCHAR(50), src.[ods_row_id])))';
                END;
                ELSE IF @target_table = N'fact_amr_queue'
                BEGIN
                    /* AMR_Queue stores an offset-aware UTC instant. DWD's task
                       contract is Thailand local wall clock, not a stripped UTC
                       clock; preserve the instant before removing the offset. */
                    IF @p_source_schema = N'ODS'
                       AND @p_source_table = N'AMR_Queue'
                    BEGIN
                        SET @event_time = N'TRY_CONVERT(DATETIME2(3), SWITCHOFFSET(TRY_CONVERT(DATETIMEOFFSET(7), src.[enqueued_at]), N''+07:00''))';
                        SET @queue_start_time = N'TRY_CONVERT(DATETIME2(3), SWITCHOFFSET(TRY_CONVERT(DATETIMEOFFSET(7), src.[enqueued_at]), N''+07:00''))';
                    END;

                    SET @insert_columns = N'
                        queue_id, event_time, robot_id, robot_code, project_id, project_code,
                        job_id, subjob_id, queue_status, priority_value, start_station_code,
                        end_station_code, queue_start_time, queue_end_time, duration_seconds,
                        source_schema, source_table, source_ods_row_id, source_ods_load_time,
                        dwd_batch_id, dwd_hash_value';

                    SET @select_columns =
                        @queue_id + N', ' + @event_time + N', ' + @robot_id + N', ' + @robot_code + N', ' +
                        @project_id + N', ' + @project_code + N', ' + @job_id + N', ' + @subjob_id + N', ' +
                        @queue_status + N', ' + @priority_value + N', ' + @from_station_code + N', ' + @to_station_code + N', ' +
                        @queue_start_time + N', ' + @queue_end_time + N', ' + @queue_duration +
                        N', @p_source_schema, @p_source_table, TRY_CONVERT(BIGINT, src.[ods_row_id]), ' +
                        N'TRY_CONVERT(DATETIME2(3), src.[ods_load_time]), @p_batch_id, ' +
                        N'HASHBYTES(''SHA2_256'', CONCAT(@p_source_schema, N''|'', @p_source_table, N''|'', TRY_CONVERT(NVARCHAR(50), src.[ods_row_id])))';
                END;
                ELSE IF @target_table = N'fact_amr_subjob'
                BEGIN
                    SET @insert_columns = N'
                        subjob_id, job_id, robot_id, robot_code, project_id, project_code,
                        job_type_code, subjob_type_code, subjob_status, start_station_code,
                        end_station_code, subjob_start_time, subjob_end_time, duration_seconds,
                        result_code, result_message, source_schema, source_table, source_ods_row_id,
                        source_ods_load_time, dwd_batch_id, dwd_hash_value';

                    SET @select_columns =
                        @subjob_id + N', ' + @job_id + N', ' + @robot_id + N', ' + @robot_code + N', ' +
                        @project_id + N', ' + @project_code + N', ' + @job_type_code + N', ' + @subjob_type_code + N', ' +
                        @subjob_status + N', ' + @from_station_code + N', ' + @to_station_code + N', ' +
                        @subjob_start_time + N', ' + @subjob_end_time + N', ' + @subjob_duration + N', ' +
                        @result_code + N', ' + @result_message +
                        N', @p_source_schema, @p_source_table, TRY_CONVERT(BIGINT, src.[ods_row_id]), ' +
                        N'TRY_CONVERT(DATETIME2(3), src.[ods_load_time]), @p_batch_id, ' +
                        N'HASHBYTES(''SHA2_256'', CONCAT(@p_source_schema, N''|'', @p_source_table, N''|'', TRY_CONVERT(NVARCHAR(50), src.[ods_row_id])))';
                END;
                ELSE IF @target_table = N'fact_robot_battery'
                BEGIN
                    SET @insert_columns = N'
                        sample_time, robot_id, robot_code, battery_soc, battery_voltage,
                        battery_current, battery_power, charging_status, battery_status,
                        source_schema, source_table, source_ods_row_id, source_ods_load_time,
                        dwd_batch_id, dwd_hash_value';

                    SET @select_columns =
                        @sample_time + N', ' + @robot_id + N', ' + @robot_code + N', ' +
                        @battery_soc + N', ' + @battery_voltage + N', ' + @battery_current + N', ' +
                        @battery_power + N', ' + @charging_status + N', ' + @battery_status +
                        N', @p_source_schema, @p_source_table, TRY_CONVERT(BIGINT, src.[ods_row_id]), ' +
                        N'TRY_CONVERT(DATETIME2(3), src.[ods_load_time]), @p_batch_id, ' +
                        N'HASHBYTES(''SHA2_256'', CONCAT(@p_source_schema, N''|'', @p_source_table, N''|'', TRY_CONVERT(NVARCHAR(50), src.[ods_row_id])))';
                END;
                ELSE IF @target_table = N'fact_robot_job'
                BEGIN
                    SET @insert_columns = N'
                        job_id, robot_id, robot_code, job_type_code, job_status, job_start_time,
                        source_schema, source_table, source_ods_row_id, source_ods_load_time,
                        dwd_batch_id, dwd_hash_value';

                    SET @select_columns =
                        @job_id + N', ' + @robot_id + N', ' + @robot_code + N', ' + @job_type_code + N', ' +
                        @job_status + N', ' + @job_start_time +
                        N', @p_source_schema, @p_source_table, TRY_CONVERT(BIGINT, src.[ods_row_id]), ' +
                        N'TRY_CONVERT(DATETIME2(3), src.[ods_load_time]), @p_batch_id, ' +
                        N'HASHBYTES(''SHA2_256'', CONCAT(@p_source_schema, N''|'', @p_source_table, N''|'', TRY_CONVERT(NVARCHAR(50), src.[ods_row_id])))';
                END;
                ELSE IF @target_table = N'fact_robot_status'
                BEGIN
                    SET @insert_columns = N'
                        status_time, robot_id, robot_code, robot_status, robot_mode, online_status,
                        speed_mps, error_code, error_message, source_schema, source_table, source_ods_row_id,
                        source_ods_load_time, dwd_batch_id, dwd_hash_value';

                    SET @select_columns =
                        @status_time + N', ' + @robot_id + N', ' + @robot_code + N', ' +
                        @robot_status + N', ' + @robot_mode + N', ' + @online_status + N', ' +
                        @speed_mps + N', ' + @error_code + N', ' + @error_message_expr +
                        N', @p_source_schema, @p_source_table, TRY_CONVERT(BIGINT, src.[ods_row_id]), ' +
                        N'TRY_CONVERT(DATETIME2(3), src.[ods_load_time]), @p_batch_id, ' +
                        N'HASHBYTES(''SHA2_256'', CONCAT(@p_source_schema, N''|'', @p_source_table, N''|'', TRY_CONVERT(NVARCHAR(50), src.[ods_row_id])))';
                END;
                ELSE IF @target_table = N'fact_robot_wifi'
                BEGIN
                    SET @insert_columns = N'
                        sample_time, robot_id, robot_code, ssid, bssid, rssi, signal_quality,
                        network_status, source_schema, source_table, source_ods_row_id,
                        source_ods_load_time, dwd_batch_id, dwd_hash_value';

                    SET @select_columns =
                        @sample_time + N', ' + @robot_id + N', ' + @robot_code + N', ' +
                        @ssid + N', ' + @bssid + N', ' + @rssi + N', ' + @signal_quality + N', ' +
                        @network_status +
                        N', @p_source_schema, @p_source_table, TRY_CONVERT(BIGINT, src.[ods_row_id]), ' +
                        N'TRY_CONVERT(DATETIME2(3), src.[ods_load_time]), @p_batch_id, ' +
                        N'HASHBYTES(''SHA2_256'', CONCAT(@p_source_schema, N''|'', @p_source_table, N''|'', TRY_CONVERT(NVARCHAR(50), src.[ods_row_id])))';
                END;
                ELSE IF @target_table = N'snap_amr_current_status'
                BEGIN
                    SET @insert_columns = N'
                        robot_id, robot_code, robot_name, current_status, current_mode, online_status,
                        job_id, subjob_id, map_code, station_code, position_x, position_y,
                        position_theta, speed_mps, battery_soc, error_code, error_message,
                        source_event_time, source_schema, source_table, source_ods_row_id,
                        dwd_batch_id, dwd_hash_value';

                    IF @source_table = N'AMR_Currentdata'
                    BEGIN
                        SET @select_columns = N'
                            COALESCE(
                                NULLIF(
                                    NULLIF(LTRIM(RTRIM(TRY_CONVERT(NVARCHAR(100), src.[Robot_Serial]))), N''''),
                                    N''undefined''
                                ),
                                TRY_CONVERT(NVARCHAR(100), src.[Robot_number])
                            ),
                            TRY_CONVERT(NVARCHAR(100), src.[Robot_number]),
                            TRY_CONVERT(NVARCHAR(200), src.[Robot_number]),
                            TRY_CONVERT(NVARCHAR(100), src.[Robot_MoveState]),
                            COALESCE(
                                (
                                    SELECT TOP (1)
                                        TRY_CONVERT(NVARCHAR(100), mode_ref.[Mode_Detail])
                                    FROM [ODS].[AMR_Robot_Mode] AS mode_ref
                                    WHERE mode_ref.[Mode_ID] = src.[Robot_Mode]
                                    ORDER BY
                                        mode_ref.[ods_row_id] DESC
                                ),
                                TRY_CONVERT(NVARCHAR(100), src.[Robot_Mode])
                            ),
                            TRY_CONVERT(NVARCHAR(50), src.[Robot_Device_State]),
                            TRY_CONVERT(NVARCHAR(100), src.[Job_Name]),
                            NULL,
                            TRY_CONVERT(NVARCHAR(100), src.[Robot_Current_Map]),
                            TRY_CONVERT(NVARCHAR(100), src.[POI_Current]),
                            TRY_CONVERT(DECIMAL(18,6), src.[Robot_Position_X]),
                            TRY_CONVERT(DECIMAL(18,6), src.[Robot_Position_Y]),
                            TRY_CONVERT(DECIMAL(18,6), src.[Robot_Orientation_Z]),
                            TRY_CONVERT(DECIMAL(18,6), src.[Robot_Speed]),
                            TRY_CONVERT(DECIMAL(9,4), src.[Batt_Level]),
                            TRY_CONVERT(NVARCHAR(100), src.[Robot_Emer_Status]),
                            NULL,
                            TRY_CONVERT(DATETIME2(3), src.[Datetime]),
                            @p_source_schema,
                            @p_source_table,
                            TRY_CONVERT(BIGINT, src.[ods_row_id]),
                            @p_batch_id,
                            HASHBYTES(''SHA2_256'', CONCAT(@p_source_schema, N''|'', @p_source_table, N''|'', TRY_CONVERT(NVARCHAR(50), src.[ods_row_id])))';
                    END
                    ELSE IF @source_table = N'AMR_Robot_Mode'
                    BEGIN
                        SET @insert_columns = NULL;
                        SET @select_columns = NULL;
                    END
                    ELSE
                    BEGIN
                        SET @select_columns =
                            @robot_id + N', ' + @robot_code + N', ' + @robot_name + N', ' +
                            @current_status + N', ' + @current_mode + N', ' + @online_status + N', ' +
                            @job_id + N', ' + @subjob_id + N', ' + @map_code + N', ' + @station_code + N', ' +
                            @position_x + N', ' + @position_y + N', ' + @position_theta + N', ' + @speed_mps + N', ' +
                            @battery_soc + N', ' + @error_code + N', ' + @error_message_expr + N', ' + @event_time +
                            N', @p_source_schema, @p_source_table, TRY_CONVERT(BIGINT, src.[ods_row_id]), @p_batch_id, ' +
                            N'HASHBYTES(''SHA2_256'', CONCAT(@p_source_schema, N''|'', @p_source_table, N''|'', TRY_CONVERT(NVARCHAR(50), src.[ods_row_id])))';
                    END;
                END;

                IF @insert_columns IS NULL OR @select_columns IS NULL
                BEGIN
                    INSERT INTO [DWD].[etl_load_log] (
                        batch_id, source_schema, source_table, target_schema, target_table,
                        load_mode, load_start_time, load_end_time, rows_inserted, rows_updated,
                        rows_deleted, load_status, error_message
                    )
                    VALUES (
                        @batch_id, @source_schema, @source_table, @target_schema, @target_table,
                        @load_mode, @load_start_time, SYSDATETIME(), 0, 0,
                        0, N'SKIPPED', N'Target table is not supported by this procedure.'
                    );

                    FETCH NEXT FROM wm_cursor
                    INTO
                        @watermark_id,
                        @source_schema,
                        @source_table,
                        @target_schema,
                        @target_table,
                        @load_mode,
                        @watermark_column,
                        @last_bigint_value,
                        @last_datetime_value;

                    CONTINUE;
                END;

                IF @load_mode IN (N'FULL_REPLACE', N'SNAPSHOT')
                BEGIN
                    SET @where_sql = N'';
                END
                ELSE IF @load_mode = N'ID_INCREMENT'
                BEGIN
                    IF @watermark_column IS NULL
                    BEGIN
                        THROW 52003, 'ID_INCREMENT requires a watermark column.', 1;
                    END;

                    IF NOT EXISTS (
                        SELECT 1
                        FROM sys.columns
                        WHERE object_id = @source_object_id
                          AND name = @watermark_column
                    )
                    BEGIN
                        THROW 52004, 'The configured watermark column does not exist in the source table.', 1;
                    END;

                    SET @where_sql =
                        N' WHERE TRY_CONVERT(BIGINT, src.' + QUOTENAME(@watermark_column) + N') > ISNULL(@p_last_bigint, 0)
                           AND NOT EXISTS (
                               SELECT 1
                               FROM ' + @target_full + N' AS tgt
                               WHERE tgt.source_schema = @p_source_schema
                                 AND tgt.source_table = @p_source_table
                                 AND tgt.source_ods_row_id = TRY_CONVERT(BIGINT, src.[ods_row_id])
                           )';
                END
                ELSE
                BEGIN
                    INSERT INTO [DWD].[etl_load_log] (
                        batch_id, source_schema, source_table, target_schema, target_table,
                        load_mode, load_start_time, load_end_time, rows_inserted, rows_updated,
                        rows_deleted, load_status, error_message
                    )
                    VALUES (
                        @batch_id, @source_schema, @source_table, @target_schema, @target_table,
                        @load_mode, @load_start_time, SYSDATETIME(), 0, 0,
                        0, N'SKIPPED', N'Unsupported load mode.'
                    );

                    FETCH NEXT FROM wm_cursor
                    INTO
                        @watermark_id,
                        @source_schema,
                        @source_table,
                        @target_schema,
                        @target_table,
                        @load_mode,
                        @watermark_column,
                        @last_bigint_value,
                        @last_datetime_value;

                    CONTINUE;
                END;

                BEGIN TRAN;

                IF @load_mode IN (N'FULL_REPLACE', N'SNAPSHOT')
                BEGIN
                    SET @delete_sql =
                        N'DELETE tgt
                          FROM ' + @target_full + N' AS tgt
                          WHERE tgt.source_schema = @p_source_schema
                            AND tgt.source_table = @p_source_table;
                          SET @p_rows_deleted = @@ROWCOUNT;';

                    EXEC sys.sp_executesql
                        @delete_sql,
                        N'@p_source_schema SYSNAME, @p_source_table SYSNAME, @p_rows_deleted BIGINT OUTPUT',
                        @p_source_schema = @source_schema,
                        @p_source_table = @source_table,
                        @p_rows_deleted = @rows_deleted OUTPUT;
                END;

                SET @insert_sql =
                    N'INSERT INTO ' + @target_full + N' (' + @insert_columns + N')
                      SELECT ' + @select_columns + N'
                      FROM ' + @source_full + N' AS src' + @where_sql + N';
                      SET @p_rows_inserted = @@ROWCOUNT;';

                EXEC sys.sp_executesql
                    @insert_sql,
                    N'@p_batch_id BIGINT,
                      @p_source_schema SYSNAME,
                      @p_source_table SYSNAME,
                      @p_last_bigint BIGINT,
                      @p_rows_inserted BIGINT OUTPUT',
                    @p_batch_id = @batch_id,
                    @p_source_schema = @source_schema,
                    @p_source_table = @source_table,
                    @p_last_bigint = @last_bigint_value,
                    @p_rows_inserted = @rows_inserted OUTPUT;

                COMMIT;

                IF @load_mode = N'ID_INCREMENT'
                BEGIN
                    SET @max_sql =
                        N'SELECT @p_max_bigint = ISNULL(MAX(TRY_CONVERT(BIGINT, src.' + QUOTENAME(@watermark_column) + N')), ISNULL(@p_previous_bigint, 0))
                          FROM ' + @source_full + N' AS src;';

                    EXEC sys.sp_executesql
                        @max_sql,
                        N'@p_previous_bigint BIGINT, @p_max_bigint BIGINT OUTPUT',
                        @p_previous_bigint = @last_bigint_value,
                        @p_max_bigint = @max_bigint OUTPUT;

                    UPDATE [DWD].[etl_watermark]
                    SET
                        last_bigint_value = @max_bigint,
                        last_datetime_value = NULL,
                        last_load_time = SYSDATETIME()
                    WHERE watermark_id = @watermark_id;
                END
                ELSE
                BEGIN
                    UPDATE [DWD].[etl_watermark]
                    SET
                        last_load_time = SYSDATETIME()
                    WHERE watermark_id = @watermark_id;
                END;

                INSERT INTO [DWD].[etl_load_log] (
                    batch_id, source_schema, source_table, target_schema, target_table,
                    load_mode, load_start_time, load_end_time, rows_inserted, rows_updated,
                    rows_deleted, load_status, error_message
                )
                VALUES (
                    @batch_id, @source_schema, @source_table, @target_schema, @target_table,
                    @load_mode, @load_start_time, SYSDATETIME(), @rows_inserted, 0,
                    @rows_deleted, N'SUCCESS', NULL
                );
            END TRY
            BEGIN CATCH
                IF @@TRANCOUNT > 0
                    ROLLBACK;

                SET @has_error = 1;
                SET @error_message = CONCAT(
                    N'Error ', ERROR_NUMBER(),
                    N', line ', ERROR_LINE(),
                    N': ', ERROR_MESSAGE()
                );

                INSERT INTO [DWD].[etl_load_log] (
                    batch_id, source_schema, source_table, target_schema, target_table,
                    load_mode, load_start_time, load_end_time, rows_inserted, rows_updated,
                    rows_deleted, load_status, error_message
                )
                VALUES (
                    @batch_id, @source_schema, @source_table, @target_schema, @target_table,
                    @load_mode, @load_start_time, SYSDATETIME(), @rows_inserted, 0,
                    @rows_deleted, N'FAILED', @error_message
                );

                SET @batch_error_message = CONCAT_WS(CHAR(10), @batch_error_message, @source_table + N': ' + @error_message);
            END CATCH;

            FETCH NEXT FROM wm_cursor
            INTO
                @watermark_id,
                @source_schema,
                @source_table,
                @target_schema,
                @target_table,
                @load_mode,
                @watermark_column,
                @last_bigint_value,
                @last_datetime_value;
        END;

        CLOSE wm_cursor;
        DEALLOCATE wm_cursor;

        UPDATE [DWD].[etl_batch]
        SET
            batch_end_time = SYSDATETIME(),
            batch_status = CASE WHEN @has_error = 1 THEN N'FAILED' ELSE N'SUCCESS' END,
            error_message = @batch_error_message
        WHERE batch_id = @batch_id;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'wm_cursor') >= 0
        BEGIN
            CLOSE wm_cursor;
        END;

        IF CURSOR_STATUS('local', 'wm_cursor') > -3
        BEGIN
            DEALLOCATE wm_cursor;
        END;

        IF @batch_id IS NOT NULL
        BEGIN
            UPDATE [DWD].[etl_batch]
            SET
                batch_end_time = SYSDATETIME(),
                batch_status = N'FAILED',
                error_message = CONCAT(
                    N'Fatal error ', ERROR_NUMBER(),
                    N', line ', ERROR_LINE(),
                    N': ', ERROR_MESSAGE()
                )
            WHERE batch_id = @batch_id;
        END;

        EXEC sys.sp_releaseapplock
            @Resource = N'DWD.sp_load_dwd_all_incremental',
            @LockOwner = N'Session';

        THROW;
    END CATCH;

    EXEC sys.sp_releaseapplock
        @Resource = N'DWD.sp_load_dwd_all_incremental',
        @LockOwner = N'Session';
END;
GO

/* Smoke-test commands. Run manually after creating the procedure.

USE IOT2020;
GO

EXEC [DWD].[sp_load_dwd_all_incremental];
GO

SELECT TOP 20
    batch_id,
    batch_start_time,
    batch_end_time,
    batch_status,
    DATEDIFF(SECOND, batch_start_time, batch_end_time) AS duration_seconds,
    error_message
FROM [DWD].[etl_batch]
ORDER BY batch_id DESC;

DECLARE @last_batch_id BIGINT = (
    SELECT MAX(batch_id)
    FROM [DWD].[etl_batch]
);

SELECT
    batch_id,
    source_table,
    target_table,
    load_mode,
    rows_inserted,
    rows_deleted,
    load_status,
    error_message
FROM [DWD].[etl_load_log]
WHERE batch_id = @last_batch_id
ORDER BY
    load_status,
    target_table,
    source_table;
*/

-- END OF SCRIPT.
