USE [IOT2020];

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'[DWS].[sp_check_etl_freshness]', N'P') IS NULL
BEGIN
    RAISERROR(N'Missing procedure: DWS.sp_check_etl_freshness. Run 47_install_etl_freshness_monitor.sql first.', 16, 1);
    RETURN;
END;

EXEC [DWS].[sp_check_etl_freshness]
    @ods_threshold_minutes = 10,
    @dwd_threshold_minutes = 20,
    @dws_threshold_minutes = 30,
    @fail_on_stale = 0;

SELECT
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
    f.[check_time],
    f.[status_detail]
FROM [DWS].[v_etl_freshness_latest] AS f
ORDER BY
    f.[pipeline_layer],
    f.[source_schema],
    f.[source_table],
    f.[target_schema],
    f.[target_table];
