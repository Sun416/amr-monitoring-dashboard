USE [IOT2020];

/*
    Repair DWD robot identity mapping for Task Analytics.

    Scope:
      - Correct DWD.dim_amr_robot from ODS.MA_AMR.
      - Correct only the latest 24 hours of DWD.fact_robot_battery.
      - Source rows without an exact ODS.MA_AMR match are not updated.

    This is deliberately a bounded pilot. Historical backfill remains a
    separate, reviewed operation after this validation succeeds.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'IOT2020'
BEGIN
    THROW 58400, N'Expected database IOT2020.', 1;
END;

DECLARE @window_end DATETIME2(3) = SYSDATETIME();
DECLARE @window_start DATETIME2(3) = DATEADD(DAY, -1, @window_end);

BEGIN TRY
    BEGIN TRANSACTION;

    ;WITH latest_robot AS
    (
        SELECT
            source_row.[ods_row_id],
            source_row.[id],
            source_row.[name],
            source_row.[is_active],
            source_row.[created_at],
            source_row.[updated_at],
            ROW_NUMBER() OVER (PARTITION BY source_row.[id] ORDER BY source_row.[ods_row_id] DESC) AS [rn]
        FROM [ODS].[MA_AMR] AS source_row
    )
    UPDATE robot_dim
    SET
        robot_dim.[robot_id] = CONVERT(NVARCHAR(100), robot_ref.[id]),
        robot_dim.[robot_code] = robot_ref.[name],
        robot_dim.[robot_name] = robot_ref.[name],
        robot_dim.[is_enabled] = CASE WHEN UPPER(LTRIM(RTRIM(COALESCE(robot_ref.[is_active], N'')))) = N'Y' THEN CONVERT(BIT, 1) ELSE CONVERT(BIT, 0) END,
        robot_dim.[source_created_time] = CONVERT(DATETIME2(3), robot_ref.[created_at]),
        robot_dim.[source_updated_time] = CONVERT(DATETIME2(3), robot_ref.[updated_at]),
        robot_dim.[dwd_update_time] = SYSDATETIME()
    FROM [DWD].[dim_amr_robot] AS robot_dim
    INNER JOIN latest_robot AS robot_ref
        ON robot_ref.[ods_row_id] = robot_dim.[source_ods_row_id]
       AND robot_ref.[rn] = 1
    WHERE robot_dim.[source_schema] = N'ODS'
      AND robot_dim.[source_table] = N'MA_AMR'
      AND
      (
          ISNULL(robot_dim.[robot_id], N'') <> CONVERT(NVARCHAR(100), robot_ref.[id])
          OR ISNULL(robot_dim.[robot_code], N'') <> ISNULL(robot_ref.[name], N'')
          OR ISNULL(robot_dim.[robot_name], N'') <> ISNULL(robot_ref.[name], N'')
          OR ISNULL(robot_dim.[is_enabled], CONVERT(BIT, 0)) <> CASE WHEN UPPER(LTRIM(RTRIM(COALESCE(robot_ref.[is_active], N'')))) = N'Y' THEN CONVERT(BIT, 1) ELSE CONVERT(BIT, 0) END
      );

    ;WITH latest_robot AS
    (
        SELECT
            source_row.[id],
            source_row.[name],
            ROW_NUMBER() OVER (PARTITION BY source_row.[id] ORDER BY source_row.[ods_row_id] DESC) AS [rn]
        FROM [ODS].[MA_AMR] AS source_row
    )
    UPDATE battery_fact
    SET battery_fact.[robot_code] = robot_ref.[name]
    FROM [DWD].[fact_robot_battery] AS battery_fact
    INNER JOIN latest_robot AS robot_ref
        ON robot_ref.[id] = TRY_CONVERT(INT, battery_fact.[robot_id])
       AND robot_ref.[rn] = 1
    WHERE battery_fact.[sample_time] >= @window_start
      AND battery_fact.[sample_time] < @window_end
      AND NULLIF(LTRIM(RTRIM(robot_ref.[name])), N'') IS NOT NULL
      AND ISNULL(battery_fact.[robot_code], N'') <> robot_ref.[name];

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
    BEGIN
        ROLLBACK TRANSACTION;
    END;

    THROW;
END CATCH;

SELECT
    @window_start AS [repaired_window_start],
    @window_end AS [repaired_window_end],
    COUNT_BIG(*) AS [battery_rows],
    SUM(CASE WHEN robot_ref.[name] IS NOT NULL AND battery_fact.[robot_code] = robot_ref.[name] THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [mapped_battery_rows],
    SUM(CASE WHEN robot_ref.[name] IS NOT NULL AND battery_fact.[robot_code] <> robot_ref.[name] THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [still_mismatched_battery_rows],
    SUM(CASE WHEN robot_ref.[name] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [unmatched_master_rows]
FROM [DWD].[fact_robot_battery] AS battery_fact
LEFT JOIN
(
    SELECT
        source_row.[id],
        source_row.[name],
        ROW_NUMBER() OVER (PARTITION BY source_row.[id] ORDER BY source_row.[ods_row_id] DESC) AS [rn]
    FROM [ODS].[MA_AMR] AS source_row
) AS robot_ref
    ON robot_ref.[id] = TRY_CONVERT(INT, battery_fact.[robot_id])
   AND robot_ref.[rn] = 1
WHERE battery_fact.[sample_time] >= @window_start
  AND battery_fact.[sample_time] < @window_end;

SELECT
    robot_dim.[is_enabled],
    COUNT_BIG(*) AS [robot_dimension_rows],
    COUNT_BIG(DISTINCT robot_dim.[robot_code]) AS [distinct_robot_codes]
FROM [DWD].[dim_amr_robot] AS robot_dim
GROUP BY robot_dim.[is_enabled]
ORDER BY robot_dim.[is_enabled];
