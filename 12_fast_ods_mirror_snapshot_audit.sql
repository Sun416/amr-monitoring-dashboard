USE IOT2020;
GO

/*
    Fast ODS mirror/snapshot audit.

    Purpose:
    - Only checks ODS tables whose load mode is FULL_REPLACE or SNAPSHOT.
    - These tables should normally mirror dbo row counts after each load.
    - It intentionally skips ID_INCREMENT history tables to avoid scanning tens of millions of rows.

    This script is read-only.
*/

SET NOCOUNT ON;

IF OBJECT_ID(N'[ODS].[etl_watermark]', N'U') IS NULL
BEGIN
    THROW 54000, 'ODS.etl_watermark does not exist. Cannot run ODS mirror audit.', 1;
END;

IF OBJECT_ID(N'tempdb..#mirror_audit', N'U') IS NOT NULL
    DROP TABLE #mirror_audit;

CREATE TABLE #mirror_audit (
    source_table SYSNAME NOT NULL,
    load_mode NVARCHAR(30) NOT NULL,
    dbo_rows BIGINT NULL,
    ods_rows BIGINT NULL,
    row_count_diff BIGINT NULL,
    distinct_ods_batch_id BIGINT NULL,
    min_ods_load_time DATETIME2(3) NULL,
    max_ods_load_time DATETIME2(3) NULL,
    metadata_bad_rows BIGINT NULL,
    recommended_action NVARCHAR(60) NOT NULL
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
ORDER BY
    w.source_table;

OPEN mirror_cursor;

FETCH NEXT FROM mirror_cursor
INTO @source_table, @load_mode;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(@source_table), N'U') IS NOT NULL
       AND OBJECT_ID(QUOTENAME(N'ODS') + N'.' + QUOTENAME(@source_table), N'U') IS NOT NULL
    BEGIN
        SET @sql = N'
INSERT INTO #mirror_audit (
    source_table,
    load_mode,
    dbo_rows,
    ods_rows,
    row_count_diff,
    distinct_ods_batch_id,
    min_ods_load_time,
    max_ods_load_time,
    metadata_bad_rows,
    recommended_action
)
SELECT
    @p_source_table AS source_table,
    @p_load_mode AS load_mode,
    src.dbo_rows,
    ods.ods_rows,
    ods.ods_rows - src.dbo_rows AS row_count_diff,
    ods.distinct_ods_batch_id,
    ods.min_ods_load_time,
    ods.max_ods_load_time,
    ods.metadata_bad_rows,
    CASE
        WHEN COALESCE(ods.metadata_bad_rows, 0) > 0
            THEN N''CHECK_METADATA_BEFORE_REPAIR''
        WHEN ods.ods_rows <> src.dbo_rows
            THEN N''SOFT_REPAIR_ODS_MIRROR_TABLE''
        WHEN ods.distinct_ods_batch_id > 1
             AND @p_load_mode = N''SNAPSHOT''
            THEN N''CHECK_REPEATED_SNAPSHOT_LOAD''
        ELSE N''OK''
    END AS recommended_action
FROM (
    SELECT COUNT_BIG(*) AS dbo_rows
    FROM [dbo].' + QUOTENAME(@source_table) + N'
) AS src
CROSS APPLY (
    SELECT
        COUNT_BIG(*) AS ods_rows,
        COUNT_BIG(DISTINCT [ods_batch_id]) AS distinct_ods_batch_id,
        MIN([ods_load_time]) AS min_ods_load_time,
        MAX([ods_load_time]) AS max_ods_load_time,
        SUM(
            CASE
                WHEN [ods_source_schema] <> N''dbo''
                  OR [ods_source_table] <> @p_source_table
                    THEN CONVERT(BIGINT, 1)
                ELSE CONVERT(BIGINT, 0)
            END
        ) AS metadata_bad_rows
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
        INSERT INTO #mirror_audit (
            source_table,
            load_mode,
            recommended_action
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
    distinct_ods_batch_id,
    min_ods_load_time,
    max_ods_load_time,
    metadata_bad_rows,
    recommended_action
FROM #mirror_audit
ORDER BY
    CASE recommended_action
        WHEN N'SOFT_REPAIR_ODS_MIRROR_TABLE' THEN 1
        WHEN N'CHECK_METADATA_BEFORE_REPAIR' THEN 2
        WHEN N'CHECK_REPEATED_SNAPSHOT_LOAD' THEN 3
        WHEN N'MISSING_SOURCE_OR_ODS_TABLE' THEN 4
        ELSE 5
    END,
    ABS(COALESCE(row_count_diff, 0)) DESC,
    source_table;
GO
