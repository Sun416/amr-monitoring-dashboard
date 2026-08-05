/*
    Runs one bounded incremental load and verifies source traceability.
    Re-running this script is safe: source tuples are unique and the loader
    advances by ODS ods_row_id.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'IOT2020'
BEGIN
    THROW 55300, N'Expected database IOT2020.', 1;
END;

IF OBJECT_ID(N'[DWD].[sp_load_robot_operation_event_incremental]', N'P') IS NULL
BEGIN
    THROW 55301, N'Run script 52_install_robot_event_incremental_loader.sql first.', 1;
END;

SELECT
    watermark.[source_schema],
    watermark.[source_table],
    watermark.[last_ods_row_id],
    watermark.[last_event_time],
    watermark.[last_success_time],
    watermark.[last_source_row_count],
    watermark.[last_inserted_event_count]
FROM [DWD].[robot_event_watermark] AS watermark
ORDER BY watermark.[source_schema], watermark.[source_table];

EXEC [DWD].[sp_load_robot_operation_event_incremental]
    @batch_size = 5000,
    @bootstrap_rows = 5000;

SELECT
    coverage.[source_schema],
    coverage.[source_table],
    coverage.[event_category],
    coverage.[event_type],
    coverage.[event_count],
    coverage.[robot_attributed_event_count],
    coverage.[first_event_time],
    coverage.[latest_event_time],
    coverage.[latest_load_time]
FROM [DWS].[v_robot_event_audit_coverage] AS coverage
ORDER BY
    coverage.[source_schema],
    coverage.[source_table],
    coverage.[event_category],
    coverage.[event_type];

SELECT
    duplicate_event.[source_schema],
    duplicate_event.[source_table],
    duplicate_event.[source_ods_row_id],
    duplicate_event.[source_event_part],
    COUNT_BIG(1) AS [duplicate_count]
FROM [DWD].[fact_robot_operation_event] AS duplicate_event
GROUP BY
    duplicate_event.[source_schema],
    duplicate_event.[source_table],
    duplicate_event.[source_ods_row_id],
    duplicate_event.[source_event_part]
HAVING COUNT_BIG(1) > 1;

SELECT
    watermark.[source_schema],
    watermark.[source_table],
    watermark.[last_ods_row_id],
    source_anchor.[source_max_ods_row_id],
    source_anchor.[source_max_ods_row_id] - watermark.[last_ods_row_id] AS [remaining_source_rows_by_id],
    watermark.[last_event_time],
    watermark.[last_success_time],
    watermark.[last_source_row_count],
    watermark.[last_inserted_event_count]
FROM [DWD].[robot_event_watermark] AS watermark
INNER JOIN (
    SELECT
        N'ODS' AS [source_schema],
        N'AMR_Queue' AS [source_table],
        MAX(source_row.[ods_row_id]) AS [source_max_ods_row_id]
    FROM [ODS].[AMR_Queue] AS source_row
    UNION ALL
    SELECT
        N'ODS',
        N'TA_AMR',
        MAX(source_row.[ods_row_id])
    FROM [ODS].[TA_AMR] AS source_row
    UNION ALL
    SELECT
        N'ODS',
        N'MA_AMR_Project_Assignment',
        MAX(source_row.[ods_row_id])
    FROM [ODS].[MA_AMR_Project_Assignment] AS source_row
) AS source_anchor
    ON source_anchor.[source_schema] = watermark.[source_schema]
   AND source_anchor.[source_table] = watermark.[source_table]
ORDER BY watermark.[source_schema], watermark.[source_table];

