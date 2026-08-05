USE IOT2020;

GO

/*
    Full ODS / DWD audit before DWS build.

    Purpose:
    - Compare dbo robot/AMR source tables with ODS tables.
    - Find row-count mismatches, column mismatches, ODS metadata problems,
      repeated snapshot loads, and DWD reconciliation gaps.
    - Read-only: this script does not modify data.

    Notes:
    - Robot project source tables are identified by table name containing robot or AMR.
    - ODS metadata columns are excluded when comparing source business columns.
*/

SET NOCOUNT ON;

IF OBJECT_ID(N'tempdb..#table_scope', N'U') IS NOT NULL
    DROP TABLE #table_scope;

CREATE TABLE #table_scope (
    source_schema SYSNAME NOT NULL,
    source_table SYSNAME NOT NULL,
    source_object_id INT NULL,
    ods_schema SYSNAME NULL,
    ods_table SYSNAME NULL,
    ods_object_id INT NULL,
    ods_load_mode NVARCHAR(30) NULL,
    ods_is_enabled BIT NULL,
    dwd_target_table SYSNAME NULL,
    dwd_load_mode NVARCHAR(30) NULL,
    dwd_is_enabled BIT NULL
);

INSERT INTO #table_scope (
    source_schema,
    source_table,
    source_object_id,
    ods_schema,
    ods_table,
    ods_object_id,
    ods_load_mode,
    ods_is_enabled,
    dwd_target_table,
    dwd_load_mode,
    dwd_is_enabled
)
SELECT
    s.name AS source_schema,
    t.name AS source_table,
    t.object_id AS source_object_id,
    ods_s.name AS ods_schema,
    ods_t.name AS ods_table,
    ods_t.object_id AS ods_object_id,
    ow.load_mode AS ods_load_mode,
    ow.is_enabled AS ods_is_enabled,
    dw.target_table AS dwd_target_table,
    dw.load_mode AS dwd_load_mode,
    dw.is_enabled AS dwd_is_enabled
FROM sys.tables AS t
JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
LEFT JOIN sys.schemas AS ods_s
    ON ods_s.name = N'ODS'
LEFT JOIN sys.tables AS ods_t
    ON ods_t.schema_id = ods_s.schema_id
   AND ods_t.name = t.name
LEFT JOIN [ODS].[etl_watermark] AS ow
    ON OBJECT_ID(N'[ODS].[etl_watermark]', N'U') IS NOT NULL
   AND ow.source_schema = s.name
   AND ow.source_table = t.name
   AND ow.target_schema = N'ODS'
   AND ow.target_table = t.name
LEFT JOIN [DWD].[etl_watermark] AS dw
    ON OBJECT_ID(N'[DWD].[etl_watermark]', N'U') IS NOT NULL
   AND dw.source_schema = N'ODS'
   AND dw.source_table = t.name
WHERE s.name = N'dbo'
  AND (
         LOWER(t.name) LIKE N'%robot%'
      OR UPPER(t.name) LIKE N'%AMR%'


  )
ORDER BY
    s.name,
    t.name;

/* 1. Table-level row-count comparison: dbo vs ODS. */
IF OBJECT_ID(N'tempdb..#row_count_audit', N'U') IS NOT NULL
    DROP TABLE #row_count_audit;

CREATE TABLE #row_count_audit (
    source_schema SYSNAME NOT NULL,
    source_table SYSNAME NOT NULL,
    ods_table SYSNAME NULL,
    ods_load_mode NVARCHAR(30) NULL,
    dwd_target_table SYSNAME NULL,
    dwd_load_mode NVARCHAR(30) NULL,
    dbo_rows BIGINT NULL,
    ods_rows BIGINT NULL,
    row_count_diff BIGINT NULL,
    audit_status NVARCHAR(30) NOT NULL
);

DECLARE
    @source_schema SYSNAME,
    @source_table SYSNAME,
    @ods_table SYSNAME,
    @ods_load_mode NVARCHAR(30),
    @dwd_target_table SYSNAME,
    @dwd_load_mode NVARCHAR(30),
    @sql NVARCHAR(MAX);

DECLARE table_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    source_schema,
    source_table,
    ods_table,
    ods_load_mode,
    dwd_target_table,
    dwd_load_mode
FROM #table_scope
ORDER BY source_table;

OPEN table_cursor;
FETCH NEXT FROM table_cursor
INTO @source_schema, @source_table, @ods_table, @ods_load_mode, @dwd_target_table, @dwd_load_mode;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
INSERT INTO #row_count_audit (
    source_schema,
    source_table,
    ods_table,
    ods_load_mode,
    dwd_target_table,
    dwd_load_mode,
    dbo_rows,
    ods_rows,
    row_count_diff,
    audit_status
)
SELECT
    @p_source_schema,
    @p_source_table,
    @p_ods_table,
    @p_ods_load_mode,
    @p_dwd_target_table,
    @p_dwd_load_mode,
    src.dbo_rows,
    ods.ods_rows,
    CASE WHEN ods.ods_rows IS NULL THEN NULL ELSE ods.ods_rows - src.dbo_rows END AS row_count_diff,
    CASE
        WHEN @p_ods_table IS NULL THEN N''MISSING_ODS_TABLE''
        WHEN ods.ods_rows = src.dbo_rows THEN N''OK''
        ELSE N''CHECK''
    END AS audit_status
FROM (
    SELECT COUNT_BIG(*) AS dbo_rows
    FROM ' + QUOTENAME(@source_schema) + N'.' + QUOTENAME(@source_table) + N'
) AS src
CROSS APPLY (
    SELECT ' +
        CASE
            WHEN @ods_table IS NULL THEN N'CAST(NULL AS BIGINT)'
            ELSE N'(SELECT COUNT_BIG(*) FROM [ODS].' + QUOTENAME(@ods_table) + N')'
        END + N' AS ods_rows
) AS ods;
';

    EXEC sys.sp_executesql
        @sql,
        N'@p_source_schema SYSNAME,
          @p_source_table SYSNAME,
          @p_ods_table SYSNAME,
          @p_ods_load_mode NVARCHAR(30),
          @p_dwd_target_table SYSNAME,
          @p_dwd_load_mode NVARCHAR(30)',
        @p_source_schema = @source_schema,
        @p_source_table = @source_table,
        @p_ods_table = @ods_table,
        @p_ods_load_mode = @ods_load_mode,
        @p_dwd_target_table = @dwd_target_table,
        @p_dwd_load_mode = @dwd_load_mode;

    FETCH NEXT FROM table_cursor
    INTO @source_schema, @source_table, @ods_table, @ods_load_mode, @dwd_target_table, @dwd_load_mode;
END;

CLOSE table_cursor;
DEALLOCATE table_cursor;

SELECT
    source_schema,
    source_table,
    ods_table,
    ods_load_mode,
    dwd_target_table,
    dwd_load_mode,
    dbo_rows,
    ods_rows,
    row_count_diff,
    audit_status
FROM #row_count_audit
ORDER BY
    CASE audit_status WHEN N'CHECK' THEN 1 WHEN N'MISSING_ODS_TABLE' THEN 2 ELSE 3 END,
    ABS(COALESCE(row_count_diff, 0)) DESC,
    source_table;

/* 2. Column comparison: dbo source columns vs ODS business columns. */
WITH source_columns AS (
    SELECT
        ts.source_schema,
        ts.source_table,
        c.name AS column_name,
        ty.name AS data_type,
        c.max_length,
        c.precision,
        c.scale,
        c.is_nullable,
        c.column_id
    FROM #table_scope AS ts
    JOIN sys.columns AS c
        ON c.object_id = ts.source_object_id
    JOIN sys.types AS ty
        ON ty.user_type_id = c.user_type_id
),
ods_columns AS (
    SELECT
        ts.source_schema,
        ts.source_table,
        c.name AS column_name,
        ty.name AS data_type,
        c.max_length,
        c.precision,
        c.scale,
        c.is_nullable,
        c.column_id
    FROM #table_scope AS ts
    JOIN sys.columns AS c
        ON c.object_id = ts.ods_object_id
    JOIN sys.types AS ty
        ON ty.user_type_id = c.user_type_id
    WHERE c.name NOT LIKE N'ods[_]%'
),
column_compare AS (
    SELECT
        COALESCE(sc.source_schema, oc.source_schema) AS source_schema,
        COALESCE(sc.source_table, oc.source_table) AS source_table,
        COALESCE(sc.column_name, oc.column_name) AS column_name,
        sc.data_type AS dbo_data_type,
        oc.data_type AS ods_data_type,
        sc.max_length AS dbo_max_length,
        oc.max_length AS ods_max_length,
        sc.precision AS dbo_precision,
        oc.precision AS ods_precision,
        sc.scale AS dbo_scale,
        oc.scale AS ods_scale,
        sc.is_nullable AS dbo_is_nullable,
        oc.is_nullable AS ods_is_nullable,
        CASE
            WHEN sc.column_name IS NULL THEN N'EXTRA_IN_ODS'
            WHEN oc.column_name IS NULL THEN N'MISSING_IN_ODS'
            WHEN sc.data_type <> oc.data_type
              OR sc.max_length <> oc.max_length
              OR sc.precision <> oc.precision
              OR sc.scale <> oc.scale THEN N'TYPE_MISMATCH'
            ELSE N'OK'
        END AS column_status
    FROM source_columns AS sc
    FULL OUTER JOIN ods_columns AS oc
        ON oc.source_schema = sc.source_schema
       AND oc.source_table = sc.source_table
       AND oc.column_name = sc.column_name
)
SELECT
    source_schema,
    source_table,
    column_name,
    dbo_data_type,
    ods_data_type,
    dbo_max_length,
    ods_max_length,
    dbo_precision,
    ods_precision,
    dbo_scale,
    ods_scale,
    column_status
FROM column_compare
WHERE column_status <> N'OK'
ORDER BY
    CASE column_status
        WHEN N'MISSING_IN_ODS' THEN 1
        WHEN N'TYPE_MISMATCH' THEN 2
        WHEN N'EXTRA_IN_ODS' THEN 3
        ELSE 4
    END,
    source_table,
    column_name;

/* 3. ODS metadata-column health. */
SELECT
    ts.source_table,
    ts.ods_table,
    SUM(CASE WHEN c.name = N'ods_row_id' THEN 1 ELSE 0 END) AS has_ods_row_id,
    SUM(CASE WHEN c.name = N'ods_load_time' THEN 1 ELSE 0 END) AS has_ods_load_time,
    SUM(CASE WHEN c.name = N'ods_batch_id' THEN 1 ELSE 0 END) AS has_ods_batch_id,
    SUM(CASE WHEN c.name = N'ods_source_schema' THEN 1 ELSE 0 END) AS has_ods_source_schema,
    SUM(CASE WHEN c.name = N'ods_source_table' THEN 1 ELSE 0 END) AS has_ods_source_table,
    SUM(CASE WHEN c.name = N'ods_operation' THEN 1 ELSE 0 END) AS has_ods_operation,
    SUM(CASE WHEN c.name = N'ods_hash_value' THEN 1 ELSE 0 END) AS has_ods_hash_value
FROM #table_scope AS ts
LEFT JOIN sys.columns AS c
    ON c.object_id = ts.ods_object_id
GROUP BY
    ts.source_table,
    ts.ods_table
ORDER BY
    ts.source_table;

/* 4. ODS load profile: repeated batches/load times are suspicious for mirror tables. */
IF OBJECT_ID(N'tempdb..#ods_load_profile', N'U') IS NOT NULL
    DROP TABLE #ods_load_profile;

CREATE TABLE #ods_load_profile (
    source_table SYSNAME NOT NULL,
    ods_load_mode NVARCHAR(30) NULL,
    ods_rows BIGINT NULL,
    distinct_ods_batch_id BIGINT NULL,
    min_ods_load_time DATETIME2(3) NULL,
    max_ods_load_time DATETIME2(3) NULL,
    rows_with_expected_source_metadata BIGINT NULL,
    rows_with_other_source_metadata BIGINT NULL
);

DECLARE profile_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    source_table,
    ods_table,
    ods_load_mode
FROM #table_scope
WHERE ods_object_id IS NOT NULL
  AND EXISTS (
        SELECT 1
        FROM sys.columns AS c
        WHERE c.object_id = ods_object_id
          AND c.name = N'ods_batch_id'
  )
  AND EXISTS (
        SELECT 1
        FROM sys.columns AS c
        WHERE c.object_id = ods_object_id
          AND c.name = N'ods_load_time'
  )
  AND EXISTS (
        SELECT 1
        FROM sys.columns AS c
        WHERE c.object_id = ods_object_id
          AND c.name = N'ods_source_schema'
  )
  AND EXISTS (
        SELECT 1
        FROM sys.columns AS c
        WHERE c.object_id = ods_object_id
          AND c.name = N'ods_source_table'
  )
ORDER BY source_table;

OPEN profile_cursor;
FETCH NEXT FROM profile_cursor
INTO @source_table, @ods_table, @ods_load_mode;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
INSERT INTO #ods_load_profile (
    source_table,
    ods_load_mode,
    ods_rows,
    distinct_ods_batch_id,
    min_ods_load_time,
    max_ods_load_time,
    rows_with_expected_source_metadata,
    rows_with_other_source_metadata
)
SELECT
    @p_source_table,
    @p_ods_load_mode,
    COUNT_BIG(*) AS ods_rows,
    COUNT_BIG(DISTINCT [ods_batch_id]) AS distinct_ods_batch_id,
    MIN([ods_load_time]) AS min_ods_load_time,
    MAX([ods_load_time]) AS max_ods_load_time,
    SUM(CASE WHEN [ods_source_schema] = N''dbo'' AND [ods_source_table] = @p_source_table THEN CONVERT(BIGINT, 1) ELSE 0 END),
    SUM(CASE WHEN NOT ([ods_source_schema] = N''dbo'' AND [ods_source_table] = @p_source_table) THEN CONVERT(BIGINT, 1) ELSE 0 END)
FROM [ODS].' + QUOTENAME(@ods_table) + N';';

    EXEC sys.sp_executesql
        @sql,
        N'@p_source_table SYSNAME, @p_ods_load_mode NVARCHAR(30)',
        @p_source_table = @source_table,
        @p_ods_load_mode = @ods_load_mode;

    FETCH NEXT FROM profile_cursor
    INTO @source_table, @ods_table, @ods_load_mode;
END;

CLOSE profile_cursor;
DEALLOCATE profile_cursor;

SELECT
    p.source_table,
    p.ods_load_mode,
    r.dbo_rows,
    p.ods_rows,
    p.distinct_ods_batch_id,
    p.min_ods_load_time,
    p.max_ods_load_time,
    p.rows_with_expected_source_metadata,
    p.rows_with_other_source_metadata,
    CASE
        WHEN p.ods_load_mode IN (N'FULL_REPLACE', N'SNAPSHOT') AND p.ods_rows <> r.dbo_rows THEN N'SOFT_REPAIR_ODS_MIRROR_TABLE'
        WHEN p.rows_with_other_source_metadata > 0 THEN N'CHECK_METADATA'
        WHEN p.ods_rows <> r.dbo_rows THEN N'CHECK_INCREMENTAL_OR_DEDUP'
        ELSE N'OK'
    END AS recommended_action
FROM #ods_load_profile AS p
LEFT JOIN #row_count_audit AS r
    ON r.source_table = p.source_table
ORDER BY
    CASE
        WHEN p.ods_load_mode IN (N'FULL_REPLACE', N'SNAPSHOT') AND p.ods_rows <> r.dbo_rows THEN 1
        WHEN p.rows_with_other_source_metadata > 0 THEN 2
        WHEN p.ods_rows <> r.dbo_rows THEN 3
        ELSE 4
    END,
    ABS(COALESCE(p.ods_rows, 0) - COALESCE(r.dbo_rows, 0)) DESC,
    p.source_table;

/* 5. Exact duplicate check for small ODS mirror tables only.
      Avoid running expensive full-row hashing on tens-of-millions-row history tables. */
IF OBJECT_ID(N'tempdb..#small_table_duplicate_audit', N'U') IS NOT NULL
    DROP TABLE #small_table_duplicate_audit;

CREATE TABLE #small_table_duplicate_audit (
    source_table SYSNAME NOT NULL,
    ods_load_mode NVARCHAR(30) NULL,
    ods_rows BIGINT NOT NULL,
    distinct_business_hash_rows BIGINT NULL,
    duplicate_business_rows BIGINT NULL,
    audit_note NVARCHAR(200) NOT NULL
);

DECLARE
    @business_concat NVARCHAR(MAX),
    @duplicate_sql NVARCHAR(MAX),
    @ods_rows BIGINT;

DECLARE dup_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    ts.source_table,
    ts.ods_table,
    ts.ods_load_mode,
    r.ods_rows
FROM #table_scope AS ts
JOIN #row_count_audit AS r
    ON r.source_table = ts.source_table
WHERE ts.ods_object_id IS NOT NULL
  AND COALESCE(r.ods_rows, 0) <= 100000
ORDER BY ts.source_table;

OPEN dup_cursor;
FETCH NEXT FROM dup_cursor
INTO @source_table, @ods_table, @ods_load_mode, @ods_rows;

WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT
        @business_concat = STRING_AGG(
            N'COALESCE(CONVERT(NVARCHAR(MAX), src.' + QUOTENAME(c.name) + N'), N''<NULL>'')',
            N' + N''|'' + '
        ) WITHIN GROUP (ORDER BY c.column_id)
    FROM sys.schemas AS s
    JOIN sys.tables AS t
        ON t.schema_id = s.schema_id
       AND s.name = N'ODS'
       AND t.name = @ods_table
    JOIN sys.columns AS c
        ON c.object_id = t.object_id
    WHERE c.name NOT LIKE N'ods[_]%';

    IF @business_concat IS NOT NULL
    BEGIN
        SET @duplicate_sql = N'
WITH business_hash AS (
    SELECT
        HASHBYTES(''SHA2_256'', CONVERT(VARBINARY(MAX), ' + @business_concat + N')) AS row_hash
    FROM [ODS].' + QUOTENAME(@ods_table) + N' AS src
)
INSERT INTO #small_table_duplicate_audit (
    source_table,
    ods_load_mode,
    ods_rows,
    distinct_business_hash_rows,
    duplicate_business_rows,
    audit_note
)
SELECT
    @p_source_table,
    @p_ods_load_mode,
    COUNT_BIG(*) AS ods_rows,
    COUNT_BIG(DISTINCT row_hash) AS distinct_business_hash_rows,
    COUNT_BIG(*) - COUNT_BIG(DISTINCT row_hash) AS duplicate_business_rows,
    CASE WHEN COUNT_BIG(*) - COUNT_BIG(DISTINCT row_hash) > 0 THEN N''DUPLICATE_BUSINESS_ROWS'' ELSE N''OK'' END
FROM business_hash;';

        EXEC sys.sp_executesql
            @duplicate_sql,
            N'@p_source_table SYSNAME, @p_ods_load_mode NVARCHAR(30)',
            @p_source_table = @source_table,
            @p_ods_load_mode = @ods_load_mode;
    END;

    FETCH NEXT FROM dup_cursor
    INTO @source_table, @ods_table, @ods_load_mode, @ods_rows;
END;

CLOSE dup_cursor;
DEALLOCATE dup_cursor;

SELECT
    source_table,
    ods_load_mode,
    ods_rows,
    distinct_business_hash_rows,
    duplicate_business_rows,
    audit_note
FROM #small_table_duplicate_audit
WHERE audit_note <> N'OK'
ORDER BY
    duplicate_business_rows DESC,
    source_table;

/* 6. DWD control and target row-count profile. */
IF OBJECT_ID(N'[DWD].[etl_watermark]', N'U') IS NOT NULL
BEGIN
    SELECT
        w.source_schema,
        w.source_table,
        w.target_schema,
        w.target_table,
        w.load_mode,
        w.watermark_column,
        w.last_bigint_value,
        w.last_datetime_value,
        w.last_load_time,
        w.is_enabled
    FROM [DWD].[etl_watermark] AS w
    ORDER BY
        w.target_table,
        w.source_table;
END;

/* 7. DWD latest batch/log errors. */
IF OBJECT_ID(N'[DWD].[etl_batch]', N'U') IS NOT NULL
BEGIN
    SELECT TOP (20)
        batch_id,
        batch_start_time,
        batch_end_time,
        batch_status,
        DATEDIFF(SECOND, batch_start_time, batch_end_time) AS duration_seconds,
        error_message
    FROM [DWD].[etl_batch]
    ORDER BY batch_id DESC;
END;

IF OBJECT_ID(N'[DWD].[etl_load_log]', N'U') IS NOT NULL
BEGIN
    SELECT TOP (200)
        batch_id,
        source_schema,
        source_table,
        target_schema,
        target_table,
        load_mode,
        rows_inserted,
        rows_deleted,
        load_status,
        error_message
    FROM [DWD].[etl_load_log]
    WHERE load_status <> N'SUCCESS'
       OR error_message IS NOT NULL
    ORDER BY batch_id DESC, source_table;
END;
GO
