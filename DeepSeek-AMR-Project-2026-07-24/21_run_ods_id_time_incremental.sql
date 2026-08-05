USE IOT2020;
GO

/*
    ODS manual incremental load for ID_INCREMENT and TIME_INCREMENT mappings.

    Scope:
    - Source schema: dbo
    - Target schema: ODS
    - Uses [ODS].[etl_watermark]
    - Only INSERTS new rows.
    - Does not DELETE / TRUNCATE / UPDATE ODS business table rows.
    - Updates [ODS].[etl_watermark] after each table.

    Why this script exists:
    - Audit showed ODS is behind dbo for large robot history tables by about 0.9M rows.
    - This script catches ODS up before DWD incremental is run.
*/

CREATE OR ALTER PROCEDURE [ODS].[sp_load_id_time_incremental]
AS
BEGIN
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'[ODS].[etl_watermark]', N'U') IS NULL
BEGIN
    SELECT N'Missing control table: ODS.etl_watermark.' AS [message];
    RETURN;
END;

DECLARE @load_result TABLE (
    source_schema SYSNAME NOT NULL,
    source_table SYSNAME NOT NULL,
    target_schema SYSNAME NOT NULL,
    target_table SYSNAME NOT NULL,
    load_mode NVARCHAR(30) NOT NULL,
    watermark_column SYSNAME NULL,
    rows_inserted BIGINT NOT NULL,
    old_last_bigint_value BIGINT NULL,
    new_last_bigint_value BIGINT NULL,
    old_last_datetime_value DATETIME2(3) NULL,
    new_last_datetime_value DATETIME2(3) NULL,
    load_status NVARCHAR(30) NOT NULL,
    message NVARCHAR(4000) NULL
);

DECLARE
    @source_schema SYSNAME,
    @source_table SYSNAME,
    @target_schema SYSNAME,
    @target_table SYSNAME,
    @load_mode NVARCHAR(30),
    @watermark_column SYSNAME,
    @last_bigint_value BIGINT,
    @last_datetime_value DATETIME2(3),
    @source_full NVARCHAR(300),
    @target_full NVARCHAR(300),
    @source_object_id INT,
    @target_object_id INT,
    @insert_columns NVARCHAR(MAX),
    @select_columns NVARCHAR(MAX),
    @sql NVARCHAR(MAX),
    @max_sql NVARCHAR(MAX),
    @rows_inserted BIGINT,
    @new_last_bigint_value BIGINT,
    @new_last_datetime_value DATETIME2(3),
    @error_message NVARCHAR(4000);

DECLARE ods_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    [source_schema],
    [source_table],
    [target_schema],
    [target_table],
    [load_mode],
    [watermark_column],
    [last_bigint_value],
    [last_datetime_value]
FROM [ODS].[etl_watermark]
WHERE [is_enabled] = 1
  AND [source_schema] = N'dbo'
  AND [target_schema] = N'ODS'
  AND [load_mode] IN (N'ID_INCREMENT', N'TIME_INCREMENT')
ORDER BY
    [source_table];

OPEN ods_cursor;

FETCH NEXT FROM ods_cursor
INTO
    @source_schema,
    @source_table,
    @target_schema,
    @target_table,
    @load_mode,
    @watermark_column,
    @last_bigint_value,
    @last_datetime_value;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @rows_inserted = 0;
    SET @new_last_bigint_value = NULL;
    SET @new_last_datetime_value = NULL;
    SET @error_message = NULL;
    SET @source_full = QUOTENAME(@source_schema) + N'.' + QUOTENAME(@source_table);
    SET @target_full = QUOTENAME(@target_schema) + N'.' + QUOTENAME(@target_table);
    SET @source_object_id = OBJECT_ID(@source_full, N'U');
    SET @target_object_id = OBJECT_ID(@target_full, N'U');

    BEGIN TRY
        IF @source_object_id IS NULL
        BEGIN
            INSERT INTO @load_result
            VALUES (
                @source_schema, @source_table, @target_schema, @target_table,
                @load_mode, @watermark_column, 0,
                @last_bigint_value, NULL, @last_datetime_value, NULL,
                N'SKIPPED', N'Source table does not exist.'
            );

            FETCH NEXT FROM ods_cursor
            INTO @source_schema, @source_table, @target_schema, @target_table,
                 @load_mode, @watermark_column, @last_bigint_value, @last_datetime_value;
            CONTINUE;
        END;

        IF @target_object_id IS NULL
        BEGIN
            INSERT INTO @load_result
            VALUES (
                @source_schema, @source_table, @target_schema, @target_table,
                @load_mode, @watermark_column, 0,
                @last_bigint_value, NULL, @last_datetime_value, NULL,
                N'SKIPPED', N'Target ODS table does not exist.'
            );

            FETCH NEXT FROM ods_cursor
            INTO @source_schema, @source_table, @target_schema, @target_table,
                 @load_mode, @watermark_column, @last_bigint_value, @last_datetime_value;
            CONTINUE;
        END;

        IF @watermark_column IS NULL
        BEGIN
            INSERT INTO @load_result
            VALUES (
                @source_schema, @source_table, @target_schema, @target_table,
                @load_mode, @watermark_column, 0,
                @last_bigint_value, NULL, @last_datetime_value, NULL,
                N'SKIPPED', N'Watermark column is NULL.'
            );

            FETCH NEXT FROM ods_cursor
            INTO @source_schema, @source_table, @target_schema, @target_table,
                 @load_mode, @watermark_column, @last_bigint_value, @last_datetime_value;
            CONTINUE;
        END;

        IF NOT EXISTS (
            SELECT 1
            FROM sys.columns
            WHERE object_id = @source_object_id
              AND name = @watermark_column
        )
        BEGIN
            INSERT INTO @load_result
            VALUES (
                @source_schema, @source_table, @target_schema, @target_table,
                @load_mode, @watermark_column, 0,
                @last_bigint_value, NULL, @last_datetime_value, NULL,
                N'SKIPPED', N'Watermark column does not exist in source table.'
            );

            FETCH NEXT FROM ods_cursor
            INTO @source_schema, @source_table, @target_schema, @target_table,
                 @load_mode, @watermark_column, @last_bigint_value, @last_datetime_value;
            CONTINUE;
        END;

        SELECT
            @insert_columns = STRING_AGG(CAST(QUOTENAME(tc.name) AS NVARCHAR(MAX)), N', ')
                WITHIN GROUP (ORDER BY tc.column_id),
            @select_columns = STRING_AGG(CAST(N'src.' + QUOTENAME(tc.name) AS NVARCHAR(MAX)), N', ')
                WITHIN GROUP (ORDER BY tc.column_id)
        FROM sys.columns AS tc
        JOIN sys.columns AS sc
            ON sc.object_id = @source_object_id
           AND sc.name = tc.name
        WHERE tc.object_id = @target_object_id
          AND tc.is_computed = 0
          AND tc.name NOT LIKE N'ods[_]%'
          AND tc.name NOT IN (
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
            INSERT INTO @load_result
            VALUES (
                @source_schema, @source_table, @target_schema, @target_table,
                @load_mode, @watermark_column, 0,
                @last_bigint_value, NULL, @last_datetime_value, NULL,
                N'SKIPPED', N'No matching business columns between source and ODS target.'
            );

            FETCH NEXT FROM ods_cursor
            INTO @source_schema, @source_table, @target_schema, @target_table,
                 @load_mode, @watermark_column, @last_bigint_value, @last_datetime_value;
            CONTINUE;
        END;

        IF @load_mode = N'ID_INCREMENT'
        BEGIN
            SET @sql =
                N'INSERT INTO ' + @target_full + N' (' + @insert_columns + N')
                  SELECT ' + @select_columns + N'
                  FROM ' + @source_full + N' AS src
                  WHERE TRY_CONVERT(BIGINT, src.' + QUOTENAME(@watermark_column) + N') > ISNULL(@p_last_bigint_value, 0)
                    AND NOT EXISTS (
                        SELECT 1
                        FROM ' + @target_full + N' AS tgt
                        WHERE TRY_CONVERT(BIGINT, tgt.' + QUOTENAME(@watermark_column) + N') = TRY_CONVERT(BIGINT, src.' + QUOTENAME(@watermark_column) + N')
                    );

                  SET @p_rows_inserted = @@ROWCOUNT;';

            EXEC sys.sp_executesql
                @sql,
                N'@p_last_bigint_value BIGINT, @p_rows_inserted BIGINT OUTPUT',
                @p_last_bigint_value = @last_bigint_value,
                @p_rows_inserted = @rows_inserted OUTPUT;

            SET @max_sql =
                N'SELECT @p_new_last_bigint_value = ISNULL(MAX(TRY_CONVERT(BIGINT, src.' + QUOTENAME(@watermark_column) + N')), ISNULL(@p_old_last_bigint_value, 0))
                  FROM ' + @source_full + N' AS src;';

            EXEC sys.sp_executesql
                @max_sql,
                N'@p_old_last_bigint_value BIGINT, @p_new_last_bigint_value BIGINT OUTPUT',
                @p_old_last_bigint_value = @last_bigint_value,
                @p_new_last_bigint_value = @new_last_bigint_value OUTPUT;

            UPDATE [ODS].[etl_watermark]
            SET
                [last_bigint_value] = @new_last_bigint_value,
                [last_datetime_value] = NULL,
                [last_load_time] = SYSDATETIME()
            WHERE [source_schema] = @source_schema
              AND [source_table] = @source_table
              AND [target_schema] = @target_schema
              AND [target_table] = @target_table;
        END;

        IF @load_mode = N'TIME_INCREMENT'
        BEGIN
            SET @sql =
                N'INSERT INTO ' + @target_full + N' (' + @insert_columns + N')
                  SELECT ' + @select_columns + N'
                  FROM ' + @source_full + N' AS src
                  WHERE TRY_CONVERT(DATETIME2(3), src.' + QUOTENAME(@watermark_column) + N') > ISNULL(@p_last_datetime_value, CONVERT(DATETIME2(3), ''1900-01-01''));

                  SET @p_rows_inserted = @@ROWCOUNT;';

            EXEC sys.sp_executesql
                @sql,
                N'@p_last_datetime_value DATETIME2(3), @p_rows_inserted BIGINT OUTPUT',
                @p_last_datetime_value = @last_datetime_value,
                @p_rows_inserted = @rows_inserted OUTPUT;

            SET @max_sql =
                N'SELECT @p_new_last_datetime_value = ISNULL(MAX(TRY_CONVERT(DATETIME2(3), src.' + QUOTENAME(@watermark_column) + N')), ISNULL(@p_old_last_datetime_value, CONVERT(DATETIME2(3), ''1900-01-01'')))
                  FROM ' + @source_full + N' AS src;';

            EXEC sys.sp_executesql
                @max_sql,
                N'@p_old_last_datetime_value DATETIME2(3), @p_new_last_datetime_value DATETIME2(3) OUTPUT',
                @p_old_last_datetime_value = @last_datetime_value,
                @p_new_last_datetime_value = @new_last_datetime_value OUTPUT;

            UPDATE [ODS].[etl_watermark]
            SET
                [last_bigint_value] = NULL,
                [last_datetime_value] = @new_last_datetime_value,
                [last_load_time] = SYSDATETIME()
            WHERE [source_schema] = @source_schema
              AND [source_table] = @source_table
              AND [target_schema] = @target_schema
              AND [target_table] = @target_table;
        END;

        INSERT INTO @load_result
        VALUES (
            @source_schema, @source_table, @target_schema, @target_table,
            @load_mode, @watermark_column, @rows_inserted,
            @last_bigint_value, @new_last_bigint_value,
            @last_datetime_value, @new_last_datetime_value,
            N'SUCCESS', NULL
        );
    END TRY
    BEGIN CATCH
        SET @error_message = CONCAT(N'Error ', ERROR_NUMBER(), N', line ', ERROR_LINE(), N': ', ERROR_MESSAGE());

        INSERT INTO @load_result
        VALUES (
            @source_schema, @source_table, @target_schema, @target_table,
            @load_mode, @watermark_column, @rows_inserted,
            @last_bigint_value, @new_last_bigint_value,
            @last_datetime_value, @new_last_datetime_value,
            N'FAILED', @error_message
        );
    END CATCH;

    FETCH NEXT FROM ods_cursor
    INTO
        @source_schema,
        @source_table,
        @target_schema,
        @target_table,
        @load_mode,
        @watermark_column,
        @last_bigint_value,
        @last_datetime_value;
END;

CLOSE ods_cursor;
DEALLOCATE ods_cursor;

SELECT
    [source_schema],
    [source_table],
    [target_schema],
    [target_table],
    [load_mode],
    [watermark_column],
    [rows_inserted],
    [old_last_bigint_value],
    [new_last_bigint_value],
    [old_last_datetime_value],
    [new_last_datetime_value],
    [load_status],
    [message]
FROM @load_result
ORDER BY
    CASE [load_status] WHEN N'FAILED' THEN 1 WHEN N'SKIPPED' THEN 2 ELSE 3 END,
    [source_table];

IF EXISTS (
    SELECT 1
    FROM @load_result
    WHERE [load_status] = N'FAILED'
)
BEGIN
    THROW 52101, 'One or more ODS ID/TIME incremental loads failed. Review the preceding result set.', 1;
END;
END;
GO

EXEC [ODS].[sp_load_id_time_incremental];
GO
