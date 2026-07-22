USE IOT2020;
GO

/*
    One-time repair for DWD/DWS current snapshot mapping.

    Problem found by 28_dws_current_snapshot_diagnosis.sql:
    - ODS.AMR_Currentdata has valid fields:
        Robot_number, Robot_Serial, Robot_MoveState, Robot_Mode,
        Batt_Level, Robot_Position_X, Robot_Position_Y, etc.
    - DWD.snap_amr_current_status was loaded with NULL robot_code / robot_id.
    - DWS.dws_robot_current_snapshot collapsed those NULL rows into one UNKNOWN row.

    This script:
    1. Disables the wrong DWD watermark mapping:
       ODS.AMR_Robot_Mode -> DWD.snap_amr_current_status.
       AMR_Robot_Mode is a mode dictionary, not a per-robot current snapshot.
    2. Deletes only the broken current snapshot rows sourced from:
       AMR_Currentdata and AMR_Robot_Mode.
    3. Reinserts correctly mapped current snapshot rows from ODS.AMR_Currentdata.
    4. Repairs DWS.dws_robot_current_snapshot from the corrected DWD snapshot.

    Scope:
    - Does not touch ODS.
    - Does not rebuild DWD or DWS.
    - DELETE statements are limited by source_table / robot_code filters.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE
    @dwd_batch_id BIGINT,
    @dws_batch_id BIGINT,
    @rows_disabled BIGINT = 0,
    @rows_deleted_dwd BIGINT = 0,
    @rows_inserted_dwd BIGINT = 0,
    @rows_deleted_dws BIGINT = 0,
    @rows_merged_dws BIGINT = 0;

SELECT
    N'01_before_dwd_watermark' AS [check_section],
    [watermark_id],
    [source_schema],
    [source_table],
    [target_schema],
    [target_table],
    [load_mode],
    [is_enabled],
    [watermark_column],
    [last_bigint_value],
    [last_datetime_value],
    [last_load_time]
FROM [DWD].[etl_watermark]
WHERE [target_schema] = N'DWD'
  AND [target_table] = N'snap_amr_current_status'
  AND [source_table] IN (N'AMR_Currentdata', N'AMR_Robot_Mode')
ORDER BY
    [source_table];

SELECT
    N'02_before_dwd_snapshot_profile' AS [check_section],
    [source_table],
    COUNT_BIG(*) AS [row_count],
    COUNT_BIG(CASE WHEN [robot_code] IS NULL OR [robot_code] = N'' THEN 1 END) AS [blank_robot_code_count],
    COUNT_BIG(CASE WHEN [robot_id] IS NULL OR [robot_id] = N'' THEN 1 END) AS [blank_robot_id_count],
    COUNT_BIG(CASE WHEN [current_status] IS NULL OR [current_status] = N'' THEN 1 END) AS [blank_current_status_count],
    COUNT_BIG(CASE WHEN [battery_soc] IS NULL THEN 1 END) AS [blank_battery_soc_count]
FROM [DWD].[snap_amr_current_status]
WHERE [source_table] IN (N'AMR_Currentdata', N'AMR_Robot_Mode')
GROUP BY
    [source_table]
ORDER BY
    [source_table];

BEGIN TRY
    BEGIN TRAN;

    SELECT
        @dwd_batch_id = MAX([batch_id])
    FROM [DWD].[etl_batch];

    SELECT
        @dws_batch_id = MAX([batch_id])
    FROM [DWS].[etl_batch];

    UPDATE [DWD].[etl_watermark]
    SET
        [load_mode] = N'IGNORE',
        [is_enabled] = 0,
        [last_bigint_value] = NULL,
        [last_datetime_value] = NULL,
        [last_load_time] = SYSDATETIME()
    WHERE [target_schema] = N'DWD'
      AND [target_table] = N'snap_amr_current_status'
      AND [source_schema] = N'ODS'
      AND [source_table] = N'AMR_Robot_Mode';

    SET @rows_disabled = @@ROWCOUNT;

    DELETE tgt
    FROM [DWD].[snap_amr_current_status] AS tgt
    WHERE tgt.[source_schema] = N'ODS'
      AND tgt.[source_table] IN (N'AMR_Currentdata', N'AMR_Robot_Mode');

    SET @rows_deleted_dwd = @@ROWCOUNT;

    INSERT INTO [DWD].[snap_amr_current_status] (
        [robot_id],
        [robot_code],
        [robot_name],
        [current_status],
        [current_mode],
        [online_status],
        [job_id],
        [subjob_id],
        [map_code],
        [station_code],
        [position_x],
        [position_y],
        [position_theta],
        [speed_mps],
        [battery_soc],
        [error_code],
        [error_message],
        [source_event_time],
        [source_schema],
        [source_table],
        [source_ods_row_id],
        [dwd_batch_id],
        [dwd_hash_value]
    )
    SELECT
        COALESCE(
            NULLIF(
                NULLIF(LTRIM(RTRIM(TRY_CONVERT(NVARCHAR(100), src.[Robot_Serial]))), N''),
                N'undefined'
            ),
            TRY_CONVERT(NVARCHAR(100), src.[Robot_number])
        ) AS [robot_id],
        TRY_CONVERT(NVARCHAR(100), src.[Robot_number]) AS [robot_code],
        TRY_CONVERT(NVARCHAR(200), src.[Robot_number]) AS [robot_name],
        TRY_CONVERT(NVARCHAR(100), src.[Robot_MoveState]) AS [current_status],
        COALESCE(
            TRY_CONVERT(NVARCHAR(100), mode_ref.[Mode_Detail]),
            TRY_CONVERT(NVARCHAR(100), src.[Robot_Mode])
        ) AS [current_mode],
        TRY_CONVERT(NVARCHAR(50), src.[Robot_Device_State]) AS [online_status],
        TRY_CONVERT(NVARCHAR(100), src.[Job_Name]) AS [job_id],
        NULL AS [subjob_id],
        TRY_CONVERT(NVARCHAR(100), src.[Robot_Current_Map]) AS [map_code],
        TRY_CONVERT(NVARCHAR(100), src.[POI_Current]) AS [station_code],
        TRY_CONVERT(DECIMAL(18,6), src.[Robot_Position_X]) AS [position_x],
        TRY_CONVERT(DECIMAL(18,6), src.[Robot_Position_Y]) AS [position_y],
        TRY_CONVERT(DECIMAL(18,6), src.[Robot_Orientation_Z]) AS [position_theta],
        TRY_CONVERT(DECIMAL(18,6), src.[Robot_Speed]) AS [speed_mps],
        TRY_CONVERT(DECIMAL(9,4), src.[Batt_Level]) AS [battery_soc],
        TRY_CONVERT(NVARCHAR(100), src.[Robot_Emer_Status]) AS [error_code],
        NULL AS [error_message],
        TRY_CONVERT(DATETIME2(3), src.[Datetime]) AS [source_event_time],
        N'ODS' AS [source_schema],
        N'AMR_Currentdata' AS [source_table],
        TRY_CONVERT(BIGINT, src.[ods_row_id]) AS [source_ods_row_id],
        @dwd_batch_id AS [dwd_batch_id],
        HASHBYTES(
            'SHA2_256',
            CONCAT(N'ODS', N'|', N'AMR_Currentdata', N'|', TRY_CONVERT(NVARCHAR(50), src.[ods_row_id]))
        ) AS [dwd_hash_value]
    FROM [ODS].[AMR_Currentdata] AS src
    OUTER APPLY (
        SELECT TOP (1)
            mode_source.[Mode_Detail]
        FROM [ODS].[AMR_Robot_Mode] AS mode_source
        WHERE mode_source.[Mode_ID] = src.[Robot_Mode]
        ORDER BY
            mode_source.[ods_row_id] DESC
    ) AS mode_ref;

    SET @rows_inserted_dwd = @@ROWCOUNT;

    DELETE tgt
    FROM [DWS].[dws_robot_current_snapshot] AS tgt
    WHERE tgt.[robot_code] = N'UNKNOWN'
       OR EXISTS (
            SELECT 1
            FROM [DWD].[snap_amr_current_status] AS s
            WHERE s.[source_schema] = N'ODS'
              AND s.[source_table] = N'AMR_Currentdata'
              AND s.[robot_code] = tgt.[robot_code]
       );

    SET @rows_deleted_dws = @@ROWCOUNT;

    ;WITH ranked_snapshot AS (
        SELECT
            s.[robot_code],
            s.[robot_id],
            s.[robot_name],
            s.[current_status],
            s.[current_mode],
            s.[online_status],
            s.[job_id],
            s.[subjob_id],
            s.[map_code],
            s.[station_code],
            s.[position_x],
            s.[position_y],
            s.[position_theta],
            s.[speed_mps],
            s.[battery_soc],
            s.[error_code],
            s.[error_message],
            s.[source_event_time],
            s.[snapshot_time],
            ROW_NUMBER() OVER (
                PARTITION BY s.[robot_code]
                ORDER BY s.[snapshot_time] DESC, s.[snapshot_id] DESC
            ) AS [rn]
        FROM [DWD].[snap_amr_current_status] AS s
        WHERE s.[source_schema] = N'ODS'
          AND s.[source_table] = N'AMR_Currentdata'
          AND s.[robot_code] IS NOT NULL
          AND s.[robot_code] <> N''
    )
    INSERT INTO [DWS].[dws_robot_current_snapshot] (
        [robot_code],
        [robot_id],
        [robot_name],
        [current_status],
        [current_mode],
        [online_status],
        [job_id],
        [subjob_id],
        [map_code],
        [station_code],
        [position_x],
        [position_y],
        [position_theta],
        [speed_mps],
        [battery_soc],
        [error_code],
        [error_message],
        [source_event_time],
        [source_snapshot_time],
        [dws_batch_id]
    )
    SELECT
        rs.[robot_code],
        rs.[robot_id],
        rs.[robot_name],
        rs.[current_status],
        rs.[current_mode],
        rs.[online_status],
        rs.[job_id],
        rs.[subjob_id],
        rs.[map_code],
        rs.[station_code],
        rs.[position_x],
        rs.[position_y],
        rs.[position_theta],
        rs.[speed_mps],
        rs.[battery_soc],
        rs.[error_code],
        rs.[error_message],
        rs.[source_event_time],
        rs.[snapshot_time],
        @dws_batch_id
    FROM ranked_snapshot AS rs
    WHERE rs.[rn] = 1;

    SET @rows_merged_dws = @@ROWCOUNT;

    COMMIT;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK;

    THROW;
END CATCH;

SELECT
    N'03_repair_summary' AS [check_section],
    @rows_disabled AS [rows_disabled_in_dwd_watermark],
    @rows_deleted_dwd AS [rows_deleted_from_dwd_snapshot],
    @rows_inserted_dwd AS [rows_inserted_to_dwd_snapshot],
    @rows_deleted_dws AS [rows_deleted_from_dws_snapshot],
    @rows_merged_dws AS [rows_inserted_to_dws_snapshot];

SELECT
    N'04_after_dwd_snapshot_profile' AS [check_section],
    [source_table],
    COUNT_BIG(*) AS [row_count],
    COUNT_BIG(CASE WHEN [robot_code] IS NULL OR [robot_code] = N'' THEN 1 END) AS [blank_robot_code_count],
    COUNT_BIG(CASE WHEN [robot_id] IS NULL OR [robot_id] = N'' THEN 1 END) AS [blank_robot_id_count],
    COUNT_BIG(CASE WHEN [current_status] IS NULL OR [current_status] = N'' THEN 1 END) AS [blank_current_status_count],
    COUNT_BIG(CASE WHEN [battery_soc] IS NULL THEN 1 END) AS [blank_battery_soc_count]
FROM [DWD].[snap_amr_current_status]
WHERE [source_table] IN (N'AMR_Currentdata', N'AMR_Robot_Mode')
GROUP BY
    [source_table]
ORDER BY
    [source_table];

SELECT
    N'05_after_dws_current_snapshot_profile' AS [check_section],
    COUNT_BIG(*) AS [row_count],
    COUNT_BIG(CASE WHEN [robot_code] IS NULL OR [robot_code] = N'' OR [robot_code] = N'UNKNOWN' THEN 1 END) AS [blank_or_unknown_robot_code_count],
    COUNT_BIG(CASE WHEN [robot_id] IS NULL OR [robot_id] = N'' THEN 1 END) AS [blank_robot_id_count],
    COUNT_BIG(CASE WHEN [current_status] IS NULL OR [current_status] = N'' THEN 1 END) AS [blank_current_status_count],
    COUNT_BIG(CASE WHEN [battery_soc] IS NULL THEN 1 END) AS [blank_battery_soc_count]
FROM [DWS].[dws_robot_current_snapshot];

SELECT
    N'06_after_dws_current_snapshot_sample' AS [check_section],
    [robot_code],
    [robot_id],
    [robot_name],
    [current_status],
    [current_mode],
    [online_status],
    [job_id],
    [map_code],
    [station_code],
    [position_x],
    [position_y],
    [position_theta],
    [speed_mps],
    [battery_soc],
    [error_code],
    [source_event_time],
    [source_snapshot_time],
    [dws_load_time],
    [dws_batch_id]
FROM [DWS].[dws_robot_current_snapshot]
ORDER BY
    [robot_code];
GO
