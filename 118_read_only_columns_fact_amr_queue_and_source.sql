USE [IOT2020];

SET NOCOUNT ON;

SELECT
    N'DWD.fact_amr_queue' AS [object_name],
    c.[name] AS [column_name],
    ty.[name] AS [data_type],
    c.[max_length],
    c.[precision],
    c.[scale]
FROM [sys].[columns] AS c
INNER JOIN [sys].[tables] AS t
    ON t.[object_id] = c.[object_id]
INNER JOIN [sys].[schemas] AS s
    ON s.[schema_id] = t.[schema_id]
INNER JOIN [sys].[types] AS ty
    ON ty.[user_type_id] = c.[user_type_id]
WHERE s.[name] = N'DWD'
  AND t.[name] = N'fact_amr_queue'
ORDER BY c.[column_id];

SELECT
    N'dbo.AMR_Queue' AS [object_name],
    c.[name] AS [column_name],
    ty.[name] AS [data_type],
    c.[max_length],
    c.[precision],
    c.[scale]
FROM [sys].[columns] AS c
INNER JOIN [sys].[tables] AS t
    ON t.[object_id] = c.[object_id]
INNER JOIN [sys].[schemas] AS s
    ON s.[schema_id] = t.[schema_id]
INNER JOIN [sys].[types] AS ty
    ON ty.[user_type_id] = c.[user_type_id]
WHERE s.[name] = N'dbo'
  AND t.[name] = N'AMR_Queue'
ORDER BY c.[column_id];
