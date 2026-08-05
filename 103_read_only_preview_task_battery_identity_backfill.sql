USE [IOT2020];

/*
  Read-only preflight for the approved 30-day battery identity repair.
  Exact lineage only:
    DWD.fact_robot_battery.source_ods_row_id
      -> ODS.robot_battery_history.ods_row_id
      -> latest ODS.MA_AMR row for the source amr_id.
*/
SET NOCOUNT ON;

IF DB_NAME() <> N'IOT2020'
BEGIN
    THROW 58500, N'Expected database IOT2020.', 1;
END;

DECLARE @window_end DATETIME2(3) = SYSDATETIME();
DECLARE @window_start DATETIME2(3) = DATEADD(DAY, -30, @window_end);

;WITH latest_master_robot AS
(
    SELECT
        master_row.[id] AS [amr_id],
        master_row.[name] AS [robot_code],
        ROW_NUMBER() OVER (PARTITION BY master_row.[id] ORDER BY master_row.[ods_row_id] DESC) AS [rn]
    FROM [ODS].[MA_AMR] AS master_row
), scoped_battery AS
(
    SELECT
        battery_fact.[source_ods_row_id],
        battery_fact.[robot_id],
        battery_fact.[robot_code]
    FROM [DWD].[fact_robot_battery] AS battery_fact
    WHERE battery_fact.[sample_time] >= @window_start
      AND battery_fact.[sample_time] < @window_end
      AND battery_fact.[source_schema] = N'ODS'
      AND battery_fact.[source_table] = N'robot_battery_history'
)
SELECT
    @window_start AS [preview_window_start],
    @window_end AS [preview_window_end],
    COUNT_BIG(*) AS [scoped_dwd_battery_rows],
    SUM(CASE WHEN ods_battery.[ods_row_id] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [missing_ods_battery_link_rows],
    SUM(CASE WHEN master_robot.[amr_id] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [missing_master_link_rows],
    SUM(CASE WHEN master_robot.[amr_id] IS NOT NULL
                  AND (ISNULL(scoped_battery.[robot_id], N'') <> CONVERT(NVARCHAR(100), master_robot.[amr_id])
                    OR ISNULL(scoped_battery.[robot_code], N'') <> ISNULL(master_robot.[robot_code], N''))
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [repairable_identity_rows],
    SUM(CASE WHEN master_robot.[amr_id] IS NOT NULL
                  AND ISNULL(scoped_battery.[robot_id], N'') = CONVERT(NVARCHAR(100), master_robot.[amr_id])
                  AND ISNULL(scoped_battery.[robot_code], N'') = ISNULL(master_robot.[robot_code], N'')
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [already_correct_rows]
FROM scoped_battery
LEFT JOIN [ODS].[robot_battery_history] AS ods_battery
    ON ods_battery.[ods_row_id] = scoped_battery.[source_ods_row_id]
LEFT JOIN latest_master_robot AS master_robot
    ON master_robot.[amr_id] = ods_battery.[amr_id]
   AND master_robot.[rn] = 1;

SELECT
    scoped_battery.[source_ods_row_id],
    COUNT_BIG(*) AS [dwd_rows_for_ods_source]
FROM [DWD].[fact_robot_battery] AS scoped_battery
WHERE scoped_battery.[sample_time] >= @window_start
  AND scoped_battery.[sample_time] < @window_end
  AND scoped_battery.[source_schema] = N'ODS'
  AND scoped_battery.[source_table] = N'robot_battery_history'
GROUP BY scoped_battery.[source_ods_row_id]
HAVING COUNT_BIG(*) > 1
ORDER BY scoped_battery.[source_ods_row_id];
