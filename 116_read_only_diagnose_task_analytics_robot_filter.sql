USE [IOT2020];

/*
    Read-only diagnosis for the Task Analytics robot filter.

    Purpose
    -------
    The Web Task Analytics bottom panels (Calling Box leaderboard,
    Assigned-task leaderboard and their two hourly trend charts) filter
    DWS.dws_robot_calling_box_hourly / DWS.dws_robot_assigned_task_hourly by
    robot_code. When one specific robot is selected the panels can return
    empty even though the execution trend (dws_robot_task_hourly) has data.

    This script compares robot_code values across the three hourly serving
    tables and against dbo.MA_AMR identity to tell whether the cause is a
    missing-data gap or a robot_code mismatch (numeric id vs display name).
*/

SET NOCOUNT ON;

/* 1. Overall row and distinct-robot counts per serving table. */
SELECT
    N'task_hourly'           AS [source_table],
    COUNT_BIG(1)             AS [row_count],
    COUNT(DISTINCT robot_code) AS [robot_code_count],
    CONVERT(NVARCHAR(19), MIN(stat_hour), 120) AS [min_stat_hour],
    CONVERT(NVARCHAR(19), MAX(stat_hour), 120) AS [max_stat_hour]
FROM [DWS].[dws_robot_task_hourly];

SELECT
    N'calling_box_hourly'    AS [source_table],
    COUNT_BIG(1)             AS [row_count],
    COUNT(DISTINCT robot_code) AS [robot_code_count],
    CONVERT(NVARCHAR(19), MIN(stat_hour), 120) AS [min_stat_hour],
    CONVERT(NVARCHAR(19), MAX(stat_hour), 120) AS [max_stat_hour]
FROM [DWS].[dws_robot_calling_box_hourly];

SELECT
    N'assigned_task_hourly'  AS [source_table],
    COUNT_BIG(1)             AS [row_count],
    COUNT(DISTINCT robot_code) AS [robot_code_count],
    CONVERT(NVARCHAR(19), MIN(stat_hour), 120) AS [min_stat_hour],
    CONVERT(NVARCHAR(19), MAX(stat_hour), 120) AS [max_stat_hour]
FROM [DWS].[dws_robot_assigned_task_hourly];

/* 2. Distinct robot_code values per serving table. */
SELECT N'task_hourly' AS [source_table], robot_code FROM (SELECT DISTINCT robot_code FROM [DWS].[dws_robot_task_hourly]) AS d ORDER BY robot_code;
SELECT N'calling_box_hourly' AS [source_table], robot_code FROM (SELECT DISTINCT robot_code FROM [DWS].[dws_robot_calling_box_hourly]) AS d ORDER BY robot_code;
SELECT N'assigned_task_hourly' AS [source_table], robot_code FROM (SELECT DISTINCT robot_code FROM [DWS].[dws_robot_assigned_task_hourly]) AS d ORDER BY robot_code;

/* 3. Robot codes present in task_hourly but missing from the two bottom-panel tables. */
SELECT DISTINCT
    h.[robot_code],
    CASE WHEN a.[robot_code] IS NULL THEN N'MISSING_FROM_ASSIGNED_TASK_HOURLY' ELSE N'OK' END AS [assigned_task_status],
    CASE WHEN c.[robot_code] IS NULL THEN N'MISSING_FROM_CALLING_BOX_HOURLY' ELSE N'OK' END AS [calling_box_status]
FROM [DWS].[dws_robot_task_hourly] AS h
LEFT JOIN (SELECT DISTINCT robot_code FROM [DWS].[dws_robot_assigned_task_hourly]) AS a
    ON a.[robot_code] = h.[robot_code]
LEFT JOIN (SELECT DISTINCT robot_code FROM [DWS].[dws_robot_calling_box_hourly]) AS c
    ON c.[robot_code] = h.[robot_code]
ORDER BY h.[robot_code];

/* 4. Identity check: how many task_hourly robot_code values are numeric ids vs names. */
SELECT
    CASE
        WHEN TRY_CONVERT(BIGINT, h.[robot_code]) IS NOT NULL THEN N'NUMERIC_CODE'
        ELSE N'DISPLAY_NAME'
    END AS [robot_code_style],
    COUNT(DISTINCT h.[robot_code]) AS [robot_code_count]
FROM [DWS].[dws_robot_task_hourly] AS h
GROUP BY CASE
    WHEN TRY_CONVERT(BIGINT, h.[robot_code]) IS NOT NULL THEN N'NUMERIC_CODE'
    ELSE N'DISPLAY_NAME'
END;

SELECT
    CASE
        WHEN TRY_CONVERT(BIGINT, a.[robot_code]) IS NOT NULL THEN N'NUMERIC_CODE'
        ELSE N'DISPLAY_NAME'
    END AS [robot_code_style],
    COUNT(DISTINCT a.[robot_code]) AS [robot_code_count]
FROM [DWS].[dws_robot_assigned_task_hourly] AS a
GROUP BY CASE
    WHEN TRY_CONVERT(BIGINT, a.[robot_code]) IS NOT NULL THEN N'NUMERIC_CODE'
    ELSE N'DISPLAY_NAME'
END;

/* 5. dbo.MA_AMR identity for reference. */
SELECT
    [id],
    [name],
    [is_active]
FROM [dbo].[MA_AMR]
ORDER BY [id];
