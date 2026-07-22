USE IOT2020;
GO

/*
    Read-only preview before repairing DWD/DWS current snapshot mapping.

    Purpose:
    1. Confirm whether Robot_number or Robot_Serial is the stable robot code/id.
    2. Check whether Robot_Mode matches AMR_Robot_Mode.Mode_ID.
    3. Preview the proposed DWD snapshot values and conversion failures.

    This script does not modify any data.
*/

SET NOCOUNT ON;

SELECT
    N'01_currentdata_values' AS [check_section],
    src.[ods_row_id],
    src.[Datetime],
    src.[Robot_number],
    src.[Robot_Serial],
    src.[Robot_MoveState],
    src.[Robot_Mode],
    mode_ref.[Mode_Detail],
    src.[Robot_Device_State],
    src.[Robot_Speed],
    src.[Batt_Level],
    src.[Robot_Current_Map],
    src.[POI_Current],
    src.[Robot_Position_X],
    src.[Robot_Position_Y],
    src.[Robot_Orientation_Z],
    src.[Robot_Emer_Status],
    src.[Job_Name]
FROM [ODS].[AMR_Currentdata] AS src
OUTER APPLY (
    SELECT TOP (1)
        m.[Mode_Detail]
    FROM [ODS].[AMR_Robot_Mode] AS m
    WHERE m.[Mode_ID] = src.[Robot_Mode]
    ORDER BY
        m.[ods_row_id] DESC
) AS mode_ref
ORDER BY
    src.[ods_row_id];

SELECT
    N'02_robot_mode_dictionary' AS [check_section],
    mode_ref.[ods_row_id],
    mode_ref.[Mode_ID],
    mode_ref.[Mode_Detail]
FROM [ODS].[AMR_Robot_Mode] AS mode_ref
ORDER BY
    mode_ref.[Mode_ID],
    mode_ref.[ods_row_id];

SELECT
    N'03_identifier_quality' AS [check_section],
    COUNT_BIG(*) AS [row_count],
    COUNT_BIG(CASE
        WHEN NULLIF(LTRIM(RTRIM(src.[Robot_number])), N'') IS NULL THEN 1
    END) AS [blank_robot_number_count],
    COUNT_BIG(CASE
        WHEN NULLIF(LTRIM(RTRIM(src.[Robot_Serial])), N'') IS NULL THEN 1
    END) AS [blank_robot_serial_count],
    COUNT_BIG(DISTINCT NULLIF(LTRIM(RTRIM(src.[Robot_number])), N'')) AS [distinct_robot_number_count],
    COUNT_BIG(DISTINCT NULLIF(LTRIM(RTRIM(src.[Robot_Serial])), N'')) AS [distinct_robot_serial_count],
    COUNT_BIG(CASE
        WHEN NULLIF(LTRIM(RTRIM(src.[Robot_Mode])), N'') IS NOT NULL
         AND NOT EXISTS (
                SELECT 1
                FROM [ODS].[AMR_Robot_Mode] AS mode_ref
                WHERE mode_ref.[Mode_ID] = src.[Robot_Mode]
         )
            THEN 1
    END) AS [unmatched_robot_mode_count]
FROM [ODS].[AMR_Currentdata] AS src;

SELECT
    N'04_conversion_quality' AS [check_section],
    COUNT_BIG(*) AS [row_count],
    COUNT_BIG(CASE
        WHEN NULLIF(LTRIM(RTRIM(src.[Robot_Speed])), N'') IS NOT NULL
         AND TRY_CONVERT(DECIMAL(18,6), src.[Robot_Speed]) IS NULL THEN 1
    END) AS [invalid_speed_count],
    COUNT_BIG(CASE
        WHEN NULLIF(LTRIM(RTRIM(src.[Batt_Level])), N'') IS NOT NULL
         AND TRY_CONVERT(DECIMAL(9,4), src.[Batt_Level]) IS NULL THEN 1
    END) AS [invalid_battery_soc_count],
    COUNT_BIG(CASE
        WHEN NULLIF(LTRIM(RTRIM(src.[Robot_Position_X])), N'') IS NOT NULL
         AND TRY_CONVERT(DECIMAL(18,6), src.[Robot_Position_X]) IS NULL THEN 1
    END) AS [invalid_position_x_count],
    COUNT_BIG(CASE
        WHEN NULLIF(LTRIM(RTRIM(src.[Robot_Position_Y])), N'') IS NOT NULL
         AND TRY_CONVERT(DECIMAL(18,6), src.[Robot_Position_Y]) IS NULL THEN 1
    END) AS [invalid_position_y_count],
    COUNT_BIG(CASE
        WHEN NULLIF(LTRIM(RTRIM(src.[Robot_Orientation_Z])), N'') IS NOT NULL
         AND TRY_CONVERT(DECIMAL(18,6), src.[Robot_Orientation_Z]) IS NULL THEN 1
    END) AS [invalid_orientation_z_count]
FROM [ODS].[AMR_Currentdata] AS src;
GO
