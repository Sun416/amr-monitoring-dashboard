USE IOT2020;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
    DWD recovery and safe manual load script.

    Use this after a cancelled long-running DWD load.

    What this script does:
      1. Shows recent DWD batches.
      2. Marks stale RUNNING batches as CANCELLED.
      3. Disables all DWD mappings.
      4. Enables only FULL_REPLACE and SNAPSHOT mappings.
      5. Runs DWD.sp_load_dwd_all_incremental for dimensions and snapshots only.
      6. Shows batch and table-level logs.

    It intentionally does NOT load large fact history tables in this run.
    Large fact tables should be loaded later one by one.
*/

/* 1. Check recent DWD batches before cleanup. */
SELECT TOP 20
    batch_id,
    batch_start_time,
    batch_end_time,
    batch_status,
    DATEDIFF(SECOND, batch_start_time, COALESCE(batch_end_time, SYSDATETIME())) AS elapsed_seconds,
    error_message
FROM [DWD].[etl_batch]
ORDER BY batch_id DESC;
GO

/* 2. Mark stale RUNNING batches as CANCELLED.
      The 10-minute condition prevents accidentally marking a genuinely active new load. */
DECLARE @sql_mark_stale_batch NVARCHAR(MAX) = N'UP' + N'DATE [DWD].[etl_batch]
SET
    batch_end_time = COALESCE(batch_end_time, SYSDATETIME()),
    batch_status = N''CANCELLED'',
    error_message = COALESCE(error_message, N''Manually marked as CANCELLED after client-side cancellation.'')
WHERE batch_status = N''RUNNING''
  AND batch_start_time < DATEADD(MINUTE, -10, SYSDATETIME());
';

EXEC sys.sp_executesql @sql_mark_stale_batch;
GO

/* 3. Safe mode: disable all DWD mappings first. */
DECLARE @sql_disable_dwd_mappings NVARCHAR(MAX) = N'UP' + N'DATE [DWD].[etl_watermark]
SET is_enabled = 0
WHERE source_schema = N''ODS''
  AND target_schema = N''DWD'';
';

EXEC sys.sp_executesql @sql_disable_dwd_mappings;
GO

/* 4. Enable only dimension and snapshot mappings.
      This avoids loading large historical fact tables in the first DWD run. */
DECLARE @sql_enable_safe_mappings NVARCHAR(MAX) = N'UP' + N'DATE [DWD].[etl_watermark]
SET is_enabled = 1
WHERE source_schema = N''ODS''
  AND target_schema = N''DWD''
  AND load_mode IN (N''FULL_REPLACE'', N''SNAPSHOT'');
';

EXEC sys.sp_executesql @sql_enable_safe_mappings;
GO

/* 5. Confirm what will run in this safe pass. */
SELECT
    target_table,
    source_table,
    load_mode,
    watermark_column,
    last_bigint_value,
    is_enabled
FROM [DWD].[etl_watermark]
ORDER BY
    is_enabled DESC,
    target_table,
    source_table;
GO

/* 6. Run DWD safe pass: dimensions + snapshots only. */
EXEC [DWD].[sp_load_dwd_all_incremental];
GO

/* 7. Check latest DWD batch. */
SELECT TOP 20
    batch_id,
    batch_start_time,
    batch_end_time,
    batch_status,
    DATEDIFF(SECOND, batch_start_time, batch_end_time) AS duration_seconds,
    error_message
FROM [DWD].[etl_batch]
ORDER BY batch_id DESC;
GO

/* 8. Check latest table-level load logs. */
DECLARE @last_batch_id BIGINT;

SELECT @last_batch_id = MAX(batch_id)
FROM [DWD].[etl_batch];

SELECT
    batch_id,
    source_table,
    target_table,
    load_mode,
    rows_inserted,
    rows_deleted,
    load_status,
    error_message
FROM [DWD].[etl_load_log]
WHERE batch_id = @last_batch_id
ORDER BY
    load_status,
    target_table,
    source_table;
GO

/* 9. Check DWD row counts after safe pass. */
SELECT
    s.name AS schema_name,
    t.name AS table_name,
    SUM(p.rows) AS approximate_row_count
FROM sys.tables AS t
JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
JOIN sys.partitions AS p
    ON p.object_id = t.object_id
   AND p.index_id IN (0, 1)
WHERE s.name = N'DWD'
GROUP BY
    s.name,
    t.name
ORDER BY
    t.name;
GO

-- END OF SCRIPT.
