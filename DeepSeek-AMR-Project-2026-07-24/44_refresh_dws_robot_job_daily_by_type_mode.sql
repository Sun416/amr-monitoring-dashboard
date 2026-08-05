USE [IOT2020];
GO

/*
    Targeted refresh for DWS.dws_robot_job_daily.

    Grain of detail rows:
        stat_date + robot_code + job_type_code + robot_mode_id

    Queue outcome metrics are intentionally stored in one rollup row per robot
    and date using the reserved values __ALL__/__ALL__. They are not copied to
    every type/mode row, which would multiply completed and failed totals.

    The default call at the end is preview-only. Change @execute to 1 only after
    the DWD history backfill in script 43 is complete.
*/

/*
    DataGrip compatibility: keep the complete procedure definition inside one
    executable statement so current-statement parsing cannot split JOIN/ON.
*/
EXEC sys.sp_executesql N'CREATE OR ALTER PROCEDURE [DWS].[sp_refresh_robot_job_daily_by_type_mode]
    @execute BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @lock_result INT,
        @batch_id BIGINT = NULL,
        @detail_affected_rows BIGINT = 0,
        @rollup_affected_rows BIGINT = 0,
        @started_at DATETIME2(3) = SYSDATETIME(),
        @error_message NVARCHAR(4000);

    IF @execute NOT IN (0, 1)
    BEGIN
        RAISERROR(N''@execute must be 0 or 1.'', 16, 1);
        RETURN;
    END;

    IF OBJECT_ID(N''[DWD].[fact_robot_job]'', N''U'') IS NULL
       OR OBJECT_ID(N''[DWD].[fact_amr_queue]'', N''U'') IS NULL
       OR OBJECT_ID(N''[DWS].[dws_robot_job_daily]'', N''U'') IS NULL
       OR OBJECT_ID(N''[DWS].[etl_batch]'', N''U'') IS NULL
       OR OBJECT_ID(N''[DWS].[etl_load_log]'', N''U'') IS NULL
    BEGIN
        RAISERROR(N''Required DWD or DWS object is missing.'', 16, 1);
        RETURN;
    END;

    IF COL_LENGTH(N''DWD.fact_robot_job'', N''robot_mode_id'') IS NULL
       OR COL_LENGTH(N''DWD.fact_robot_job'', N''robot_mode_detail'') IS NULL
       OR COL_LENGTH(N''DWS.dws_robot_job_daily'', N''robot_mode_id'') IS NULL
       OR COL_LENGTH(N''DWS.dws_robot_job_daily'', N''robot_mode_detail'') IS NULL
    BEGIN
        RAISERROR(N''Robot mode columns are missing. Run script 41 first.'', 16, 1);
        RETURN;
    END;

    IF NOT EXISTS (
        SELECT 1
        FROM sys.indexes AS i
        WHERE i.[object_id] = OBJECT_ID(N''[DWS].[dws_robot_job_daily]'')
          AND i.[name] = N''UX_DWS_robot_job_daily_robot_date_type''
          AND 4 = (
              SELECT COUNT(*)
              FROM sys.index_columns AS ic
              WHERE ic.[object_id] = i.[object_id]
                AND ic.[index_id] = i.[index_id]
                AND ic.[key_ordinal] > 0
          )
    )
    BEGIN
        RAISERROR(N''DWS four-column unique key is missing. Run script 41 first.'', 16, 1);
        RETURN;
    END;

    /* Cheap preview: no 40+ million row aggregation is started. */
    IF @execute = 0
    BEGIN
        SELECT
            @execute AS [execute_flag],
            SUM(CASE WHEN p.[index_id] IN (0, 1) THEN p.[row_count] ELSE 0 END) AS [approximate_dwd_job_rows],
            (SELECT COUNT_BIG(*) FROM [DWS].[dws_robot_job_daily]) AS [current_dws_rows],
            N''Preview only. Run after script 43 completes, then set @execute = 1.'' AS [next_action]
        FROM sys.dm_db_partition_stats AS p
        WHERE p.[object_id] = OBJECT_ID(N''[DWD].[fact_robot_job]'');

        RETURN;
    END;

    EXEC @lock_result = sys.sp_getapplock
        @Resource = N''DWS.sp_refresh_robot_job_daily_by_type_mode'',
        @LockMode = N''Exclusive'',
        @LockOwner = N''Session'',
        @LockTimeout = 0;

    IF @lock_result < 0
    BEGIN
        RAISERROR(N''DWS robot job daily refresh is already running.'', 16, 1);
        RETURN;
    END;

    BEGIN TRY
        INSERT INTO [DWS].[etl_batch] (
            [batch_start_time],
            [batch_status],
            [error_message]
        )
        VALUES (
            @started_at,
            N''RUNNING'',
            NULL
        );

        SET @batch_id = SCOPE_IDENTITY();

        RAISERROR(N''Aggregating DWD.fact_robot_job by date, robot, job type, and robot mode.'', 10, 1) WITH NOWAIT;

        SELECT
            CONVERT(DATE, f.[job_start_time]) AS [stat_date],
            COALESCE(
                NULLIF(LTRIM(RTRIM(f.[robot_code])), N''''),
                NULLIF(LTRIM(RTRIM(f.[robot_id])), N''''),
                N''UNKNOWN''
            ) AS [robot_code],
            MAX(f.[robot_id]) AS [robot_id],
            COALESCE(NULLIF(LTRIM(RTRIM(f.[job_type_code])), N''''), N''UNKNOWN'') AS [job_type_code],
            COALESCE(NULLIF(LTRIM(RTRIM(f.[robot_mode_id])), N''''), N''UNKNOWN'') AS [robot_mode_id],
            COALESCE(MAX(NULLIF(LTRIM(RTRIM(f.[robot_mode_detail])), N'''')), N''UNKNOWN'') AS [robot_mode_detail],
            COUNT_BIG(*) AS [job_count],
            MIN(f.[job_start_time]) AS [first_job_start_time],
            MAX(f.[job_start_time]) AS [last_job_start_time],
            MIN(f.[job_fact_id]) AS [source_min_fact_id],
            MAX(f.[job_fact_id]) AS [source_max_fact_id]
        INTO #job_daily_detail
        FROM [DWD].[fact_robot_job] AS f
        WHERE f.[job_start_time] IS NOT NULL
        GROUP BY
            CONVERT(DATE, f.[job_start_time]),
            COALESCE(
                NULLIF(LTRIM(RTRIM(f.[robot_code])), N''''),
                NULLIF(LTRIM(RTRIM(f.[robot_id])), N''''),
                N''UNKNOWN''
            ),
            COALESCE(NULLIF(LTRIM(RTRIM(f.[job_type_code])), N''''), N''UNKNOWN''),
            COALESCE(NULLIF(LTRIM(RTRIM(f.[robot_mode_id])), N''''), N''UNKNOWN'');

        RAISERROR(N''Aggregating queue outcome metrics into reserved __ALL__ rows.'', 10, 1) WITH NOWAIT;

        ;WITH queue_item AS (
            SELECT
                CONVERT(DATE, q.[event_time]) AS [stat_date],
                COALESCE(
                    NULLIF(LTRIM(RTRIM(q.[robot_code])), N''''),
                    NULLIF(LTRIM(RTRIM(q.[robot_id])), N''''),
                    N''UNKNOWN''
                ) AS [robot_code],
                MAX(q.[robot_id]) AS [robot_id],
                NULLIF(LTRIM(RTRIM(q.[queue_id])), N'''') AS [queue_id],
                MAX(CASE
                    WHEN UPPER(LTRIM(RTRIM(COALESCE(q.[queue_status], N'''')))) IN (
                        N''COMPLETED'', N''COMPLEATED'', N''COMPLETE'', N''SUCCESS'',
                        N''SUCCEEDED'', N''DONE'', N''FINISHED'', N''完成'', N''成功''
                    ) THEN 1 ELSE 0
                END) AS [is_completed],
                MAX(CASE
                    WHEN UPPER(LTRIM(RTRIM(COALESCE(q.[queue_status], N'''')))) IN (
                        N''CANCELLED'', N''CANCELED'', N''FAILED'', N''FAIL'', N''ERROR'',
                        N''ABORTED'', N''取消'', N''失败'', N''异常''
                    ) THEN 1 ELSE 0
                END) AS [is_unsuccessful]
            FROM [DWD].[fact_amr_queue] AS q
            WHERE q.[event_time] IS NOT NULL
              AND NULLIF(LTRIM(RTRIM(q.[queue_id])), N'''') IS NOT NULL
            GROUP BY
                CONVERT(DATE, q.[event_time]),
                COALESCE(
                    NULLIF(LTRIM(RTRIM(q.[robot_code])), N''''),
                    NULLIF(LTRIM(RTRIM(q.[robot_id])), N''''),
                    N''UNKNOWN''
                ),
                NULLIF(LTRIM(RTRIM(q.[queue_id])), N'''')
        ), queue_daily AS (
            SELECT
                q.[stat_date],
                q.[robot_code],
                MAX(q.[robot_id]) AS [robot_id],
                COUNT_BIG(*) AS [distinct_job_count],
                SUM(CONVERT(BIGINT, q.[is_completed])) AS [completed_status_count],
                SUM(CASE
                    WHEN q.[is_completed] = 0 AND q.[is_unsuccessful] = 1
                        THEN CONVERT(BIGINT, 1)
                    ELSE CONVERT(BIGINT, 0)
                END) AS [failed_status_count]
            FROM queue_item AS q
            GROUP BY
                q.[stat_date],
                q.[robot_code]
        )
        SELECT
            q.[stat_date],
            q.[robot_code],
            q.[robot_id],
            q.[distinct_job_count],
            q.[completed_status_count],
            q.[failed_status_count]
        INTO #job_daily_rollup
        FROM queue_daily AS q;

        BEGIN TRANSACTION;

        UPDATE d
        SET
            d.[robot_id] = s.[robot_id],
            d.[robot_mode_detail] = s.[robot_mode_detail],
            d.[job_count] = s.[job_count],
            d.[distinct_job_count] = 0,
            d.[completed_status_count] = 0,
            d.[failed_status_count] = 0,
            d.[first_job_start_time] = s.[first_job_start_time],
            d.[last_job_start_time] = s.[last_job_start_time],
            d.[source_min_fact_id] = s.[source_min_fact_id],
            d.[source_max_fact_id] = s.[source_max_fact_id],
            d.[dws_load_time] = SYSDATETIME(),
            d.[dws_batch_id] = @batch_id
        FROM [DWS].[dws_robot_job_daily] AS d
        INNER JOIN #job_daily_detail AS s
            ON s.[stat_date] = d.[stat_date]
           AND s.[robot_code] = d.[robot_code]
           AND s.[job_type_code] = d.[job_type_code]
           AND s.[robot_mode_id] = d.[robot_mode_id];

        SET @detail_affected_rows = @@ROWCOUNT;

        INSERT INTO [DWS].[dws_robot_job_daily] (
            [stat_date],
            [robot_code],
            [robot_id],
            [job_type_code],
            [robot_mode_id],
            [robot_mode_detail],
            [job_count],
            [distinct_job_count],
            [completed_status_count],
            [failed_status_count],
            [first_job_start_time],
            [last_job_start_time],
            [source_min_fact_id],
            [source_max_fact_id],
            [dws_batch_id]
        )
        SELECT
            s.[stat_date],
            s.[robot_code],
            s.[robot_id],
            s.[job_type_code],
            s.[robot_mode_id],
            s.[robot_mode_detail],
            s.[job_count],
            0,
            0,
            0,
            s.[first_job_start_time],
            s.[last_job_start_time],
            s.[source_min_fact_id],
            s.[source_max_fact_id],
            @batch_id
        FROM #job_daily_detail AS s
        WHERE NOT EXISTS (
            SELECT 1
            FROM [DWS].[dws_robot_job_daily] AS d
            WHERE d.[stat_date] = s.[stat_date]
              AND d.[robot_code] = s.[robot_code]
              AND d.[job_type_code] = s.[job_type_code]
              AND d.[robot_mode_id] = s.[robot_mode_id]
        );

        SET @detail_affected_rows += @@ROWCOUNT;

        DELETE d
        FROM [DWS].[dws_robot_job_daily] AS d
        LEFT JOIN #job_daily_detail AS s
            ON s.[stat_date] = d.[stat_date]
           AND s.[robot_code] = d.[robot_code]
           AND s.[job_type_code] = d.[job_type_code]
           AND s.[robot_mode_id] = d.[robot_mode_id]
        WHERE COALESCE(d.[job_type_code], N'''') <> N''__ALL__''
          AND s.[stat_date] IS NULL;

        SET @detail_affected_rows += @@ROWCOUNT;

        UPDATE d
        SET
            d.[robot_id] = s.[robot_id],
            d.[robot_mode_detail] = N''ALL MODES'',
            d.[job_count] = 0,
            d.[distinct_job_count] = s.[distinct_job_count],
            d.[completed_status_count] = s.[completed_status_count],
            d.[failed_status_count] = s.[failed_status_count],
            d.[first_job_start_time] = NULL,
            d.[last_job_start_time] = NULL,
            d.[source_min_fact_id] = NULL,
            d.[source_max_fact_id] = NULL,
            d.[dws_load_time] = SYSDATETIME(),
            d.[dws_batch_id] = @batch_id
        FROM [DWS].[dws_robot_job_daily] AS d
        INNER JOIN #job_daily_rollup AS s
            ON s.[stat_date] = d.[stat_date]
           AND s.[robot_code] = d.[robot_code]
        WHERE d.[job_type_code] = N''__ALL__''
          AND d.[robot_mode_id] = N''__ALL__'';

        SET @rollup_affected_rows = @@ROWCOUNT;

        INSERT INTO [DWS].[dws_robot_job_daily] (
            [stat_date],
            [robot_code],
            [robot_id],
            [job_type_code],
            [robot_mode_id],
            [robot_mode_detail],
            [job_count],
            [distinct_job_count],
            [completed_status_count],
            [failed_status_count],
            [first_job_start_time],
            [last_job_start_time],
            [source_min_fact_id],
            [source_max_fact_id],
            [dws_batch_id]
        )
        SELECT
            s.[stat_date],
            s.[robot_code],
            s.[robot_id],
            N''__ALL__'',
            N''__ALL__'',
            N''ALL MODES'',
            0,
            s.[distinct_job_count],
            s.[completed_status_count],
            s.[failed_status_count],
            NULL,
            NULL,
            NULL,
            NULL,
            @batch_id
        FROM #job_daily_rollup AS s
        WHERE NOT EXISTS (
            SELECT 1
            FROM [DWS].[dws_robot_job_daily] AS d
            WHERE d.[stat_date] = s.[stat_date]
              AND d.[robot_code] = s.[robot_code]
              AND d.[job_type_code] = N''__ALL__''
              AND d.[robot_mode_id] = N''__ALL__''
        );

        SET @rollup_affected_rows += @@ROWCOUNT;

        DELETE d
        FROM [DWS].[dws_robot_job_daily] AS d
        LEFT JOIN #job_daily_rollup AS s
            ON s.[stat_date] = d.[stat_date]
           AND s.[robot_code] = d.[robot_code]
        WHERE d.[job_type_code] = N''__ALL__''
          AND d.[robot_mode_id] = N''__ALL__''
          AND s.[stat_date] IS NULL;

        SET @rollup_affected_rows += @@ROWCOUNT;

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
        VALUES
        (
            @batch_id,
            N''DWS'',
            N''dws_robot_job_daily'',
            N''DWD'',
            N''fact_robot_job'',
            N''REFRESH_TYPE_MODE'',
            @detail_affected_rows,
            N''SUCCESS'',
            NULL,
            @started_at,
            SYSDATETIME()
        ),
        (
            @batch_id,
            N''DWS'',
            N''dws_robot_job_daily'',
            N''DWD'',
            N''fact_amr_queue'',
            N''REFRESH_QUEUE_ROLLUP'',
            @rollup_affected_rows,
            N''SUCCESS'',
            NULL,
            @started_at,
            SYSDATETIME()
        );

        UPDATE [DWS].[etl_batch]
        SET
            [batch_end_time] = SYSDATETIME(),
            [batch_status] = N''SUCCESS'',
            [error_message] = NULL
        WHERE [batch_id] = @batch_id;

        COMMIT TRANSACTION;

        EXEC sys.sp_releaseapplock
            @Resource = N''DWS.sp_refresh_robot_job_daily_by_type_mode'',
            @LockOwner = N''Session'';

        SELECT
            @batch_id AS [batch_id],
            @detail_affected_rows AS [detail_rows_affected],
            @rollup_affected_rows AS [rollup_rows_affected],
            DATEDIFF(SECOND, @started_at, SYSDATETIME()) AS [elapsed_seconds];
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SET @error_message = ERROR_MESSAGE();

        IF @batch_id IS NOT NULL
        BEGIN
            UPDATE [DWS].[etl_batch]
            SET
                [batch_end_time] = SYSDATETIME(),
                [batch_status] = N''FAILED'',
                [error_message] = @error_message
            WHERE [batch_id] = @batch_id;
        END;

        EXEC sys.sp_releaseapplock
            @Resource = N''DWS.sp_refresh_robot_job_daily_by_type_mode'',
            @LockOwner = N''Session'';

        RAISERROR(N''DWS robot job daily type/mode refresh failed: %s'', 16, 1, @error_message);
        RETURN;
    END CATCH;
END;';
GO

/* Preview only. Change @execute from 0 to 1 after script 43 finishes. */
EXEC [DWS].[sp_refresh_robot_job_daily_by_type_mode]
    @execute = 0;
GO
