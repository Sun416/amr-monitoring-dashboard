USE IOT2020;
GO

/*
    ODS historical gap backfill by anti-join.

    Purpose:
    - Fix the situation where [ODS].[etl_watermark] has already moved forward,
      but some source rows before the watermark are missing in ODS.
    - This script compares dbo.<source_table> to ODS.<target_table> by the
      ID_INCREMENT watermark column and inserts only source rows that do not
      exist in ODS.

    Scope:
    - Source schema: dbo
    - Target schema: ODS
    - Load mode: ID_INCREMENT only
    - Current known gap tables from the latest audit:
        robot_battery_history
        robot_wifi_history
        robot_status_history
        robot_job_history
        AMR_Queue
        TA_AMR_Silence_History

    Safety:
    - Does not DELETE / TRUNCATE / DROP business tables.
    - Does not rebuild tables.
    - Inserts only rows whose source watermark id is missing in the ODS table.
    - Updates ODS.etl_watermark to the current source MAX(id) after each table
      is processed successfully.

    Performance note:
    - Large tables have tens of millions of rows.
    - The script creates a nonclustered index on each ODS target watermark
      column if no index currently starts with that column. This makes the
      NOT EXISTS anti-join practical.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE
    @batch_size INT = 100000,
    @max_batches_per_table INT = 10000;

IF OBJECT_ID(N'[ODS].[etl_watermark]', N'U') IS NULL
BEGIN
    SELECT N'Missing control table: ODS.etl_watermark.';
    RETURN;
END;

DECLARE @target_gap_tables TABLE (
    source_table SYSNAME NOT NULL PRIMARY KEY
);

INSERT INTO @target_gap_tables ([source_table])
VALUES
    (N'robot_battery_history'),
    (N'robot_wifi_history'),
    (N'robot_status_history'),
    (N'robot_job_history'),
    (N'AMR_Queue'),
    (N'TA_AMR_Silence_History');

DECLARE @backfill_result TABLE (
    source_schema SYSNAME NOT NULL,
    source_table SYSNAME NOT NULL,
    target_schema SYSNAME NOT NULL,
    target_table SYSNAME NOT NULL,
    watermark_column SYSNAME NULL,
    rows_inserted BIGINT NOT NULL,
    batches_finished INT NOT NULL,
    new_last_bigint_value BIGINT NULL,
    load_status NVARCHAR(30) NOT NULL,
    result_message NVARCHAR(4000) NULL
);

DECLARE
    @source_schema SYSNAME,
    @source_table SYSNAME,
    @target_schema SYSNAME,
    @target_table SYSNAME,
    @watermark_column SYSNAME,
    @source_full NVARCHAR(300),
    @target_full NVARCHAR(300),
    @source_object_id INT,
    @target_object_id INT,
    @source_column_id INT,
    @target_column_id INT,
    @has_target_index BIT,
    @index_name SYSNAME,
    @index_sql NVARCHAR(MAX),
    @insert_columns NVARCHAR(MAX),
    @select_columns NVARCHAR(MAX),
    @sql NVARCHAR(MAX),
    @rows_inserted BIGINT,
    @batches_finished INT,
    @new_last_bigint_value BIGINT,
    @error_message NVARCHAR(4000);

DECLARE gap_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    wm.[source_schema],
    wm.[source_table],
    wm.[target_schema],
    wm.[target_table],
    wm.[watermark_column]
FROM [ODS].[etl_watermark] AS wm
JOIN @target_gap_tables AS gt
    ON gt.[source_table] = wm.[source_table]
WHERE wm.[is_enabled] = 1
  AND wm.[source_schema] = N'dbo'
  AND wm.[target_schema] = N'ODS'
  AND wm.[load_mode] = N'ID_INCREMENT'
ORDER BY
    wm.[source_table];

OPEN gap_cursor;

FETCH NEXT FROM gap_cursor
INTO
    @source_schema,
    @source_table,
    @target_schema,
    @target_table,
    @watermark_column;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @rows_inserted = 0;
    SET @batches_finished = 0;
    SET @new_last_bigint_value = NULL;
    SET @error_message = NULL;
    SET @source_full = QUOTENAME(@source_schema) + N'.' + QUOTENAME(@source_table);
    SET @target_full = QUOTENAME(@target_schema) + N'.' + QUOTENAME(@target_table);
    SET @source_object_id = OBJECT_ID(@source_full, N'U');
    SET @target_object_id = OBJECT_ID(@target_full, N'U');

    BEGIN TRY
        IF @source_object_id IS NULL
        BEGIN
            INSERT INTO @backfill_result
            VALUES (
                @source_schema, @source_table, @target_schema, @target_table,
                @watermark_column, 0, 0, NULL, N'SKIPPED',
                N'Source table does not exist.'
            );

            FETCH NEXT FROM gap_cursor
            INTO @source_schema, @source_table, @target_schema, @target_table, @watermark_column;
            CONTINUE;
        END;

        IF @target_object_id IS NULL
        BEGIN
            INSERT INTO @backfill_result
            VALUES (
                @source_schema, @source_table, @target_schema, @target_table,
                @watermark_column, 0, 0, NULL, N'SKIPPED',
                N'Target ODS table does not exist.'
            );

            FETCH NEXT FROM gap_cursor
            INTO @source_schema, @source_table, @target_schema, @target_table, @watermark_column;
            CONTINUE;
        END;

        SELECT
            @source_column_id = sc.[column_id]
        FROM sys.columns AS sc
        WHERE sc.[object_id] = @source_object_id
          AND sc.[name] = @watermark_column;

        SELECT
            @target_column_id = tc.[column_id]
        FROM sys.columns AS tc
        WHERE tc.[object_id] = @target_object_id
          AND tc.[name] = @watermark_column;

        IF @source_column_id IS NULL OR @target_column_id IS NULL
        BEGIN
            INSERT INTO @backfill_result
            VALUES (
                @source_schema, @source_table, @target_schema, @target_table,
                @watermark_column, 0, 0, NULL, N'SKIPPED',
                N'Watermark column does not exist in source or target table.'
            );

            FETCH NEXT FROM gap_cursor
            INTO @source_schema, @source_table, @target_schema, @target_table, @watermark_column;
            CONTINUE;
        END;

        SELECT
            @has_target_index =
                CASE
                    WHEN EXISTS (
                        SELECT 1
                        FROM sys.index_columns AS ic
                        JOIN sys.indexes AS ix
                            ON ix.[object_id] = ic.[object_id]
                           AND ix.[index_id] = ic.[index_id]
                        WHERE ic.[object_id] = @target_object_id
                          AND ic.[column_id] = @target_column_id
                          AND ic.[key_ordinal] = 1
                          AND ix.[is_hypothetical] = 0
                          AND ix.[is_disabled] = 0
                    )
                    THEN 1
                    ELSE 0
                END;

        IF @has_target_index = 0
        BEGIN
            SET @index_name = LEFT(
                N'IX_ODS_Backfill_' + REPLACE(@target_table, N']', N'') + N'_' + REPLACE(@watermark_column, N']', N''),
                128
            );

            SET @index_sql =
                N'CREATE NONCLUSTERED INDEX ' + QUOTENAME(@index_name) +
                N' ON ' + @target_full + N' (' + QUOTENAME(@watermark_column) + N');';

            RAISERROR(N'Creating helper index on %s.%s(%s).', 0, 1, @target_schema, @target_table, @watermark_column) WITH NOWAIT;
            EXEC sys.sp_executesql @index_sql;
        END;

        SELECT
            @insert_columns = STRING_AGG(CAST(QUOTENAME(tc.[name]) AS NVARCHAR(MAX)), N', ')
                WITHIN GROUP (ORDER BY tc.[column_id]),
            @select_columns = STRING_AGG(CAST(N'src.' + QUOTENAME(tc.[name]) AS NVARCHAR(MAX)), N', ')
                WITHIN GROUP (ORDER BY tc.[column_id])
        FROM sys.columns AS tc
        JOIN sys.columns AS sc
            ON sc.[object_id] = @source_object_id
           AND sc.[name] = tc.[name]
        WHERE tc.[object_id] = @target_object_id
          AND tc.[is_computed] = 0
          AND tc.[name] NOT LIKE N'ods[_]%'
          AND tc.[name] NOT IN (
                N'ods_row_id',
                N'ods_load_time',
                N'ods_batch_id',
                N'ods_source_schema',
                N'ods_source_table',
                N'ods_operation',
                N'ods_hash_value'
          );

        IF @insert_columns IS NULL OR @select_columns IS NULL
        BEGIN
            INSERT INTO @backfill_result
            VALUES (
                @source_schema, @source_table, @target_schema, @target_table,
                @watermark_column, 0, 0, NULL, N'SKIPPED',
                N'No matching business columns between source and ODS target.'
            );

            FETCH NEXT FROM gap_cursor
            INTO @source_schema, @source_table, @target_schema, @target_table, @watermark_column;
            CONTINUE;
        END;

SET @sql =
N'DECLARE
    @last_scan_value BIGINT = 0,
    @batch_no INT = 0,
    @one_batch_rows BIGINT = 0,
    @progress_message NVARCHAR(4000);

CREATE TABLE #ods_inserted_keys (
    watermark_value BIGINT NOT NULL PRIMARY KEY
);

WHILE @batch_no < @p_max_batches_per_table
BEGIN
    TRUNCATE TABLE #ods_inserted_keys;

    INSERT INTO ' + @target_full + N' (' + @insert_columns + N')
        OUTPUT inserted.' + QUOTENAME(@watermark_column) + N' INTO #ods_inserted_keys ([watermark_value])
    SELECT TOP (@p_batch_size)
        ' + @select_columns + N'
    FROM ' + @source_full + N' AS src
    WHERE src.' + QUOTENAME(@watermark_column) + N' > @last_scan_value
      AND src.' + QUOTENAME(@watermark_column) + N' IS NOT NULL
      AND NOT EXISTS (
            SELECT 1
            FROM ' + @target_full + N' AS tgt
            WHERE tgt.' + QUOTENAME(@watermark_column) + N' = src.' + QUOTENAME(@watermark_column) + N'
      )
    ORDER BY
        src.' + QUOTENAME(@watermark_column) + N';

    SET @one_batch_rows = @@ROWCOUNT;

    IF @one_batch_rows = 0
        BREAK;

    SELECT
        @last_scan_value = MAX([watermark_value])
    FROM #ods_inserted_keys;

    SET @p_rows_inserted += @one_batch_rows;
    SET @batch_no += 1;
    SET @p_batches_finished = @batch_no;

    SET @progress_message = CONCAT(
        N''ODS backfill '',
        @p_source_table,
        N'' batch '',
        @batch_no,
        N'' inserted '',
        @one_batch_rows,
        N'' rows, last id = '',
        @last_scan_value,
        N''.''
    );

    RAISERROR(@progress_message, 0, 1) WITH NOWAIT;
END;

DROP TABLE #ods_inserted_keys;';

        RAISERROR(N'Start ODS anti-join backfill: %s.', 0, 1, @source_table) WITH NOWAIT;

        EXEC sys.sp_executesql
            @sql,
            N'@p_batch_size INT, @p_max_batches_per_table INT, @p_source_table SYSNAME, @p_rows_inserted BIGINT OUTPUT, @p_batches_finished INT OUTPUT',
            @p_batch_size = @batch_size,
            @p_max_batches_per_table = @max_batches_per_table,
            @p_source_table = @source_table,
            @p_rows_inserted = @rows_inserted OUTPUT,
            @p_batches_finished = @batches_finished OUTPUT;

        SET @sql =
            N'SELECT @p_new_last_bigint_value = ISNULL(MAX(src.' + QUOTENAME(@watermark_column) + N'), 0)
              FROM ' + @source_full + N' AS src;';

        EXEC sys.sp_executesql
            @sql,
            N'@p_new_last_bigint_value BIGINT OUTPUT',
            @p_new_last_bigint_value = @new_last_bigint_value OUTPUT;

        UPDATE [ODS].[etl_watermark]
        SET
            [last_bigint_value] = @new_last_bigint_value,
            [last_datetime_value] = NULL,
            [last_load_time] = SYSDATETIME()
        WHERE [source_schema] = @source_schema
          AND [source_table] = @source_table
          AND [target_schema] = @target_schema
          AND [target_table] = @target_table
          AND [load_mode] = N'ID_INCREMENT';

        INSERT INTO @backfill_result
        VALUES (
            @source_schema, @source_table, @target_schema, @target_table,
            @watermark_column, @rows_inserted, @batches_finished,
            @new_last_bigint_value, N'SUCCESS', NULL
        );
    END TRY
    BEGIN CATCH
        SET @error_message = CONCAT(N'Error ', ERROR_NUMBER(), N', line ', ERROR_LINE(), N': ', ERROR_MESSAGE());

        INSERT INTO @backfill_result
        VALUES (
            @source_schema, @source_table, @target_schema, @target_table,
            @watermark_column, @rows_inserted, @batches_finished,
            @new_last_bigint_value, N'FAILED', @error_message
        );
    END CATCH;

    FETCH NEXT FROM gap_cursor
    INTO
        @source_schema,
        @source_table,
        @target_schema,
        @target_table,
        @watermark_column;
END;

CLOSE gap_cursor;
DEALLOCATE gap_cursor;

SELECT
    [source_schema],
    [source_table],
    [target_schema],
    [target_table],
    [watermark_column],
    [rows_inserted],
    [batches_finished],
    [new_last_bigint_value],
    [load_status],
    [result_message]
FROM @backfill_result
ORDER BY
    CASE [load_status] WHEN N'FAILED' THEN 1 WHEN N'SKIPPED' THEN 2 ELSE 3 END,
    [source_table];
GO

/*
    Post-check:
    After this script finishes, run:

    1) 21_run_ods_id_time_incremental.sql
    2) 22_run_dwd_incremental_and_verify.sql
    3) 23_post_fix_quick_check.sql

    The expected result is that dbo-vs-ODS row gaps become 0 or close to 0.
*/
