USE IOT2020;
GO

/*
    DWD / ODS post-repair quality check.

    This script is read-only.
    Use it after ODS mirror repair or DWD incremental load.
*/

SET NOCOUNT ON;

/* 1. Latest DWD batches. */
SELECT TOP 20
    b.batch_id,
    b.batch_start_time,
    b.batch_end_time,
    b.batch_status,
    b.error_message
FROM [DWD].[etl_batch] AS b
ORDER BY b.batch_id DESC;

/* 2. Latest DWD load log; failures appear first. */
DECLARE @latest_batch_id BIGINT = (
    SELECT MAX(batch_id)
    FROM [DWD].[etl_batch]
);

SELECT
    l.batch_id,
    l.source_table,
    l.target_table,
    l.load_mode,
    l.rows_inserted,
    l.rows_deleted,
    l.load_status,
    l.error_message
FROM [DWD].[etl_load_log] AS l
WHERE l.batch_id = @latest_batch_id
ORDER BY
    CASE WHEN l.load_status <> N'SUCCESS' THEN 1 ELSE 2 END,
    l.target_table,
    l.source_table;

/* 3. ODS FULL_REPLACE / SNAPSHOT tables must match dbo row counts. */
IF OBJECT_ID(N'tempdb..#ods_mirror_audit', N'U') IS NOT NULL
    DROP TABLE #ods_mirror_audit;

CREATE TABLE #ods_mirror_audit (
    source_table SYSNAME NOT NULL,
    load_mode NVARCHAR(30) NOT NULL,
    dbo_rows BIGINT NULL,
    ods_rows BIGINT NULL,
    row_count_diff BIGINT NULL,
    check_status NVARCHAR(30) NOT NULL
);

DECLARE
    @source_table SYSNAME,
    @load_mode NVARCHAR(30),
    @sql NVARCHAR(MAX);

DECLARE mirror_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    w.source_table,
    w.load_mode
FROM [ODS].[etl_watermark] AS w
WHERE w.source_schema = N'dbo'
  AND w.target_schema = N'ODS'
  AND w.is_enabled = 1
  AND w.load_mode IN (N'FULL_REPLACE', N'SNAPSHOT')
ORDER BY w.source_table;

OPEN mirror_cursor;

FETCH NEXT FROM mirror_cursor
INTO @source_table, @load_mode;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(@source_table), N'U') IS NOT NULL
       AND OBJECT_ID(QUOTENAME(N'ODS') + N'.' + QUOTENAME(@source_table), N'U') IS NOT NULL
    BEGIN
        SET @sql = N'
INSERT INTO #ods_mirror_audit (
    source_table,
    load_mode,
    dbo_rows,
    ods_rows,
    row_count_diff,
    check_status
)
SELECT
    @p_source_table,
    @p_load_mode,
    src.dbo_rows,
    ods.ods_rows,
    ods.ods_rows - src.dbo_rows,
    CASE WHEN ods.ods_rows = src.dbo_rows THEN N''OK'' ELSE N''ROW_COUNT_MISMATCH'' END
FROM (
    SELECT COUNT_BIG(*) AS dbo_rows
    FROM [dbo].' + QUOTENAME(@source_table) + N'
) AS src
CROSS APPLY (
    SELECT COUNT_BIG(*) AS ods_rows
    FROM [ODS].' + QUOTENAME(@source_table) + N'
) AS ods;
';

        EXEC sys.sp_executesql
            @sql,
            N'@p_source_table SYSNAME, @p_load_mode NVARCHAR(30)',
            @p_source_table = @source_table,
            @p_load_mode = @load_mode;
    END
    ELSE
    BEGIN
        INSERT INTO #ods_mirror_audit (
            source_table,
            load_mode,
            check_status
        )
        VALUES (
            @source_table,
            @load_mode,
            N'MISSING_SOURCE_OR_ODS_TABLE'
        );
    END;

    FETCH NEXT FROM mirror_cursor
    INTO @source_table, @load_mode;
END;

CLOSE mirror_cursor;
DEALLOCATE mirror_cursor;

SELECT
    source_table,
    load_mode,
    dbo_rows,
    ods_rows,
    row_count_diff,
    check_status
FROM #ods_mirror_audit
ORDER BY
    CASE WHEN check_status <> N'OK' THEN 1 ELSE 2 END,
    ABS(COALESCE(row_count_diff, 0)) DESC,
    source_table;

/* 4. Core DWD row counts. */
SELECT
    v.table_name,
    v.row_count
FROM (
    SELECT N'DWD.dim_amr_factory_line' AS table_name, COUNT_BIG(*) AS row_count FROM [DWD].[dim_amr_factory_line]
    UNION ALL SELECT N'DWD.dim_amr_job_type', COUNT_BIG(*) FROM [DWD].[dim_amr_job_type]
    UNION ALL SELECT N'DWD.dim_amr_map', COUNT_BIG(*) FROM [DWD].[dim_amr_map]
    UNION ALL SELECT N'DWD.dim_amr_project', COUNT_BIG(*) FROM [DWD].[dim_amr_project]
    UNION ALL SELECT N'DWD.dim_amr_robot', COUNT_BIG(*) FROM [DWD].[dim_amr_robot]
    UNION ALL SELECT N'DWD.dim_amr_station', COUNT_BIG(*) FROM [DWD].[dim_amr_station]
    UNION ALL SELECT N'DWD.snap_amr_current_status', COUNT_BIG(*) FROM [DWD].[snap_amr_current_status]
    UNION ALL SELECT N'DWD.fact_amr_queue', COUNT_BIG(*) FROM [DWD].[fact_amr_queue]
    UNION ALL SELECT N'DWD.fact_amr_raw_status', COUNT_BIG(*) FROM [DWD].[fact_amr_raw_status]
    UNION ALL SELECT N'DWD.fact_amr_subjob', COUNT_BIG(*) FROM [DWD].[fact_amr_subjob]
    UNION ALL SELECT N'DWD.fact_robot_battery', COUNT_BIG(*) FROM [DWD].[fact_robot_battery]
    UNION ALL SELECT N'DWD.fact_robot_job', COUNT_BIG(*) FROM [DWD].[fact_robot_job]
    UNION ALL SELECT N'DWD.fact_robot_status', COUNT_BIG(*) FROM [DWD].[fact_robot_status]
    UNION ALL SELECT N'DWD.fact_robot_wifi', COUNT_BIG(*) FROM [DWD].[fact_robot_wifi]
) AS v
ORDER BY v.table_name;

/* 5. DWD fact source provenance duplicates. */
SELECT
    check_name,
    duplicate_count
FROM (
    SELECT
        N'fact_amr_queue duplicate source rows' AS check_name,
        COUNT_BIG(*) AS duplicate_count
    FROM (
        SELECT source_schema, source_table, source_ods_row_id
        FROM [DWD].[fact_amr_queue]
        WHERE source_ods_row_id IS NOT NULL
        GROUP BY source_schema, source_table, source_ods_row_id
        HAVING COUNT_BIG(*) > 1
    ) AS d

    UNION ALL

    SELECT
        N'fact_amr_subjob duplicate source rows',
        COUNT_BIG(*)
    FROM (
        SELECT source_schema, source_table, source_ods_row_id
        FROM [DWD].[fact_amr_subjob]
        WHERE source_ods_row_id IS NOT NULL
        GROUP BY source_schema, source_table, source_ods_row_id
        HAVING COUNT_BIG(*) > 1
    ) AS d

    UNION ALL

    SELECT
        N'fact_robot_battery duplicate source rows',
        COUNT_BIG(*)
    FROM (
        SELECT source_schema, source_table, source_ods_row_id
        FROM [DWD].[fact_robot_battery]
        WHERE source_ods_row_id IS NOT NULL
        GROUP BY source_schema, source_table, source_ods_row_id
        HAVING COUNT_BIG(*) > 1
    ) AS d

    UNION ALL

    SELECT
        N'fact_robot_job duplicate source rows',
        COUNT_BIG(*)
    FROM (
        SELECT source_schema, source_table, source_ods_row_id
        FROM [DWD].[fact_robot_job]
        WHERE source_ods_row_id IS NOT NULL
        GROUP BY source_schema, source_table, source_ods_row_id
        HAVING COUNT_BIG(*) > 1
    ) AS d

    UNION ALL

    SELECT
        N'fact_robot_status duplicate source rows',
        COUNT_BIG(*)
    FROM (
        SELECT source_schema, source_table, source_ods_row_id
        FROM [DWD].[fact_robot_status]
        WHERE source_ods_row_id IS NOT NULL
        GROUP BY source_schema, source_table, source_ods_row_id
        HAVING COUNT_BIG(*) > 1
    ) AS d

    UNION ALL

    SELECT
        N'fact_robot_wifi duplicate source rows',
        COUNT_BIG(*)
    FROM (
        SELECT source_schema, source_table, source_ods_row_id
        FROM [DWD].[fact_robot_wifi]
        WHERE source_ods_row_id IS NOT NULL
        GROUP BY source_schema, source_table, source_ods_row_id
        HAVING COUNT_BIG(*) > 1
    ) AS d
) AS q
ORDER BY q.check_name;
GO
