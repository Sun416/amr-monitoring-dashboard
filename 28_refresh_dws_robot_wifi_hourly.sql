USE [IOT2020];
GO

/*
    单独刷新 DWS.dws_robot_wifi_hourly。

    RSSI 口径：
    1. RSSI < 0：有效 RSSI，参与平均值、最小值和最大值计算。
    2. RSSI <= -70：弱信号。
    3. RSSI = 0：源系统中的无信号/断连异常值，不参与平均值、最小值和最大值，
       但计入 weak_signal_sample_count。

    本脚本不会删除或清空 DWS 表，只更新已有小时粒度记录并插入新增记录。
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'[DWD].[fact_robot_wifi]', N'U') IS NULL
BEGIN
    RAISERROR(N'Missing source table: DWD.fact_robot_wifi.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'[DWS].[dws_robot_wifi_hourly]', N'U') IS NULL
BEGIN
    RAISERROR(N'Missing target table: DWS.dws_robot_wifi_hourly. Run 25_create_dws_core_tables.sql first.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'[DWS].[etl_batch]', N'U') IS NULL
BEGIN
    RAISERROR(N'Missing table: DWS.etl_batch. Run 25_create_dws_core_tables.sql first.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'[DWS].[etl_load_log]', N'U') IS NULL
BEGIN
    RAISERROR(N'Missing table: DWS.etl_load_log. Run 25_create_dws_core_tables.sql first.', 16, 1);
    RETURN;
END;

/* 执行前预览：确认 DWD RSSI 原始分布。 */
SELECT
    COUNT_BIG(*) AS [total_rows],
    SUM(CASE WHEN fw.[rssi] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [null_rssi_rows],
    SUM(CASE WHEN fw.[rssi] = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [zero_rssi_rows],
    SUM(CASE WHEN fw.[rssi] < 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [valid_negative_rssi_rows],
    SUM(CASE WHEN fw.[rssi] <= -70 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [weak_negative_rssi_rows],
    MIN(CASE WHEN fw.[rssi] < 0 THEN fw.[rssi] END) AS [min_valid_rssi],
    MAX(CASE WHEN fw.[rssi] < 0 THEN fw.[rssi] END) AS [max_valid_rssi],
    AVG(CASE WHEN fw.[rssi] < 0 THEN fw.[rssi] END) AS [avg_valid_rssi]
FROM [DWD].[fact_robot_wifi] AS fw
WHERE fw.[sample_time] IS NOT NULL;

IF OBJECT_ID(N'tempdb..#wifi_hourly_src', N'U') IS NOT NULL
BEGIN
    DROP TABLE #wifi_hourly_src;
END;

CREATE TABLE #wifi_hourly_src (
    [stat_hour] DATETIME2(0) NOT NULL,
    [robot_code] NVARCHAR(100) NOT NULL,
    [robot_id] NVARCHAR(100) NULL,
    [sample_count] BIGINT NOT NULL,
    [avg_rssi] DECIMAL(18,6) NULL,
    [min_rssi] DECIMAL(18,6) NULL,
    [max_rssi] DECIMAL(18,6) NULL,
    [weak_signal_sample_count] BIGINT NOT NULL,
    [first_sample_time] DATETIME2(3) NULL,
    [last_sample_time] DATETIME2(3) NULL,
    [source_min_fact_id] BIGINT NULL,
    [source_max_fact_id] BIGINT NULL,
    PRIMARY KEY CLUSTERED ([robot_code], [stat_hour])
);

/* 先在事务外完成大表聚合，避免长时间占用 DWS 写事务。 */
INSERT INTO #wifi_hourly_src (
    [stat_hour],
    [robot_code],
    [robot_id],
    [sample_count],
    [avg_rssi],
    [min_rssi],
    [max_rssi],
    [weak_signal_sample_count],
    [first_sample_time],
    [last_sample_time],
    [source_min_fact_id],
    [source_max_fact_id]
)
SELECT
    DATEADD(HOUR, DATEDIFF(HOUR, 0, fw.[sample_time]), 0) AS [stat_hour],
    COALESCE(NULLIF(fw.[robot_code], N''), NULLIF(fw.[robot_id], N''), N'UNKNOWN') AS [robot_code],
    MAX(fw.[robot_id]) AS [robot_id],
    COUNT_BIG(*) AS [sample_count],
    AVG(CASE WHEN fw.[rssi] < 0 THEN fw.[rssi] END) AS [avg_rssi],
    MIN(CASE WHEN fw.[rssi] < 0 THEN fw.[rssi] END) AS [min_rssi],
    MAX(CASE WHEN fw.[rssi] < 0 THEN fw.[rssi] END) AS [max_rssi],
    SUM(
        CASE
            WHEN fw.[rssi] = 0 THEN CONVERT(BIGINT, 1)
            WHEN fw.[rssi] <= -70 THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END
    ) AS [weak_signal_sample_count],
    MIN(fw.[sample_time]) AS [first_sample_time],
    MAX(fw.[sample_time]) AS [last_sample_time],
    MIN(fw.[wifi_fact_id]) AS [source_min_fact_id],
    MAX(fw.[wifi_fact_id]) AS [source_max_fact_id]
FROM [DWD].[fact_robot_wifi] AS fw
WHERE fw.[sample_time] IS NOT NULL
GROUP BY
    DATEADD(HOUR, DATEDIFF(HOUR, 0, fw.[sample_time]), 0),
    COALESCE(NULLIF(fw.[robot_code], N''), NULLIF(fw.[robot_id], N''), N'UNKNOWN');

/* 写入前预览：查看即将更新和插入的小时记录数量。 */
SELECT
    COUNT_BIG(*) AS [source_hourly_rows],
    SUM(
        CASE
            WHEN tgt.[wifi_hourly_id] IS NOT NULL THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END
    ) AS [rows_to_update],
    SUM(
        CASE
            WHEN tgt.[wifi_hourly_id] IS NULL THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END
    ) AS [rows_to_insert]
FROM #wifi_hourly_src AS src
LEFT JOIN [DWS].[dws_robot_wifi_hourly] AS tgt
    ON tgt.[robot_code] = src.[robot_code]
   AND tgt.[stat_hour] = src.[stat_hour];

DECLARE
    @batch_id BIGINT,
    @load_start_time DATETIME2(3) = SYSDATETIME(),
    @rows_updated BIGINT = 0,
    @rows_inserted BIGINT = 0,
    @affected_rows BIGINT = 0,
    @error_message NVARCHAR(4000);

INSERT INTO [DWS].[etl_batch] (
    [batch_start_time],
    [batch_status],
    [error_message]
)
VALUES (
    @load_start_time,
    N'RUNNING',
    NULL
);

SET @batch_id = SCOPE_IDENTITY();

BEGIN TRY
    BEGIN TRANSACTION;

    UPDATE tgt
    SET
        tgt.[robot_id] = src.[robot_id],
        tgt.[sample_count] = src.[sample_count],
        tgt.[avg_rssi] = src.[avg_rssi],
        tgt.[min_rssi] = src.[min_rssi],
        tgt.[max_rssi] = src.[max_rssi],
        tgt.[weak_signal_sample_count] = src.[weak_signal_sample_count],
        tgt.[first_sample_time] = src.[first_sample_time],
        tgt.[last_sample_time] = src.[last_sample_time],
        tgt.[source_min_fact_id] = src.[source_min_fact_id],
        tgt.[source_max_fact_id] = src.[source_max_fact_id],
        tgt.[dws_load_time] = SYSDATETIME(),
        tgt.[dws_batch_id] = @batch_id
    FROM [DWS].[dws_robot_wifi_hourly] AS tgt
    INNER JOIN #wifi_hourly_src AS src
        ON src.[robot_code] = tgt.[robot_code]
       AND src.[stat_hour] = tgt.[stat_hour]
    WHERE tgt.[robot_code] = src.[robot_code]
      AND tgt.[stat_hour] = src.[stat_hour];

    SET @rows_updated = @@ROWCOUNT;

    INSERT INTO [DWS].[dws_robot_wifi_hourly] (
        [stat_hour],
        [robot_code],
        [robot_id],
        [sample_count],
        [avg_rssi],
        [min_rssi],
        [max_rssi],
        [weak_signal_sample_count],
        [first_sample_time],
        [last_sample_time],
        [source_min_fact_id],
        [source_max_fact_id],
        [dws_batch_id]
    )
    SELECT
        src.[stat_hour],
        src.[robot_code],
        src.[robot_id],
        src.[sample_count],
        src.[avg_rssi],
        src.[min_rssi],
        src.[max_rssi],
        src.[weak_signal_sample_count],
        src.[first_sample_time],
        src.[last_sample_time],
        src.[source_min_fact_id],
        src.[source_max_fact_id],
        @batch_id
    FROM #wifi_hourly_src AS src
    WHERE NOT EXISTS (
        SELECT 1
        FROM [DWS].[dws_robot_wifi_hourly] AS tgt WITH (UPDLOCK, HOLDLOCK)
        WHERE tgt.[robot_code] = src.[robot_code]
          AND tgt.[stat_hour] = src.[stat_hour]
    );

    SET @rows_inserted = @@ROWCOUNT;
    SET @affected_rows = @rows_updated + @rows_inserted;

    INSERT INTO [DWS].[etl_load_log] (
        [batch_id],
        [target_schema],
        [target_table],
        [source_schema],
        [source_table],
        [load_mode],
        [affected_rows],
        [load_status],
        [error_message],
        [load_start_time],
        [load_end_time]
    )
    VALUES (
        @batch_id,
        N'DWS',
        N'dws_robot_wifi_hourly',
        N'DWD',
        N'fact_robot_wifi',
        N'UPSERT_FULL_AGG',
        @affected_rows,
        N'SUCCESS',
        NULL,
        @load_start_time,
        SYSDATETIME()
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
    BEGIN
        ROLLBACK TRANSACTION;
    END;

    SET @error_message = CONCAT(
        N'Error ',
        ERROR_NUMBER(),
        N', line ',
        ERROR_LINE(),
        N': ',
        ERROR_MESSAGE()
    );

    UPDATE [DWS].[etl_batch]
    SET
        [batch_end_time] = SYSDATETIME(),
        [batch_status] = N'FAILED',
        [error_message] = @error_message
    WHERE [batch_id] = @batch_id;

    RAISERROR(@error_message, 16, 1);
    RETURN;
END CATCH;

/* 执行后验证 1：本次批次和日志。 */
SELECT
    b.[batch_id],
    b.[batch_start_time],
    b.[batch_end_time],
    b.[batch_status],
    b.[error_message]
FROM [DWS].[etl_batch] AS b
WHERE b.[batch_id] = @batch_id;

SELECT
    l.[load_id],
    l.[batch_id],
    l.[source_schema],
    l.[source_table],
    l.[target_schema],
    l.[target_table],
    l.[load_mode],
    l.[affected_rows],
    l.[load_status],
    l.[error_message],
    l.[load_start_time],
    l.[load_end_time]
FROM [DWS].[etl_load_log] AS l
WHERE l.[batch_id] = @batch_id
ORDER BY l.[load_id];

/* 执行后验证 2：检查新口径是否生效。 */
SELECT
    COUNT_BIG(*) AS [dws_hourly_rows],
    SUM(CASE WHEN wh.[avg_rssi] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [no_valid_negative_rssi_hour_rows],
    SUM(CASE WHEN wh.[avg_rssi] = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [avg_rssi_zero_rows],
    SUM(CASE WHEN wh.[min_rssi] = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [min_rssi_zero_rows],
    SUM(CASE WHEN wh.[max_rssi] = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [max_rssi_zero_rows],
    SUM(CASE WHEN wh.[weak_signal_sample_count] > 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [hour_rows_with_weak_or_zero_signal]
FROM [DWS].[dws_robot_wifi_hourly] AS wh;

SELECT TOP (100)
    wh.[stat_hour],
    wh.[robot_code],
    wh.[robot_id],
    wh.[sample_count],
    wh.[avg_rssi],
    wh.[min_rssi],
    wh.[max_rssi],
    wh.[weak_signal_sample_count],
    wh.[first_sample_time],
    wh.[last_sample_time],
    wh.[dws_load_time],
    wh.[dws_batch_id]
FROM [DWS].[dws_robot_wifi_hourly] AS wh
ORDER BY
    wh.[stat_hour] DESC,
    wh.[robot_code];
GO
