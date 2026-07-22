USE [IOT2020];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
    Install the core ETL freshness monitor.

    Scope:
      - dbo -> ODS for the four high-volume robot history tables.
      - ODS -> DWD for the matching four fact tables.
      - DWD -> DWS for the matching hourly/daily aggregates.

    Safety:
      - Does not update or delete warehouse business data.
      - Writes only to DWS.etl_freshness_log.
      - estimated_rows_behind is an ID/watermark difference, not an exact COUNT_BIG difference.
*/

IF SCHEMA_ID(N'DWS') IS NULL
BEGIN
    EXEC(N'CREATE SCHEMA [DWS]');
END;
GO

IF OBJECT_ID(N'[DWS].[etl_freshness_log]', N'U') IS NULL
BEGIN
    CREATE TABLE [DWS].[etl_freshness_log]
    (
        [freshness_log_id] BIGINT IDENTITY(1, 1) NOT NULL,
        [check_batch_id] UNIQUEIDENTIFIER NOT NULL,
        [check_time] DATETIME2(3) NOT NULL,
        [pipeline_layer] NVARCHAR(10) NOT NULL,
        [source_schema] SYSNAME NOT NULL,
        [source_table] SYSNAME NOT NULL,
        [target_schema] SYSNAME NOT NULL,
        [target_table] SYSNAME NOT NULL,
        [source_max_id] BIGINT NULL,
        [target_watermark] BIGINT NULL,
        [estimated_rows_behind] BIGINT NULL,
        [source_max_time] DATETIME2(3) NULL,
        [target_max_time] DATETIME2(3) NULL,
        [source_age_minutes] INT NULL,
        [target_age_minutes] INT NULL,
        [freshness_minutes] INT NULL,
        [threshold_minutes] INT NOT NULL,
        [freshness_status] NVARCHAR(10) NOT NULL,
        [status_detail] NVARCHAR(4000) NULL,
        CONSTRAINT [PK_DWS_etl_freshness_log]
            PRIMARY KEY CLUSTERED ([freshness_log_id]),
        CONSTRAINT [CK_DWS_etl_freshness_log_status]
            CHECK ([freshness_status] IN (N'SUCCESS', N'STALE', N'FAILED')),
        CONSTRAINT [CK_DWS_etl_freshness_log_threshold]
            CHECK ([threshold_minutes] > 0)
    );
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE [object_id] = OBJECT_ID(N'[DWS].[etl_freshness_log]')
      AND [name] = N'IX_DWS_etl_freshness_log_latest'
)
BEGIN
    CREATE NONCLUSTERED INDEX [IX_DWS_etl_freshness_log_latest]
        ON [DWS].[etl_freshness_log]
        (
            [pipeline_layer],
            [source_table],
            [target_table],
            [check_time] DESC,
            [freshness_log_id] DESC
        )
        INCLUDE
        (
            [freshness_status],
            [estimated_rows_behind],
            [freshness_minutes],
            [threshold_minutes],
            [status_detail]
        );
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE [object_id] = OBJECT_ID(N'[DWS].[etl_freshness_log]')
      AND [name] = N'IX_DWS_etl_freshness_log_alert'
)
BEGIN
    CREATE NONCLUSTERED INDEX [IX_DWS_etl_freshness_log_alert]
        ON [DWS].[etl_freshness_log]
        (
            [freshness_status],
            [check_time] DESC
        )
        INCLUDE
        (
            [pipeline_layer],
            [source_table],
            [target_table],
            [estimated_rows_behind],
            [freshness_minutes],
            [threshold_minutes]
        );
END;
GO

CREATE OR ALTER PROCEDURE [DWS].[sp_check_etl_freshness]
    @ods_threshold_minutes INT = 10,
    @dwd_threshold_minutes INT = 20,
    @dws_threshold_minutes INT = 30,
    @fail_on_stale BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ods_threshold_minutes <= 0
       OR @dwd_threshold_minutes <= 0
       OR @dws_threshold_minutes <= 0
    BEGIN
        RAISERROR(N'Freshness thresholds must be positive minute values.', 16, 1);
        RETURN;
    END;

    DECLARE
        @check_batch_id UNIQUEIDENTIFIER = NEWID(),
        @check_time DATETIME2(3) = SYSDATETIME();

    DECLARE @metrics TABLE
    (
        [pipeline_layer] NVARCHAR(10) NOT NULL,
        [source_schema] SYSNAME NOT NULL,
        [source_table] SYSNAME NOT NULL,
        [target_schema] SYSNAME NOT NULL,
        [target_table] SYSNAME NOT NULL,
        [source_max_id] BIGINT NULL,
        [target_watermark] BIGINT NULL,
        [source_max_time] DATETIME2(3) NULL,
        [target_max_time] DATETIME2(3) NULL,
        [threshold_minutes] INT NOT NULL
    );

    BEGIN TRY
        /* dbo -> ODS */
        INSERT INTO @metrics
        (
            [pipeline_layer], [source_schema], [source_table],
            [target_schema], [target_table], [source_max_id],
            [target_watermark], [source_max_time], [target_max_time],
            [threshold_minutes]
        )
        SELECT
            N'ODS', N'dbo', N'robot_battery_history',
            N'ODS', N'robot_battery_history',
            (SELECT MAX([id]) FROM [dbo].[robot_battery_history]),
            (SELECT MAX([last_bigint_value]) FROM [ODS].[etl_watermark]
             WHERE [source_schema] = N'dbo' AND [source_table] = N'robot_battery_history'
               AND [target_schema] = N'ODS' AND [target_table] = N'robot_battery_history'
               AND [is_enabled] = 1),
            (SELECT TOP (1) [pc_timestamp] FROM [dbo].[robot_battery_history] ORDER BY [id] DESC),
            (SELECT TOP (1) [pc_timestamp] FROM [ODS].[robot_battery_history] ORDER BY [ods_row_id] DESC),
            @ods_threshold_minutes
        UNION ALL
        SELECT
            N'ODS', N'dbo', N'robot_job_history',
            N'ODS', N'robot_job_history',
            (SELECT MAX([id]) FROM [dbo].[robot_job_history]),
            (SELECT MAX([last_bigint_value]) FROM [ODS].[etl_watermark]
             WHERE [source_schema] = N'dbo' AND [source_table] = N'robot_job_history'
               AND [target_schema] = N'ODS' AND [target_table] = N'robot_job_history'
               AND [is_enabled] = 1),
            (SELECT TOP (1) [pc_timestamp] FROM [dbo].[robot_job_history] ORDER BY [id] DESC),
            (SELECT TOP (1) [pc_timestamp] FROM [ODS].[robot_job_history] ORDER BY [ods_row_id] DESC),
            @ods_threshold_minutes
        UNION ALL
        SELECT
            N'ODS', N'dbo', N'robot_status_history',
            N'ODS', N'robot_status_history',
            (SELECT MAX([id]) FROM [dbo].[robot_status_history]),
            (SELECT MAX([last_bigint_value]) FROM [ODS].[etl_watermark]
             WHERE [source_schema] = N'dbo' AND [source_table] = N'robot_status_history'
               AND [target_schema] = N'ODS' AND [target_table] = N'robot_status_history'
               AND [is_enabled] = 1),
            (SELECT TOP (1) [pc_timestamp] FROM [dbo].[robot_status_history] ORDER BY [id] DESC),
            (SELECT TOP (1) [pc_timestamp] FROM [ODS].[robot_status_history] ORDER BY [ods_row_id] DESC),
            @ods_threshold_minutes
        UNION ALL
        SELECT
            N'ODS', N'dbo', N'robot_wifi_history',
            N'ODS', N'robot_wifi_history',
            (SELECT MAX([id]) FROM [dbo].[robot_wifi_history]),
            (SELECT MAX([last_bigint_value]) FROM [ODS].[etl_watermark]
             WHERE [source_schema] = N'dbo' AND [source_table] = N'robot_wifi_history'
               AND [target_schema] = N'ODS' AND [target_table] = N'robot_wifi_history'
               AND [is_enabled] = 1),
            (SELECT TOP (1) [pc_timestamp] FROM [dbo].[robot_wifi_history] ORDER BY [id] DESC),
            (SELECT TOP (1) [pc_timestamp] FROM [ODS].[robot_wifi_history] ORDER BY [ods_row_id] DESC),
            @ods_threshold_minutes;

        /* ODS -> DWD */
        INSERT INTO @metrics
        (
            [pipeline_layer], [source_schema], [source_table],
            [target_schema], [target_table], [source_max_id],
            [target_watermark], [source_max_time], [target_max_time],
            [threshold_minutes]
        )
        SELECT
            N'DWD', N'ODS', N'robot_battery_history',
            N'DWD', N'fact_robot_battery',
            (SELECT MAX([ods_row_id]) FROM [ODS].[robot_battery_history]),
            (SELECT MAX([last_bigint_value]) FROM [DWD].[etl_watermark]
             WHERE [source_schema] = N'ODS' AND [source_table] = N'robot_battery_history'
               AND [target_schema] = N'DWD' AND [target_table] = N'fact_robot_battery'
               AND [is_enabled] = 1),
            (SELECT TOP (1) [pc_timestamp] FROM [ODS].[robot_battery_history] ORDER BY [ods_row_id] DESC),
            (SELECT TOP (1) o.[pc_timestamp]
             FROM [ODS].[robot_battery_history] AS o
             WHERE o.[ods_row_id] <=
             (
                 SELECT MAX(w.[last_bigint_value])
                 FROM [DWD].[etl_watermark] AS w
                 WHERE w.[source_schema] = N'ODS' AND w.[source_table] = N'robot_battery_history'
                   AND w.[target_schema] = N'DWD' AND w.[target_table] = N'fact_robot_battery'
                   AND w.[is_enabled] = 1
             )
             ORDER BY o.[ods_row_id] DESC),
            @dwd_threshold_minutes
        UNION ALL
        SELECT
            N'DWD', N'ODS', N'robot_job_history',
            N'DWD', N'fact_robot_job',
            (SELECT MAX([ods_row_id]) FROM [ODS].[robot_job_history]),
            (SELECT MAX([last_bigint_value]) FROM [DWD].[etl_watermark]
             WHERE [source_schema] = N'ODS' AND [source_table] = N'robot_job_history'
               AND [target_schema] = N'DWD' AND [target_table] = N'fact_robot_job'
               AND [is_enabled] = 1),
            (SELECT TOP (1) [pc_timestamp] FROM [ODS].[robot_job_history] ORDER BY [ods_row_id] DESC),
            (SELECT TOP (1) o.[pc_timestamp]
             FROM [ODS].[robot_job_history] AS o
             WHERE o.[ods_row_id] <=
             (
                 SELECT MAX(w.[last_bigint_value])
                 FROM [DWD].[etl_watermark] AS w
                 WHERE w.[source_schema] = N'ODS' AND w.[source_table] = N'robot_job_history'
                   AND w.[target_schema] = N'DWD' AND w.[target_table] = N'fact_robot_job'
                   AND w.[is_enabled] = 1
             )
             ORDER BY o.[ods_row_id] DESC),
            @dwd_threshold_minutes
        UNION ALL
        SELECT
            N'DWD', N'ODS', N'robot_status_history',
            N'DWD', N'fact_robot_status',
            (SELECT MAX([ods_row_id]) FROM [ODS].[robot_status_history]),
            (SELECT MAX([last_bigint_value]) FROM [DWD].[etl_watermark]
             WHERE [source_schema] = N'ODS' AND [source_table] = N'robot_status_history'
               AND [target_schema] = N'DWD' AND [target_table] = N'fact_robot_status'
               AND [is_enabled] = 1),
            (SELECT TOP (1) [pc_timestamp] FROM [ODS].[robot_status_history] ORDER BY [ods_row_id] DESC),
            (SELECT TOP (1) o.[pc_timestamp]
             FROM [ODS].[robot_status_history] AS o
             WHERE o.[ods_row_id] <=
             (
                 SELECT MAX(w.[last_bigint_value])
                 FROM [DWD].[etl_watermark] AS w
                 WHERE w.[source_schema] = N'ODS' AND w.[source_table] = N'robot_status_history'
                   AND w.[target_schema] = N'DWD' AND w.[target_table] = N'fact_robot_status'
                   AND w.[is_enabled] = 1
             )
             ORDER BY o.[ods_row_id] DESC),
            @dwd_threshold_minutes
        UNION ALL
        SELECT
            N'DWD', N'ODS', N'robot_wifi_history',
            N'DWD', N'fact_robot_wifi',
            (SELECT MAX([ods_row_id]) FROM [ODS].[robot_wifi_history]),
            (SELECT MAX([last_bigint_value]) FROM [DWD].[etl_watermark]
             WHERE [source_schema] = N'ODS' AND [source_table] = N'robot_wifi_history'
               AND [target_schema] = N'DWD' AND [target_table] = N'fact_robot_wifi'
               AND [is_enabled] = 1),
            (SELECT TOP (1) [pc_timestamp] FROM [ODS].[robot_wifi_history] ORDER BY [ods_row_id] DESC),
            (SELECT TOP (1) o.[pc_timestamp]
             FROM [ODS].[robot_wifi_history] AS o
             WHERE o.[ods_row_id] <=
             (
                 SELECT MAX(w.[last_bigint_value])
                 FROM [DWD].[etl_watermark] AS w
                 WHERE w.[source_schema] = N'ODS' AND w.[source_table] = N'robot_wifi_history'
                   AND w.[target_schema] = N'DWD' AND w.[target_table] = N'fact_robot_wifi'
                   AND w.[is_enabled] = 1
             )
             ORDER BY o.[ods_row_id] DESC),
            @dwd_threshold_minutes;

        /* DWD -> DWS */
        INSERT INTO @metrics
        (
            [pipeline_layer], [source_schema], [source_table],
            [target_schema], [target_table], [source_max_id],
            [target_watermark], [source_max_time], [target_max_time],
            [threshold_minutes]
        )
        SELECT
            N'DWS', N'DWD', N'fact_robot_battery',
            N'DWS', N'dws_robot_battery_hourly',
            (SELECT MAX([battery_fact_id]) FROM [DWD].[fact_robot_battery]),
            (SELECT MAX([source_max_fact_id]) FROM [DWS].[dws_robot_battery_hourly]),
            (SELECT TOP (1) [sample_time] FROM [DWD].[fact_robot_battery] ORDER BY [battery_fact_id] DESC),
            (SELECT TOP (1) f.[sample_time]
             FROM [DWD].[fact_robot_battery] AS f
             WHERE f.[battery_fact_id] =
             (SELECT MAX([source_max_fact_id]) FROM [DWS].[dws_robot_battery_hourly])),
            @dws_threshold_minutes
        UNION ALL
        SELECT
            N'DWS', N'DWD', N'fact_robot_job',
            N'DWS', N'dws_robot_job_daily',
            (SELECT MAX([job_fact_id]) FROM [DWD].[fact_robot_job]),
            (SELECT MAX([source_max_fact_id]) FROM [DWS].[dws_robot_job_daily]),
            (SELECT TOP (1) [job_start_time] FROM [DWD].[fact_robot_job] ORDER BY [job_fact_id] DESC),
            (SELECT TOP (1) f.[job_start_time]
             FROM [DWD].[fact_robot_job] AS f
             WHERE f.[job_fact_id] =
             (SELECT MAX([source_max_fact_id]) FROM [DWS].[dws_robot_job_daily])),
            @dws_threshold_minutes
        UNION ALL
        SELECT
            N'DWS', N'DWD', N'fact_robot_status',
            N'DWS', N'dws_robot_status_hourly',
            (SELECT MAX([status_fact_id]) FROM [DWD].[fact_robot_status]),
            (SELECT MAX([source_max_fact_id]) FROM [DWS].[dws_robot_status_hourly]),
            (SELECT TOP (1) [status_time] FROM [DWD].[fact_robot_status] ORDER BY [status_fact_id] DESC),
            (SELECT TOP (1) f.[status_time]
             FROM [DWD].[fact_robot_status] AS f
             WHERE f.[status_fact_id] =
             (SELECT MAX([source_max_fact_id]) FROM [DWS].[dws_robot_status_hourly])),
            @dws_threshold_minutes
        UNION ALL
        SELECT
            N'DWS', N'DWD', N'fact_robot_wifi',
            N'DWS', N'dws_robot_wifi_hourly',
            (SELECT MAX([wifi_fact_id]) FROM [DWD].[fact_robot_wifi]),
            (SELECT MAX([source_max_fact_id]) FROM [DWS].[dws_robot_wifi_hourly]),
            (SELECT TOP (1) [sample_time] FROM [DWD].[fact_robot_wifi] ORDER BY [wifi_fact_id] DESC),
            (SELECT TOP (1) f.[sample_time]
             FROM [DWD].[fact_robot_wifi] AS f
             WHERE f.[wifi_fact_id] =
             (SELECT MAX([source_max_fact_id]) FROM [DWS].[dws_robot_wifi_hourly])),
            @dws_threshold_minutes;

        ;WITH calculated AS
        (
            SELECT
                m.[pipeline_layer],
                m.[source_schema],
                m.[source_table],
                m.[target_schema],
                m.[target_table],
                m.[source_max_id],
                m.[target_watermark],
                CASE
                    WHEN m.[source_max_id] IS NULL OR m.[target_watermark] IS NULL THEN NULL
                    WHEN m.[source_max_id] > m.[target_watermark]
                        THEN m.[source_max_id] - m.[target_watermark]
                    ELSE CONVERT(BIGINT, 0)
                END AS [estimated_rows_behind],
                m.[source_max_time],
                m.[target_max_time],
                CASE
                    WHEN m.[source_max_time] IS NULL THEN NULL
                    WHEN m.[source_max_time] >= @check_time THEN 0
                    ELSE DATEDIFF(MINUTE, m.[source_max_time], @check_time)
                END AS [source_age_minutes],
                CASE
                    WHEN m.[target_max_time] IS NULL THEN NULL
                    WHEN m.[target_max_time] >= @check_time THEN 0
                    ELSE DATEDIFF(MINUTE, m.[target_max_time], @check_time)
                END AS [target_age_minutes],
                CASE
                    WHEN m.[source_max_time] IS NULL OR m.[target_max_time] IS NULL THEN NULL
                    WHEN m.[source_max_time] <= m.[target_max_time] THEN 0
                    ELSE DATEDIFF(MINUTE, m.[target_max_time], m.[source_max_time])
                END AS [freshness_minutes],
                m.[threshold_minutes]
            FROM @metrics AS m
        ),
        evaluated AS
        (
            SELECT
                c.*,
                CASE
                    WHEN c.[source_max_id] IS NULL THEN N'FAILED'
                    WHEN c.[target_watermark] IS NULL THEN N'FAILED'
                    WHEN c.[target_watermark] > c.[source_max_id] THEN N'FAILED'
                    WHEN c.[source_max_time] IS NULL THEN N'FAILED'
                    WHEN c.[target_max_time] IS NULL THEN N'FAILED'
                    WHEN c.[estimated_rows_behind] > 0 THEN N'STALE'
                    WHEN c.[freshness_minutes] > c.[threshold_minutes] THEN N'STALE'
                    WHEN c.[source_age_minutes] > c.[threshold_minutes] THEN N'STALE'
                    ELSE N'SUCCESS'
                END AS [freshness_status],
                CASE
                    WHEN c.[source_max_id] IS NULL THEN N'Source watermark is unavailable.'
                    WHEN c.[target_watermark] IS NULL THEN N'Target watermark is unavailable.'
                    WHEN c.[target_watermark] > c.[source_max_id] THEN N'Target watermark is greater than the source maximum ID.'
                    WHEN c.[source_max_time] IS NULL THEN N'Source event time is unavailable.'
                    WHEN c.[target_max_time] IS NULL THEN N'Target event time is unavailable.'
                    WHEN c.[estimated_rows_behind] > 0 THEN N'Target watermark is behind the source maximum ID.'
                    WHEN c.[freshness_minutes] > c.[threshold_minutes] THEN N'Target event time is behind the source event time.'
                    WHEN c.[source_age_minutes] > c.[threshold_minutes] THEN N'Source data is older than the configured threshold.'
                    ELSE N'Source and target watermarks are within the configured threshold.'
                END AS [status_detail]
            FROM calculated AS c
        )
        INSERT INTO [DWS].[etl_freshness_log]
        (
            [check_batch_id], [check_time], [pipeline_layer],
            [source_schema], [source_table], [target_schema], [target_table],
            [source_max_id], [target_watermark], [estimated_rows_behind],
            [source_max_time], [target_max_time], [source_age_minutes],
            [target_age_minutes], [freshness_minutes], [threshold_minutes],
            [freshness_status], [status_detail]
        )
        SELECT
            @check_batch_id, @check_time, e.[pipeline_layer],
            e.[source_schema], e.[source_table], e.[target_schema], e.[target_table],
            e.[source_max_id], e.[target_watermark], e.[estimated_rows_behind],
            e.[source_max_time], e.[target_max_time], e.[source_age_minutes],
            e.[target_age_minutes], e.[freshness_minutes], e.[threshold_minutes],
            e.[freshness_status], e.[status_detail]
        FROM evaluated AS e;
    END TRY
    BEGIN CATCH
        INSERT INTO [DWS].[etl_freshness_log]
        (
            [check_batch_id], [check_time], [pipeline_layer],
            [source_schema], [source_table], [target_schema], [target_table],
            [threshold_minutes], [freshness_status], [status_detail]
        )
        VALUES
        (
            @check_batch_id, @check_time, N'MONITOR',
            N'DWS', N'sp_check_etl_freshness', N'DWS', N'etl_freshness_log',
            @dws_threshold_minutes, N'FAILED', ERROR_MESSAGE()
        );
    END CATCH;

    SELECT
        [freshness_log_id], [check_batch_id], [check_time], [pipeline_layer],
        [source_schema], [source_table], [target_schema], [target_table],
        [source_max_id], [target_watermark], [estimated_rows_behind],
        [source_max_time], [target_max_time], [source_age_minutes],
        [target_age_minutes], [freshness_minutes], [threshold_minutes],
        [freshness_status], [status_detail]
    FROM [DWS].[etl_freshness_log]
    WHERE [check_batch_id] = @check_batch_id
    ORDER BY
        CASE [freshness_status]
            WHEN N'FAILED' THEN 1
            WHEN N'STALE' THEN 2
            ELSE 3
        END,
        [pipeline_layer], [source_table], [target_table];

    SELECT
        [pipeline_layer], [source_table], [target_table],
        [estimated_rows_behind], [freshness_minutes], [threshold_minutes],
        [freshness_status], [status_detail]
    FROM [DWS].[etl_freshness_log]
    WHERE [check_batch_id] = @check_batch_id
      AND [freshness_status] IN (N'STALE', N'FAILED')
    ORDER BY
        CASE [freshness_status] WHEN N'FAILED' THEN 1 ELSE 2 END,
        [pipeline_layer], [source_table], [target_table];

    /*
        SQL Server Agent can set @fail_on_stale = 1. Results are persisted
        before the error is raised, so the failed job remains diagnosable.
    */
    IF @fail_on_stale = 1
       AND EXISTS
       (
           SELECT 1
           FROM [DWS].[etl_freshness_log]
           WHERE [check_batch_id] = @check_batch_id
             AND [freshness_status] IN (N'STALE', N'FAILED')
       )
    BEGIN
        RAISERROR(N'ETL freshness monitor detected one or more STALE or FAILED pipeline steps.', 16, 1);
        RETURN;
    END;
END;
GO

CREATE OR ALTER VIEW [DWS].[v_etl_freshness_latest]
AS
WITH ranked AS
(
    SELECT
        f.[freshness_log_id],
        f.[check_batch_id],
        f.[check_time],
        f.[pipeline_layer],
        f.[source_schema],
        f.[source_table],
        f.[target_schema],
        f.[target_table],
        f.[source_max_id],
        f.[target_watermark],
        f.[estimated_rows_behind],
        f.[source_max_time],
        f.[target_max_time],
        f.[source_age_minutes],
        f.[target_age_minutes],
        f.[freshness_minutes],
        f.[threshold_minutes],
        f.[freshness_status],
        f.[status_detail],
        ROW_NUMBER() OVER
        (
            PARTITION BY f.[pipeline_layer], f.[source_table], f.[target_table]
            ORDER BY f.[check_time] DESC, f.[freshness_log_id] DESC
        ) AS [row_number]
    FROM [DWS].[etl_freshness_log] AS f
)
SELECT
    [freshness_log_id], [check_batch_id], [check_time], [pipeline_layer],
    [source_schema], [source_table], [target_schema], [target_table],
    [source_max_id], [target_watermark], [estimated_rows_behind],
    [source_max_time], [target_max_time], [source_age_minutes],
    [target_age_minutes], [freshness_minutes], [threshold_minutes],
    [freshness_status], [status_detail]
FROM ranked
WHERE [row_number] = 1;
GO

/* Initial check. This will normally report STALE until automatic jobs catch up. */
EXEC [DWS].[sp_check_etl_freshness]
    @ods_threshold_minutes = 10,
    @dwd_threshold_minutes = 20,
    @dws_threshold_minutes = 30,
    @fail_on_stale = 0;
GO
