USE [IOT2020];

SET NOCOUNT ON;

/* Column inventory for the project-robot assignment tables. */
SELECT
    N'dbo.MA_AMR_Project_Assignment' AS [object_name],
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
  AND t.[name] = N'MA_AMR_Project_Assignment'
ORDER BY c.[column_id];

/* Sample rows to see whether assignments carry time bounds or status. */
SELECT TOP (10)
    assignment_row.*
FROM [dbo].[MA_AMR_Project_Assignment] AS assignment_row
ORDER BY assignment_row.[id] DESC;
