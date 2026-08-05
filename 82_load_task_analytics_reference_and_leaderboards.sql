USE [IOT2020];

/*
    Task Analytics reference and leaderboard load
    ==============================================

    Source path:
      dbo.MA_ESP_Button -> ODS.MA_ESP_Button -> DWD.dim_amr_calling_box
      ODS.MA_AMR_Job    -> DWD.dim_amr_task
      ODS.AMR_Queue     -> DWD.fact_amr_queue -> DWS leaderboard tables

    The final two INSERTs read DWD only. dbo and ODS are not Web-serving sources.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'IOT2020'
BEGIN
    THROW 58200, N'Expected database IOT2020.', 1;
END;

/* Match the Task Analytics Web's maximum selectable serving horizon. */
DECLARE @window_end DATETIME2(3) = DATEADD(HOUR, DATEDIFF(HOUR, 0, SYSDATETIME()) + 1, 0);
DECLARE @window_start DATETIME2(3) = DATEADD(DAY, -30, @window_end);

BEGIN TRY
    BEGIN TRANSACTION;

    IF OBJECT_ID(N'[ODS].[MA_ESP_Button]', N'U') IS NULL
    BEGIN
        CREATE TABLE [ODS].[MA_ESP_Button]
        (
            [ods_row_id] BIGINT IDENTITY(1, 1) NOT NULL,
            [id] INT NOT NULL,
            [esp_id] INT NOT NULL,
            [name] NVARCHAR(200) NULL,
            [position] INT NOT NULL,
            [created_at] DATETIME NULL,
            [updated_at] DATETIME NULL,
            [deleted_at] DATETIME NULL,
            [ods_load_time] DATETIME2(3) NOT NULL
                CONSTRAINT [DF_ODS_MA_ESP_Button_load_time] DEFAULT SYSDATETIME(),
            [ods_source_schema] NVARCHAR(128) NOT NULL
                CONSTRAINT [DF_ODS_MA_ESP_Button_source_schema] DEFAULT N'dbo',
            [ods_source_table] NVARCHAR(128) NOT NULL
                CONSTRAINT [DF_ODS_MA_ESP_Button_source_table] DEFAULT N'MA_ESP_Button',
            CONSTRAINT [PK_ODS_MA_ESP_Button] PRIMARY KEY CLUSTERED ([ods_row_id])
        );

        CREATE UNIQUE NONCLUSTERED INDEX [UX_ODS_MA_ESP_Button_source_id]
            ON [ODS].[MA_ESP_Button] ([id]);
    END;

    /* Reference mirror is small. Keep a row's original ODS identity when the source changes. */
    UPDATE target
    SET
        target.[esp_id] = source_row.[esp_id],
        target.[name] = source_row.[name],
        target.[position] = source_row.[position],
        target.[created_at] = source_row.[created_at],
        target.[updated_at] = source_row.[updated_at],
        target.[deleted_at] = source_row.[deleted_at],
        target.[ods_load_time] = SYSDATETIME()
    FROM [ODS].[MA_ESP_Button] AS target
    INNER JOIN [dbo].[MA_ESP_Button] AS source_row
        ON source_row.[id] = target.[id]
    WHERE
        ISNULL(target.[esp_id], -1) <> ISNULL(source_row.[esp_id], -1)
        OR ISNULL(target.[name], N'') <> ISNULL(source_row.[name], N'')
        OR ISNULL(target.[position], -1) <> ISNULL(source_row.[position], -1)
        OR ISNULL(target.[updated_at], CONVERT(DATETIME, '19000101', 112)) <> ISNULL(source_row.[updated_at], CONVERT(DATETIME, '19000101', 112))
        OR ISNULL(target.[deleted_at], CONVERT(DATETIME, '19000101', 112)) <> ISNULL(source_row.[deleted_at], CONVERT(DATETIME, '19000101', 112));

    INSERT INTO [ODS].[MA_ESP_Button]
    (
        [id], [esp_id], [name], [position], [created_at], [updated_at], [deleted_at]
    )
    SELECT
        source_row.[id],
        source_row.[esp_id],
        source_row.[name],
        source_row.[position],
        source_row.[created_at],
        source_row.[updated_at],
        source_row.[deleted_at]
    FROM [dbo].[MA_ESP_Button] AS source_row
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM [ODS].[MA_ESP_Button] AS target
        WHERE target.[id] = source_row.[id]
    );

    UPDATE target
    SET
        target.[project_id] = source_row.[project_id],
        target.[task_name] = source_row.[name],
        target.[source_created_time] = CONVERT(DATETIME2(3), source_row.[created_at]),
        target.[source_updated_time] = CONVERT(DATETIME2(3), source_row.[updated_at]),
        target.[source_deleted_time] = CONVERT(DATETIME2(3), source_row.[deleted_at]),
        target.[source_ods_row_id] = source_row.[ods_row_id],
        target.[source_ods_load_time] = source_row.[ods_load_time],
        target.[dwd_load_time] = SYSDATETIME()
    FROM [DWD].[dim_amr_task] AS target
    INNER JOIN [ODS].[MA_AMR_Job] AS source_row
        ON source_row.[id] = target.[job_id];

    INSERT INTO [DWD].[dim_amr_task]
    (
        [job_id], [project_id], [task_name], [source_created_time], [source_updated_time], [source_deleted_time],
        [source_ods_row_id], [source_ods_load_time]
    )
    SELECT
        source_row.[id],
        source_row.[project_id],
        source_row.[name],
        CONVERT(DATETIME2(3), source_row.[created_at]),
        CONVERT(DATETIME2(3), source_row.[updated_at]),
        CONVERT(DATETIME2(3), source_row.[deleted_at]),
        source_row.[ods_row_id],
        source_row.[ods_load_time]
    FROM [ODS].[MA_AMR_Job] AS source_row
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM [DWD].[dim_amr_task] AS target
        WHERE target.[job_id] = source_row.[id]
    );

    UPDATE target
    SET
        target.[esp_id] = source_row.[esp_id],
        target.[calling_box_name] = source_row.[name],
        target.[button_position] = source_row.[position],
        target.[source_created_time] = CONVERT(DATETIME2(3), source_row.[created_at]),
        target.[source_updated_time] = CONVERT(DATETIME2(3), source_row.[updated_at]),
        target.[source_deleted_time] = CONVERT(DATETIME2(3), source_row.[deleted_at]),
        target.[source_ods_row_id] = source_row.[ods_row_id],
        target.[source_ods_load_time] = source_row.[ods_load_time],
        target.[dwd_load_time] = SYSDATETIME()
    FROM [DWD].[dim_amr_calling_box] AS target
    INNER JOIN [ODS].[MA_ESP_Button] AS source_row
        ON source_row.[id] = target.[calling_box_id];

    INSERT INTO [DWD].[dim_amr_calling_box]
    (
        [calling_box_id], [esp_id], [calling_box_name], [button_position],
        [source_created_time], [source_updated_time], [source_deleted_time],
        [source_ods_row_id], [source_ods_load_time]
    )
    SELECT
        source_row.[id],
        source_row.[esp_id],
        source_row.[name],
        source_row.[position],
        CONVERT(DATETIME2(3), source_row.[created_at]),
        CONVERT(DATETIME2(3), source_row.[updated_at]),
        CONVERT(DATETIME2(3), source_row.[deleted_at]),
        source_row.[ods_row_id],
        source_row.[ods_load_time]
    FROM [ODS].[MA_ESP_Button] AS source_row
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM [DWD].[dim_amr_calling_box] AS target
        WHERE target.[calling_box_id] = source_row.[id]
    );

    /* Only queue rows explicitly attributed to a Calling Box receive the enrichment. */
    UPDATE queue_fact
    SET
        queue_fact.[calling_box_id] = queue_source.[esp_button_id],
        queue_fact.[calling_box_name] = calling_box.[calling_box_name]
    FROM [DWD].[fact_amr_queue] AS queue_fact
    INNER JOIN [ODS].[AMR_Queue] AS queue_source
        ON queue_source.[ods_row_id] = queue_fact.[source_ods_row_id]
    LEFT JOIN [DWD].[dim_amr_calling_box] AS calling_box
        ON calling_box.[calling_box_id] = queue_source.[esp_button_id]
    WHERE queue_fact.[source_schema] = N'ODS'
      AND queue_fact.[source_table] = N'AMR_Queue'
      AND queue_source.[esp_button_id] IS NOT NULL
      AND
      (
          queue_fact.[calling_box_id] IS NULL
          OR queue_fact.[calling_box_id] <> queue_source.[esp_button_id]
          OR ISNULL(queue_fact.[calling_box_name], N'') <> ISNULL(calling_box.[calling_box_name], N'')
      );

    /* Rebuild only the 30-day Web-serving horizon from refreshed DWD facts. */
    DELETE FROM [DWS].[dws_robot_calling_box_daily]
    WHERE [stat_date] >= CONVERT(DATE, @window_start)
      AND [stat_date] <= CONVERT(DATE, DATEADD(MILLISECOND, -1, @window_end));

    INSERT INTO [DWS].[dws_robot_calling_box_daily]
    (
        [stat_date], [robot_code], [robot_id], [calling_box_id], [calling_box_name], [calling_box_label],
        [calling_box_count], [first_called_at], [last_called_at]
    )
    SELECT
        CONVERT(DATE, queue_fact.[event_time]),
        queue_fact.[robot_code],
        queue_fact.[robot_id],
        queue_fact.[calling_box_id],
        MAX(queue_fact.[calling_box_name]),
        COALESCE(MAX(NULLIF(queue_fact.[calling_box_name], N'')), N'Calling Box #')
            + CASE WHEN MAX(NULLIF(queue_fact.[calling_box_name], N'')) IS NULL THEN CONVERT(NVARCHAR(20), queue_fact.[calling_box_id]) ELSE N' · #' + CONVERT(NVARCHAR(20), queue_fact.[calling_box_id]) END,
        COUNT_BIG(DISTINCT queue_fact.[queue_id]),
        MIN(queue_fact.[event_time]),
        MAX(queue_fact.[event_time])
    FROM [DWD].[fact_amr_queue] AS queue_fact
    WHERE queue_fact.[event_time] IS NOT NULL
      AND queue_fact.[event_time] >= @window_start
      AND queue_fact.[event_time] < @window_end
      AND queue_fact.[calling_box_id] IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(queue_fact.[robot_code])), N'') IS NOT NULL
    GROUP BY
        CONVERT(DATE, queue_fact.[event_time]),
        queue_fact.[robot_code],
        queue_fact.[robot_id],
        queue_fact.[calling_box_id];

    DELETE FROM [DWS].[dws_robot_assigned_task_daily]
    WHERE [stat_date] >= CONVERT(DATE, @window_start)
      AND [stat_date] <= CONVERT(DATE, DATEADD(MILLISECOND, -1, @window_end));

    INSERT INTO [DWS].[dws_robot_assigned_task_daily]
    (
        [stat_date], [robot_code], [robot_id], [job_id], [task_name], [task_label],
        [assigned_task_count], [completed_task_count], [first_assigned_at], [last_assigned_at]
    )
    SELECT
        CONVERT(DATE, queue_fact.[event_time]),
        queue_fact.[robot_code],
        queue_fact.[robot_id],
        TRY_CONVERT(INT, queue_fact.[job_id]),
        MAX(task_dim.[task_name]),
        COALESCE(MAX(NULLIF(task_dim.[task_name], N'')), N'Task #')
            + CASE WHEN MAX(NULLIF(task_dim.[task_name], N'')) IS NULL THEN CONVERT(NVARCHAR(20), TRY_CONVERT(INT, queue_fact.[job_id])) ELSE N' · #' + CONVERT(NVARCHAR(20), TRY_CONVERT(INT, queue_fact.[job_id])) END,
        COUNT_BIG(DISTINCT queue_fact.[queue_id]),
        COUNT_BIG(DISTINCT CASE
            WHEN LOWER(LTRIM(RTRIM(COALESCE(queue_fact.[queue_status], N'')))) IN (N'completed', N'compleated')
                THEN queue_fact.[queue_id]
        END),
        MIN(queue_fact.[event_time]),
        MAX(queue_fact.[event_time])
    FROM [DWD].[fact_amr_queue] AS queue_fact
    LEFT JOIN [DWD].[dim_amr_task] AS task_dim
        ON task_dim.[job_id] = TRY_CONVERT(INT, queue_fact.[job_id])
    WHERE queue_fact.[event_time] IS NOT NULL
      AND queue_fact.[event_time] >= @window_start
      AND queue_fact.[event_time] < @window_end
      AND TRY_CONVERT(INT, queue_fact.[job_id]) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(queue_fact.[robot_code])), N'') IS NOT NULL
    GROUP BY
        CONVERT(DATE, queue_fact.[event_time]),
        queue_fact.[robot_code],
        queue_fact.[robot_id],
        TRY_CONVERT(INT, queue_fact.[job_id]);

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
    N'DWS.dws_robot_calling_box_daily' AS [table_name],
    COUNT_BIG(*) AS [row_count],
    MIN([stat_date]) AS [first_stat_date],
    MAX([stat_date]) AS [last_stat_date],
    MAX([dws_load_time]) AS [latest_load_time]
FROM [DWS].[dws_robot_calling_box_daily]
UNION ALL
SELECT
    N'DWS.dws_robot_assigned_task_daily',
    COUNT_BIG(*),
    MIN([stat_date]),
    MAX([stat_date]),
    MAX([dws_load_time])
FROM [DWS].[dws_robot_assigned_task_daily];
