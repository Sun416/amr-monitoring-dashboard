USE [IOT2020];
GO

SET NOCOUNT ON;
GO

/*
    Manual freshness check while SQL Server Agent permission is unavailable.

    Result set 1: all 12 monitored pipeline steps.
    Result set 2: only STALE and FAILED alerts.
*/
EXEC [DWS].[sp_check_etl_freshness]
    @ods_threshold_minutes = 10,
    @dwd_threshold_minutes = 20,
    @dws_threshold_minutes = 30,
    @fail_on_stale = 0;
GO

/* Latest status for each monitored source-target pair. */
SELECT
    [check_time],
    [pipeline_layer],
    [source_schema],
    [source_table],
    [target_schema],
    [target_table],
    [source_max_id],
    [target_watermark],
    [estimated_rows_behind],
    [source_max_time],
    [target_max_time],
    [source_age_minutes],
    [target_age_minutes],
    [freshness_minutes],
    [threshold_minutes],
    [freshness_status],
    [status_detail]
FROM [DWS].[v_etl_freshness_latest]
ORDER BY
    CASE [freshness_status]
        WHEN N'FAILED' THEN 1
        WHEN N'STALE' THEN 2
        ELSE 3
    END,
    [pipeline_layer],
    [source_table],
    [target_table];
GO
