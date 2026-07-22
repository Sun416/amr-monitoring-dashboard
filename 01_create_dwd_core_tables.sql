USE IOT2020;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
    DWD core table bootstrap for the AMR / robot project.

    Scope:
      - Create DWD schema.
      - Create DWD ETL control tables.
      - Create the first batch of core DWD dimension, fact, and snapshot tables.
      - Seed DWD.etl_watermark from existing ODS tables.

    This script only creates metadata/table structures and seeds DWD control rows.
    It does NOT load business rows from ODS into DWD.
*/

IF NOT EXISTS (
    SELECT 1
    FROM sys.schemas
    WHERE name = N'DWD'
)
BEGIN
    EXEC(N'CREATE SCHEMA [DWD]');
END;
GO

/* ============================================================
   1. DWD ETL control tables
   ============================================================ */

IF OBJECT_ID(N'[DWD].[etl_batch]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[etl_batch] (
        batch_id BIGINT IDENTITY(1,1) NOT NULL,
        batch_start_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_etl_batch_start_time] DEFAULT SYSDATETIME(),
        batch_end_time DATETIME2(3) NULL,
        batch_status NVARCHAR(20) NOT NULL
            CONSTRAINT [DF_DWD_etl_batch_status] DEFAULT N'RUNNING',
        error_message NVARCHAR(MAX) NULL,
        CONSTRAINT [PK_DWD_etl_batch] PRIMARY KEY CLUSTERED (batch_id)
    );
END;
GO

IF OBJECT_ID(N'[DWD].[etl_load_log]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[etl_load_log] (
        load_id BIGINT IDENTITY(1,1) NOT NULL,
        batch_id BIGINT NOT NULL,
        source_schema SYSNAME NOT NULL,
        source_table SYSNAME NOT NULL,
        target_schema SYSNAME NOT NULL,
        target_table SYSNAME NOT NULL,
        load_mode NVARCHAR(30) NOT NULL,
        load_start_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_etl_load_log_start_time] DEFAULT SYSDATETIME(),
        load_end_time DATETIME2(3) NULL,
        rows_inserted BIGINT NULL,
        rows_updated BIGINT NULL,
        rows_deleted BIGINT NULL,
        load_status NVARCHAR(20) NOT NULL,
        error_message NVARCHAR(MAX) NULL,
        CONSTRAINT [PK_DWD_etl_load_log] PRIMARY KEY CLUSTERED (load_id)
    );
END;
GO

IF OBJECT_ID(N'[DWD].[etl_watermark]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[etl_watermark] (
        watermark_id BIGINT IDENTITY(1,1) NOT NULL,
        source_schema SYSNAME NOT NULL,
        source_table SYSNAME NOT NULL,
        target_schema SYSNAME NOT NULL,
        target_table SYSNAME NOT NULL,
        load_mode NVARCHAR(30) NOT NULL,
        watermark_column SYSNAME NULL,
        last_bigint_value BIGINT NULL,
        last_datetime_value DATETIME2(3) NULL,
        last_load_time DATETIME2(3) NULL,
        is_enabled BIT NOT NULL
            CONSTRAINT [DF_DWD_etl_watermark_enabled] DEFAULT 1,
        comment NVARCHAR(500) NULL,
        CONSTRAINT [PK_DWD_etl_watermark] PRIMARY KEY CLUSTERED (watermark_id),
        CONSTRAINT [UQ_DWD_etl_watermark_source_target] UNIQUE (
            source_schema,
            source_table,
            target_schema,
            target_table
        )
    );
END;
GO

/* ============================================================
   2. DWD dimension tables
   ============================================================ */

IF OBJECT_ID(N'[DWD].[dim_amr_robot]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[dim_amr_robot] (
        robot_key BIGINT IDENTITY(1,1) NOT NULL,
        robot_id NVARCHAR(100) NULL,
        robot_code NVARCHAR(100) NULL,
        robot_name NVARCHAR(200) NULL,
        robot_type NVARCHAR(100) NULL,
        robot_model NVARCHAR(100) NULL,
        factory_code NVARCHAR(100) NULL,
        plant_code NVARCHAR(100) NULL,
        line_code NVARCHAR(100) NULL,
        project_code NVARCHAR(100) NULL,
        is_enabled BIT NULL,
        source_created_time DATETIME2(3) NULL,
        source_updated_time DATETIME2(3) NULL,
        source_schema SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_dim_amr_robot_source_schema] DEFAULT N'ODS',
        source_table SYSNAME NULL,
        source_ods_row_id BIGINT NULL,
        dwd_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_dim_amr_robot_load_time] DEFAULT SYSDATETIME(),
        dwd_update_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_dim_amr_robot_update_time] DEFAULT SYSDATETIME(),
        dwd_batch_id BIGINT NULL,
        dwd_hash_value VARBINARY(32) NULL,
        CONSTRAINT [PK_DWD_dim_amr_robot] PRIMARY KEY CLUSTERED (robot_key)
    );
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[dim_amr_robot]')
      AND name = N'IX_DWD_dim_amr_robot_code'
)
BEGIN
    CREATE INDEX [IX_DWD_dim_amr_robot_code]
        ON [DWD].[dim_amr_robot] (robot_code, source_table)
        WHERE robot_code IS NOT NULL;
END;
GO

IF OBJECT_ID(N'[DWD].[dim_amr_factory_line]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[dim_amr_factory_line] (
        org_key BIGINT IDENTITY(1,1) NOT NULL,
        factory_id NVARCHAR(100) NULL,
        factory_code NVARCHAR(100) NULL,
        factory_name NVARCHAR(200) NULL,
        plant_id NVARCHAR(100) NULL,
        plant_code NVARCHAR(100) NULL,
        plant_name NVARCHAR(200) NULL,
        line_id NVARCHAR(100) NULL,
        line_code NVARCHAR(100) NULL,
        line_name NVARCHAR(200) NULL,
        is_enabled BIT NULL,
        source_created_time DATETIME2(3) NULL,
        source_updated_time DATETIME2(3) NULL,
        source_schema SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_dim_amr_factory_line_source_schema] DEFAULT N'ODS',
        source_table SYSNAME NULL,
        source_ods_row_id BIGINT NULL,
        dwd_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_dim_amr_factory_line_load_time] DEFAULT SYSDATETIME(),
        dwd_update_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_dim_amr_factory_line_update_time] DEFAULT SYSDATETIME(),
        dwd_batch_id BIGINT NULL,
        dwd_hash_value VARBINARY(32) NULL,
        CONSTRAINT [PK_DWD_dim_amr_factory_line] PRIMARY KEY CLUSTERED (org_key)
    );
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[dim_amr_factory_line]')
      AND name = N'IX_DWD_dim_amr_factory_line_codes'
)
BEGIN
    CREATE INDEX [IX_DWD_dim_amr_factory_line_codes]
        ON [DWD].[dim_amr_factory_line] (factory_code, plant_code, line_code);
END;
GO

IF OBJECT_ID(N'[DWD].[dim_amr_station]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[dim_amr_station] (
        station_key BIGINT IDENTITY(1,1) NOT NULL,
        station_id NVARCHAR(100) NULL,
        station_code NVARCHAR(100) NULL,
        station_name NVARCHAR(200) NULL,
        station_type NVARCHAR(100) NULL,
        factory_code NVARCHAR(100) NULL,
        plant_code NVARCHAR(100) NULL,
        line_code NVARCHAR(100) NULL,
        map_code NVARCHAR(100) NULL,
        position_x DECIMAL(18,6) NULL,
        position_y DECIMAL(18,6) NULL,
        position_theta DECIMAL(18,6) NULL,
        is_enabled BIT NULL,
        source_created_time DATETIME2(3) NULL,
        source_updated_time DATETIME2(3) NULL,
        source_schema SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_dim_amr_station_source_schema] DEFAULT N'ODS',
        source_table SYSNAME NULL,
        source_ods_row_id BIGINT NULL,
        dwd_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_dim_amr_station_load_time] DEFAULT SYSDATETIME(),
        dwd_update_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_dim_amr_station_update_time] DEFAULT SYSDATETIME(),
        dwd_batch_id BIGINT NULL,
        dwd_hash_value VARBINARY(32) NULL,
        CONSTRAINT [PK_DWD_dim_amr_station] PRIMARY KEY CLUSTERED (station_key)
    );
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[dim_amr_station]')
      AND name = N'IX_DWD_dim_amr_station_code'
)
BEGIN
    CREATE INDEX [IX_DWD_dim_amr_station_code]
        ON [DWD].[dim_amr_station] (station_code, source_table)
        WHERE station_code IS NOT NULL;
END;
GO

IF OBJECT_ID(N'[DWD].[dim_amr_map]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[dim_amr_map] (
        map_key BIGINT IDENTITY(1,1) NOT NULL,
        map_id NVARCHAR(100) NULL,
        map_code NVARCHAR(100) NULL,
        map_name NVARCHAR(200) NULL,
        map_type NVARCHAR(100) NULL,
        parent_map_code NVARCHAR(100) NULL,
        factory_code NVARCHAR(100) NULL,
        plant_code NVARCHAR(100) NULL,
        line_code NVARCHAR(100) NULL,
        path_code NVARCHAR(100) NULL,
        from_station_code NVARCHAR(100) NULL,
        to_station_code NVARCHAR(100) NULL,
        distance_m DECIMAL(18,6) NULL,
        is_enabled BIT NULL,
        source_created_time DATETIME2(3) NULL,
        source_updated_time DATETIME2(3) NULL,
        source_schema SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_dim_amr_map_source_schema] DEFAULT N'ODS',
        source_table SYSNAME NULL,
        source_ods_row_id BIGINT NULL,
        dwd_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_dim_amr_map_load_time] DEFAULT SYSDATETIME(),
        dwd_update_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_dim_amr_map_update_time] DEFAULT SYSDATETIME(),
        dwd_batch_id BIGINT NULL,
        dwd_hash_value VARBINARY(32) NULL,
        CONSTRAINT [PK_DWD_dim_amr_map] PRIMARY KEY CLUSTERED (map_key)
    );
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[dim_amr_map]')
      AND name = N'IX_DWD_dim_amr_map_code_type'
)
BEGIN
    CREATE INDEX [IX_DWD_dim_amr_map_code_type]
        ON [DWD].[dim_amr_map] (map_code, map_type);
END;
GO

IF OBJECT_ID(N'[DWD].[dim_amr_project]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[dim_amr_project] (
        project_key BIGINT IDENTITY(1,1) NOT NULL,
        project_id NVARCHAR(100) NULL,
        project_code NVARCHAR(100) NULL,
        project_name NVARCHAR(200) NULL,
        project_type NVARCHAR(100) NULL,
        default_robot_code NVARCHAR(100) NULL,
        start_station_code NVARCHAR(100) NULL,
        end_station_code NVARCHAR(100) NULL,
        priority_value INT NULL,
        is_enabled BIT NULL,
        source_created_time DATETIME2(3) NULL,
        source_updated_time DATETIME2(3) NULL,
        source_schema SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_dim_amr_project_source_schema] DEFAULT N'ODS',
        source_table SYSNAME NULL,
        source_ods_row_id BIGINT NULL,
        dwd_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_dim_amr_project_load_time] DEFAULT SYSDATETIME(),
        dwd_update_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_dim_amr_project_update_time] DEFAULT SYSDATETIME(),
        dwd_batch_id BIGINT NULL,
        dwd_hash_value VARBINARY(32) NULL,
        CONSTRAINT [PK_DWD_dim_amr_project] PRIMARY KEY CLUSTERED (project_key)
    );
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[dim_amr_project]')
      AND name = N'IX_DWD_dim_amr_project_code'
)
BEGIN
    CREATE INDEX [IX_DWD_dim_amr_project_code]
        ON [DWD].[dim_amr_project] (project_code);
END;
GO

IF OBJECT_ID(N'[DWD].[dim_amr_job_type]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[dim_amr_job_type] (
        job_type_key BIGINT IDENTITY(1,1) NOT NULL,
        job_type_id NVARCHAR(100) NULL,
        job_type_code NVARCHAR(100) NULL,
        job_type_name NVARCHAR(200) NULL,
        subjob_type_id NVARCHAR(100) NULL,
        subjob_type_code NVARCHAR(100) NULL,
        subjob_type_name NVARCHAR(200) NULL,
        is_enabled BIT NULL,
        source_created_time DATETIME2(3) NULL,
        source_updated_time DATETIME2(3) NULL,
        source_schema SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_dim_amr_job_type_source_schema] DEFAULT N'ODS',
        source_table SYSNAME NULL,
        source_ods_row_id BIGINT NULL,
        dwd_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_dim_amr_job_type_load_time] DEFAULT SYSDATETIME(),
        dwd_update_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_dim_amr_job_type_update_time] DEFAULT SYSDATETIME(),
        dwd_batch_id BIGINT NULL,
        dwd_hash_value VARBINARY(32) NULL,
        CONSTRAINT [PK_DWD_dim_amr_job_type] PRIMARY KEY CLUSTERED (job_type_key)
    );
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[dim_amr_job_type]')
      AND name = N'IX_DWD_dim_amr_job_type_code'
)
BEGIN
    CREATE INDEX [IX_DWD_dim_amr_job_type_code]
        ON [DWD].[dim_amr_job_type] (job_type_code, subjob_type_code);
END;
GO

/* ============================================================
   3. DWD fact tables
   ============================================================ */

IF OBJECT_ID(N'[DWD].[fact_amr_raw_status]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[fact_amr_raw_status] (
        raw_status_fact_id BIGINT IDENTITY(1,1) NOT NULL,
        event_time DATETIME2(3) NULL,
        robot_id NVARCHAR(100) NULL,
        robot_code NVARCHAR(100) NULL,
        robot_name NVARCHAR(200) NULL,
        robot_status NVARCHAR(100) NULL,
        robot_mode NVARCHAR(100) NULL,
        job_id NVARCHAR(100) NULL,
        subjob_id NVARCHAR(100) NULL,
        map_code NVARCHAR(100) NULL,
        station_code NVARCHAR(100) NULL,
        position_x DECIMAL(18,6) NULL,
        position_y DECIMAL(18,6) NULL,
        position_theta DECIMAL(18,6) NULL,
        speed_mps DECIMAL(18,6) NULL,
        battery_soc DECIMAL(9,4) NULL,
        battery_voltage DECIMAL(18,6) NULL,
        battery_current DECIMAL(18,6) NULL,
        battery_power DECIMAL(18,6) NULL,
        online_status NVARCHAR(50) NULL,
        error_code NVARCHAR(100) NULL,
        error_message NVARCHAR(1000) NULL,
        source_schema SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_fact_amr_raw_status_source_schema] DEFAULT N'ODS',
        source_table SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_fact_amr_raw_status_source_table] DEFAULT N'AMR_Rawdata',
        source_ods_row_id BIGINT NULL,
        source_ods_load_time DATETIME2(3) NULL,
        dwd_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_fact_amr_raw_status_load_time] DEFAULT SYSDATETIME(),
        dwd_batch_id BIGINT NULL,
        dwd_hash_value VARBINARY(32) NULL,
        CONSTRAINT [PK_DWD_fact_amr_raw_status] PRIMARY KEY CLUSTERED (raw_status_fact_id)
    );
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[fact_amr_raw_status]')
      AND name = N'IX_DWD_fact_amr_raw_status_robot_time'
)
BEGIN
    CREATE INDEX [IX_DWD_fact_amr_raw_status_robot_time]
        ON [DWD].[fact_amr_raw_status] (robot_code, event_time);
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[fact_amr_raw_status]')
      AND name = N'UX_DWD_fact_amr_raw_status_source_row'
)
BEGIN
    CREATE UNIQUE INDEX [UX_DWD_fact_amr_raw_status_source_row]
        ON [DWD].[fact_amr_raw_status] (source_schema, source_table, source_ods_row_id)
        WHERE source_ods_row_id IS NOT NULL;
END;
GO

IF OBJECT_ID(N'[DWD].[fact_amr_queue]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[fact_amr_queue] (
        queue_fact_id BIGINT IDENTITY(1,1) NOT NULL,
        queue_id NVARCHAR(100) NULL,
        event_time DATETIME2(3) NULL,
        robot_id NVARCHAR(100) NULL,
        robot_code NVARCHAR(100) NULL,
        project_id NVARCHAR(100) NULL,
        project_code NVARCHAR(100) NULL,
        job_id NVARCHAR(100) NULL,
        subjob_id NVARCHAR(100) NULL,
        queue_status NVARCHAR(100) NULL,
        priority_value INT NULL,
        start_station_code NVARCHAR(100) NULL,
        end_station_code NVARCHAR(100) NULL,
        queue_start_time DATETIME2(3) NULL,
        queue_end_time DATETIME2(3) NULL,
        duration_seconds BIGINT NULL,
        source_schema SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_fact_amr_queue_source_schema] DEFAULT N'ODS',
        source_table SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_fact_amr_queue_source_table] DEFAULT N'AMR_Queue',
        source_ods_row_id BIGINT NULL,
        source_ods_load_time DATETIME2(3) NULL,
        dwd_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_fact_amr_queue_load_time] DEFAULT SYSDATETIME(),
        dwd_batch_id BIGINT NULL,
        dwd_hash_value VARBINARY(32) NULL,
        CONSTRAINT [PK_DWD_fact_amr_queue] PRIMARY KEY CLUSTERED (queue_fact_id)
    );
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[fact_amr_queue]')
      AND name = N'IX_DWD_fact_amr_queue_robot_time'
)
BEGIN
    CREATE INDEX [IX_DWD_fact_amr_queue_robot_time]
        ON [DWD].[fact_amr_queue] (robot_code, event_time);
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[fact_amr_queue]')
      AND name = N'UX_DWD_fact_amr_queue_source_row'
)
BEGIN
    CREATE UNIQUE INDEX [UX_DWD_fact_amr_queue_source_row]
        ON [DWD].[fact_amr_queue] (source_schema, source_table, source_ods_row_id)
        WHERE source_ods_row_id IS NOT NULL;
END;
GO

IF OBJECT_ID(N'[DWD].[fact_amr_subjob]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[fact_amr_subjob] (
        subjob_fact_id BIGINT IDENTITY(1,1) NOT NULL,
        subjob_id NVARCHAR(100) NULL,
        job_id NVARCHAR(100) NULL,
        robot_id NVARCHAR(100) NULL,
        robot_code NVARCHAR(100) NULL,
        project_id NVARCHAR(100) NULL,
        project_code NVARCHAR(100) NULL,
        job_type_code NVARCHAR(100) NULL,
        subjob_type_code NVARCHAR(100) NULL,
        subjob_status NVARCHAR(100) NULL,
        start_station_code NVARCHAR(100) NULL,
        end_station_code NVARCHAR(100) NULL,
        subjob_start_time DATETIME2(3) NULL,
        subjob_end_time DATETIME2(3) NULL,
        duration_seconds BIGINT NULL,
        result_code NVARCHAR(100) NULL,
        result_message NVARCHAR(1000) NULL,
        source_schema SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_fact_amr_subjob_source_schema] DEFAULT N'ODS',
        source_table SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_fact_amr_subjob_source_table] DEFAULT N'AMR_Subjob_Analyze',
        source_ods_row_id BIGINT NULL,
        source_ods_load_time DATETIME2(3) NULL,
        dwd_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_fact_amr_subjob_load_time] DEFAULT SYSDATETIME(),
        dwd_batch_id BIGINT NULL,
        dwd_hash_value VARBINARY(32) NULL,
        CONSTRAINT [PK_DWD_fact_amr_subjob] PRIMARY KEY CLUSTERED (subjob_fact_id)
    );
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[fact_amr_subjob]')
      AND name = N'IX_DWD_fact_amr_subjob_robot_time'
)
BEGIN
    CREATE INDEX [IX_DWD_fact_amr_subjob_robot_time]
        ON [DWD].[fact_amr_subjob] (robot_code, subjob_start_time);
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[fact_amr_subjob]')
      AND name = N'UX_DWD_fact_amr_subjob_source_row'
)
BEGIN
    CREATE UNIQUE INDEX [UX_DWD_fact_amr_subjob_source_row]
        ON [DWD].[fact_amr_subjob] (source_schema, source_table, source_ods_row_id)
        WHERE source_ods_row_id IS NOT NULL;
END;
GO

IF OBJECT_ID(N'[DWD].[fact_robot_battery]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[fact_robot_battery] (
        battery_fact_id BIGINT IDENTITY(1,1) NOT NULL,
        sample_time DATETIME2(3) NULL,
        robot_id NVARCHAR(100) NULL,
        robot_code NVARCHAR(100) NULL,
        battery_soc DECIMAL(9,4) NULL,
        battery_voltage DECIMAL(18,6) NULL,
        battery_current DECIMAL(18,6) NULL,
        battery_power DECIMAL(18,6) NULL,
        charging_status NVARCHAR(100) NULL,
        battery_status NVARCHAR(100) NULL,
        source_schema SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_fact_robot_battery_source_schema] DEFAULT N'ODS',
        source_table SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_fact_robot_battery_source_table] DEFAULT N'robot_battery_history',
        source_ods_row_id BIGINT NULL,
        source_ods_load_time DATETIME2(3) NULL,
        dwd_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_fact_robot_battery_load_time] DEFAULT SYSDATETIME(),
        dwd_batch_id BIGINT NULL,
        dwd_hash_value VARBINARY(32) NULL,
        CONSTRAINT [PK_DWD_fact_robot_battery] PRIMARY KEY CLUSTERED (battery_fact_id)
    );
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[fact_robot_battery]')
      AND name = N'IX_DWD_fact_robot_battery_robot_time'
)
BEGIN
    CREATE INDEX [IX_DWD_fact_robot_battery_robot_time]
        ON [DWD].[fact_robot_battery] (robot_code, sample_time);
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[fact_robot_battery]')
      AND name = N'UX_DWD_fact_robot_battery_source_row'
)
BEGIN
    CREATE UNIQUE INDEX [UX_DWD_fact_robot_battery_source_row]
        ON [DWD].[fact_robot_battery] (source_schema, source_table, source_ods_row_id)
        WHERE source_ods_row_id IS NOT NULL;
END;
GO

IF OBJECT_ID(N'[DWD].[fact_robot_job]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[fact_robot_job] (
        job_fact_id BIGINT IDENTITY(1,1) NOT NULL,
        job_id NVARCHAR(100) NULL,
        robot_id NVARCHAR(100) NULL,
        robot_code NVARCHAR(100) NULL,
        job_type_code NVARCHAR(100) NULL,
        robot_mode_id NVARCHAR(100) NULL,
        robot_mode_detail NVARCHAR(200) NULL,
        source_status_ods_row_id BIGINT NULL,
        job_status NVARCHAR(100) NULL,
        job_start_time DATETIME2(3) NULL,
        job_end_time DATETIME2(3) NULL,
        duration_seconds BIGINT NULL,
        result_code NVARCHAR(100) NULL,
        result_message NVARCHAR(1000) NULL,
        source_schema SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_fact_robot_job_source_schema] DEFAULT N'ODS',
        source_table SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_fact_robot_job_source_table] DEFAULT N'robot_job_history',
        source_ods_row_id BIGINT NULL,
        source_ods_load_time DATETIME2(3) NULL,
        dwd_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_fact_robot_job_load_time] DEFAULT SYSDATETIME(),
        dwd_batch_id BIGINT NULL,
        dwd_hash_value VARBINARY(32) NULL,
        CONSTRAINT [PK_DWD_fact_robot_job] PRIMARY KEY CLUSTERED (job_fact_id)
    );
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[fact_robot_job]')
      AND name = N'IX_DWD_fact_robot_job_robot_time'
)
BEGIN
    CREATE INDEX [IX_DWD_fact_robot_job_robot_time]
        ON [DWD].[fact_robot_job] (robot_code, job_start_time);
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[fact_robot_job]')
      AND name = N'UX_DWD_fact_robot_job_source_row'
)
BEGIN
    CREATE UNIQUE INDEX [UX_DWD_fact_robot_job_source_row]
        ON [DWD].[fact_robot_job] (source_schema, source_table, source_ods_row_id)
        WHERE source_ods_row_id IS NOT NULL;
END;
GO

IF OBJECT_ID(N'[DWD].[fact_robot_status]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[fact_robot_status] (
        status_fact_id BIGINT IDENTITY(1,1) NOT NULL,
        status_time DATETIME2(3) NULL,
        robot_id NVARCHAR(100) NULL,
        robot_code NVARCHAR(100) NULL,
        robot_status NVARCHAR(100) NULL,
        robot_mode NVARCHAR(100) NULL,
        online_status NVARCHAR(50) NULL,
        speed_mps DECIMAL(18,6) NULL,
        error_code NVARCHAR(100) NULL,
        error_message NVARCHAR(1000) NULL,
        source_schema SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_fact_robot_status_source_schema] DEFAULT N'ODS',
        source_table SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_fact_robot_status_source_table] DEFAULT N'robot_status_history',
        source_ods_row_id BIGINT NULL,
        source_ods_load_time DATETIME2(3) NULL,
        dwd_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_fact_robot_status_load_time] DEFAULT SYSDATETIME(),
        dwd_batch_id BIGINT NULL,
        dwd_hash_value VARBINARY(32) NULL,
        CONSTRAINT [PK_DWD_fact_robot_status] PRIMARY KEY CLUSTERED (status_fact_id)
    );
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[fact_robot_status]')
      AND name = N'IX_DWD_fact_robot_status_robot_time'
)
BEGIN
    CREATE INDEX [IX_DWD_fact_robot_status_robot_time]
        ON [DWD].[fact_robot_status] (robot_code, status_time);
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[fact_robot_status]')
      AND name = N'UX_DWD_fact_robot_status_source_row'
)
BEGIN
    CREATE UNIQUE INDEX [UX_DWD_fact_robot_status_source_row]
        ON [DWD].[fact_robot_status] (source_schema, source_table, source_ods_row_id)
        WHERE source_ods_row_id IS NOT NULL;
END;
GO

IF OBJECT_ID(N'[DWD].[fact_robot_wifi]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[fact_robot_wifi] (
        wifi_fact_id BIGINT IDENTITY(1,1) NOT NULL,
        sample_time DATETIME2(3) NULL,
        robot_id NVARCHAR(100) NULL,
        robot_code NVARCHAR(100) NULL,
        ssid NVARCHAR(200) NULL,
        bssid NVARCHAR(200) NULL,
        rssi DECIMAL(18,6) NULL,
        signal_quality DECIMAL(18,6) NULL,
        network_status NVARCHAR(100) NULL,
        source_schema SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_fact_robot_wifi_source_schema] DEFAULT N'ODS',
        source_table SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_fact_robot_wifi_source_table] DEFAULT N'robot_wifi_history',
        source_ods_row_id BIGINT NULL,
        source_ods_load_time DATETIME2(3) NULL,
        dwd_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_fact_robot_wifi_load_time] DEFAULT SYSDATETIME(),
        dwd_batch_id BIGINT NULL,
        dwd_hash_value VARBINARY(32) NULL,
        CONSTRAINT [PK_DWD_fact_robot_wifi] PRIMARY KEY CLUSTERED (wifi_fact_id)
    );
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[fact_robot_wifi]')
      AND name = N'IX_DWD_fact_robot_wifi_robot_time'
)
BEGIN
    CREATE INDEX [IX_DWD_fact_robot_wifi_robot_time]
        ON [DWD].[fact_robot_wifi] (robot_code, sample_time);
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[fact_robot_wifi]')
      AND name = N'UX_DWD_fact_robot_wifi_source_row'
)
BEGIN
    CREATE UNIQUE INDEX [UX_DWD_fact_robot_wifi_source_row]
        ON [DWD].[fact_robot_wifi] (source_schema, source_table, source_ods_row_id)
        WHERE source_ods_row_id IS NOT NULL;
END;
GO

/* ============================================================
   4. DWD snapshot table
   ============================================================ */

IF OBJECT_ID(N'[DWD].[snap_amr_current_status]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWD].[snap_amr_current_status] (
        snapshot_id BIGINT IDENTITY(1,1) NOT NULL,
        robot_id NVARCHAR(100) NULL,
        robot_code NVARCHAR(100) NULL,
        robot_name NVARCHAR(200) NULL,
        current_status NVARCHAR(100) NULL,
        current_mode NVARCHAR(100) NULL,
        online_status NVARCHAR(50) NULL,
        job_id NVARCHAR(100) NULL,
        subjob_id NVARCHAR(100) NULL,
        map_code NVARCHAR(100) NULL,
        station_code NVARCHAR(100) NULL,
        position_x DECIMAL(18,6) NULL,
        position_y DECIMAL(18,6) NULL,
        position_theta DECIMAL(18,6) NULL,
        speed_mps DECIMAL(18,6) NULL,
        battery_soc DECIMAL(9,4) NULL,
        error_code NVARCHAR(100) NULL,
        error_message NVARCHAR(1000) NULL,
        source_event_time DATETIME2(3) NULL,
        snapshot_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_snap_amr_current_status_snapshot_time] DEFAULT SYSDATETIME(),
        source_schema SYSNAME NOT NULL
            CONSTRAINT [DF_DWD_snap_amr_current_status_source_schema] DEFAULT N'ODS',
        source_table SYSNAME NULL,
        source_ods_row_id BIGINT NULL,
        dwd_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWD_snap_amr_current_status_load_time] DEFAULT SYSDATETIME(),
        dwd_batch_id BIGINT NULL,
        dwd_hash_value VARBINARY(32) NULL,
        CONSTRAINT [PK_DWD_snap_amr_current_status] PRIMARY KEY CLUSTERED (snapshot_id)
    );
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[snap_amr_current_status]')
      AND name = N'IX_DWD_snap_amr_current_status_robot'
)
BEGIN
    CREATE INDEX [IX_DWD_snap_amr_current_status_robot]
        ON [DWD].[snap_amr_current_status] (robot_code, source_table)
        WHERE robot_code IS NOT NULL;
END;
GO

/* ============================================================
   5. Seed DWD watermark configs from existing ODS tables
   ============================================================ */

;WITH seed_config AS (
    SELECT *
    FROM (VALUES
        (N'ODS', N'MA_AMR',                  N'DWD', N'dim_amr_robot',            N'FULL_REPLACE', NULL,            1, N'Robot master data'),
        (N'ODS', N'MA_AMR_Info',             N'DWD', N'dim_amr_robot',            N'FULL_REPLACE', NULL,            1, N'Robot extended information'),
        (N'ODS', N'MA_AMR_Factory',          N'DWD', N'dim_amr_factory_line',     N'FULL_REPLACE', NULL,            1, N'Factory dimension'),
        (N'ODS', N'MA_AMR_Plant',            N'DWD', N'dim_amr_factory_line',     N'FULL_REPLACE', NULL,            1, N'Plant dimension'),
        (N'ODS', N'MA_AMR_Line',             N'DWD', N'dim_amr_factory_line',     N'FULL_REPLACE', NULL,            1, N'Line dimension'),
        (N'ODS', N'MA_AMR_Station',          N'DWD', N'dim_amr_station',          N'FULL_REPLACE', NULL,            1, N'Station dimension'),
        (N'ODS', N'MA_AMR_MAIN_MAP',         N'DWD', N'dim_amr_map',              N'FULL_REPLACE', NULL,            1, N'Main map dimension'),
        (N'ODS', N'MA_AMR_SUB_MAP',          N'DWD', N'dim_amr_map',              N'FULL_REPLACE', NULL,            1, N'Sub map dimension'),
        (N'ODS', N'MA_AMR_TRAFFIC_MAP',      N'DWD', N'dim_amr_map',              N'FULL_REPLACE', NULL,            1, N'Traffic map dimension'),
        (N'ODS', N'MA_AMR_TRAFFIC_PATH',     N'DWD', N'dim_amr_map',              N'FULL_REPLACE', NULL,            1, N'Traffic path dimension'),
        (N'ODS', N'MA_AMR_Project',          N'DWD', N'dim_amr_project',          N'FULL_REPLACE', NULL,            1, N'Project dimension'),
        (N'ODS', N'MA_AMR_DefaultProject',   N'DWD', N'dim_amr_project',          N'FULL_REPLACE', NULL,            1, N'Default project dimension'),
        (N'ODS', N'MA_AMR_Job_Type',         N'DWD', N'dim_amr_job_type',         N'FULL_REPLACE', NULL,            1, N'Job type dimension'),
        (N'ODS', N'MA_AMR_Subjob_Type',      N'DWD', N'dim_amr_job_type',         N'FULL_REPLACE', NULL,            1, N'Subjob type dimension'),
        (N'ODS', N'AMR_Currentdata',         N'DWD', N'snap_amr_current_status',  N'SNAPSHOT',     NULL,            1, N'Current AMR status snapshot'),
        (N'ODS', N'AMR_Robot_Mode',          N'DWD', N'snap_amr_current_status',  N'SNAPSHOT',     NULL,            1, N'Current AMR mode snapshot'),
        (N'ODS', N'AMR_Rawdata',             N'DWD', N'fact_amr_raw_status',      N'ID_INCREMENT', N'ods_row_id',    1, N'AMR raw status detail'),
        (N'ODS', N'AMR_Queue',               N'DWD', N'fact_amr_queue',           N'ID_INCREMENT', N'ods_row_id',    1, N'AMR queue detail'),
        (N'ODS', N'AMR_Subjob_Analyze',      N'DWD', N'fact_amr_subjob',          N'ID_INCREMENT', N'ods_row_id',    1, N'AMR subjob detail'),
        (N'ODS', N'robot_battery_history',   N'DWD', N'fact_robot_battery',       N'ID_INCREMENT', N'ods_row_id',    1, N'Robot battery history'),
        (N'ODS', N'robot_job_history',       N'DWD', N'fact_robot_job',           N'ID_INCREMENT', N'ods_row_id',    1, N'Robot job history'),
        (N'ODS', N'robot_status_history',    N'DWD', N'fact_robot_status',        N'ID_INCREMENT', N'ods_row_id',    1, N'Robot status history'),
        (N'ODS', N'robot_wifi_history',      N'DWD', N'fact_robot_wifi',          N'ID_INCREMENT', N'ods_row_id',    1, N'Robot WiFi history')
    ) AS v (
        source_schema,
        source_table,
        target_schema,
        target_table,
        load_mode,
        watermark_column,
        is_enabled,
        comment
    )
)
INSERT INTO [DWD].[etl_watermark] (
    source_schema,
    source_table,
    target_schema,
    target_table,
    load_mode,
    watermark_column,
    last_bigint_value,
    last_datetime_value,
    last_load_time,
    is_enabled,
    comment
)
SELECT
    sc.source_schema,
    sc.source_table,
    sc.target_schema,
    sc.target_table,
    sc.load_mode,
    sc.watermark_column,
    0 AS last_bigint_value,
    NULL AS last_datetime_value,
    NULL AS last_load_time,
    sc.is_enabled,
    sc.comment
FROM seed_config AS sc
WHERE EXISTS (
        SELECT 1
        FROM sys.tables AS t
        JOIN sys.schemas AS s
            ON s.schema_id = t.schema_id
        WHERE s.name = sc.source_schema
          AND t.name = sc.source_table
    )
  AND NOT EXISTS (
        SELECT 1
        FROM [DWD].[etl_watermark] AS w
        WHERE w.source_schema = sc.source_schema
          AND w.source_table = sc.source_table
          AND w.target_schema = sc.target_schema
          AND w.target_table = sc.target_table
    );
GO

/* ============================================================
   6. Verification output
   ============================================================ */

SELECT
    s.name AS schema_name,
    t.name AS table_name,
    SUM(p.rows) AS approximate_row_count
FROM sys.tables AS t
JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
JOIN sys.partitions AS p
    ON p.object_id = t.object_id
   AND p.index_id IN (0, 1)
WHERE s.name = N'DWD'
GROUP BY
    s.name,
    t.name
ORDER BY
    t.name;

SELECT
    load_mode,
    is_enabled,
    COUNT(*) AS mapping_count
FROM [DWD].[etl_watermark]
GROUP BY
    load_mode,
    is_enabled
ORDER BY
    load_mode,
    is_enabled;

;WITH expected_sources AS (
    SELECT *
    FROM (VALUES
        (N'ODS', N'MA_AMR'),
        (N'ODS', N'MA_AMR_Info'),
        (N'ODS', N'MA_AMR_Factory'),
        (N'ODS', N'MA_AMR_Plant'),
        (N'ODS', N'MA_AMR_Line'),
        (N'ODS', N'MA_AMR_Station'),
        (N'ODS', N'MA_AMR_MAIN_MAP'),
        (N'ODS', N'MA_AMR_SUB_MAP'),
        (N'ODS', N'MA_AMR_TRAFFIC_MAP'),
        (N'ODS', N'MA_AMR_TRAFFIC_PATH'),
        (N'ODS', N'MA_AMR_Project'),
        (N'ODS', N'MA_AMR_DefaultProject'),
        (N'ODS', N'MA_AMR_Job_Type'),
        (N'ODS', N'MA_AMR_Subjob_Type'),
        (N'ODS', N'AMR_Currentdata'),
        (N'ODS', N'AMR_Robot_Mode'),
        (N'ODS', N'AMR_Rawdata'),
        (N'ODS', N'AMR_Queue'),
        (N'ODS', N'AMR_Subjob_Analyze'),
        (N'ODS', N'robot_battery_history'),
        (N'ODS', N'robot_job_history'),
        (N'ODS', N'robot_status_history'),
        (N'ODS', N'robot_wifi_history')
    ) AS v (source_schema, source_table)
)
SELECT
    es.source_schema,
    es.source_table,
    CASE
        WHEN t.object_id IS NULL THEN N'MISSING_IN_ODS'
        ELSE N'OK'
    END AS source_status
FROM expected_sources AS es
LEFT JOIN sys.schemas AS s
    ON s.name = es.source_schema
LEFT JOIN sys.tables AS t
    ON t.schema_id = s.schema_id
   AND t.name = es.source_table
ORDER BY
    source_status DESC,
    es.source_table;
GO

-- END OF SCRIPT.
