USE IOT2020;
GO

/*
    Fix DWD.fact_robot_wifi schema drift.

    Problem observed:
    - DWD.sp_load_dwd_all_incremental failed on robot_wifi_history with SQL Server Error 207.
    - The current load procedure writes these columns into DWD.fact_robot_wifi:
      sample_time, robot_id, robot_code, ssid, bssid, rssi, signal_quality,
      network_status, source_schema, source_table, source_ods_row_id,
      source_ods_load_time, dwd_batch_id, dwd_hash_value.

    This script only adds missing nullable columns required by the current procedure.
    It does not drop or truncate data.
*/

SET NOCOUNT ON;

IF OBJECT_ID(N'[DWD].[fact_robot_wifi]', N'U') IS NULL
BEGIN
    THROW 55000, 'DWD.fact_robot_wifi does not exist. Run 01_create_dwd_core_tables.sql first.', 1;
END;

/* Preview current columns before repair. */
SELECT
    c.column_id,
    c.name AS column_name,
    ty.name AS data_type,
    c.max_length,
    c.precision,
    c.scale,
    c.is_nullable
FROM sys.columns AS c
JOIN sys.types AS ty
    ON ty.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID(N'[DWD].[fact_robot_wifi]')
ORDER BY c.column_id;

IF COL_LENGTH(N'DWD.fact_robot_wifi', N'sample_time') IS NULL
    ALTER TABLE [DWD].[fact_robot_wifi] ADD [sample_time] DATETIME2(3) NULL;

IF COL_LENGTH(N'DWD.fact_robot_wifi', N'robot_id') IS NULL
    ALTER TABLE [DWD].[fact_robot_wifi] ADD [robot_id] NVARCHAR(100) NULL;

IF COL_LENGTH(N'DWD.fact_robot_wifi', N'robot_code') IS NULL
    ALTER TABLE [DWD].[fact_robot_wifi] ADD [robot_code] NVARCHAR(100) NULL;

IF COL_LENGTH(N'DWD.fact_robot_wifi', N'ssid') IS NULL
    ALTER TABLE [DWD].[fact_robot_wifi] ADD [ssid] NVARCHAR(200) NULL;

IF COL_LENGTH(N'DWD.fact_robot_wifi', N'bssid') IS NULL
    ALTER TABLE [DWD].[fact_robot_wifi] ADD [bssid] NVARCHAR(200) NULL;

IF COL_LENGTH(N'DWD.fact_robot_wifi', N'rssi') IS NULL
    ALTER TABLE [DWD].[fact_robot_wifi] ADD [rssi] DECIMAL(18,6) NULL;

IF COL_LENGTH(N'DWD.fact_robot_wifi', N'signal_quality') IS NULL
    ALTER TABLE [DWD].[fact_robot_wifi] ADD [signal_quality] DECIMAL(18,6) NULL;

IF COL_LENGTH(N'DWD.fact_robot_wifi', N'network_status') IS NULL
    ALTER TABLE [DWD].[fact_robot_wifi] ADD [network_status] NVARCHAR(100) NULL;

IF COL_LENGTH(N'DWD.fact_robot_wifi', N'source_schema') IS NULL
    ALTER TABLE [DWD].[fact_robot_wifi] ADD [source_schema] SYSNAME NULL;

IF COL_LENGTH(N'DWD.fact_robot_wifi', N'source_table') IS NULL
    ALTER TABLE [DWD].[fact_robot_wifi] ADD [source_table] SYSNAME NULL;

IF COL_LENGTH(N'DWD.fact_robot_wifi', N'source_ods_row_id') IS NULL
    ALTER TABLE [DWD].[fact_robot_wifi] ADD [source_ods_row_id] BIGINT NULL;

IF COL_LENGTH(N'DWD.fact_robot_wifi', N'source_ods_load_time') IS NULL
    ALTER TABLE [DWD].[fact_robot_wifi] ADD [source_ods_load_time] DATETIME2(3) NULL;

IF COL_LENGTH(N'DWD.fact_robot_wifi', N'dwd_batch_id') IS NULL
    ALTER TABLE [DWD].[fact_robot_wifi] ADD [dwd_batch_id] BIGINT NULL;

IF COL_LENGTH(N'DWD.fact_robot_wifi', N'dwd_hash_value') IS NULL
    ALTER TABLE [DWD].[fact_robot_wifi] ADD [dwd_hash_value] VARBINARY(32) NULL;

/* If an older redundant column exists, keep it but backfill rssi from it where useful. */
IF COL_LENGTH(N'DWD.fact_robot_wifi', N'wifi_signal_level') IS NOT NULL
   AND COL_LENGTH(N'DWD.fact_robot_wifi', N'rssi') IS NOT NULL
BEGIN
    EXEC sys.sp_executesql N'
UPDATE [DWD].[fact_robot_wifi]
SET [rssi] = TRY_CONVERT(DECIMAL(18,6), [wifi_signal_level])
WHERE [rssi] IS NULL
  AND [wifi_signal_level] IS NOT NULL;
';
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[fact_robot_wifi]')
      AND name = N'IX_DWD_fact_robot_wifi_robot_time'
)
BEGIN
    CREATE INDEX [IX_DWD_fact_robot_wifi_robot_time]
        ON [DWD].[fact_robot_wifi] ([robot_code], [sample_time]);
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'[DWD].[fact_robot_wifi]')
      AND name = N'UX_DWD_fact_robot_wifi_source_row'
)
BEGIN
    CREATE UNIQUE INDEX [UX_DWD_fact_robot_wifi_source_row]
        ON [DWD].[fact_robot_wifi] ([source_schema], [source_table], [source_ods_row_id])
        WHERE [source_ods_row_id] IS NOT NULL;
END;

/* Verify expected columns after repair. */
SELECT
    expected.column_name,
    CASE WHEN c.column_id IS NULL THEN 0 ELSE 1 END AS exists_in_fact_robot_wifi
FROM (
    VALUES
        (N'sample_time'),
        (N'robot_id'),
        (N'robot_code'),
        (N'ssid'),
        (N'bssid'),
        (N'rssi'),
        (N'signal_quality'),
        (N'network_status'),
        (N'source_schema'),
        (N'source_table'),
        (N'source_ods_row_id'),
        (N'source_ods_load_time'),
        (N'dwd_batch_id'),
        (N'dwd_hash_value')
) AS expected(column_name)
LEFT JOIN sys.columns AS c
    ON c.object_id = OBJECT_ID(N'[DWD].[fact_robot_wifi]')
   AND c.name = expected.column_name
ORDER BY expected.column_name;
GO
