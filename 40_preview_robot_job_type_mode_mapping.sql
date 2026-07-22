USE [IOT2020];
GO

/*
    Read-only preview for the robot job type and robot mode mapping.

    Confirmed semantic path:
      ODS.robot_job_history.job_name
          -> DWD.fact_robot_job.job_type_code

      ODS.robot_job_history.(amr_id, pc_timestamp)
          -> ODS.robot_status_history.(amr_id, pc_timestamp)
          -> ODS.robot_status_history.robot_mode
          -> ODS.AMR_Robot_Mode.Mode_ID
          -> DWD.fact_robot_job.robot_mode_id / robot_mode_detail

    This script does not change any data or schema.
*/

SET NOCOUNT ON;

/* 1. Required object and column check. */
SELECT
    v.[object_name],
    CASE WHEN OBJECT_ID(v.[object_name], N'U') IS NULL THEN N'MISSING' ELSE N'OK' END AS [object_status]
FROM (VALUES
    (N'[ODS].[robot_job_history]'),
    (N'[ODS].[robot_status_history]'),
    (N'[ODS].[AMR_Robot_Mode]'),
    (N'[DWD].[fact_robot_job]'),
    (N'[DWS].[dws_robot_job_daily]')
) AS v([object_name]);

SELECT
    s.[name] AS [schema_name],
    t.[name] AS [table_name],
    c.[column_id],
    c.[name] AS [column_name],
    TYPE_NAME(c.[user_type_id]) AS [data_type],
    c.[max_length],
    c.[precision],
    c.[scale],
    c.[is_nullable]
FROM sys.tables AS t
INNER JOIN sys.schemas AS s
    ON s.[schema_id] = t.[schema_id]
INNER JOIN sys.columns AS c
    ON c.[object_id] = t.[object_id]
WHERE
       (s.[name] = N'ODS' AND t.[name] IN (N'robot_job_history', N'robot_status_history', N'AMR_Robot_Mode'))
    OR (s.[name] = N'DWD' AND t.[name] = N'fact_robot_job')
    OR (s.[name] = N'DWS' AND t.[name] = N'dws_robot_job_daily')
ORDER BY
    s.[name],
    t.[name],
    c.[column_id];

/* 2. Current mode dictionary. */
SELECT
    m.[Mode_ID],
    m.[Mode_Detail],
    m.[ods_row_id],
    m.[ods_load_time]
FROM [ODS].[AMR_Robot_Mode] AS m
ORDER BY
    TRY_CONVERT(INT, m.[Mode_ID]),
    m.[Mode_ID],
    m.[ods_row_id];

/*
    3-4. Preview and coverage check.

    DataGrip can split an IF...ELSE block incorrectly when only the current
    statement is executed. Use one dynamically selected read-only batch instead.

    The exact status lookup is executed only when the required composite index
    already exists. This prevents accidental repeated scans of the large status
    history table before script 41 creates the index.
*/
DECLARE @mapping_preview_sql NVARCHAR(MAX);

SELECT
    @mapping_preview_sql = CASE
        WHEN EXISTS (
            SELECT 1
            FROM sys.indexes AS i
            WHERE i.[object_id] = OBJECT_ID(N'[ODS].[robot_status_history]')
              AND i.[name] = N'IX_ODS_robot_status_history_amr_time'
              AND i.[is_disabled] = 0
        )
        THEN N'
;WITH latest_job AS (
    SELECT TOP (20)
        j.[ods_row_id],
        j.[id],
        j.[amr_id],
        j.[pc_timestamp],
        j.[job_name],
        j.[job_status]
    FROM [ODS].[robot_job_history] AS j
    ORDER BY j.[ods_row_id] DESC
)
SELECT
    j.[ods_row_id] AS [job_ods_row_id],
    j.[id] AS [source_job_id],
    j.[amr_id],
    j.[pc_timestamp],
    NULLIF(NULLIF(LTRIM(RTRIM(j.[job_name])), N''''), N''-'') AS [proposed_job_type_code],
    j.[job_status],
    s.[ods_row_id] AS [matched_status_ods_row_id],
    CONVERT(NVARCHAR(100), s.[robot_mode]) AS [proposed_robot_mode_id],
    m.[Mode_Detail] AS [proposed_robot_mode_detail],
    N''Exact mode matching enabled because the lookup index exists.'' AS [preview_note]
FROM latest_job AS j
OUTER APPLY (
    SELECT TOP (1)
        h.[ods_row_id],
        h.[robot_mode]
    FROM [ODS].[robot_status_history] AS h WITH (INDEX([IX_ODS_robot_status_history_amr_time]))
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
ORDER BY j.[ods_row_id] DESC;

;WITH latest_job AS (
    SELECT TOP (10000)
        j.[ods_row_id],
        j.[amr_id],
        j.[pc_timestamp],
        j.[job_name]
    FROM [ODS].[robot_job_history] AS j
    ORDER BY j.[ods_row_id] DESC
), mapped AS (
    SELECT
        j.[ods_row_id],
        NULLIF(NULLIF(LTRIM(RTRIM(j.[job_name])), N''''), N''-'') AS [job_type_code],
        s.[ods_row_id] AS [status_ods_row_id],
        s.[robot_mode],
        m.[Mode_Detail]
    FROM latest_job AS j
    OUTER APPLY (
        SELECT TOP (1)
            h.[ods_row_id],
            h.[robot_mode]
        FROM [ODS].[robot_status_history] AS h WITH (INDEX([IX_ODS_robot_status_history_amr_time]))
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
    COUNT_BIG(*) AS [sample_job_rows],
    SUM(CASE WHEN [job_type_code] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [job_type_available_rows],
    SUM(CASE WHEN [status_ods_row_id] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [exact_status_match_rows],
    SUM(CASE WHEN [robot_mode] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [mode_id_available_rows],
    SUM(CASE WHEN [Mode_Detail] IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [mode_dictionary_match_rows],
    N''Exact coverage sample used the required lookup index.'' AS [coverage_note]
FROM mapped;'
        ELSE N'
;WITH latest_job AS (
    SELECT TOP (20)
        j.[ods_row_id],
        j.[id],
        j.[amr_id],
        j.[pc_timestamp],
        j.[job_name],
        j.[job_status]
    FROM [ODS].[robot_job_history] AS j
    ORDER BY j.[ods_row_id] DESC
)
SELECT
    j.[ods_row_id] AS [job_ods_row_id],
    j.[id] AS [source_job_id],
    j.[amr_id],
    j.[pc_timestamp],
    NULLIF(NULLIF(LTRIM(RTRIM(j.[job_name])), N''''), N''-'') AS [proposed_job_type_code],
    j.[job_status],
    CONVERT(BIGINT, NULL) AS [matched_status_ods_row_id],
    CONVERT(NVARCHAR(100), NULL) AS [proposed_robot_mode_id],
    CONVERT(NVARCHAR(200), NULL) AS [proposed_robot_mode_detail],
    N''Exact mode matching skipped: run script 41 to create the required lookup index.'' AS [preview_note]
FROM latest_job AS j
ORDER BY j.[ods_row_id] DESC;

;WITH latest_job AS (
    SELECT TOP (10000)
        j.[job_name]
    FROM [ODS].[robot_job_history] AS j
    ORDER BY j.[ods_row_id] DESC
)
SELECT
    COUNT_BIG(*) AS [sample_job_rows],
    SUM(CASE WHEN NULLIF(NULLIF(LTRIM(RTRIM([job_name])), N''''), N''-'') IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [job_type_available_rows],
    CONVERT(BIGINT, NULL) AS [exact_status_match_rows],
    CONVERT(BIGINT, NULL) AS [mode_id_available_rows],
    CONVERT(BIGINT, NULL) AS [mode_dictionary_match_rows],
    N''Exact coverage skipped: script 41 has not created the ODS status lookup index.'' AS [coverage_note]
FROM latest_job;'
    END;

EXEC sys.sp_executesql @mapping_preview_sql;

/* 5. Indexes that affect the proposed lookup and aggregation. */
SELECT
    s.[name] AS [schema_name],
    t.[name] AS [table_name],
    i.[name] AS [index_name],
    i.[is_unique],
    i.[type_desc],
    ic.[key_ordinal],
    ic.[is_included_column],
    c.[name] AS [column_name]
FROM sys.tables AS t
INNER JOIN sys.schemas AS s
    ON s.[schema_id] = t.[schema_id]
INNER JOIN sys.indexes AS i
    ON i.[object_id] = t.[object_id]
INNER JOIN sys.index_columns AS ic
    ON ic.[object_id] = i.[object_id]
   AND ic.[index_id] = i.[index_id]
INNER JOIN sys.columns AS c
    ON c.[object_id] = ic.[object_id]
   AND c.[column_id] = ic.[column_id]
WHERE
       (s.[name] = N'ODS' AND t.[name] IN (N'robot_job_history', N'robot_status_history', N'AMR_Robot_Mode'))
    OR (s.[name] = N'DWD' AND t.[name] = N'fact_robot_job')
    OR (s.[name] = N'DWS' AND t.[name] = N'dws_robot_job_daily')
ORDER BY
    s.[name],
    t.[name],
    i.[index_id],
    ic.[key_ordinal],
    ic.[index_column_id];
GO
