USE IOT2020;
GO

/*
    Full read-only audit for ODS and DWD layers.

    Scope:
    - No INSERT / UPDATE / DELETE / DROP / TRUNCATE.
    - Uses catalog and partition metadata for fast row-count checks.
    - Focuses on robot / AMR source tables and ODS / DWD layered tables.

    How to use:
    1. Execute the whole file in DataGrip.
    2. Export or copy all result tabs.
    3. Send the result files/screenshots back to Codex for diagnosis.
*/

SET NOCOUNT ON;

DECLARE @line NVARCHAR(200);

/* 01. Fast table inventory for ODS and DWD. */
SELECT
    N'01_layer_table_inventory' AS audit_section,
    s.name AS schema_name,
    t.name AS table_name,
    SUM(ps.row_count) AS approximate_row_count,
    CAST(SUM(ps.reserved_page_count) * 8.0 / 1024 AS DECIMAL(18, 2)) AS reserved_mb,
    t.create_date,
    t.modify_date
FROM sys.tables AS t
JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
JOIN sys.dm_db_partition_stats AS ps
    ON ps.object_id = t.object_id
   AND ps.index_id IN (0, 1)
WHERE s.name IN (N'ODS', N'DWD')
GROUP BY
    s.name,
    t.name,
    t.create_date,
    t.modify_date
ORDER BY
    s.name,
    t.name;

/* 02. dbo robot / AMR source tables and matching ODS table existence. */
SELECT
    N'02_dbo_robot_amr_source_vs_ods_existence' AS audit_section,
    src_s.name AS source_schema,
    src_t.name AS source_table,
    SUM(src_ps.row_count) AS source_approximate_row_count,
    CASE WHEN ods_t.object_id IS NULL THEN 0 ELSE 1 END AS exists_in_ods,
    COALESCE(SUM(ods_ps.row_count), 0) AS ods_approximate_row_count,
    SUM(src_ps.row_count) - COALESCE(SUM(ods_ps.row_count), 0) AS approximate_row_count_diff
FROM sys.tables AS src_t
JOIN sys.schemas AS src_s
    ON src_s.schema_id = src_t.schema_id
JOIN sys.dm_db_partition_stats AS src_ps
    ON src_ps.object_id = src_t.object_id
   AND src_ps.index_id IN (0, 1)
LEFT JOIN sys.schemas AS ods_s
    ON ods_s.name = N'ODS'
LEFT JOIN sys.tables AS ods_t
    ON ods_t.schema_id = ods_s.schema_id
   AND ods_t.name = src_t.name
LEFT JOIN sys.dm_db_partition_stats AS ods_ps
    ON ods_ps.object_id = ods_t.object_id
   AND ods_ps.index_id IN (0, 1)
WHERE src_s.name = N'dbo'
  AND (
         LOWER(src_t.name) LIKE N'%robot%'
      OR UPPER(src_t.name) LIKE N'%AMR%'
  )
GROUP BY
    src_s.name,
    src_t.name,
    ods_t.object_id
ORDER BY
    ABS(SUM(src_ps.row_count) - COALESCE(SUM(ods_ps.row_count), 0)) DESC,
    src_t.name;

/* 03. ODS robot / AMR tables that do not have same-name dbo source tables. */
SELECT
    N'03_ods_robot_amr_without_same_name_dbo_source' AS audit_section,
    ods_s.name AS ods_schema,
    ods_t.name AS ods_table,
    SUM(ods_ps.row_count) AS ods_approximate_row_count,
    ods_t.create_date,
    ods_t.modify_date
FROM sys.tables AS ods_t
JOIN sys.schemas AS ods_s
    ON ods_s.schema_id = ods_t.schema_id
JOIN sys.dm_db_partition_stats AS ods_ps
    ON ods_ps.object_id = ods_t.object_id
   AND ods_ps.index_id IN (0, 1)
LEFT JOIN sys.schemas AS src_s
    ON src_s.name = N'dbo'
LEFT JOIN sys.tables AS src_t
    ON src_t.schema_id = src_s.schema_id
   AND src_t.name = ods_t.name
WHERE ods_s.name = N'ODS'
  AND (
         LOWER(ods_t.name) LIKE N'%robot%'
      OR UPPER(ods_t.name) LIKE N'%AMR%'
  )
  AND src_t.object_id IS NULL
GROUP BY
    ods_s.name,
    ods_t.name,
    ods_t.create_date,
    ods_t.modify_date
ORDER BY
    ods_t.name;

/* 04. ODS control table health. */
IF OBJECT_ID(N'[ODS].[etl_watermark]', N'U') IS NOT NULL
BEGIN
    SELECT
        N'04_ods_watermark_summary' AS audit_section,
        [load_mode],
        [is_enabled],
        COUNT_BIG(*) AS mapping_count
    FROM [ODS].[etl_watermark]
    GROUP BY
        [load_mode],
        [is_enabled]
    ORDER BY
        [is_enabled] DESC,
        [load_mode];

    SELECT
        N'05_ods_watermark_detail' AS audit_section,
        [source_schema],
        [source_table],
        [target_schema],
        [target_table],
        [load_mode],
        [watermark_column],
        [last_bigint_value],
        [last_datetime_value],
        [last_load_time],
        [is_enabled]
    FROM [ODS].[etl_watermark]
    ORDER BY
        [is_enabled] DESC,
        [load_mode],
        [source_table];
END;
ELSE
BEGIN
    SELECT N'04_ods_watermark_missing' AS audit_section, N'ODS.etl_watermark does not exist.' AS message;
END;

/* 06. DWD control table health. */
IF OBJECT_ID(N'[DWD].[etl_watermark]', N'U') IS NOT NULL
BEGIN
    SELECT
        N'06_dwd_watermark_summary' AS audit_section,
        [load_mode],
        [is_enabled],
        COUNT_BIG(*) AS mapping_count
    FROM [DWD].[etl_watermark]
    GROUP BY
        [load_mode],
        [is_enabled]
    ORDER BY
        [is_enabled] DESC,
        [load_mode];

    SELECT
        N'07_dwd_watermark_detail' AS audit_section,
        [source_schema],
        [source_table],
        [target_schema],
        [target_table],
        [load_mode],
        [watermark_column],
        [last_bigint_value],
        [last_datetime_value],
        [last_load_time],
        [is_enabled]
    FROM [DWD].[etl_watermark]
    ORDER BY
        [is_enabled] DESC,
        [load_mode],
        [target_table],
        [source_table];
END;
ELSE
BEGIN
    SELECT N'06_dwd_watermark_missing' AS audit_section, N'DWD.etl_watermark does not exist.' AS message;
END;

/* 08. Latest DWD batches. */
IF OBJECT_ID(N'[DWD].[etl_batch]', N'U') IS NOT NULL
BEGIN
    DECLARE @batch_sql NVARCHAR(MAX) = N'SELECT TOP 50
        N''08_latest_dwd_batches'' AS audit_section';

    IF COL_LENGTH(N'DWD.etl_batch', N'batch_id') IS NOT NULL
        SET @batch_sql += N',
        [batch_id]';

    IF COL_LENGTH(N'DWD.etl_batch', N'batch_start_time') IS NOT NULL
        SET @batch_sql += N',
        [batch_start_time]';

    IF COL_LENGTH(N'DWD.etl_batch', N'batch_end_time') IS NOT NULL
        SET @batch_sql += N',
        [batch_end_time]';

    IF COL_LENGTH(N'DWD.etl_batch', N'batch_status') IS NOT NULL
        SET @batch_sql += N',
        [batch_status]';

    IF COL_LENGTH(N'DWD.etl_batch', N'error_message') IS NOT NULL
        SET @batch_sql += N',
        [error_message]';

    SET @batch_sql += N'
    FROM [DWD].[etl_batch]';

    IF COL_LENGTH(N'DWD.etl_batch', N'batch_id') IS NOT NULL
        SET @batch_sql += N'
    ORDER BY [batch_id] DESC';

    EXEC sys.sp_executesql @batch_sql;
END;

/* 09. Latest DWD load logs. */
IF OBJECT_ID(N'[DWD].[etl_load_log]', N'U') IS NOT NULL
BEGIN
    SELECT TOP 200
        N'09_latest_dwd_load_log' AS audit_section,
        [batch_id],
        [source_schema],
        [source_table],
        [target_schema],
        [target_table],
        [load_mode],
        [rows_inserted],
        [rows_updated],
        [rows_deleted],
        [load_status],
        [error_message],
        [load_start_time],
        [load_end_time]
    FROM [DWD].[etl_load_log]
    ORDER BY
        [batch_id] DESC,
        [target_table],
        [source_table];
END;

/* 10. DWD source-to-target row count reconciliation using DWD.etl_watermark. */
IF OBJECT_ID(N'[DWD].[etl_watermark]', N'U') IS NOT NULL
BEGIN
    SELECT
        N'10_dwd_mapping_row_count_reconciliation' AS audit_section,
        wm.[source_schema],
        wm.[source_table],
        wm.[target_schema],
        wm.[target_table],
        wm.[load_mode],
        wm.[is_enabled],
        src_row.approximate_source_rows,
        tgt_row.approximate_target_rows_for_same_source,
        src_row.approximate_source_rows - tgt_row.approximate_target_rows_for_same_source AS approximate_row_diff,
        wm.[watermark_column],
        wm.[last_bigint_value],
        wm.[last_load_time]
    FROM [DWD].[etl_watermark] AS wm
    OUTER APPLY (
        SELECT
            SUM(ps.row_count) AS approximate_source_rows
        FROM sys.schemas AS s
        JOIN sys.tables AS t
            ON t.schema_id = s.schema_id
        JOIN sys.dm_db_partition_stats AS ps
            ON ps.object_id = t.object_id
           AND ps.index_id IN (0, 1)
        WHERE s.name = wm.[source_schema]
          AND t.name = wm.[source_table]
    ) AS src_row
    OUTER APPLY (
        SELECT
            SUM(ps.row_count) AS approximate_target_rows_for_same_source
        FROM sys.schemas AS s
        JOIN sys.tables AS t
            ON t.schema_id = s.schema_id
        JOIN sys.dm_db_partition_stats AS ps
            ON ps.object_id = t.object_id
           AND ps.index_id IN (0, 1)
        WHERE s.name = wm.[target_schema]
          AND t.name = wm.[target_table]
    ) AS tgt_row
    ORDER BY
        ABS(COALESCE(src_row.approximate_source_rows, 0) - COALESCE(tgt_row.approximate_target_rows_for_same_source, 0)) DESC,
        wm.[target_table],
        wm.[source_table];
END;

/* 11. DWD fact-table duplicate source row checks. */
DECLARE @duplicate_sql NVARCHAR(MAX) = N'';

SELECT @duplicate_sql = STRING_AGG(CAST(N'
SELECT
    N''11_dwd_duplicate_source_ods_row'' AS audit_section,
    N''' + REPLACE(s.name, N'''', N'''''') + N''' AS schema_name,
    N''' + REPLACE(t.name, N'''', N'''''') + N''' AS table_name,
    COUNT_BIG(*) AS duplicate_source_row_count
FROM (
    SELECT
        [source_schema],
        [source_table],
        [source_ods_row_id]
    FROM ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + N'
    WHERE [source_ods_row_id] IS NOT NULL
    GROUP BY
        [source_schema],
        [source_table],
        [source_ods_row_id]
    HAVING COUNT_BIG(*) > 1
) AS d' AS NVARCHAR(MAX)), N'
UNION ALL
')
FROM sys.tables AS t
JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
WHERE s.name = N'DWD'
  AND t.name LIKE N'fact[_]%'
  AND EXISTS (
      SELECT 1
      FROM sys.columns AS c
      WHERE c.object_id = t.object_id
        AND c.name = N'source_ods_row_id'
  )
  AND EXISTS (
      SELECT 1
      FROM sys.columns AS c
      WHERE c.object_id = t.object_id
        AND c.name = N'source_schema'
  )
  AND EXISTS (
      SELECT 1
      FROM sys.columns AS c
      WHERE c.object_id = t.object_id
        AND c.name = N'source_table'
  );

IF @duplicate_sql IS NOT NULL AND LEN(@duplicate_sql) > 0
BEGIN
    EXEC sys.sp_executesql @duplicate_sql;
END;

/* 12. DWD fact-table null profile for important columns that actually exist. */
DECLARE @null_profile_sql NVARCHAR(MAX) = N'';

SELECT @null_profile_sql = STRING_AGG(CAST(N'
SELECT
    N''12_dwd_fact_null_profile'' AS audit_section,
    N''' + REPLACE(s.name, N'''', N'''''') + N''' AS schema_name,
    N''' + REPLACE(t.name, N'''', N'''''') + N''' AS table_name,
    N''' + REPLACE(c.name, N'''', N'''''') + N''' AS column_name,
    COUNT_BIG(*) AS total_rows,
    SUM(CASE WHEN ' + QUOTENAME(c.name) + N' IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS null_rows
FROM ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + N'
WHERE 1 = 1' AS NVARCHAR(MAX)), N'
UNION ALL
')
FROM sys.tables AS t
JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
JOIN sys.columns AS c
    ON c.object_id = t.object_id
WHERE s.name = N'DWD'
  AND t.name LIKE N'fact[_]%'
  AND c.name IN (
      N'source_ods_row_id',
      N'source_ods_load_time',
      N'robot_id',
      N'robot_code',
      N'sample_time',
      N'status_time',
      N'job_start_time',
      N'queue_start_time',
      N'subjob_start_time',
      N'battery_soc',
      N'battery_voltage',
      N'battery_current',
      N'wifi_signal_level',
      N'rssi'
  );

IF @null_profile_sql IS NOT NULL AND LEN(@null_profile_sql) > 0
BEGIN
    EXEC sys.sp_executesql @null_profile_sql;
END;

/* 13. DWD target columns by table, useful for spotting manually removed fields. */
SELECT
    N'13_dwd_column_dictionary' AS audit_section,
    s.name AS schema_name,
    t.name AS table_name,
    c.column_id,
    c.name AS column_name,
    ty.name AS data_type,
    CASE
        WHEN ty.name IN (N'nvarchar', N'nchar') AND c.max_length > 0 THEN c.max_length / 2
        ELSE c.max_length
    END AS max_length,
    c.precision,
    c.scale,
    c.is_nullable,
    c.is_identity
FROM sys.tables AS t
JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
JOIN sys.columns AS c
    ON c.object_id = t.object_id
JOIN sys.types AS ty
    ON ty.user_type_id = c.user_type_id
WHERE s.name = N'DWD'
ORDER BY
    s.name,
    t.name,
    c.column_id;

/* 14. ODS/DWD table names that look like old / backup / test. */
SELECT
    N'14_suspicious_old_backup_test_tables' AS audit_section,
    s.name AS schema_name,
    t.name AS table_name,
    SUM(ps.row_count) AS approximate_row_count,
    t.create_date,
    t.modify_date
FROM sys.tables AS t
JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
JOIN sys.dm_db_partition_stats AS ps
    ON ps.object_id = t.object_id
   AND ps.index_id IN (0, 1)
WHERE s.name IN (N'ODS', N'DWD')
  AND (
         LOWER(t.name) LIKE N'%old%'
      OR LOWER(t.name) LIKE N'%backup%'
      OR LOWER(t.name) LIKE N'%test%'
  )
GROUP BY
    s.name,
    t.name,
    t.create_date,
    t.modify_date
ORDER BY
    s.name,
    t.name;
GO
