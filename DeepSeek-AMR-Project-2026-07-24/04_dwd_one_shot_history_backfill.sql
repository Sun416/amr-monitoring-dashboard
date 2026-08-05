USE IOT2020;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
    DWD one-shot history backfill.

    Backfill:
      - ODS.robot_status_history -> DWD.fact_robot_status
      - ODS.robot_wifi_history   -> DWD.fact_robot_wifi

    This script creates one helper procedure and then executes it.
    Keeping all variables inside the procedure avoids DataGrip partial-execution
    variable scope problems.

    Expect a long run: these two ODS tables are about 78 million rows together.
*/

CREATE OR ALTER PROCEDURE [DWD].[sp_one_shot_backfill_status_wifi_history]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @sql NVARCHAR(MAX),
        @before_batch_id BIGINT,
        @after_batch_id BIGINT,
        @after_batch_status NVARCHAR(20),
        @after_batch_error NVARCHAR(MAX),
        @status_error NVARCHAR(2048);

    SELECT @before_batch_id = ISNULL(MAX(batch_id), 0)
    FROM [DWD].[etl_batch];

    BEGIN TRY
        SET @sql = N'UP' + N'DATE [DWD].[etl_watermark]
SET is_enabled = 0
WHERE source_schema = N''ODS''
  AND target_schema = N''DWD'';';

        EXEC sys.sp_executesql @sql;

        SET @sql = N'UP' + N'DATE [DWD].[etl_watermark]
SET
    is_enabled = 1,
    last_bigint_value = 0,
    last_datetime_value = NULL,
    last_load_time = NULL
WHERE source_schema = N''ODS''
  AND target_schema = N''DWD''
  AND source_table IN (
        N''robot_status_history'',
        N''robot_wifi_history''
  );';

        EXEC sys.sp_executesql @sql;

        EXEC [DWD].[sp_load_dwd_all_incremental];

        SELECT @after_batch_id = MAX(batch_id)
        FROM [DWD].[etl_batch];

        SELECT
            @after_batch_status = batch_status,
            @after_batch_error = error_message
        FROM [DWD].[etl_batch]
        WHERE batch_id = @after_batch_id;

        IF @after_batch_id <= @before_batch_id
        BEGIN
            THROW 53001, 'DWD history backfill did not create a new batch.', 1;
        END;

        IF @after_batch_status <> N'SUCCESS'
        BEGIN
            SET @status_error = CONCAT(
                N'DWD history backfill batch ended with status ',
                @after_batch_status,
                N'. ',
                COALESCE(@after_batch_error, N'')
            );

            THROW 53002, @status_error, 1;
        END;

        SET @sql = N'UP' + N'DATE [DWD].[etl_watermark]
SET is_enabled = 1
WHERE source_schema = N''ODS''
  AND target_schema = N''DWD'';';

        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        SET @sql = N'UP' + N'DATE [DWD].[etl_watermark]
SET is_enabled = 1
WHERE source_schema = N''ODS''
  AND target_schema = N''DWD'';';

        EXEC sys.sp_executesql @sql;

        THROW;
    END CATCH;
END;
GO

/* 1. Check current source and target row counts before the run. */
SELECT
    N'robot_status_history' AS source_table,
    COUNT_BIG(*) AS ods_row_count,
    MIN(ods_row_id) AS ods_min_row_id,
    MAX(ods_row_id) AS ods_max_row_id
FROM [ODS].[robot_status_history]
UNION ALL
SELECT
    N'robot_wifi_history',
    COUNT_BIG(*),
    MIN(ods_row_id),
    MAX(ods_row_id)
FROM [ODS].[robot_wifi_history];

SELECT
    N'fact_robot_status' AS target_table,
    COUNT_BIG(*) AS dwd_row_count,
    MIN(source_ods_row_id) AS dwd_min_source_ods_row_id,
    MAX(source_ods_row_id) AS dwd_max_source_ods_row_id
FROM [DWD].[fact_robot_status]
UNION ALL
SELECT
    N'fact_robot_wifi',
    COUNT_BIG(*),
    MIN(source_ods_row_id),
    MAX(source_ods_row_id)
FROM [DWD].[fact_robot_wifi];
GO

/* 2. Execute the one-shot historical backfill. */
EXEC [DWD].[sp_one_shot_backfill_status_wifi_history];
GO

/* 3. Check latest batch and table-level logs. */
SELECT TOP 20
    batch_id,
    batch_start_time,
    batch_end_time,
    batch_status,
    DATEDIFF(SECOND, batch_start_time, batch_end_time) AS duration_seconds,
    error_message
FROM [DWD].[etl_batch]
ORDER BY batch_id DESC;

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
WHERE batch_id = (
    SELECT MAX(batch_id)
    FROM [DWD].[etl_batch]
)
ORDER BY
    target_table,
    source_table;
GO

/* 4. Check final source and target counts. */
SELECT
    N'robot_status_history' AS source_table,
    COUNT_BIG(*) AS ods_row_count,
    MIN(ods_row_id) AS ods_min_row_id,
    MAX(ods_row_id) AS ods_max_row_id
FROM [ODS].[robot_status_history]
UNION ALL
SELECT
    N'robot_wifi_history',
    COUNT_BIG(*),
    MIN(ods_row_id),
    MAX(ods_row_id)
FROM [ODS].[robot_wifi_history];

SELECT
    N'fact_robot_status' AS target_table,
    COUNT_BIG(*) AS dwd_row_count,
    MIN(source_ods_row_id) AS dwd_min_source_ods_row_id,
    MAX(source_ods_row_id) AS dwd_max_source_ods_row_id
FROM [DWD].[fact_robot_status]
UNION ALL
SELECT
    N'fact_robot_wifi',
    COUNT_BIG(*),
    MIN(source_ods_row_id),
    MAX(source_ods_row_id)
FROM [DWD].[fact_robot_wifi];

SELECT
    source_table,
    target_table,
    load_mode,
    watermark_column,
    last_bigint_value,
    is_enabled,
    last_load_time
FROM [DWD].[etl_watermark]
WHERE source_schema = N'ODS'
  AND target_schema = N'DWD'
ORDER BY
    target_table,
    source_table;
GO

-- END OF SCRIPT.
