'use strict';

const path = require('node:path');
const { getPool, closePool } = require('../src/db');

try {
  if (typeof process.loadEnvFile === 'function') {
    process.loadEnvFile(path.join(__dirname, '..', '.env'));
  }
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
}

const query = `
SET NOCOUNT ON;

DECLARE @requested_objects TABLE (
    [schema_name] SYSNAME NOT NULL,
    [table_name] SYSNAME NOT NULL
);

INSERT INTO @requested_objects ([schema_name], [table_name])
VALUES
    (N'ODS', N'AMR_Queue'),
    (N'ODS', N'TA_AMR'),
    (N'ODS', N'MA_AMR_Project_Assignment'),
    (N'DWD', N'fact_dispatch_decision_candidate'),
    (N'DWD', N'fact_robot_operation_event'),
    (N'DWD', N'fact_robot_incident'),
    (N'DWD', N'fact_robot_incident_evidence'),
    (N'DWD', N'robot_event_watermark');

SELECT
    requested.[schema_name],
    requested.[table_name],
    CASE WHEN table_info.[object_id] IS NULL THEN CONVERT(BIT, 0) ELSE CONVERT(BIT, 1) END AS [object_exists],
    ISNULL(SUM(partition_stats.[row_count]), 0) AS [approximate_row_count]
FROM @requested_objects AS requested
LEFT JOIN [sys].[schemas] AS schema_info
    ON schema_info.[name] = requested.[schema_name]
LEFT JOIN [sys].[tables] AS table_info
    ON table_info.[schema_id] = schema_info.[schema_id]
   AND table_info.[name] = requested.[table_name]
LEFT JOIN [sys].[dm_db_partition_stats] AS partition_stats
    ON partition_stats.[object_id] = table_info.[object_id]
   AND partition_stats.[index_id] IN (0, 1)
GROUP BY
    requested.[schema_name],
    requested.[table_name],
    table_info.[object_id]
ORDER BY
    requested.[schema_name],
    requested.[table_name];

SELECT
    schema_info.[name] AS [schema_name],
    table_info.[name] AS [table_name],
    column_info.[column_id],
    column_info.[name] AS [column_name],
    type_info.[name] AS [data_type],
    column_info.[max_length],
    column_info.[is_nullable]
FROM [sys].[tables] AS table_info
INNER JOIN [sys].[schemas] AS schema_info
    ON schema_info.[schema_id] = table_info.[schema_id]
INNER JOIN @requested_objects AS requested
    ON requested.[schema_name] = schema_info.[name]
   AND requested.[table_name] = table_info.[name]
INNER JOIN [sys].[columns] AS column_info
    ON column_info.[object_id] = table_info.[object_id]
INNER JOIN [sys].[types] AS type_info
    ON type_info.[user_type_id] = column_info.[user_type_id]
ORDER BY
    schema_info.[name],
    table_info.[name],
    column_info.[column_id];

SELECT
    schema_info.[name] AS [schema_name],
    table_info.[name] AS [table_name],
    index_info.[name] AS [index_name],
    index_info.[type_desc],
    index_column.[key_ordinal],
    column_info.[name] AS [column_name],
    index_column.[is_included_column]
FROM [sys].[indexes] AS index_info
INNER JOIN [sys].[tables] AS table_info
    ON table_info.[object_id] = index_info.[object_id]
INNER JOIN [sys].[schemas] AS schema_info
    ON schema_info.[schema_id] = table_info.[schema_id]
INNER JOIN @requested_objects AS requested
    ON requested.[schema_name] = schema_info.[name]
   AND requested.[table_name] = table_info.[name]
INNER JOIN [sys].[index_columns] AS index_column
    ON index_column.[object_id] = index_info.[object_id]
   AND index_column.[index_id] = index_info.[index_id]
INNER JOIN [sys].[columns] AS column_info
    ON column_info.[object_id] = index_column.[object_id]
   AND column_info.[column_id] = index_column.[column_id]
ORDER BY
    schema_info.[name],
    table_info.[name],
    index_info.[name],
    index_column.[key_ordinal],
    column_info.[column_id];

SELECT
    N'ODS.AMR_Queue' AS [source_object],
    MIN(source_row.[ods_row_id]) AS [min_ods_row_id],
    MAX(source_row.[ods_row_id]) AS [max_ods_row_id],
    MIN(source_row.[enqueued_at]) AS [min_event_time],
    MAX(source_row.[enqueued_at]) AS [max_event_time]
FROM [ODS].[AMR_Queue] AS source_row
UNION ALL
SELECT
    N'ODS.TA_AMR',
    MIN(source_row.[ods_row_id]),
    MAX(source_row.[ods_row_id]),
    MIN(source_row.[start_time]),
    MAX(source_row.[start_time])
FROM [ODS].[TA_AMR] AS source_row
UNION ALL
SELECT
    N'ODS.MA_AMR_Project_Assignment',
    MIN(source_row.[ods_row_id]),
    MAX(source_row.[ods_row_id]),
    MIN(source_row.[start_time]),
    MAX(source_row.[start_time])
FROM [ODS].[MA_AMR_Project_Assignment] AS source_row;

SELECT
    permission_info.[permission_name],
    permission_info.[state_desc],
    schema_info.[name] AS [schema_name],
    object_info.[name] AS [object_name]
FROM [sys].[database_permissions] AS permission_info
LEFT JOIN [sys].[objects] AS object_info
    ON object_info.[object_id] = permission_info.[major_id]
LEFT JOIN [sys].[schemas] AS schema_info
    ON schema_info.[schema_id] = object_info.[schema_id]
WHERE permission_info.[grantee_principal_id] = DATABASE_PRINCIPAL_ID(USER_NAME())
  AND permission_info.[permission_name] IN (N'CREATE TABLE', N'CREATE PROCEDURE', N'ALTER', N'INSERT', N'EXECUTE')
ORDER BY
    permission_info.[permission_name],
    schema_info.[name],
    object_info.[name];

SELECT
    USER_NAME() AS [database_user],
    HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'CREATE TABLE') AS [can_create_table],
    HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'CREATE PROCEDURE') AS [can_create_procedure],
    HAS_PERMS_BY_NAME(N'DWD', N'SCHEMA', N'ALTER') AS [can_alter_dwd],
    HAS_PERMS_BY_NAME(N'DWD', N'SCHEMA', N'INSERT') AS [can_insert_dwd],
    HAS_PERMS_BY_NAME(N'DWD', N'SCHEMA', N'SELECT') AS [can_select_dwd];
`;

async function main() {
  const pool = await getPool();
  const request = pool.request();
  request.multiple = true;
  const result = await request.query(query);
  process.stdout.write(`${JSON.stringify({
    objects: result.recordsets[0] || [],
    columns: result.recordsets[1] || [],
    indexes: result.recordsets[2] || [],
    sourceAnchors: result.recordsets[3] || [],
    explicitPermissions: result.recordsets[4] || [],
    effectivePermissions: result.recordsets[5]?.[0] || {}
  }, null, 2)}\n`);
}

main()
  .then(closePool)
  .catch(async (error) => {
    console.error(error);
    await closePool();
    process.exitCode = 1;
  });
