USE [IOT2020];
GO

/*
    只读诊断：DWS.dws_robot_job_daily 三个指标全为 0。

    本版本不使用 IF、RAISERROR、变量或临时表，
    避免 DataGrip 将 T-SQL 控制语句错误拆分。

    每次只检查最近 100000 条 ODS/DWD 记录。
    本脚本不会修改任何持久表数据。
*/

/* 结果 1：DWS 当前指标情况。 */
SELECT
    COUNT_BIG(*) AS [dws_rows],
    SUM(CASE WHEN d.[distinct_job_count] = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [distinct_job_count_zero_rows],
    SUM(CASE WHEN d.[completed_status_count] = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [completed_status_count_zero_rows],
    SUM(CASE WHEN d.[failed_status_count] = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [failed_status_count_zero_rows],
    SUM(d.[job_count]) AS [total_job_rows],
    SUM(d.[distinct_job_count]) AS [total_distinct_job_count],
    SUM(d.[completed_status_count]) AS [total_completed_status_count],
    SUM(d.[failed_status_count]) AS [total_failed_status_count]
FROM [DWS].[dws_robot_job_daily] AS d;

/* 结果 2：DWD 最近 100000 条记录的字段完整度。 */
;WITH [dwd_job_sample] AS (
    SELECT TOP (100000)
        fj.[job_fact_id],
        fj.[job_id],
        fj.[job_type_code],
        fj.[job_status],
        fj.[source_ods_row_id]
    FROM [DWD].[fact_robot_job] AS fj
    WHERE fj.[source_schema] = N'ODS'
      AND fj.[source_table] = N'robot_job_history'
    ORDER BY fj.[job_fact_id] DESC
)
SELECT
    COUNT_BIG(*) AS [sample_rows],
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(s.[job_id])), N'') IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [null_or_blank_job_id_rows],
    COUNT(DISTINCT NULLIF(LTRIM(RTRIM(s.[job_id])), N'')) AS [distinct_nonblank_job_id_count],
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(s.[job_type_code])), N'') IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [null_or_blank_job_type_rows],
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(s.[job_status])), N'') IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [null_or_blank_job_status_rows]
FROM [dwd_job_sample] AS s;

/* 结果 3：DWD.job_status 实际取值。 */
;WITH [dwd_job_sample] AS (
    SELECT TOP (100000)
        fj.[job_fact_id],
        fj.[job_status]
    FROM [DWD].[fact_robot_job] AS fj
    WHERE fj.[source_schema] = N'ODS'
      AND fj.[source_table] = N'robot_job_history'
    ORDER BY fj.[job_fact_id] DESC
)
SELECT TOP (50)
    COALESCE(NULLIF(LTRIM(RTRIM(s.[job_status])), N''), N'(NULL/BLANK)') AS [dwd_job_status],
    COUNT_BIG(*) AS [row_count]
FROM [dwd_job_sample] AS s
GROUP BY COALESCE(NULLIF(LTRIM(RTRIM(s.[job_status])), N''), N'(NULL/BLANK)')
ORDER BY [row_count] DESC, [dwd_job_status];

/* 结果 4：ODS 最近 100000 条记录的源字段完整度。 */
;WITH [ods_job_sample] AS (
    SELECT TOP (100000)
        o.[ods_row_id],
        TRY_CONVERT(NVARCHAR(100), o.[id]) AS [source_id],
        TRY_CONVERT(NVARCHAR(200), o.[job_name]) AS [source_job_name],
        TRY_CONVERT(NVARCHAR(100), o.[job_status]) AS [source_job_status]
    FROM [ODS].[robot_job_history] AS o
    ORDER BY o.[ods_row_id] DESC
)
SELECT
    COUNT_BIG(*) AS [sample_rows],
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(o.[source_id])), N'') IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [null_or_blank_id_rows],
    COUNT(DISTINCT NULLIF(LTRIM(RTRIM(o.[source_id])), N'')) AS [distinct_source_id_count],
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(o.[source_job_name])), N'') IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [null_or_blank_job_name_rows],
    COUNT(DISTINCT NULLIF(LTRIM(RTRIM(o.[source_job_name])), N'')) AS [distinct_job_name_count],
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(o.[source_job_status])), N'') IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [null_or_blank_job_status_rows]
FROM [ods_job_sample] AS o;

/* 结果 5：最重要——ODS.job_status 真实取值。 */
;WITH [ods_job_sample] AS (
    SELECT TOP (100000)
        o.[ods_row_id],
        TRY_CONVERT(NVARCHAR(100), o.[job_status]) AS [source_job_status]
    FROM [ODS].[robot_job_history] AS o
    ORDER BY o.[ods_row_id] DESC
)
SELECT TOP (50)
    COALESCE(NULLIF(LTRIM(RTRIM(o.[source_job_status])), N''), N'(NULL/BLANK)') AS [ods_job_status],
    COUNT_BIG(*) AS [row_count]
FROM [ods_job_sample] AS o
GROUP BY COALESCE(NULLIF(LTRIM(RTRIM(o.[source_job_status])), N''), N'(NULL/BLANK)')
ORDER BY [row_count] DESC, [ods_job_status];

/* 结果 6：ODS.job_name 真实取值。 */
;WITH [ods_job_sample] AS (
    SELECT TOP (100000)
        o.[ods_row_id],
        TRY_CONVERT(NVARCHAR(200), o.[job_name]) AS [source_job_name]
    FROM [ODS].[robot_job_history] AS o
    ORDER BY o.[ods_row_id] DESC
)
SELECT TOP (50)
    COALESCE(NULLIF(LTRIM(RTRIM(o.[source_job_name])), N''), N'(NULL/BLANK)') AS [ods_job_name],
    COUNT_BIG(*) AS [row_count]
FROM [ods_job_sample] AS o
GROUP BY COALESCE(NULLIF(LTRIM(RTRIM(o.[source_job_name])), N''), N'(NULL/BLANK)')
ORDER BY [row_count] DESC, [ods_job_name];

/* 结果 7：ODS -> DWD 同一源记录字段对照。 */
;WITH [ods_job_sample] AS (
    SELECT TOP (100000)
        o.[ods_row_id],
        TRY_CONVERT(NVARCHAR(100), o.[id]) AS [source_id],
        TRY_CONVERT(NVARCHAR(100), o.[amr_id]) AS [source_amr_id],
        TRY_CONVERT(NVARCHAR(200), o.[job_name]) AS [source_job_name],
        TRY_CONVERT(NVARCHAR(100), o.[job_status]) AS [source_job_status],
        TRY_CONVERT(DATETIME2(3), o.[robot_datetime]) AS [source_robot_datetime]
    FROM [ODS].[robot_job_history] AS o
    ORDER BY o.[ods_row_id] DESC
)
SELECT TOP (100)
    o.[ods_row_id],
    o.[source_id] AS [ods_id],
    d.[job_id] AS [dwd_job_id],
    o.[source_job_name] AS [ods_job_name],
    d.[job_type_code] AS [dwd_job_type_code],
    o.[source_job_status] AS [ods_job_status],
    d.[job_status] AS [dwd_job_status],
    o.[source_amr_id] AS [ods_amr_id],
    d.[robot_id] AS [dwd_robot_id],
    d.[robot_code] AS [dwd_robot_code],
    o.[source_robot_datetime],
    d.[job_start_time] AS [dwd_job_start_time]
FROM [ods_job_sample] AS o
LEFT JOIN [DWD].[fact_robot_job] AS d
    ON d.[source_schema] = N'ODS'
   AND d.[source_table] = N'robot_job_history'
   AND d.[source_ods_row_id] = o.[ods_row_id]
ORDER BY o.[ods_row_id] DESC;

/* 结果 8：当前建议映射，仅展示，不修改数据。 */
SELECT
    v.[dwd_column],
    v.[recommended_ods_column],
    v.[reason]
FROM (VALUES
    (N'job_id', N'id', N'先确认 id 是作业编号还是普通历史行编号。'),
    (N'job_type_code', N'job_name', N'ODS 中实际描述作业类型或名称的字段。'),
    (N'job_status', N'job_status', N'需要根据结果 5 定义成功和失败状态。'),
    (N'robot_id', N'amr_id', N'机器人标识字段。'),
    (N'robot_code', N'amr_id', N'没有独立 robot_code 时可使用 amr_id。'),
    (N'job_start_time', N'robot_datetime', N'机器人事件时间。')
) AS v ([dwd_column], [recommended_ods_column], [reason])
ORDER BY v.[dwd_column];
GO
