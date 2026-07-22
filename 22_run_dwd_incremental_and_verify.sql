USE IOT2020;
GO

/*
    Run DWD incremental load and verify the latest batch.

    Prerequisite:
    - Execute 02_create_dwd_load_procedure.sql first.
      That script now fixes DWD.sp_load_dwd_all_incremental so fact_robot_job
      no longer references manually removed columns:
          job_end_time, duration_seconds, result_code, result_message

    Scope:
    - Runs [DWD].[sp_load_dwd_all_incremental].
    - Does not directly DELETE/UPDATE business tables in this script.
      Any load behavior is controlled by [DWD].[etl_watermark] and the procedure.
*/

SET NOCOUNT ON;

IF OBJECT_ID(N'[DWD].[sp_load_dwd_all_incremental]', N'P') IS NULL
BEGIN
    SELECT N'Missing procedure: DWD.sp_load_dwd_all_incremental. Run 02_create_dwd_load_procedure.sql first.' AS [check_message];
    RETURN;
END;

DECLARE @before_batch_id BIGINT;
DECLARE @after_batch_id BIGINT;

SELECT @before_batch_id = MAX([batch_id])
FROM [DWD].[etl_batch];

EXEC [DWD].[sp_load_dwd_all_incremental];

SELECT @after_batch_id = MAX([batch_id])
FROM [DWD].[etl_batch];

SELECT TOP 20
    N'01_latest_dwd_batch' AS [check_section],
    [batch_id],
    [batch_start_time],
    [batch_end_time],
    [batch_status],
    [error_message]
FROM [DWD].[etl_batch]
WHERE [batch_id] >= ISNULL(@before_batch_id, 0)
ORDER BY [batch_id] DESC;

SELECT
    N'02_latest_dwd_load_log' AS [check_section],
    [batch_id],
    [source_schema],
    [source_table],
    [target_schema],
    [target_table],
    [load_mode],
    [rows_inserted],
    [rows_updated],
    [rows_deleted],
    [load_status],
    [error_message],
    [load_start_time],
    [load_end_time]
FROM [DWD].[etl_load_log]
WHERE [batch_id] = @after_batch_id
ORDER BY
    CASE [load_status]
        WHEN N'FAILED' THEN 1
        WHEN N'SKIPPED' THEN 2
        ELSE 3
    END,
    [target_table],
    [source_table];

SELECT
    N'03_core_fact_row_counts' AS [check_section],
    N'DWD.fact_amr_queue' AS [table_name],
    COUNT_BIG(*) AS [row_count]
FROM [DWD].[fact_amr_queue]
UNION ALL
SELECT N'03_core_fact_row_counts', N'DWD.fact_amr_subjob', COUNT_BIG(*) FROM [DWD].[fact_amr_subjob]
UNION ALL
SELECT N'03_core_fact_row_counts', N'DWD.fact_robot_battery', COUNT_BIG(*) FROM [DWD].[fact_robot_battery]
UNION ALL
SELECT N'03_core_fact_row_counts', N'DWD.fact_robot_job', COUNT_BIG(*) FROM [DWD].[fact_robot_job]
UNION ALL
SELECT N'03_core_fact_row_counts', N'DWD.fact_robot_status', COUNT_BIG(*) FROM [DWD].[fact_robot_status]
UNION ALL
SELECT N'03_core_fact_row_counts', N'DWD.fact_robot_wifi', COUNT_BIG(*) FROM [DWD].[fact_robot_wifi];

SELECT
    N'04_dwd_watermark_id_increment' AS [check_section],
    [source_table],
    [target_table],
    [load_mode],
    [watermark_column],
    [last_bigint_value],
    [last_datetime_value],
    [last_load_time],
    [is_enabled]
FROM [DWD].[etl_watermark]
WHERE [load_mode] = N'ID_INCREMENT'
ORDER BY
    [target_table],
    [source_table];

SELECT
    N'05_duplicate_source_ods_row' AS [check_section],
    N'DWD.fact_amr_queue' AS [table_name],
    COUNT_BIG(*) AS [duplicate_source_row_count]
FROM (
    SELECT [source_schema], [source_table], [source_ods_row_id]
    FROM [DWD].[fact_amr_queue]
    WHERE [source_ods_row_id] IS NOT NULL
    GROUP BY [source_schema], [source_table], [source_ods_row_id]
    HAVING COUNT_BIG(*) > 1
) AS d
UNION ALL
SELECT N'05_duplicate_source_ods_row', N'DWD.fact_amr_subjob', COUNT_BIG(*)
FROM (
    SELECT [source_schema], [source_table], [source_ods_row_id]
    FROM [DWD].[fact_amr_subjob]
    WHERE [source_ods_row_id] IS NOT NULL
    GROUP BY [source_schema], [source_table], [source_ods_row_id]
    HAVING COUNT_BIG(*) > 1
) AS d
UNION ALL
SELECT N'05_duplicate_source_ods_row', N'DWD.fact_robot_battery', COUNT_BIG(*)
FROM (
    SELECT [source_schema], [source_table], [source_ods_row_id]
    FROM [DWD].[fact_robot_battery]
    WHERE [source_ods_row_id] IS NOT NULL
    GROUP BY [source_schema], [source_table], [source_ods_row_id]
    HAVING COUNT_BIG(*) > 1
) AS d
UNION ALL
SELECT N'05_duplicate_source_ods_row', N'DWD.fact_robot_job', COUNT_BIG(*)
FROM (
    SELECT [source_schema], [source_table], [source_ods_row_id]
    FROM [DWD].[fact_robot_job]
    WHERE [source_ods_row_id] IS NOT NULL
    GROUP BY [source_schema], [source_table], [source_ods_row_id]
    HAVING COUNT_BIG(*) > 1
) AS d
UNION ALL
SELECT N'05_duplicate_source_ods_row', N'DWD.fact_robot_status', COUNT_BIG(*)
FROM (
    SELECT [source_schema], [source_table], [source_ods_row_id]
    FROM [DWD].[fact_robot_status]
    WHERE [source_ods_row_id] IS NOT NULL
    GROUP BY [source_schema], [source_table], [source_ods_row_id]
    HAVING COUNT_BIG(*) > 1
) AS d
UNION ALL
SELECT N'05_duplicate_source_ods_row', N'DWD.fact_robot_wifi', COUNT_BIG(*)
FROM (
    SELECT [source_schema], [source_table], [source_ods_row_id]
    FROM [DWD].[fact_robot_wifi]
    WHERE [source_ods_row_id] IS NOT NULL
    GROUP BY [source_schema], [source_table], [source_ods_row_id]
    HAVING COUNT_BIG(*) > 1
) AS d;
GO
