USE IOT2020;
GO

CREATE OR ALTER PROCEDURE [DWS].[sp_load_dws_core_upsert]
    @include_current_snapshot BIT = 1
AS
BEGIN
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'[DWS].[etl_batch]', N'U') IS NULL
BEGIN
    PRINT N'Missing table: DWS.etl_batch. Run 25_create_dws_core_tables.sql first.';
    RETURN;
END;

IF OBJECT_ID(N'[DWD].[fact_robot_battery]', N'U') IS NULL
   OR OBJECT_ID(N'[DWD].[fact_robot_status]', N'U') IS NULL
   OR OBJECT_ID(N'[DWD].[fact_robot_wifi]', N'U') IS NULL
   OR OBJECT_ID(N'[DWD].[fact_robot_job]', N'U') IS NULL
   OR OBJECT_ID(N'[DWD].[fact_amr_queue]', N'U') IS NULL
   OR OBJECT_ID(N'[DWD].[snap_amr_current_status]', N'U') IS NULL
BEGIN
    PRINT N'Missing one or more required DWD source tables.';
    RETURN;
END;

DECLARE
    @batch_id BIGINT,
    @lock_result INT,
    @step_start_time DATETIME2(3),
    @affected_rows BIGINT,
    @queue_metric_rows BIGINT,
    @error_message NVARCHAR(4000);

EXEC @lock_result = sys.sp_getapplock
    @Resource = N'DWS.sp_load_dws_core_upsert',
    @LockMode = N'Exclusive',
    @LockOwner = N'Session',
    @LockTimeout = 0;

IF @lock_result < 0
BEGIN
    RAISERROR(N'DWS aggregate load is already running. Retry later.', 16, 1);
    RETURN;
END;

BEGIN TRY
INSERT INTO [DWS].[etl_batch] (
    [batch_start_time],
    [batch_status],
    [error_message]
)
VALUES (
    SYSDATETIME(),
    N'RUNNING',
    NULL
);

SET @batch_id = SCOPE_IDENTITY();

    SET @step_start_time = SYSDATETIME();

    ;WITH src AS (
        SELECT
            DATEADD(HOUR, DATEDIFF(HOUR, 0, fb.[sample_time]), 0) AS [stat_hour],
            COALESCE(NULLIF(fb.[robot_code], N''), NULLIF(fb.[robot_id], N''), N'UNKNOWN') AS [robot_code],
            MAX(fb.[robot_id]) AS [robot_id],
            COUNT_BIG(*) AS [sample_count],
            AVG(fb.[battery_soc]) AS [avg_battery_soc],
            MIN(fb.[battery_soc]) AS [min_battery_soc],
            MAX(fb.[battery_soc]) AS [max_battery_soc],
            AVG(fb.[battery_voltage]) AS [avg_battery_voltage],
            AVG(fb.[battery_current]) AS [avg_battery_current],
            AVG(fb.[battery_power]) AS [avg_battery_power],
            SUM(
                CASE
                    WHEN fb.[charging_status] LIKE N'%充%'
                      OR LOWER(fb.[charging_status]) LIKE N'%charg%'
                      OR LOWER(fb.[charging_status]) IN (N'1', N'true', N'yes')
                    THEN 1
                    ELSE 0
                END
            ) AS [charging_sample_count],
            MIN(fb.[sample_time]) AS [first_sample_time],
            MAX(fb.[sample_time]) AS [last_sample_time],
            MIN(fb.[battery_fact_id]) AS [source_min_fact_id],
            MAX(fb.[battery_fact_id]) AS [source_max_fact_id]
        FROM [DWD].[fact_robot_battery] AS fb
        WHERE fb.[sample_time] IS NOT NULL
        GROUP BY
            DATEADD(HOUR, DATEDIFF(HOUR, 0, fb.[sample_time]), 0),
            COALESCE(NULLIF(fb.[robot_code], N''), NULLIF(fb.[robot_id], N''), N'UNKNOWN')
    )
    MERGE [DWS].[dws_robot_battery_hourly] AS tgt
    USING src
        ON tgt.[robot_code] = src.[robot_code]
       AND tgt.[stat_hour] = src.[stat_hour]
    WHEN MATCHED THEN
        UPDATE SET
            tgt.[robot_id] = src.[robot_id],
            tgt.[sample_count] = src.[sample_count],
            tgt.[avg_battery_soc] = src.[avg_battery_soc],
            tgt.[min_battery_soc] = src.[min_battery_soc],
            tgt.[max_battery_soc] = src.[max_battery_soc],
            tgt.[avg_battery_voltage] = src.[avg_battery_voltage],
            tgt.[avg_battery_current] = src.[avg_battery_current],
            tgt.[avg_battery_power] = src.[avg_battery_power],
            tgt.[charging_sample_count] = src.[charging_sample_count],
            tgt.[first_sample_time] = src.[first_sample_time],
            tgt.[last_sample_time] = src.[last_sample_time],
            tgt.[source_min_fact_id] = src.[source_min_fact_id],
            tgt.[source_max_fact_id] = src.[source_max_fact_id],
            tgt.[dws_load_time] = SYSDATETIME(),
            tgt.[dws_batch_id] = @batch_id
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (
            [stat_hour],
            [robot_code],
            [robot_id],
            [sample_count],
            [avg_battery_soc],
            [min_battery_soc],
            [max_battery_soc],
            [avg_battery_voltage],
            [avg_battery_current],
            [avg_battery_power],
            [charging_sample_count],
            [first_sample_time],
            [last_sample_time],
            [source_min_fact_id],
            [source_max_fact_id],
            [dws_batch_id]
        )
        VALUES (
            src.[stat_hour],
            src.[robot_code],
            src.[robot_id],
            src.[sample_count],
            src.[avg_battery_soc],
            src.[min_battery_soc],
            src.[max_battery_soc],
            src.[avg_battery_voltage],
            src.[avg_battery_current],
            src.[avg_battery_power],
            src.[charging_sample_count],
            src.[first_sample_time],
            src.[last_sample_time],
            src.[source_min_fact_id],
            src.[source_max_fact_id],
            @batch_id
        );

    SET @affected_rows = @@ROWCOUNT;

    INSERT INTO [DWS].[etl_load_log] (
        [batch_id],
        [target_schema],
        [target_table],
        [source_schema],
        [source_table],
        [load_mode],
        [affected_rows],
        [load_status],
        [load_start_time],
        [load_end_time]
    )
    VALUES (
        @batch_id,
        N'DWS',
        N'dws_robot_battery_hourly',
        N'DWD',
        N'fact_robot_battery',
        N'UPSERT_FULL_AGG',
        @affected_rows,
        N'SUCCESS',
        @step_start_time,
        SYSDATETIME()
    );

    SET @step_start_time = SYSDATETIME();

    ;WITH src AS (
        SELECT
            DATEADD(HOUR, DATEDIFF(HOUR, 0, fs.[status_time]), 0) AS [stat_hour],
            COALESCE(NULLIF(fs.[robot_code], N''), NULLIF(fs.[robot_id], N''), N'UNKNOWN') AS [robot_code],
            MAX(fs.[robot_id]) AS [robot_id],
            COUNT_BIG(*) AS [sample_count],
            SUM(
                CASE
                    WHEN fs.[online_status] LIKE N'%在线%'
                      OR LOWER(fs.[online_status]) IN (N'online', N'1', N'true', N'yes')
                    THEN 1
                    ELSE 0
                END
            ) AS [online_sample_count],
            SUM(
                CASE
                    WHEN fs.[error_code] IS NOT NULL
                     AND LTRIM(RTRIM(fs.[error_code])) <> N''
                     AND fs.[error_code] <> N'0'
                    THEN 1
                    ELSE 0
                END
            ) AS [error_sample_count],
            AVG(fs.[speed_mps]) AS [avg_speed_mps],
            MAX(fs.[speed_mps]) AS [max_speed_mps],
            MIN(fs.[status_time]) AS [first_status_time],
            MAX(fs.[status_time]) AS [last_status_time],
            MIN(fs.[status_fact_id]) AS [source_min_fact_id],
            MAX(fs.[status_fact_id]) AS [source_max_fact_id]
        FROM [DWD].[fact_robot_status] AS fs
        WHERE fs.[status_time] IS NOT NULL
        GROUP BY
            DATEADD(HOUR, DATEDIFF(HOUR, 0, fs.[status_time]), 0),
            COALESCE(NULLIF(fs.[robot_code], N''), NULLIF(fs.[robot_id], N''), N'UNKNOWN')
    )
    MERGE [DWS].[dws_robot_status_hourly] AS tgt
    USING src
        ON tgt.[robot_code] = src.[robot_code]
       AND tgt.[stat_hour] = src.[stat_hour]
    WHEN MATCHED THEN
        UPDATE SET
            tgt.[robot_id] = src.[robot_id],
            tgt.[sample_count] = src.[sample_count],
            tgt.[online_sample_count] = src.[online_sample_count],
            tgt.[error_sample_count] = src.[error_sample_count],
            tgt.[avg_speed_mps] = src.[avg_speed_mps],
            tgt.[max_speed_mps] = src.[max_speed_mps],
            tgt.[first_status_time] = src.[first_status_time],
            tgt.[last_status_time] = src.[last_status_time],
            tgt.[source_min_fact_id] = src.[source_min_fact_id],
            tgt.[source_max_fact_id] = src.[source_max_fact_id],
            tgt.[dws_load_time] = SYSDATETIME(),
            tgt.[dws_batch_id] = @batch_id
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (
            [stat_hour],
            [robot_code],
            [robot_id],
            [sample_count],
            [online_sample_count],
            [error_sample_count],
            [avg_speed_mps],
            [max_speed_mps],
            [first_status_time],
            [last_status_time],
            [source_min_fact_id],
            [source_max_fact_id],
            [dws_batch_id]
        )
        VALUES (
            src.[stat_hour],
            src.[robot_code],
            src.[robot_id],
            src.[sample_count],
            src.[online_sample_count],
            src.[error_sample_count],
            src.[avg_speed_mps],
            src.[max_speed_mps],
            src.[first_status_time],
            src.[last_status_time],
            src.[source_min_fact_id],
            src.[source_max_fact_id],
            @batch_id
        );

    SET @affected_rows = @@ROWCOUNT;

    INSERT INTO [DWS].[etl_load_log] (
        [batch_id],
        [target_schema],
        [target_table],
        [source_schema],
        [source_table],
        [load_mode],
        [affected_rows],
        [load_status],
        [load_start_time],
        [load_end_time]
    )
    VALUES (
        @batch_id,
        N'DWS',
        N'dws_robot_status_hourly',
        N'DWD',
        N'fact_robot_status',
        N'UPSERT_FULL_AGG',
        @affected_rows,
        N'SUCCESS',
        @step_start_time,
        SYSDATETIME()
    );

    SET @step_start_time = SYSDATETIME();

    ;WITH src AS (
        SELECT
            DATEADD(HOUR, DATEDIFF(HOUR, 0, fw.[sample_time]), 0) AS [stat_hour],
            COALESCE(NULLIF(fw.[robot_code], N''), NULLIF(fw.[robot_id], N''), N'UNKNOWN') AS [robot_code],
            MAX(fw.[robot_id]) AS [robot_id],
            COUNT_BIG(*) AS [sample_count],
            /* 0 表示无信号/断连异常，不作为真实 RSSI 参与均值和极值计算。 */
            AVG(CASE WHEN fw.[rssi] < 0 THEN fw.[rssi] END) AS [avg_rssi],
            MIN(CASE WHEN fw.[rssi] < 0 THEN fw.[rssi] END) AS [min_rssi],
            MAX(CASE WHEN fw.[rssi] < 0 THEN fw.[rssi] END) AS [max_rssi],
            /* 弱信号口径：有效 RSSI <= -70，或源系统无信号值 RSSI = 0。 */
            SUM(
                CASE
                    WHEN fw.[rssi] = 0 THEN 1
                    WHEN fw.[rssi] <= -70 THEN 1
                    ELSE 0
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
            COALESCE(NULLIF(fw.[robot_code], N''), NULLIF(fw.[robot_id], N''), N'UNKNOWN')
    )
    MERGE [DWS].[dws_robot_wifi_hourly] AS tgt
    USING src
        ON tgt.[robot_code] = src.[robot_code]
       AND tgt.[stat_hour] = src.[stat_hour]
    WHEN MATCHED THEN
        UPDATE SET
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
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (
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
        VALUES (
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
        );

    SET @affected_rows = @@ROWCOUNT;

    INSERT INTO [DWS].[etl_load_log] (
        [batch_id],
        [target_schema],
        [target_table],
        [source_schema],
        [source_table],
        [load_mode],
        [affected_rows],
        [load_status],
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
        @step_start_time,
        SYSDATETIME()
    );

    SET @step_start_time = SYSDATETIME();

    SELECT
        CONVERT(DATE, fj.[job_start_time]) AS [stat_date],
        COALESCE(NULLIF(LTRIM(RTRIM(fj.[robot_code])), N''), NULLIF(LTRIM(RTRIM(fj.[robot_id])), N''), N'UNKNOWN') AS [robot_code],
        MAX(fj.[robot_id]) AS [robot_id],
        COALESCE(NULLIF(LTRIM(RTRIM(fj.[job_type_code])), N''), N'UNKNOWN') AS [job_type_code],
        COALESCE(NULLIF(LTRIM(RTRIM(fj.[robot_mode_id])), N''), N'UNKNOWN') AS [robot_mode_id],
        COALESCE(MAX(NULLIF(LTRIM(RTRIM(fj.[robot_mode_detail])), N'')), N'UNKNOWN') AS [robot_mode_detail],
        COUNT_BIG(*) AS [job_count],
        CONVERT(BIGINT, 0) AS [distinct_job_count],
        CONVERT(BIGINT, 0) AS [completed_status_count],
        CONVERT(BIGINT, 0) AS [failed_status_count],
        MIN(fj.[job_start_time]) AS [first_job_start_time],
        MAX(fj.[job_start_time]) AS [last_job_start_time],
        MIN(fj.[job_fact_id]) AS [source_min_fact_id],
        MAX(fj.[job_fact_id]) AS [source_max_fact_id]
    INTO #job_daily_detail
    FROM [DWD].[fact_robot_job] AS fj
    WHERE fj.[job_start_time] IS NOT NULL
    GROUP BY
        CONVERT(DATE, fj.[job_start_time]),
        COALESCE(NULLIF(LTRIM(RTRIM(fj.[robot_code])), N''), NULLIF(LTRIM(RTRIM(fj.[robot_id])), N''), N'UNKNOWN'),
        COALESCE(NULLIF(LTRIM(RTRIM(fj.[job_type_code])), N''), N'UNKNOWN'),
        COALESCE(NULLIF(LTRIM(RTRIM(fj.[robot_mode_id])), N''), N'UNKNOWN');

    UPDATE tgt
    SET
        tgt.[robot_id] = src.[robot_id],
        tgt.[robot_mode_detail] = src.[robot_mode_detail],
        tgt.[job_count] = src.[job_count],
        tgt.[distinct_job_count] = 0,
        tgt.[completed_status_count] = 0,
        tgt.[failed_status_count] = 0,
        tgt.[first_job_start_time] = src.[first_job_start_time],
        tgt.[last_job_start_time] = src.[last_job_start_time],
        tgt.[source_min_fact_id] = src.[source_min_fact_id],
        tgt.[source_max_fact_id] = src.[source_max_fact_id],
        tgt.[dws_load_time] = SYSDATETIME(),
        tgt.[dws_batch_id] = @batch_id
    FROM [DWS].[dws_robot_job_daily] AS tgt
    INNER JOIN #job_daily_detail AS src
        ON src.[robot_code] = tgt.[robot_code]
       AND src.[stat_date] = tgt.[stat_date]
       AND src.[job_type_code] = tgt.[job_type_code]
       AND src.[robot_mode_id] = tgt.[robot_mode_id];

    SET @affected_rows = @@ROWCOUNT;

    INSERT INTO [DWS].[dws_robot_job_daily] (
        [stat_date], [robot_code], [robot_id], [job_type_code], [robot_mode_id],
        [robot_mode_detail], [job_count], [distinct_job_count],
        [completed_status_count], [failed_status_count], [first_job_start_time],
        [last_job_start_time], [source_min_fact_id], [source_max_fact_id], [dws_batch_id]
    )
    SELECT
        src.[stat_date], src.[robot_code], src.[robot_id], src.[job_type_code], src.[robot_mode_id],
        src.[robot_mode_detail], src.[job_count], 0, 0, 0, src.[first_job_start_time],
        src.[last_job_start_time], src.[source_min_fact_id], src.[source_max_fact_id], @batch_id
    FROM #job_daily_detail AS src
    WHERE NOT EXISTS (
        SELECT 1
        FROM [DWS].[dws_robot_job_daily] AS tgt
        WHERE tgt.[robot_code] = src.[robot_code]
          AND tgt.[stat_date] = src.[stat_date]
          AND tgt.[job_type_code] = src.[job_type_code]
          AND tgt.[robot_mode_id] = src.[robot_mode_id]
    );

    SET @affected_rows += @@ROWCOUNT;

    DELETE tgt
    FROM [DWS].[dws_robot_job_daily] AS tgt
    LEFT JOIN #job_daily_detail AS src
        ON src.[robot_code] = tgt.[robot_code]
       AND src.[stat_date] = tgt.[stat_date]
       AND src.[job_type_code] = tgt.[job_type_code]
       AND src.[robot_mode_id] = tgt.[robot_mode_id]
    WHERE COALESCE(tgt.[job_type_code], N'') <> N'__ALL__'
      AND src.[stat_date] IS NULL;

    SET @affected_rows += @@ROWCOUNT;

    INSERT INTO [DWS].[etl_load_log] (
        [batch_id],
        [target_schema],
        [target_table],
        [source_schema],
        [source_table],
        [load_mode],
        [affected_rows],
        [load_status],
        [load_start_time],
        [load_end_time]
    )
    VALUES (
        @batch_id,
        N'DWS',
        N'dws_robot_job_daily',
        N'DWD',
        N'fact_robot_job',
        N'UPSERT_FULL_AGG',
        @affected_rows,
        N'SUCCESS',
        @step_start_time,
        SYSDATETIME()
    );

    /*
        Store queue outcomes in one explicit rollup row per date and robot.
        This prevents the same completed/failed total from being duplicated across
        every job-type and robot-mode detail row.
    */
    SET @step_start_time = SYSDATETIME();

    ;WITH queue_item AS (
        SELECT
            CONVERT(DATE, q.[event_time]) AS [stat_date],
            COALESCE(
                NULLIF(LTRIM(RTRIM(q.[robot_code])), N''),
                NULLIF(LTRIM(RTRIM(q.[robot_id])), N''),
                N'UNKNOWN'
            ) AS [robot_code],
            MAX(q.[robot_id]) AS [robot_id],
            NULLIF(LTRIM(RTRIM(q.[queue_id])), N'') AS [queue_id],
            MAX(CASE WHEN UPPER(LTRIM(RTRIM(COALESCE(q.[queue_status], N'')))) IN (
                N'COMPLETED', N'COMPLEATED', N'COMPLETE', N'SUCCESS', N'SUCCEEDED',
                N'DONE', N'FINISHED', N'完成', N'成功'
            ) THEN 1 ELSE 0 END) AS [is_completed],
            MAX(CASE WHEN UPPER(LTRIM(RTRIM(COALESCE(q.[queue_status], N'')))) IN (
                N'CANCELLED', N'CANCELED', N'FAILED', N'FAIL', N'ERROR', N'ABORTED',
                N'取消', N'失败', N'异常'
            ) THEN 1 ELSE 0 END) AS [is_unsuccessful]
        FROM [DWD].[fact_amr_queue] AS q
        WHERE q.[event_time] IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(q.[queue_id])), N'') IS NOT NULL
        GROUP BY
            CONVERT(DATE, q.[event_time]),
            COALESCE(
                NULLIF(LTRIM(RTRIM(q.[robot_code])), N''),
                NULLIF(LTRIM(RTRIM(q.[robot_id])), N''),
                N'UNKNOWN'
            ),
            NULLIF(LTRIM(RTRIM(q.[queue_id])), N'')
    ),
    queue_daily AS (
        SELECT
            qi.[stat_date],
            qi.[robot_code],
            MAX(qi.[robot_id]) AS [robot_id],
            COUNT_BIG(*) AS [distinct_job_count],
            SUM(CONVERT(BIGINT, qi.[is_completed])) AS [completed_status_count],
            SUM(CASE WHEN qi.[is_completed] = 0 AND qi.[is_unsuccessful] = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [failed_status_count]
        FROM queue_item AS qi
        GROUP BY
            qi.[stat_date],
            qi.[robot_code]
    )
    SELECT
        qd.[stat_date],
        qd.[robot_code],
        qd.[robot_id],
        qd.[distinct_job_count],
        qd.[completed_status_count],
        qd.[failed_status_count]
    INTO #job_daily_rollup
    FROM queue_daily AS qd;

    UPDATE tgt
    SET
        tgt.[robot_id] = src.[robot_id],
        tgt.[robot_mode_detail] = N'ALL MODES',
        tgt.[job_count] = 0,
        tgt.[distinct_job_count] = src.[distinct_job_count],
        tgt.[completed_status_count] = src.[completed_status_count],
        tgt.[failed_status_count] = src.[failed_status_count],
        tgt.[first_job_start_time] = NULL,
        tgt.[last_job_start_time] = NULL,
        tgt.[source_min_fact_id] = NULL,
        tgt.[source_max_fact_id] = NULL,
        tgt.[dws_load_time] = SYSDATETIME(),
        tgt.[dws_batch_id] = @batch_id
    FROM [DWS].[dws_robot_job_daily] AS tgt
    INNER JOIN #job_daily_rollup AS src
        ON src.[stat_date] = tgt.[stat_date]
       AND src.[robot_code] = tgt.[robot_code]
    WHERE tgt.[job_type_code] = N'__ALL__'
      AND tgt.[robot_mode_id] = N'__ALL__';

    SET @queue_metric_rows = @@ROWCOUNT;

    INSERT INTO [DWS].[dws_robot_job_daily] (
        [stat_date], [robot_code], [robot_id], [job_type_code], [robot_mode_id],
        [robot_mode_detail], [job_count], [distinct_job_count],
        [completed_status_count], [failed_status_count], [first_job_start_time],
        [last_job_start_time], [source_min_fact_id], [source_max_fact_id], [dws_batch_id]
    )
    SELECT
        src.[stat_date], src.[robot_code], src.[robot_id], N'__ALL__', N'__ALL__',
        N'ALL MODES', 0, src.[distinct_job_count], src.[completed_status_count],
        src.[failed_status_count], NULL, NULL, NULL, NULL, @batch_id
    FROM #job_daily_rollup AS src
    WHERE NOT EXISTS (
        SELECT 1
        FROM [DWS].[dws_robot_job_daily] AS tgt
        WHERE tgt.[stat_date] = src.[stat_date]
          AND tgt.[robot_code] = src.[robot_code]
          AND tgt.[job_type_code] = N'__ALL__'
          AND tgt.[robot_mode_id] = N'__ALL__'
    );

    SET @queue_metric_rows += @@ROWCOUNT;

    DELETE tgt
    FROM [DWS].[dws_robot_job_daily] AS tgt
    LEFT JOIN #job_daily_rollup AS src
        ON src.[stat_date] = tgt.[stat_date]
       AND src.[robot_code] = tgt.[robot_code]
    WHERE tgt.[job_type_code] = N'__ALL__'
      AND tgt.[robot_mode_id] = N'__ALL__'
      AND src.[stat_date] IS NULL;

    SET @queue_metric_rows += @@ROWCOUNT;

    INSERT INTO [DWS].[etl_load_log] (
        [batch_id],
        [target_schema],
        [target_table],
        [source_schema],
        [source_table],
        [load_mode],
        [affected_rows],
        [load_status],
        [load_start_time],
        [load_end_time]
    )
    VALUES (
        @batch_id,
        N'DWS',
        N'dws_robot_job_daily',
        N'DWD',
        N'fact_amr_queue',
        N'UPSERT_QUEUE_OUTCOME_ROLLUP',
        @queue_metric_rows,
        N'SUCCESS',
        @step_start_time,
        SYSDATETIME()
    );

    SET @step_start_time = SYSDATETIME();

    ;WITH src AS (
        SELECT
            CONVERT(DATE, fq.[event_time]) AS [stat_date],
            COALESCE(NULLIF(fq.[robot_code], N''), NULLIF(fq.[robot_id], N''), N'UNKNOWN') AS [robot_code],
            MAX(fq.[robot_id]) AS [robot_id],
            COALESCE(NULLIF(fq.[project_code], N''), N'UNKNOWN') AS [project_code],
            COUNT_BIG(*) AS [queue_count],
            COUNT(DISTINCT fq.[queue_id]) AS [distinct_queue_count],
            SUM(
                CASE
                    WHEN fq.[queue_status] LIKE N'%完成%'
                      OR fq.[queue_status] LIKE N'%成功%'
                      OR LOWER(fq.[queue_status]) LIKE N'%complete%'
                      OR LOWER(fq.[queue_status]) LIKE N'%success%'
                    THEN 1
                    ELSE 0
                END
            ) AS [completed_status_count],
            SUM(
                CASE
                    WHEN fq.[queue_status] LIKE N'%失败%'
                      OR fq.[queue_status] LIKE N'%异常%'
                      OR LOWER(fq.[queue_status]) LIKE N'%fail%'
                      OR LOWER(fq.[queue_status]) LIKE N'%error%'
                    THEN 1
                    ELSE 0
                END
            ) AS [failed_status_count],
            AVG(CONVERT(DECIMAL(18,6), fq.[duration_seconds])) AS [avg_duration_seconds],
            MIN(fq.[event_time]) AS [first_event_time],
            MAX(fq.[event_time]) AS [last_event_time],
            MIN(fq.[queue_fact_id]) AS [source_min_fact_id],
            MAX(fq.[queue_fact_id]) AS [source_max_fact_id]
        FROM [DWD].[fact_amr_queue] AS fq
        WHERE fq.[event_time] IS NOT NULL
        GROUP BY
            CONVERT(DATE, fq.[event_time]),
            COALESCE(NULLIF(fq.[robot_code], N''), NULLIF(fq.[robot_id], N''), N'UNKNOWN'),
            COALESCE(NULLIF(fq.[project_code], N''), N'UNKNOWN')
    )
    MERGE [DWS].[dws_amr_queue_daily] AS tgt
    USING src
        ON tgt.[robot_code] = src.[robot_code]
       AND tgt.[stat_date] = src.[stat_date]
       AND tgt.[project_code] = src.[project_code]
    WHEN MATCHED THEN
        UPDATE SET
            tgt.[robot_id] = src.[robot_id],
            tgt.[queue_count] = src.[queue_count],
            tgt.[distinct_queue_count] = src.[distinct_queue_count],
            tgt.[completed_status_count] = src.[completed_status_count],
            tgt.[failed_status_count] = src.[failed_status_count],
            tgt.[avg_duration_seconds] = src.[avg_duration_seconds],
            tgt.[first_event_time] = src.[first_event_time],
            tgt.[last_event_time] = src.[last_event_time],
            tgt.[source_min_fact_id] = src.[source_min_fact_id],
            tgt.[source_max_fact_id] = src.[source_max_fact_id],
            tgt.[dws_load_time] = SYSDATETIME(),
            tgt.[dws_batch_id] = @batch_id
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (
            [stat_date],
            [robot_code],
            [robot_id],
            [project_code],
            [queue_count],
            [distinct_queue_count],
            [completed_status_count],
            [failed_status_count],
            [avg_duration_seconds],
            [first_event_time],
            [last_event_time],
            [source_min_fact_id],
            [source_max_fact_id],
            [dws_batch_id]
        )
        VALUES (
            src.[stat_date],
            src.[robot_code],
            src.[robot_id],
            src.[project_code],
            src.[queue_count],
            src.[distinct_queue_count],
            src.[completed_status_count],
            src.[failed_status_count],
            src.[avg_duration_seconds],
            src.[first_event_time],
            src.[last_event_time],
            src.[source_min_fact_id],
            src.[source_max_fact_id],
            @batch_id
        );

    SET @affected_rows = @@ROWCOUNT;

    INSERT INTO [DWS].[etl_load_log] (
        [batch_id],
        [target_schema],
        [target_table],
        [source_schema],
        [source_table],
        [load_mode],
        [affected_rows],
        [load_status],
        [load_start_time],
        [load_end_time]
    )
    VALUES (
        @batch_id,
        N'DWS',
        N'dws_amr_queue_daily',
        N'DWD',
        N'fact_amr_queue',
        N'UPSERT_FULL_AGG',
        @affected_rows,
        N'SUCCESS',
        @step_start_time,
        SYSDATETIME()
    );

    IF @include_current_snapshot = 1
    BEGIN
    SET @step_start_time = SYSDATETIME();

    ;WITH ranked_snapshot AS (
        SELECT
            COALESCE(NULLIF(cs.[robot_code], N''), NULLIF(cs.[robot_id], N''), N'UNKNOWN') AS [robot_code],
            cs.[robot_id],
            cs.[robot_name],
            cs.[current_status],
            cs.[current_mode],
            cs.[online_status],
            cs.[job_id],
            cs.[subjob_id],
            cs.[map_code],
            cs.[station_code],
            cs.[position_x],
            cs.[position_y],
            cs.[position_theta],
            cs.[speed_mps],
            cs.[battery_soc],
            cs.[error_code],
            cs.[error_message],
            cs.[source_event_time],
            cs.[snapshot_time],
            ROW_NUMBER() OVER (
                PARTITION BY COALESCE(NULLIF(cs.[robot_code], N''), NULLIF(cs.[robot_id], N''), N'UNKNOWN')
                ORDER BY cs.[snapshot_time] DESC, cs.[snapshot_id] DESC
            ) AS [rn]
        FROM [DWD].[snap_amr_current_status] AS cs
    ),
    src AS (
        SELECT
            rs.[robot_code],
            rs.[robot_id],
            rs.[robot_name],
            rs.[current_status],
            rs.[current_mode],
            rs.[online_status],
            rs.[job_id],
            rs.[subjob_id],
            rs.[map_code],
            rs.[station_code],
            rs.[position_x],
            rs.[position_y],
            rs.[position_theta],
            rs.[speed_mps],
            rs.[battery_soc],
            rs.[error_code],
            rs.[error_message],
            rs.[source_event_time],
            rs.[snapshot_time] AS [source_snapshot_time]
        FROM ranked_snapshot AS rs
        WHERE rs.[rn] = 1
    )
    MERGE [DWS].[dws_robot_current_snapshot] AS tgt
    USING src
        ON tgt.[robot_code] = src.[robot_code]
    WHEN MATCHED THEN
        UPDATE SET
            tgt.[robot_id] = src.[robot_id],
            tgt.[robot_name] = src.[robot_name],
            tgt.[current_status] = src.[current_status],
            tgt.[current_mode] = src.[current_mode],
            tgt.[online_status] = src.[online_status],
            tgt.[job_id] = src.[job_id],
            tgt.[subjob_id] = src.[subjob_id],
            tgt.[map_code] = src.[map_code],
            tgt.[station_code] = src.[station_code],
            tgt.[position_x] = src.[position_x],
            tgt.[position_y] = src.[position_y],
            tgt.[position_theta] = src.[position_theta],
            tgt.[speed_mps] = src.[speed_mps],
            tgt.[battery_soc] = src.[battery_soc],
            tgt.[error_code] = src.[error_code],
            tgt.[error_message] = src.[error_message],
            tgt.[source_event_time] = src.[source_event_time],
            tgt.[source_snapshot_time] = src.[source_snapshot_time],
            tgt.[dws_load_time] = SYSDATETIME(),
            tgt.[dws_batch_id] = @batch_id
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (
            [robot_code],
            [robot_id],
            [robot_name],
            [current_status],
            [current_mode],
            [online_status],
            [job_id],
            [subjob_id],
            [map_code],
            [station_code],
            [position_x],
            [position_y],
            [position_theta],
            [speed_mps],
            [battery_soc],
            [error_code],
            [error_message],
            [source_event_time],
            [source_snapshot_time],
            [dws_batch_id]
        )
        VALUES (
            src.[robot_code],
            src.[robot_id],
            src.[robot_name],
            src.[current_status],
            src.[current_mode],
            src.[online_status],
            src.[job_id],
            src.[subjob_id],
            src.[map_code],
            src.[station_code],
            src.[position_x],
            src.[position_y],
            src.[position_theta],
            src.[speed_mps],
            src.[battery_soc],
            src.[error_code],
            src.[error_message],
            src.[source_event_time],
            src.[source_snapshot_time],
            @batch_id
        );

    SET @affected_rows = @@ROWCOUNT;

    INSERT INTO [DWS].[etl_load_log] (
        [batch_id],
        [target_schema],
        [target_table],
        [source_schema],
        [source_table],
        [load_mode],
        [affected_rows],
        [load_status],
        [load_start_time],
        [load_end_time]
    )
    VALUES (
        @batch_id,
        N'DWS',
        N'dws_robot_current_snapshot',
        N'DWD',
        N'snap_amr_current_status',
        N'UPSERT_SNAPSHOT',
        @affected_rows,
        N'SUCCESS',
        @step_start_time,
        SYSDATETIME()
    );
    END;

    UPDATE [DWS].[etl_batch]
    SET
        [batch_end_time] = SYSDATETIME(),
        [batch_status] = N'SUCCESS',
        [error_message] = NULL
    WHERE [batch_id] = @batch_id;
END TRY
BEGIN CATCH
    SET @error_message = CONCAT(N'Error ', ERROR_NUMBER(), N', line ', ERROR_LINE(), N': ', ERROR_MESSAGE());

    IF @batch_id IS NOT NULL
    BEGIN
        UPDATE [DWS].[etl_batch]
        SET
            [batch_end_time] = SYSDATETIME(),
            [batch_status] = N'FAILED',
            [error_message] = @error_message
        WHERE [batch_id] = @batch_id;

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
            N'UNKNOWN',
            N'DWD',
            N'UNKNOWN',
            N'UPSERT_FULL_AGG',
            0,
            N'FAILED',
            @error_message,
            SYSDATETIME(),
            SYSDATETIME()
        );
    END;

    EXEC sys.sp_releaseapplock
        @Resource = N'DWS.sp_load_dws_core_upsert',
        @LockOwner = N'Session';

    THROW;
END CATCH;

EXEC sys.sp_releaseapplock
    @Resource = N'DWS.sp_load_dws_core_upsert',
    @LockOwner = N'Session';

SELECT
    [batch_id],
    [batch_start_time],
    [batch_end_time],
    [batch_status],
    [error_message]
FROM [DWS].[etl_batch]
WHERE [batch_id] = @batch_id;

SELECT
    [load_id],
    [batch_id],
    [target_table],
    [source_table],
    [load_mode],
    [affected_rows],
    [load_status],
    [error_message],
    [load_start_time],
    [load_end_time]
FROM [DWS].[etl_load_log]
WHERE [batch_id] = @batch_id
ORDER BY
    [load_id];
END;
GO

/*
    Installation only: do not start a full DWS scan automatically.
    After the DWD job type/mode backfill is complete, use script 44 for the
    targeted job-daily refresh. For a later full manual DWS refresh, run:

    EXEC [DWS].[sp_load_dws_core_upsert]
        @include_current_snapshot = 1;
*/
GO
