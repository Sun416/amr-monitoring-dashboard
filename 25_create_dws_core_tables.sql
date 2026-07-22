USE IOT2020;
GO

/*
    Create core DWS tables for AMR / robot analytics.

    DWS design rule:
    - DWD keeps cleaned row-level facts.
    - DWS keeps reusable subject-level summaries.
    - ADS / Power BI should read DWS or ADS, not raw ODS.

    First DWS batch:
    1. dws_robot_battery_hourly
    2. dws_robot_status_hourly
    3. dws_robot_wifi_hourly
    4. dws_robot_job_daily
    5. dws_amr_queue_daily
    6. dws_robot_current_snapshot
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF NOT EXISTS
    (
    SELECT 1
    FROM sys.schemas
    WHERE [name] = N'DWS'
    )
BEGIN
    EXEC(N'CREATE SCHEMA [DWS]');
END;
GO

IF OBJECT_ID(N'[DWS].[etl_batch]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWS].[etl_batch] (
        batch_id BIGINT IDENTITY(1,1) NOT NULL,
        batch_start_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWS_etl_batch_start_time] DEFAULT SYSDATETIME(),
        batch_end_time DATETIME2(3) NULL,
        batch_status NVARCHAR(30) NOT NULL
            CONSTRAINT [DF_DWS_etl_batch_status] DEFAULT N'RUNNING',
        error_message NVARCHAR(4000) NULL,
        CONSTRAINT [PK_DWS_etl_batch] PRIMARY KEY CLUSTERED ([batch_id])
    );
END;
GO

IF OBJECT_ID(N'[DWS].[etl_load_log]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWS].[etl_load_log] (
        load_id BIGINT IDENTITY(1,1) NOT NULL,
        batch_id BIGINT NOT NULL,
        target_schema SYSNAME NOT NULL,
        target_table SYSNAME NOT NULL,
        source_schema SYSNAME NOT NULL,
        source_table SYSNAME NOT NULL,
        load_mode NVARCHAR(30) NOT NULL,
        affected_rows BIGINT NOT NULL
            CONSTRAINT [DF_DWS_etl_load_log_affected_rows] DEFAULT 0,
        load_status NVARCHAR(30) NOT NULL,
        error_message NVARCHAR(4000) NULL,
        load_start_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWS_etl_load_log_start_time] DEFAULT SYSDATETIME(),
        load_end_time DATETIME2(3) NULL,
        CONSTRAINT [PK_DWS_etl_load_log] PRIMARY KEY CLUSTERED ([load_id])
    );
END;
GO

IF OBJECT_ID(N'[DWS].[dws_robot_battery_hourly]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWS].[dws_robot_battery_hourly] (
        battery_hourly_id BIGINT IDENTITY(1,1) NOT NULL,
        stat_hour DATETIME2(0) NOT NULL,
        robot_code NVARCHAR(100) NOT NULL,
        robot_id NVARCHAR(100) NULL,
        sample_count BIGINT NOT NULL,
        avg_battery_soc DECIMAL(18,6) NULL,
        min_battery_soc DECIMAL(18,6) NULL,
        max_battery_soc DECIMAL(18,6) NULL,
        avg_battery_voltage DECIMAL(18,6) NULL,
        avg_battery_current DECIMAL(18,6) NULL,
        avg_battery_power DECIMAL(18,6) NULL,
        charging_sample_count BIGINT NOT NULL,
        first_sample_time DATETIME2(3) NULL,
        last_sample_time DATETIME2(3) NULL,
        source_min_fact_id BIGINT NULL,
        source_max_fact_id BIGINT NULL,
        dws_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWS_battery_hourly_load_time] DEFAULT SYSDATETIME(),
        dws_batch_id BIGINT NULL,
        CONSTRAINT [PK_DWS_dws_robot_battery_hourly] PRIMARY KEY CLUSTERED ([battery_hourly_id])
    );
END;
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE [object_id] = OBJECT_ID(N'[DWS].[dws_robot_battery_hourly]')
      AND [name] = N'UX_DWS_robot_battery_hourly_robot_hour'
)
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX [UX_DWS_robot_battery_hourly_robot_hour]
        ON [DWS].[dws_robot_battery_hourly] ([robot_code], [stat_hour]);
END;
GO

IF OBJECT_ID(N'[DWS].[dws_robot_status_hourly]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWS].[dws_robot_status_hourly] (
        status_hourly_id BIGINT IDENTITY(1,1) NOT NULL,
        stat_hour DATETIME2(0) NOT NULL,
        robot_code NVARCHAR(100) NOT NULL,
        robot_id NVARCHAR(100) NULL,
        sample_count BIGINT NOT NULL,
        online_sample_count BIGINT NOT NULL,
        error_sample_count BIGINT NOT NULL,
        avg_speed_mps DECIMAL(18,6) NULL,
        max_speed_mps DECIMAL(18,6) NULL,
        first_status_time DATETIME2(3) NULL,
        last_status_time DATETIME2(3) NULL,
        source_min_fact_id BIGINT NULL,
        source_max_fact_id BIGINT NULL,
        dws_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWS_status_hourly_load_time] DEFAULT SYSDATETIME(),
        dws_batch_id BIGINT NULL,
        CONSTRAINT [PK_DWS_dws_robot_status_hourly] PRIMARY KEY CLUSTERED ([status_hourly_id])
    );
END;
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE [object_id] = OBJECT_ID(N'[DWS].[dws_robot_status_hourly]')
      AND [name] = N'UX_DWS_robot_status_hourly_robot_hour'
)
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX [UX_DWS_robot_status_hourly_robot_hour]
        ON [DWS].[dws_robot_status_hourly] ([robot_code], [stat_hour]);
END;
GO

IF OBJECT_ID(N'[DWS].[dws_robot_wifi_hourly]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWS].[dws_robot_wifi_hourly] (
        wifi_hourly_id BIGINT IDENTITY(1,1) NOT NULL,
        stat_hour DATETIME2(0) NOT NULL,
        robot_code NVARCHAR(100) NOT NULL,
        robot_id NVARCHAR(100) NULL,
        sample_count BIGINT NOT NULL,
        avg_rssi DECIMAL(18,6) NULL,
        min_rssi DECIMAL(18,6) NULL,
        max_rssi DECIMAL(18,6) NULL,
        weak_signal_sample_count BIGINT NOT NULL,
        first_sample_time DATETIME2(3) NULL,
        last_sample_time DATETIME2(3) NULL,
        source_min_fact_id BIGINT NULL,
        source_max_fact_id BIGINT NULL,
        dws_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWS_wifi_hourly_load_time] DEFAULT SYSDATETIME(),
        dws_batch_id BIGINT NULL,
        CONSTRAINT [PK_DWS_dws_robot_wifi_hourly] PRIMARY KEY CLUSTERED ([wifi_hourly_id])
    );
END;
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE [object_id] = OBJECT_ID(N'[DWS].[dws_robot_wifi_hourly]')
      AND [name] = N'UX_DWS_robot_wifi_hourly_robot_hour'
)
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX [UX_DWS_robot_wifi_hourly_robot_hour]
        ON [DWS].[dws_robot_wifi_hourly] ([robot_code], [stat_hour]);
END;
GO

IF OBJECT_ID(N'[DWS].[dws_robot_job_daily]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWS].[dws_robot_job_daily] (
        job_daily_id BIGINT IDENTITY(1,1) NOT NULL,
        stat_date DATE NOT NULL,
        robot_code NVARCHAR(100) NOT NULL,
        robot_id NVARCHAR(100) NULL,
        job_type_code NVARCHAR(100) NULL,
        robot_mode_id NVARCHAR(100) NULL,
        robot_mode_detail NVARCHAR(200) NULL,
        job_count BIGINT NOT NULL,
        distinct_job_count BIGINT NOT NULL,
        completed_status_count BIGINT NOT NULL,
        failed_status_count BIGINT NOT NULL,
        first_job_start_time DATETIME2(3) NULL,
        last_job_start_time DATETIME2(3) NULL,
        source_min_fact_id BIGINT NULL,
        source_max_fact_id BIGINT NULL,
        dws_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWS_job_daily_load_time] DEFAULT SYSDATETIME(),
        dws_batch_id BIGINT NULL,
        CONSTRAINT [PK_DWS_dws_robot_job_daily] PRIMARY KEY CLUSTERED ([job_daily_id])
    );
END;
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE [object_id] = OBJECT_ID(N'[DWS].[dws_robot_job_daily]')
      AND [name] = N'UX_DWS_robot_job_daily_robot_date_type'
)
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX [UX_DWS_robot_job_daily_robot_date_type]
        ON [DWS].[dws_robot_job_daily] ([robot_code], [stat_date], [job_type_code], [robot_mode_id]);
END;
GO

IF OBJECT_ID(N'[DWS].[dws_amr_queue_daily]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWS].[dws_amr_queue_daily] (
        queue_daily_id BIGINT IDENTITY(1,1) NOT NULL,
        stat_date DATE NOT NULL,
        robot_code NVARCHAR(100) NOT NULL,
        robot_id NVARCHAR(100) NULL,
        project_code NVARCHAR(100) NULL,
        queue_count BIGINT NOT NULL,
        distinct_queue_count BIGINT NOT NULL,
        completed_status_count BIGINT NOT NULL,
        failed_status_count BIGINT NOT NULL,
        avg_duration_seconds DECIMAL(18,6) NULL,
        first_event_time DATETIME2(3) NULL,
        last_event_time DATETIME2(3) NULL,
        source_min_fact_id BIGINT NULL,
        source_max_fact_id BIGINT NULL,
        dws_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWS_queue_daily_load_time] DEFAULT SYSDATETIME(),
        dws_batch_id BIGINT NULL,
        CONSTRAINT [PK_DWS_dws_amr_queue_daily] PRIMARY KEY CLUSTERED ([queue_daily_id])
    );
END;
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE [object_id] = OBJECT_ID(N'[DWS].[dws_amr_queue_daily]')
      AND [name] = N'UX_DWS_amr_queue_daily_robot_date_project'
)
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX [UX_DWS_amr_queue_daily_robot_date_project]
        ON [DWS].[dws_amr_queue_daily] ([robot_code], [stat_date], [project_code]);
END;
GO

IF OBJECT_ID(N'[DWS].[dws_robot_current_snapshot]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWS].[dws_robot_current_snapshot] (
        current_snapshot_id BIGINT IDENTITY(1,1) NOT NULL,
        robot_code NVARCHAR(100) NOT NULL,
        robot_id NVARCHAR(100) NULL,
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
        source_snapshot_time DATETIME2(3) NULL,
        dws_load_time DATETIME2(3) NOT NULL
            CONSTRAINT [DF_DWS_current_snapshot_load_time] DEFAULT SYSDATETIME(),
        dws_batch_id BIGINT NULL,
        CONSTRAINT [PK_DWS_dws_robot_current_snapshot] PRIMARY KEY CLUSTERED ([current_snapshot_id])
    );
END;
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE [object_id] = OBJECT_ID(N'[DWS].[dws_robot_current_snapshot]')
      AND [name] = N'UX_DWS_robot_current_snapshot_robot'
)
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX [UX_DWS_robot_current_snapshot_robot]
        ON [DWS].[dws_robot_current_snapshot] ([robot_code]);
END;
GO
