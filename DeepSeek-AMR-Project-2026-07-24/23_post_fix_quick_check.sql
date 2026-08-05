USE IOT2020;
GO

/*
    Quick check after ODS/DWD fixes.

    Read-only.
    Use after:
    1. 02_create_dwd_load_procedure.sql
    2. 21_run_ods_id_time_incremental.sql
    3. 22_run_dwd_incremental_and_verify.sql
*/

SET NOCOUNT ON;

/* 01. dbo vs ODS row-count difference for important incremental tables. */
SELECT
    N'01_dbo_vs_ods_incremental_row_diff' AS [check_section],
    v.table_name,
    src_rows.approximate_source_rows,
    ods_rows.approximate_ods_rows,
    src_rows.approximate_source_rows - ods_rows.approximate_ods_rows AS approximate_row_diff
FROM (
    VALUES
        (N'AMR_Queue'),
        (N'AMR_Subjob_Analyze'),
        (N'robot_battery_history'),
        (N'robot_job_history'),
        (N'robot_status_history'),
        (N'robot_wifi_history'),
        (N'TA_AMR_Silence_History')
) AS v(table_name)
OUTER APPLY (
    SELECT SUM(ps.row_count) AS approximate_source_rows
    FROM sys.schemas AS s
    JOIN sys.tables AS t
        ON t.schema_id = s.schema_id
    JOIN sys.dm_db_partition_stats AS ps
        ON ps.object_id = t.object_id
       AND ps.index_id IN (0, 1)
    WHERE s.name = N'dbo'
      AND t.name = v.table_name
) AS src_rows
OUTER APPLY (
    SELECT SUM(ps.row_count) AS approximate_ods_rows
    FROM sys.schemas AS s
    JOIN sys.tables AS t
        ON t.schema_id = s.schema_id
    JOIN sys.dm_db_partition_stats AS ps
        ON ps.object_id = t.object_id
       AND ps.index_id IN (0, 1)
    WHERE s.name = N'ODS'
      AND t.name = v.table_name
) AS ods_rows
ORDER BY
    ABS(COALESCE(src_rows.approximate_source_rows, 0) - COALESCE(ods_rows.approximate_ods_rows, 0)) DESC,
    v.table_name;

/* 02. Latest DWD batches. */
SELECT TOP 10
    N'02_latest_dwd_batches' AS [check_section],
    [batch_id],
    [batch_start_time],
    [batch_end_time],
    [batch_status],
    [error_message]
FROM [DWD].[etl_batch]
ORDER BY [batch_id] DESC;

/* 03. Latest failed DWD load logs. */
SELECT TOP 50
    N'03_latest_failed_dwd_load_logs' AS [check_section],
    [batch_id],
    [source_table],
    [target_table],
    [load_mode],
    [rows_inserted],
    [rows_deleted],
    [load_status],
    [error_message],
    [load_start_time],
    [load_end_time]
FROM [DWD].[etl_load_log]
WHERE [load_status] = N'FAILED'
ORDER BY
    [batch_id] DESC,
    [source_table],
    [target_table];

/* 04. DWD core fact row counts. */
SELECT N'04_dwd_core_fact_row_counts' AS [check_section], N'fact_amr_queue' AS [table_name], COUNT_BIG(*) AS [row_count] FROM [DWD].[fact_amr_queue]
UNION ALL SELECT N'04_dwd_core_fact_row_counts', N'fact_amr_subjob', COUNT_BIG(*) FROM [DWD].[fact_amr_subjob]
UNION ALL SELECT N'04_dwd_core_fact_row_counts', N'fact_robot_battery', COUNT_BIG(*) FROM [DWD].[fact_robot_battery]
UNION ALL SELECT N'04_dwd_core_fact_row_counts', N'fact_robot_job', COUNT_BIG(*) FROM [DWD].[fact_robot_job]
UNION ALL SELECT N'04_dwd_core_fact_row_counts', N'fact_robot_status', COUNT_BIG(*) FROM [DWD].[fact_robot_status]
UNION ALL SELECT N'04_dwd_core_fact_row_counts', N'fact_robot_wifi', COUNT_BIG(*) FROM [DWD].[fact_robot_wifi];

/* 05. DWD duplicate source row check. */
SELECT
    N'05_duplicate_source_ods_row' AS [check_section],
    N'fact_robot_job' AS [table_name],
    COUNT_BIG(*) AS [duplicate_source_row_count]
FROM (
    SELECT [source_schema], [source_table], [source_ods_row_id]
    FROM [DWD].[fact_robot_job]
    WHERE [source_ods_row_id] IS NOT NULL
    GROUP BY [source_schema], [source_table], [source_ods_row_id]
    HAVING COUNT_BIG(*) > 1
) AS d
UNION ALL
SELECT N'05_duplicate_source_ods_row', N'fact_robot_battery', COUNT_BIG(*)
FROM (
    SELECT [source_schema], [source_table], [source_ods_row_id]
    FROM [DWD].[fact_robot_battery]
    WHERE [source_ods_row_id] IS NOT NULL
    GROUP BY [source_schema], [source_table], [source_ods_row_id]
    HAVING COUNT_BIG(*) > 1
) AS d
UNION ALL
SELECT N'05_duplicate_source_ods_row', N'fact_robot_status', COUNT_BIG(*)
FROM (
    SELECT [source_schema], [source_table], [source_ods_row_id]
    FROM [DWD].[fact_robot_status]
    WHERE [source_ods_row_id] IS NOT NULL
    GROUP BY [source_schema], [source_table], [source_ods_row_id]
    HAVING COUNT_BIG(*) > 1
) AS d
UNION ALL
SELECT N'05_duplicate_source_ods_row', N'fact_robot_wifi', COUNT_BIG(*)
FROM (
    SELECT [source_schema], [source_table], [source_ods_row_id]
    FROM [DWD].[fact_robot_wifi]
    WHERE [source_ods_row_id] IS NOT NULL
    GROUP BY [source_schema], [source_table], [source_ods_row_id]
    HAVING COUNT_BIG(*) > 1
) AS d;
GO
