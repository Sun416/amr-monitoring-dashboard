USE [IOT2020];
GO

/*
    Read-only verification for scripts 40-44.
    Large DWD checks use the newest 100,000 rows instead of scanning the entire
    fact table. DWS checks are exact because the aggregate table is small.
*/

SET NOCOUNT ON;

/* 1. Object, procedure, and required-index status. */
SELECT
    v.[object_name],
    v.[object_type],
    CASE
        WHEN v.[object_type] = N'TABLE' AND OBJECT_ID(v.[object_name], N'U') IS NOT NULL THEN N'OK'
        WHEN v.[object_type] = N'PROCEDURE' AND OBJECT_ID(v.[object_name], N'P') IS NOT NULL THEN N'OK'
        ELSE N'MISSING'
    END AS [object_status]
FROM (VALUES
    (N'[DWD].[etl_robot_job_mode_watermark]', N'TABLE'),
    (N'[DWD].[sp_enrich_robot_job_type_mode_incremental]', N'PROCEDURE'),
    (N'[DWD].[sp_backfill_robot_job_type_mode]', N'PROCEDURE'),
    (N'[DWS].[sp_refresh_robot_job_daily_by_type_mode]', N'PROCEDURE'),
    (N'[DWS].[sp_load_dws_core_upsert]', N'PROCEDURE')
) AS v([object_name], [object_type])
ORDER BY v.[object_name];

SELECT
    s.[name] AS [schema_name],
    t.[name] AS [table_name],
    i.[name] AS [index_name],
    i.[is_unique],
    i.[is_disabled],
    i.[type_desc]
FROM sys.indexes AS i
INNER JOIN sys.tables AS t
    ON t.[object_id] = i.[object_id]
INNER JOIN sys.schemas AS s
    ON s.[schema_id] = t.[schema_id]
WHERE i.[name] IN (
    N'IX_ODS_AMR_Robot_Mode_mode_id',
    N'IX_ODS_robot_status_history_amr_time',
    N'UX_DWS_robot_job_daily_robot_date_type'
)
ORDER BY
    s.[name],
    t.[name],
    i.[name];

/* 2. Saved incremental and backfill progress. */
SELECT
    w.[pipeline_name],
    w.[last_incremental_source_ods_row_id],
    w.[last_backfill_source_ods_row_id],
    w.[last_incremental_success_time],
    w.[last_backfill_success_time],
    w.[last_error_message],
    w.[update_time]
FROM [DWD].[etl_robot_job_mode_watermark] AS w
WHERE w.[pipeline_name] = N'robot_job_type_mode';

/* 3. Fill rate on the newest 100,000 DWD job rows. */
;WITH latest_job AS (
    SELECT TOP (100000)
        f.[job_fact_id],
        f.[source_ods_row_id],
        f.[job_type_code],
        f.[robot_mode_id],
        f.[robot_mode_detail],
        f.[source_status_ods_row_id]
    FROM [DWD].[fact_robot_job] AS f
    WHERE f.[source_schema] = N'ODS'
      AND f.[source_table] = N'robot_job_history'
    ORDER BY f.[source_ods_row_id] DESC
)
SELECT
    COUNT_BIG(*) AS [sample_rows],
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM([job_type_code])), N'') IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [job_type_filled_rows],
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM([robot_mode_id])), N'') IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [mode_id_filled_rows],
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM([robot_mode_detail])), N'') IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [mode_detail_filled_rows],
    SUM(CASE WHEN [source_status_ods_row_id] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [traceable_status_match_rows],
    MIN([source_ods_row_id]) AS [sample_min_source_ods_row_id],
    MAX([source_ods_row_id]) AS [sample_max_source_ods_row_id]
FROM latest_job;

/* 4. Reconcile the newest 10,000 DWD rows with the raw ODS mapping. */
;WITH latest_fact AS (
    SELECT TOP (10000)
        f.[job_fact_id],
        f.[source_ods_row_id],
        f.[job_type_code],
        f.[robot_mode_id],
        f.[robot_mode_detail],
        f.[source_status_ods_row_id]
    FROM [DWD].[fact_robot_job] AS f
    WHERE f.[source_schema] = N'ODS'
      AND f.[source_table] = N'robot_job_history'
    ORDER BY f.[source_ods_row_id] DESC
), comparison AS (
    SELECT
        f.[job_fact_id],
        f.[job_type_code],
        f.[robot_mode_id],
        f.[robot_mode_detail],
        f.[source_status_ods_row_id],
        CASE
            WHEN NULLIF(LTRIM(RTRIM(j.[job_name])), N'') IS NULL THEN NULL
            WHEN UPPER(LTRIM(RTRIM(j.[job_name]))) IN (N'-', N'NULL', N'UNDEFINED') THEN NULL
            ELSE LTRIM(RTRIM(j.[job_name]))
        END AS [expected_job_type_code],
        CONVERT(NVARCHAR(100), s.[robot_mode]) AS [expected_robot_mode_id],
        m.[Mode_Detail] AS [expected_robot_mode_detail],
        s.[ods_row_id] AS [expected_status_ods_row_id]
    FROM latest_fact AS f
    INNER JOIN [ODS].[robot_job_history] AS j
        ON j.[ods_row_id] = f.[source_ods_row_id]
    OUTER APPLY (
        SELECT TOP (1)
            h.[ods_row_id],
            h.[robot_mode]
        FROM [ODS].[robot_status_history] AS h
        WHERE h.[amr_id] = j.[amr_id]
          AND h.[pc_timestamp] = j.[pc_timestamp]
        ORDER BY h.[ods_row_id] DESC
    ) AS s
    OUTER APPLY (
        SELECT TOP (1)
            d.[Mode_Detail]
        FROM [ODS].[AMR_Robot_Mode] AS d
        WHERE d.[Mode_ID] = CONVERT(NVARCHAR(100), s.[robot_mode])
        ORDER BY d.[ods_row_id] DESC
    ) AS m
)
SELECT
    COUNT_BIG(*) AS [sample_rows],
    SUM(CASE WHEN ISNULL([job_type_code], N'') <> ISNULL([expected_job_type_code], N'') THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [job_type_mismatch_rows],
    SUM(CASE WHEN ISNULL([robot_mode_id], N'') <> ISNULL([expected_robot_mode_id], N'') THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [mode_id_mismatch_rows],
    SUM(CASE WHEN ISNULL([robot_mode_detail], N'') <> ISNULL([expected_robot_mode_detail], N'') THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [mode_detail_mismatch_rows],
    SUM(CASE WHEN ISNULL([source_status_ods_row_id], -1) <> ISNULL([expected_status_ods_row_id], -1) THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [status_trace_mismatch_rows]
FROM comparison;

/* 5. Exact DWS grain and total checks. */
SELECT
    COUNT_BIG(*) AS [dws_rows],
    SUM(d.[job_count]) AS [total_job_count],
    SUM(d.[distinct_job_count]) AS [total_distinct_queue_count],
    SUM(d.[completed_status_count]) AS [total_completed_status_count],
    SUM(d.[failed_status_count]) AS [total_failed_status_count],
    MIN(d.[stat_date]) AS [min_stat_date],
    MAX(d.[stat_date]) AS [max_stat_date]
FROM [DWS].[dws_robot_job_daily] AS d;

SELECT
    d.[stat_date],
    d.[robot_code],
    d.[job_type_code],
    d.[robot_mode_id],
    COUNT_BIG(*) AS [duplicate_rows]
FROM [DWS].[dws_robot_job_daily] AS d
GROUP BY
    d.[stat_date],
    d.[robot_code],
    d.[job_type_code],
    d.[robot_mode_id]
HAVING COUNT_BIG(*) > 1
ORDER BY
    d.[stat_date],
    d.[robot_code],
    d.[job_type_code],
    d.[robot_mode_id];

/* Expected result: zero detail rows carrying queue rollup metrics. */
SELECT
    COUNT_BIG(*) AS [invalid_detail_metric_rows]
FROM [DWS].[dws_robot_job_daily] AS d
WHERE COALESCE(d.[job_type_code], N'') <> N'__ALL__'
  AND (
         d.[distinct_job_count] <> 0
      OR d.[completed_status_count] <> 0
      OR d.[failed_status_count] <> 0
  );

/* Expected result: zero malformed rollup rows. */
SELECT
    COUNT_BIG(*) AS [invalid_rollup_rows]
FROM [DWS].[dws_robot_job_daily] AS d
WHERE
       (d.[job_type_code] = N'__ALL__' AND ISNULL(d.[robot_mode_id], N'') <> N'__ALL__')
    OR (d.[robot_mode_id] = N'__ALL__' AND ISNULL(d.[job_type_code], N'') <> N'__ALL__')
    OR (d.[job_type_code] = N'__ALL__' AND d.[job_count] <> 0);

/* 6. Largest DWS type/mode combinations for a quick business review. */
SELECT TOP (100)
    d.[job_type_code],
    d.[robot_mode_id],
    d.[robot_mode_detail],
    SUM(d.[job_count]) AS [job_count]
FROM [DWS].[dws_robot_job_daily] AS d
WHERE d.[job_type_code] <> N'__ALL__'
GROUP BY
    d.[job_type_code],
    d.[robot_mode_id],
    d.[robot_mode_detail]
ORDER BY
    SUM(d.[job_count]) DESC,
    d.[job_type_code],
    d.[robot_mode_id];

/* 7. Latest related DWS load records. */
SELECT TOP (20)
    l.[load_id],
    l.[batch_id],
    l.[target_table],
    l.[source_table],
    l.[load_mode],
    l.[affected_rows],
    l.[load_status],
    l.[error_message],
    l.[load_start_time],
    l.[load_end_time]
FROM [DWS].[etl_load_log] AS l
WHERE l.[target_schema] = N'DWS'
  AND l.[target_table] = N'dws_robot_job_daily'
ORDER BY l.[load_id] DESC;
GO
