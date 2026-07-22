USE [IOT2020];
GO

/*
    Permanently remove DWS.dws_robot_job_state_daily.

    Exact scope:
    - Drops only DWS.dws_robot_job_state_daily.
    - Its rows, indexes, defaults, and primary key are removed with the table.
    - ODS, DWD, DWS.dws_robot_job_daily, and ETL audit logs are not changed.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* Pre-execution preview. */
SELECT
    s.[name] AS [schema_name],
    t.[name] AS [table_name],
    SUM(p.[rows]) AS [approximate_row_count]
FROM sys.tables AS t
INNER JOIN sys.schemas AS s
    ON s.[schema_id] = t.[schema_id]
LEFT JOIN sys.partitions AS p
    ON p.[object_id] = t.[object_id]
   AND p.[index_id] IN (0, 1)
WHERE s.[name] = N'DWS'
  AND t.[name] = N'dws_robot_job_state_daily'
GROUP BY
    s.[name],
    t.[name];

SELECT
    i.[name] AS [index_name],
    i.[type_desc],
    i.[is_unique]
FROM sys.indexes AS i
WHERE i.[object_id] = OBJECT_ID(N'[DWS].[dws_robot_job_state_daily]')
ORDER BY i.[index_id];
GO

DROP TABLE [DWS].[dws_robot_job_state_daily];
GO

/* Expected result: object_id is NULL. */
SELECT
    OBJECT_ID(N'[DWS].[dws_robot_job_state_daily]', N'U') AS [object_id_after_drop],
    CASE
        WHEN OBJECT_ID(N'[DWS].[dws_robot_job_state_daily]', N'U') IS NULL THEN N'DROPPED'
        ELSE N'STILL_EXISTS'
    END AS [drop_status];
GO
