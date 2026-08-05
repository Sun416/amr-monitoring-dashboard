USE [IOT2020];

SET NOCOUNT ON;
SET XACT_ABORT ON;

/*
    Node-compatible freshness check.
    This is equivalent to 48_run_etl_freshness_check.sql, but intentionally
    contains no GO batch separators because the mssql driver sends one batch.
*/
EXEC [DWS].[sp_check_etl_freshness]
    @ods_threshold_minutes = 10,
    @dwd_threshold_minutes = 20,
    @dws_threshold_minutes = 30,
    @fail_on_stale = 0;

SELECT
    f.[check_time],
    f.[pipeline_layer],
    f.[source_schema],
    f.[source_table],
    f.[target_schema],
    f.[target_table],
    f.[source_max_id],
    f.[target_watermark],
    f.[estimated_rows_behind],
    f.[source_max_time],
    f.[target_max_time],
    f.[source_age_minutes],
    f.[target_age_minutes],
    f.[freshness_minutes],
    f.[threshold_minutes],
    f.[freshness_status],
    f.[status_detail]
FROM [DWS].[v_etl_freshness_latest] AS f
ORDER BY
    CASE f.[freshness_status]
        WHEN N'FAILED' THEN 1
        WHEN N'STALE' THEN 2
        ELSE 3
    END,
    f.[pipeline_layer],
    f.[source_table],
    f.[target_table];
