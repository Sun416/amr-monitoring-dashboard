USE IOT2020;
GO

/*
    Soft-repair ODS mirror/snapshot tables that were accidentally appended.

    Target tables:
    - ODS.etl_watermark load_mode IN ('FULL_REPLACE', 'SNAPSHOT')
    - Examples: AMR_Currentdata, AMR_Robot_Mode, MA_AMR*, AMR_List, configuration tables.

    This script intentionally does NOT repair ID_INCREMENT history tables.
    Rebuilding history ODS tables would change ods_row_id and can invalidate DWD fact provenance.

    Default mode is DRY RUN.
    Change @dry_run to 0 only after reviewing the preview result.

    Execution mode is NOT table rebuild:
    - No DROP TABLE.
    - No TRUNCATE TABLE.
    - Existing ODS table structure is preserved.
    - Before deleting stale mirror rows, the affected rows are copied into ODS_REPAIR backup tables.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @dry_run BIT = 1;  -- 1 = preview only, 0 = execute repair
DECLARE @archive_before_delete BIT = 1;
DECLARE @repair_run_token NVARCHAR(30) =
    CONVERT(NVARCHAR(8), CONVERT(DATE, SYSDATETIME()), 112) +
    REPLACE(CONVERT(NVARCHAR(8), CONVERT(TIME(0), SYSDATETIME())), N':', N'');

IF OBJECT_ID(N'[ODS].[etl_watermark]', N'U') IS NULL
BEGIN
    THROW 53000, 'ODS.etl_watermark does not exist. Cannot identify mirror tables safely.', 1;
END;

IF OBJECT_ID(N'tempdb..#repair_plan', N'U') IS NOT NULL
    DROP TABLE #repair_plan;

CREATE TABLE #repair_plan (
    plan_id INT IDENTITY(1,1) NOT NULL,
    source_schema SYSNAME NOT NULL,
    source_table SYSNAME NOT NULL,
    target_schema SYSNAME NOT NULL,
    target_table SYSNAME NOT NULL,
    load_mode NVARCHAR(30) NOT NULL,
    source_object_id INT NULL,
    target_object_id INT NULL,
    source_rows BIGINT NULL,
    target_rows_before BIGINT NULL,
    matching_business_columns INT NULL,
    missing_source_columns_in_ods INT NULL,
    extra_business_columns_in_ods INT NULL,
    can_repair BIT NOT NULL DEFAULT 0,
    repair_status NVARCHAR(40) NOT NULL DEFAULT N'PENDING',
    note NVARCHAR(1000) NULL
);

INSERT INTO #repair_plan (
    source_schema,
    source_table,
    target_schema,
    target_table,
    load_mode,
    source_object_id,
    target_object_id
)
SELECT
    w.source_schema,
    w.source_table,
    w.target_schema,
    w.target_table,
    w.load_mode,
    src.object_id AS source_object_id,
    tgt.object_id AS target_object_id
FROM [ODS].[etl_watermark] AS w
LEFT JOIN sys.schemas AS src_s
    ON src_s.name = w.source_schema
LEFT JOIN sys.tables AS src
    ON src.schema_id = src_s.schema_id
   AND src.name = w.source_table
LEFT JOIN sys.schemas AS tgt_s
    ON tgt_s.name = w.target_schema
LEFT JOIN sys.tables AS tgt
    ON tgt.schema_id = tgt_s.schema_id
   AND tgt.name = w.target_table
WHERE w.target_schema = N'ODS'
  AND w.source_schema = N'dbo'
  AND w.is_enabled = 1
  AND w.load_mode IN (N'FULL_REPLACE', N'SNAPSHOT');

/* Count source and target rows. */
DECLARE
    @plan_id INT,
    @source_schema SYSNAME,
    @source_table SYSNAME,
    @target_schema SYSNAME,
    @target_table SYSNAME,
    @source_object_id INT,
    @target_object_id INT,
    @source_rows BIGINT,
    @target_rows BIGINT,
    @sql NVARCHAR(MAX);

DECLARE count_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    plan_id,
    source_schema,
    source_table,
    target_schema,
    target_table,
    source_object_id,
    target_object_id
FROM #repair_plan
ORDER BY source_table;

OPEN count_cursor;
FETCH NEXT FROM count_cursor
INTO @plan_id, @source_schema, @source_table, @target_schema, @target_table, @source_object_id, @target_object_id;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @source_rows = NULL;
    SET @target_rows = NULL;

    IF @source_object_id IS NOT NULL
    BEGIN
        SET @sql = N'SELECT @p_count = COUNT_BIG(*) FROM ' + QUOTENAME(@source_schema) + N'.' + QUOTENAME(@source_table) + N';';
        EXEC sys.sp_executesql
            @sql,
            N'@p_count BIGINT OUTPUT',
            @p_count = @source_rows OUTPUT;
    END;

    IF @target_object_id IS NOT NULL
    BEGIN
        SET @sql = N'SELECT @p_count = COUNT_BIG(*) FROM ' + QUOTENAME(@target_schema) + N'.' + QUOTENAME(@target_table) + N';';
        EXEC sys.sp_executesql
            @sql,
            N'@p_count BIGINT OUTPUT',
            @p_count = @target_rows OUTPUT;
    END;

    UPDATE #repair_plan
    SET
        source_rows = @source_rows,
        target_rows_before = @target_rows
    WHERE plan_id = @plan_id;

    FETCH NEXT FROM count_cursor
    INTO @plan_id, @source_schema, @source_table, @target_schema, @target_table, @source_object_id, @target_object_id;
END;

CLOSE count_cursor;
DEALLOCATE count_cursor;

/* Validate column compatibility. */
WITH source_cols AS (
    SELECT
        p.plan_id,
        c.name AS column_name
    FROM #repair_plan AS p
    JOIN sys.columns AS c
        ON c.object_id = p.source_object_id
),
target_business_cols AS (
    SELECT
        p.plan_id,
        c.name AS column_name
    FROM #repair_plan AS p
    JOIN sys.columns AS c
        ON c.object_id = p.target_object_id
    WHERE c.name NOT LIKE N'ods[_]%'
),
all_business_cols AS (
    SELECT
        plan_id,
        column_name
    FROM source_cols
    UNION
    SELECT
        plan_id,
        column_name
    FROM target_business_cols
),
column_summary AS (
    SELECT
        ac.plan_id,
        SUM(CASE WHEN sc.column_name IS NOT NULL AND tc.column_name IS NOT NULL THEN 1 ELSE 0 END) AS matching_business_columns,
        SUM(CASE WHEN sc.column_name IS NOT NULL AND tc.column_name IS NULL THEN 1 ELSE 0 END) AS missing_source_columns_in_ods,
        SUM(CASE WHEN sc.column_name IS NULL AND tc.column_name IS NOT NULL THEN 1 ELSE 0 END) AS extra_business_columns_in_ods
    FROM all_business_cols AS ac
    LEFT JOIN source_cols AS sc
        ON sc.plan_id = ac.plan_id
       AND sc.column_name = ac.column_name
    LEFT JOIN target_business_cols AS tc
        ON tc.plan_id = ac.plan_id
       AND tc.column_name = ac.column_name
    GROUP BY
        ac.plan_id
)
UPDATE p
SET
    matching_business_columns = cs.matching_business_columns,
    missing_source_columns_in_ods = cs.missing_source_columns_in_ods,
    extra_business_columns_in_ods = cs.extra_business_columns_in_ods
FROM #repair_plan AS p
JOIN column_summary AS cs
    ON cs.plan_id = p.plan_id;

/* Decide which tables are safe for in-place row refresh. */
UPDATE p
SET
    can_repair = CASE
        WHEN source_object_id IS NULL THEN 0
        WHEN target_object_id IS NULL THEN 0
        WHEN source_rows IS NULL OR target_rows_before IS NULL THEN 0
        WHEN missing_source_columns_in_ods > 0 THEN 0
        WHEN extra_business_columns_in_ods > 0 THEN 0
        WHEN NOT EXISTS (
            SELECT 1
            FROM sys.columns AS c
            WHERE c.object_id = p.target_object_id
              AND c.name = N'ods_source_schema'
        ) THEN 0
        WHEN NOT EXISTS (
            SELECT 1
            FROM sys.columns AS c
            WHERE c.object_id = p.target_object_id
              AND c.name = N'ods_source_table'
        ) THEN 0
        ELSE 1
    END,
    note = CASE
        WHEN source_object_id IS NULL THEN N'Source dbo table missing.'
        WHEN target_object_id IS NULL THEN N'ODS target table missing.'
        WHEN source_rows IS NULL OR target_rows_before IS NULL THEN N'Could not count rows.'
        WHEN missing_source_columns_in_ods > 0 THEN N'ODS table is missing source business columns. Do not refresh rows until structure is reviewed.'
        WHEN extra_business_columns_in_ods > 0 THEN N'ODS table has extra business columns. Review structure before automated repair.'
        WHEN NOT EXISTS (
            SELECT 1
            FROM sys.columns AS c
            WHERE c.object_id = p.target_object_id
              AND c.name = N'ods_source_schema'
        ) THEN N'ODS metadata column ods_source_schema missing.'
        WHEN NOT EXISTS (
            SELECT 1
            FROM sys.columns AS c
            WHERE c.object_id = p.target_object_id
              AND c.name = N'ods_source_table'
        ) THEN N'ODS metadata column ods_source_table missing.'
        WHEN target_rows_before <> source_rows THEN N'Will soft-repair by archiving current ODS rows, deleting stale mirror rows, then inserting current dbo rows into the same ODS table.'
        ELSE N'Row count already matches. Row refresh is optional and skipped unless executed explicitly.'
    END
FROM #repair_plan AS p;

/* Preview. Review this result before changing @dry_run to 0. */
SELECT
    plan_id,
    source_schema,
    source_table,
    target_schema,
    target_table,
    load_mode,
    source_rows,
    target_rows_before,
    target_rows_before - source_rows AS row_count_diff,
    matching_business_columns,
    missing_source_columns_in_ods,
    extra_business_columns_in_ods,
    can_repair,
    note
FROM #repair_plan
ORDER BY
    CASE
        WHEN can_repair = 1 AND target_rows_before <> source_rows THEN 1
        WHEN can_repair = 0 THEN 2
        ELSE 3
    END,
    ABS(COALESCE(target_rows_before, 0) - COALESCE(source_rows, 0)) DESC,
    source_table;

IF @dry_run = 1
BEGIN
    SELECT
        N'DRY_RUN_ONLY' AS execution_status,
        N'No data was changed. If the preview is correct, set @dry_run = 0 and rerun this script.' AS message;
    RETURN;
END;

/* Execute repair. Only tables with count mismatch are refreshed in place. */
DECLARE
    @insert_columns NVARCHAR(MAX),
    @select_columns NVARCHAR(MAX),
    @rows_deleted BIGINT,
    @rows_inserted BIGINT,
    @archive_table SYSNAME,
    @message NVARCHAR(4000);

IF @archive_before_delete = 1
   AND SCHEMA_ID(N'ODS_REPAIR') IS NULL
BEGIN
    EXEC(N'CREATE SCHEMA [ODS_REPAIR]');
END;

DECLARE repair_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    plan_id,
    source_schema,
    source_table,
    target_schema,
    target_table,
    source_object_id,
    target_object_id
FROM #repair_plan
WHERE can_repair = 1
  AND target_rows_before <> source_rows
ORDER BY source_table;

OPEN repair_cursor;
FETCH NEXT FROM repair_cursor
INTO @plan_id, @source_schema, @source_table, @target_schema, @target_table, @source_object_id, @target_object_id;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @insert_columns = NULL;
    SET @select_columns = NULL;
    SET @rows_deleted = 0;
    SET @rows_inserted = 0;
    SET @archive_table = LEFT(N'backup_' + @target_table + N'_' + @repair_run_token, 128);

    SELECT
        @insert_columns = STRING_AGG(QUOTENAME(src.name), N', ') WITHIN GROUP (ORDER BY src.column_id),
        @select_columns = STRING_AGG(N'src.' + QUOTENAME(src.name), N', ') WITHIN GROUP (ORDER BY src.column_id)
    FROM sys.columns AS src
    JOIN sys.columns AS tgt
        ON tgt.object_id = @target_object_id
       AND tgt.name = src.name
    WHERE src.object_id = @source_object_id;

    IF @insert_columns IS NULL OR @select_columns IS NULL
    BEGIN
        UPDATE #repair_plan
        SET
            repair_status = N'SKIPPED',
            note = N'No matching source/target columns found.'
        WHERE plan_id = @plan_id;

        FETCH NEXT FROM repair_cursor
        INTO @plan_id, @source_schema, @source_table, @target_schema, @target_table, @source_object_id, @target_object_id;

        CONTINUE;
    END;

    BEGIN TRY
        BEGIN TRAN;

        IF @archive_before_delete = 1
        BEGIN
            SET @sql = N'
IF OBJECT_ID(N''[ODS_REPAIR].' + QUOTENAME(@archive_table) + N''', N''U'') IS NULL
BEGIN
    SELECT
        tgt.*
    INTO [ODS_REPAIR].' + QUOTENAME(@archive_table) + N'
    FROM ' + QUOTENAME(@target_schema) + N'.' + QUOTENAME(@target_table) + N' AS tgt
    WHERE tgt.[ods_source_schema] = @p_source_schema
      AND tgt.[ods_source_table] = @p_source_table;
END;';

            EXEC sys.sp_executesql
                @sql,
                N'@p_source_schema SYSNAME, @p_source_table SYSNAME',
                @p_source_schema = @source_schema,
                @p_source_table = @source_table;
        END;

        SET @sql = N'
DELETE tgt
FROM ' + QUOTENAME(@target_schema) + N'.' + QUOTENAME(@target_table) + N' AS tgt
WHERE tgt.[ods_source_schema] = @p_source_schema
  AND tgt.[ods_source_table] = @p_source_table;

SET @p_rows_deleted = @@ROWCOUNT;

INSERT INTO ' + QUOTENAME(@target_schema) + N'.' + QUOTENAME(@target_table) + N' (
    ' + @insert_columns + N',
    [ods_batch_id],
    [ods_source_schema],
    [ods_source_table],
    [ods_operation]
)
SELECT
    ' + @select_columns + N',
    NULL AS [ods_batch_id],
    @p_source_schema AS [ods_source_schema],
    @p_source_table AS [ods_source_table],
    N''R'' AS [ods_operation]
FROM ' + QUOTENAME(@source_schema) + N'.' + QUOTENAME(@source_table) + N' AS src;

SET @p_rows_inserted = @@ROWCOUNT;
';

        EXEC sys.sp_executesql
            @sql,
            N'@p_source_schema SYSNAME,
              @p_source_table SYSNAME,
              @p_rows_deleted BIGINT OUTPUT,
              @p_rows_inserted BIGINT OUTPUT',
            @p_source_schema = @source_schema,
            @p_source_table = @source_table,
            @p_rows_deleted = @rows_deleted OUTPUT,
            @p_rows_inserted = @rows_inserted OUTPUT;

        UPDATE [ODS].[etl_watermark]
        SET
            last_bigint_value = NULL,
            last_datetime_value = NULL,
            last_load_time = SYSDATETIME()
        WHERE target_schema = N'ODS'
          AND target_table = @target_table
          AND source_schema = @source_schema
          AND source_table = @source_table;

        COMMIT;

        UPDATE #repair_plan
        SET
            repair_status = N'REPAIRED',
            note = N'In-place row refresh. Backup table: [ODS_REPAIR].' + QUOTENAME(@archive_table) + N'. Deleted ' + CONVERT(NVARCHAR(30), @rows_deleted) + N' rows and inserted ' + CONVERT(NVARCHAR(30), @rows_inserted) + N' rows.'
        WHERE plan_id = @plan_id;

        SET @message =
            N'ODS mirror soft-repaired: ' + QUOTENAME(@target_schema) + N'.' + QUOTENAME(@target_table) +
            N', deleted=' + CONVERT(NVARCHAR(30), @rows_deleted) +
            N', inserted=' + CONVERT(NVARCHAR(30), @rows_inserted) +
            N', backup=[ODS_REPAIR].' + QUOTENAME(@archive_table);

        RAISERROR(@message, 0, 1) WITH NOWAIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK;

        UPDATE #repair_plan
        SET
            repair_status = N'ERROR',
            note = ERROR_MESSAGE()
        WHERE plan_id = @plan_id;
    END CATCH;

    FETCH NEXT FROM repair_cursor
    INTO @plan_id, @source_schema, @source_table, @target_schema, @target_table, @source_object_id, @target_object_id;
END;

CLOSE repair_cursor;
DEALLOCATE repair_cursor;

/* Final repair result. */
SELECT
    plan_id,
    source_schema,
    source_table,
    target_schema,
    target_table,
    load_mode,
    source_rows,
    target_rows_before,
    repair_status,
    note
FROM #repair_plan
ORDER BY
    CASE repair_status
        WHEN N'ERROR' THEN 1
        WHEN N'REPAIRED' THEN 2
        WHEN N'SKIPPED' THEN 3
        ELSE 4
    END,
    source_table;
GO
