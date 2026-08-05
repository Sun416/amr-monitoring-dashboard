USE IOT2020;
GO

/*
    Last-resort generator for ODS rebuild scripts from current dbo robot/AMR source tables.

    Do not use this as the default repair path.
    The preferred path is:
    1. Run 09_full_ods_dwd_audit.sql.
    2. Run 10_repair_ods_mirror_tables.sql in dry-run mode.
    3. Soft-repair existing tables without dropping/recreating them.

    Read-only generator:
    - It outputs rebuild_sql text.
    - It does NOT execute DROP/CREATE/INSERT.

    Use this only for tables whose ODS structure is proven wrong by
    09_full_ods_dwd_audit.sql.

    Important:
    - Rebuilding an ODS history table changes ods_row_id values and can invalidate
      DWD fact tables that use source_ods_row_id.
    - For FULL_REPLACE / SNAPSHOT tables, rebuild risk is lower.
*/

SET NOCOUNT ON;

IF OBJECT_ID(N'tempdb..#source_tables', N'U') IS NOT NULL
    DROP TABLE #source_tables;

CREATE TABLE #source_tables (
    source_schema SYSNAME NOT NULL,
    source_table SYSNAME NOT NULL,
    source_object_id INT NOT NULL,
    ods_load_mode NVARCHAR(30) NULL,
    dwd_target_table SYSNAME NULL,
    rebuild_risk NVARCHAR(100) NOT NULL
);

INSERT INTO #source_tables (
    source_schema,
    source_table,
    source_object_id,
    ods_load_mode,
    dwd_target_table,
    rebuild_risk
)
SELECT
    s.name AS source_schema,
    t.name AS source_table,
    t.object_id AS source_object_id,
    ow.load_mode AS ods_load_mode,
    dw.target_table AS dwd_target_table,
    CASE
        WHEN ow.load_mode IN (N'FULL_REPLACE', N'SNAPSHOT') THEN N'LOWER: mirror/snapshot table'
        WHEN ow.load_mode IN (N'ID_INCREMENT', N'TIME_INCREMENT') THEN N'HIGH: rebuilding changes ODS ods_row_id; DWD fact rebuild required'
        WHEN ow.load_mode = N'IGNORE' THEN N'LOWER: ignored table'
        ELSE N'UNKNOWN: review manually'
    END AS rebuild_risk
FROM sys.tables AS t
JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
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
  );

WITH column_defs AS (
    SELECT
        st.source_schema,
        st.source_table,
        c.column_id,
        column_definition =
            N'    ' + QUOTENAME(c.name) + N' ' +
            CASE
                WHEN ty.name IN (N'nvarchar', N'nchar') THEN
                    ty.name + N'(' +
                    CASE
                        WHEN c.max_length = -1 THEN N'MAX'
                        ELSE CONVERT(NVARCHAR(10), c.max_length / 2)
                    END + N')'
                WHEN ty.name IN (N'varchar', N'char', N'varbinary', N'binary') THEN
                    ty.name + N'(' +
                    CASE
                        WHEN c.max_length = -1 THEN N'MAX'
                        ELSE CONVERT(NVARCHAR(10), c.max_length)
                    END + N')'
                WHEN ty.name IN (N'decimal', N'numeric') THEN
                    ty.name + N'(' +
                    CONVERT(NVARCHAR(10), c.precision) + N',' +
                    CONVERT(NVARCHAR(10), c.scale) + N')'
                WHEN ty.name IN (N'datetime2', N'datetimeoffset', N'time') THEN
                    ty.name + N'(' + CONVERT(NVARCHAR(10), c.scale) + N')'
                WHEN ty.name IN (N'timestamp', N'rowversion') THEN
                    N'varbinary(8)'
                ELSE
                    ty.name
            END +
            CASE
                WHEN c.is_nullable = 1 THEN N' NULL'
                ELSE N' NOT NULL'
            END
    FROM #source_tables AS st
    JOIN sys.columns AS c
        ON c.object_id = st.source_object_id
    JOIN sys.types AS ty
        ON ty.user_type_id = c.user_type_id
),
column_def_agg AS (
    SELECT
        source_schema,
        source_table,
        STRING_AGG(column_definition, N',' + CHAR(13) + CHAR(10))
            WITHIN GROUP (ORDER BY column_id) AS create_column_definitions
    FROM column_defs
    GROUP BY
        source_schema,
        source_table
),
insert_column_agg AS (
    SELECT
        st.source_schema,
        st.source_table,
        STRING_AGG(QUOTENAME(c.name), N', ') WITHIN GROUP (ORDER BY c.column_id) AS insert_columns,
        STRING_AGG(N'src.' + QUOTENAME(c.name), N', ') WITHIN GROUP (ORDER BY c.column_id) AS select_columns
    FROM #source_tables AS st
    JOIN sys.columns AS c
        ON c.object_id = st.source_object_id
    GROUP BY
        st.source_schema,
        st.source_table
),
table_scripts AS (
    SELECT
        st.source_schema,
        st.source_table,
        st.ods_load_mode,
        st.dwd_target_table,
        st.rebuild_risk,
        rebuild_sql =
N'/*
    Rebuild script generated for [ODS].' + QUOTENAME(st.source_table) + N'
    Source: ' + QUOTENAME(st.source_schema) + N'.' + QUOTENAME(st.source_table) + N'
    ODS load mode: ' + COALESCE(st.ods_load_mode, N'(not configured)') + N'
    DWD target: ' + COALESCE(st.dwd_target_table, N'(not configured)') + N'
    Risk: ' + st.rebuild_risk + N'
*/

-- Review downstream dependencies before executing.
-- IF OBJECT_ID(N''[ODS].' + QUOTENAME(st.source_table) + N''', N''U'') IS NOT NULL
--     DROP TABLE [ODS].' + QUOTENAME(st.source_table) + N';

CREATE TABLE [ODS].' + QUOTENAME(st.source_table) + N' (
    [ods_row_id] BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY CLUSTERED,
' +
cda.create_column_definitions
+
N',
    [ods_load_time] DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
    [ods_batch_id] BIGINT NULL,
    [ods_source_schema] NVARCHAR(128) NOT NULL DEFAULT N''' + st.source_schema + N''',
    [ods_source_table] NVARCHAR(128) NOT NULL DEFAULT N''' + st.source_table + N''',
    [ods_operation] CHAR(1) NULL,
    [ods_hash_value] VARBINARY(32) NULL
);

INSERT INTO [ODS].' + QUOTENAME(st.source_table) + N' (
    ' + ica.insert_columns + N',
    [ods_source_schema],
    [ods_source_table],
    [ods_operation]
)
SELECT
    ' + ica.select_columns + N',
    N''' + st.source_schema + N''',
    N''' + st.source_table + N''',
    N''R''
FROM ' + QUOTENAME(st.source_schema) + N'.' + QUOTENAME(st.source_table) + N' AS src;
'
    FROM #source_tables AS st
    JOIN column_def_agg AS cda
        ON cda.source_schema = st.source_schema
       AND cda.source_table = st.source_table
    JOIN insert_column_agg AS ica
        ON ica.source_schema = st.source_schema
       AND ica.source_table = st.source_table
)
SELECT
    source_schema,
    source_table,
    ods_load_mode,
    dwd_target_table,
    rebuild_risk,
    rebuild_sql
FROM table_scripts
ORDER BY
    CASE
        WHEN ods_load_mode IN (N'FULL_REPLACE', N'SNAPSHOT') THEN 1
        WHEN ods_load_mode = N'IGNORE' THEN 2
        ELSE 3
    END,
    source_table;
GO
