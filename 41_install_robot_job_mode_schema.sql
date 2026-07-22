USE [IOT2020];
GO

/*
    Install the schema and required lookup indexes for robot job type + mode.

    Important:
      - No ODS business column is changed. ODS remains a raw source mirror.
      - The index on ODS.robot_status_history covers tens of millions of rows.
        Run this script in a maintenance window and make sure the database and
        transaction log have enough free space.
      - The script is idempotent and can be run again after an interruption.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

/*
    Preflight is read-only. The install flag gates every later DDL step so a
    missing source object or column cannot result in a partial installation.
*/
DECLARE @preflight_ok BIT;

SELECT
    @preflight_ok = CASE
        WHEN OBJECT_ID(N'[ODS].[robot_job_history]', N'U') IS NULL
          OR OBJECT_ID(N'[ODS].[robot_status_history]', N'U') IS NULL
          OR OBJECT_ID(N'[ODS].[AMR_Robot_Mode]', N'U') IS NULL
          OR OBJECT_ID(N'[DWD].[fact_robot_job]', N'U') IS NULL
          OR OBJECT_ID(N'[DWS].[dws_robot_job_daily]', N'U') IS NULL
          OR COL_LENGTH(N'ODS.robot_job_history', N'ods_row_id') IS NULL
          OR COL_LENGTH(N'ODS.robot_job_history', N'amr_id') IS NULL
          OR COL_LENGTH(N'ODS.robot_job_history', N'pc_timestamp') IS NULL
          OR COL_LENGTH(N'ODS.robot_job_history', N'job_name') IS NULL
          OR COL_LENGTH(N'ODS.robot_status_history', N'ods_row_id') IS NULL
          OR COL_LENGTH(N'ODS.robot_status_history', N'amr_id') IS NULL
          OR COL_LENGTH(N'ODS.robot_status_history', N'pc_timestamp') IS NULL
          OR COL_LENGTH(N'ODS.robot_status_history', N'robot_mode') IS NULL
          OR COL_LENGTH(N'ODS.AMR_Robot_Mode', N'Mode_ID') IS NULL
          OR COL_LENGTH(N'ODS.AMR_Robot_Mode', N'Mode_Detail') IS NULL
            THEN 0
        ELSE 1
    END;

SELECT
    @preflight_ok AS [preflight_ok],
    CASE
        WHEN @preflight_ok = 1 THEN N'OK: required objects and source columns exist.'
        ELSE N'STOP: a required object or source column is missing; review script 40 output.'
    END AS [preflight_message];

/*
    Install the five nullable target columns in a separate dynamic batch.
    This avoids SQL Server compiling later statements against columns that do
    not exist yet. The small column changes are transaction protected.
*/
DECLARE @column_install_sql NVARCHAR(MAX) = N'';

SELECT
    @column_install_sql = CASE
        WHEN @preflight_ok = 0 THEN N''
        ELSE
            N'SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;
' +
            CASE WHEN COL_LENGTH(N'DWD.fact_robot_job', N'robot_mode_id') IS NULL
                THEN N'ALTER TABLE [DWD].[fact_robot_job] ADD [robot_mode_id] NVARCHAR(100) NULL;
'
                ELSE N'' END +
            CASE WHEN COL_LENGTH(N'DWD.fact_robot_job', N'robot_mode_detail') IS NULL
                THEN N'ALTER TABLE [DWD].[fact_robot_job] ADD [robot_mode_detail] NVARCHAR(200) NULL;
'
                ELSE N'' END +
            CASE WHEN COL_LENGTH(N'DWD.fact_robot_job', N'source_status_ods_row_id') IS NULL
                THEN N'ALTER TABLE [DWD].[fact_robot_job] ADD [source_status_ods_row_id] BIGINT NULL;
'
                ELSE N'' END +
            CASE WHEN COL_LENGTH(N'DWS.dws_robot_job_daily', N'robot_mode_id') IS NULL
                THEN N'ALTER TABLE [DWS].[dws_robot_job_daily] ADD [robot_mode_id] NVARCHAR(100) NULL;
'
                ELSE N'' END +
            CASE WHEN COL_LENGTH(N'DWS.dws_robot_job_daily', N'robot_mode_detail') IS NULL
                THEN N'ALTER TABLE [DWS].[dws_robot_job_daily] ADD [robot_mode_detail] NVARCHAR(200) NULL;
'
                ELSE N'' END +
            N'    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    DECLARE @column_error NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR(N''Robot job/mode column installation failed: %s'', 16, 1, @column_error);
END CATCH;'
    END;

EXEC sys.sp_executesql @column_install_sql;

/*
    Rebuild the DWS unique key only when its definition is not already the
    required four-column business key. Duplicate validation occurs before DROP.
*/
DECLARE
    @dws_index_requires_rebuild BIT = 0,
    @dws_index_sql NVARCHAR(MAX) = N'';

SELECT
    @dws_index_requires_rebuild = CASE
        WHEN @preflight_ok = 0
          OR COL_LENGTH(N'DWS.dws_robot_job_daily', N'robot_mode_id') IS NULL
            THEN 0
        WHEN NOT EXISTS (
            SELECT 1
            FROM sys.indexes AS i
            WHERE i.[object_id] = OBJECT_ID(N'[DWS].[dws_robot_job_daily]')
              AND i.[name] = N'UX_DWS_robot_job_daily_robot_date_type'
        )
            THEN 1
        WHEN EXISTS (
            SELECT 1
            FROM sys.indexes AS i
            WHERE i.[object_id] = OBJECT_ID(N'[DWS].[dws_robot_job_daily]')
              AND i.[name] = N'UX_DWS_robot_job_daily_robot_date_type'
              AND NOT (
                  4 = (
                      SELECT COUNT(*)
                      FROM sys.index_columns AS ic
                      WHERE ic.[object_id] = i.[object_id]
                        AND ic.[index_id] = i.[index_id]
                        AND ic.[key_ordinal] > 0
                  )
                  AND N'robot_code' = (
                      SELECT c.[name]
                      FROM sys.index_columns AS ic
                      INNER JOIN sys.columns AS c
                          ON c.[object_id] = ic.[object_id]
                         AND c.[column_id] = ic.[column_id]
                      WHERE ic.[object_id] = i.[object_id]
                        AND ic.[index_id] = i.[index_id]
                        AND ic.[key_ordinal] = 1
                  )
                  AND N'stat_date' = (
                      SELECT c.[name]
                      FROM sys.index_columns AS ic
                      INNER JOIN sys.columns AS c
                          ON c.[object_id] = ic.[object_id]
                         AND c.[column_id] = ic.[column_id]
                      WHERE ic.[object_id] = i.[object_id]
                        AND ic.[index_id] = i.[index_id]
                        AND ic.[key_ordinal] = 2
                  )
                  AND N'job_type_code' = (
                      SELECT c.[name]
                      FROM sys.index_columns AS ic
                      INNER JOIN sys.columns AS c
                          ON c.[object_id] = ic.[object_id]
                         AND c.[column_id] = ic.[column_id]
                      WHERE ic.[object_id] = i.[object_id]
                        AND ic.[index_id] = i.[index_id]
                        AND ic.[key_ordinal] = 3
                  )
                  AND N'robot_mode_id' = (
                      SELECT c.[name]
                      FROM sys.index_columns AS ic
                      INNER JOIN sys.columns AS c
                          ON c.[object_id] = ic.[object_id]
                         AND c.[column_id] = ic.[column_id]
                      WHERE ic.[object_id] = i.[object_id]
                        AND ic.[index_id] = i.[index_id]
                        AND ic.[key_ordinal] = 4
                  )
              )
        )
            THEN 1
        ELSE 0
    END;

SELECT
    @dws_index_sql = CASE
        WHEN @dws_index_requires_rebuild = 0 THEN N''
        ELSE N'
IF EXISTS (
    SELECT 1
    FROM [DWS].[dws_robot_job_daily] AS d
    GROUP BY
        d.[robot_code],
        d.[stat_date],
        COALESCE(d.[job_type_code], N''UNKNOWN''),
        COALESCE(d.[robot_mode_id], N''UNKNOWN'')
    HAVING COUNT_BIG(*) > 1
)
BEGIN
    RAISERROR(N''DWS duplicate business keys exist. No index was changed.'', 16, 1);
    RETURN;
END;

SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;

    IF EXISTS (
        SELECT 1
        FROM sys.indexes AS i
        WHERE i.[object_id] = OBJECT_ID(N''[DWS].[dws_robot_job_daily]'')
          AND i.[name] = N''UX_DWS_robot_job_daily_robot_date_type''
    )
    BEGIN
        DROP INDEX [UX_DWS_robot_job_daily_robot_date_type]
            ON [DWS].[dws_robot_job_daily];
    END;

    CREATE UNIQUE NONCLUSTERED INDEX [UX_DWS_robot_job_daily_robot_date_type]
        ON [DWS].[dws_robot_job_daily] (
            [robot_code],
            [stat_date],
            [job_type_code],
            [robot_mode_id]
        );

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    DECLARE @index_error NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR(N''DWS unique-index installation failed: %s'', 16, 1, @index_error);
END CATCH;'
    END;

EXEC sys.sp_executesql @dws_index_sql;

/* Small reference-table index. */
DECLARE @mode_index_sql NVARCHAR(MAX) = CASE
    WHEN @preflight_ok = 1
     AND NOT EXISTS (
        SELECT 1
        FROM sys.indexes AS i
        WHERE i.[object_id] = OBJECT_ID(N'[ODS].[AMR_Robot_Mode]')
          AND i.[name] = N'IX_ODS_AMR_Robot_Mode_mode_id'
    )
        THEN N'CREATE NONCLUSTERED INDEX [IX_ODS_AMR_Robot_Mode_mode_id]
              ON [ODS].[AMR_Robot_Mode] ([Mode_ID], [ods_row_id] DESC)
              INCLUDE ([Mode_Detail]);'
    ELSE N''
END;

EXEC sys.sp_executesql @mode_index_sql;

/*
    Required exact-time lookup index. This is the long-running part because
    ODS.robot_status_history contains tens of millions of rows. It is kept out
    of the small schema-change transaction to avoid one oversized transaction.
*/
DECLARE @status_index_sql NVARCHAR(MAX) = CASE
    WHEN @preflight_ok = 1
     AND NOT EXISTS (
        SELECT 1
        FROM sys.indexes AS i
        WHERE i.[object_id] = OBJECT_ID(N'[ODS].[robot_status_history]')
          AND i.[name] = N'IX_ODS_robot_status_history_amr_time'
    )
        THEN N'RAISERROR(N''Creating the large ODS status lookup index. Do not cancel unless necessary.'', 10, 1) WITH NOWAIT;
CREATE NONCLUSTERED INDEX [IX_ODS_robot_status_history_amr_time]
    ON [ODS].[robot_status_history] (
        [amr_id],
        [pc_timestamp],
        [ods_row_id] DESC
    )
    INCLUDE ([robot_mode]);'
    ELSE N''
END;

EXEC sys.sp_executesql @status_index_sql;

/* Final schema and index verification. */
SELECT
    s.[name] AS [schema_name],
    t.[name] AS [table_name],
    c.[column_id],
    c.[name] AS [column_name],
    TYPE_NAME(c.[user_type_id]) AS [data_type],
    c.[max_length],
    c.[is_nullable]
FROM sys.tables AS t
INNER JOIN sys.schemas AS s
    ON s.[schema_id] = t.[schema_id]
INNER JOIN sys.columns AS c
    ON c.[object_id] = t.[object_id]
WHERE
       (s.[name] = N'DWD' AND t.[name] = N'fact_robot_job'
        AND c.[name] IN (N'job_type_code', N'robot_mode_id', N'robot_mode_detail', N'source_status_ods_row_id'))
    OR (s.[name] = N'DWS' AND t.[name] = N'dws_robot_job_daily'
        AND c.[name] IN (N'job_type_code', N'robot_mode_id', N'robot_mode_detail'))
ORDER BY
    s.[name],
    t.[name],
    c.[column_id];

SELECT
    s.[name] AS [schema_name],
    t.[name] AS [table_name],
    i.[name] AS [index_name],
    i.[is_unique],
    i.[type_desc]
FROM sys.indexes AS i
INNER JOIN sys.tables AS t
    ON t.[object_id] = i.[object_id]
INNER JOIN sys.schemas AS s
    ON s.[schema_id] = t.[schema_id]
WHERE i.[name] IN (
    N'IX_ODS_AMR_Robot_Mode_mode_id',
    N'IX_ODS_robot_status_history_amr_time',
    N'UX_DWS_robot_job_daily_robot_date_type'
)
ORDER BY
    s.[name],
    t.[name],
    i.[name];
GO
