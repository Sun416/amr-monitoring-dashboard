USE [IOT2020];

SET NOCOUNT ON;

/* Installed procedure body, to confirm which fact tables it reconciles. */
SELECT
    OBJECT_DEFINITION(OBJECT_ID(N'[DWD].[sp_reconcile_robot_identity_for_batch]')) AS [procedure_definition];

/* Current numeric robot_code batches across the four DWD fact tables. */
SELECT
    N'fact_amr_queue' AS [table_name],
    [dwd_batch_id],
    COUNT_BIG(1) AS [numeric_robot_code_rows]
FROM [DWD].[fact_amr_queue] AS fact_row
WHERE TRY_CONVERT(INT, fact_row.[robot_code]) IS NOT NULL
GROUP BY [dwd_batch_id]
ORDER BY [dwd_batch_id];

SELECT
    N'fact_robot_job' AS [table_name],
    [dwd_batch_id],
    COUNT_BIG(1) AS [numeric_robot_code_rows]
FROM [DWD].[fact_robot_job] AS fact_row
WHERE TRY_CONVERT(INT, fact_row.[robot_code]) IS NOT NULL
GROUP BY [dwd_batch_id]
ORDER BY [dwd_batch_id];

SELECT
    N'fact_robot_status' AS [table_name],
    [dwd_batch_id],
    COUNT_BIG(1) AS [numeric_robot_code_rows]
FROM [DWD].[fact_robot_status] AS fact_row
WHERE TRY_CONVERT(INT, fact_row.[robot_code]) IS NOT NULL
GROUP BY [dwd_batch_id]
ORDER BY [dwd_batch_id];

SELECT
    N'fact_robot_battery' AS [table_name],
    [dwd_batch_id],
    COUNT_BIG(1) AS [numeric_robot_code_rows]
FROM [DWD].[fact_robot_battery] AS fact_row
WHERE TRY_CONVERT(INT, fact_row.[robot_code]) IS NOT NULL
GROUP BY [dwd_batch_id]
ORDER BY [dwd_batch_id];
