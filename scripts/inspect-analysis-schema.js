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
DECLARE @objects TABLE (
    [schema_name] SYSNAME NOT NULL,
    [table_name] SYSNAME NOT NULL
);

INSERT INTO @objects ([schema_name], [table_name])
VALUES
    (N'dbo', N'AMR_Queue'),
    (N'dbo', N'AMR_Queue_Old'),
    (N'dbo', N'MA_AMR_Project_Assignment'),
    (N'dbo', N'MA_AMR_ProjectReservation'),
    (N'dbo', N'MA_AMR_Requirement'),
    (N'dbo', N'MA_AMR_Subjob'),
    (N'dbo', N'AMR_Subjob_Analyze'),
    (N'dbo', N'TA_AMR'),
    (N'dbo', N'TA_AMR_Old'),
    (N'dbo', N'robot_job_history'),
    (N'dbo', N'robot_battery_history'),
    (N'DWD', N'fact_robot_job'),
    (N'DWD', N'fact_robot_battery'),
    (N'DWD', N'fact_amr_queue'),
    (N'DWD', N'fact_amr_subjob'),
    (N'DWS', N'dws_robot_job_daily'),
    (N'DWS', N'dws_robot_queue_daily'),
    (N'DWS', N'dws_robot_battery_hourly');

SELECT
    schema_info.[name] AS [schema_name],
    table_info.[name] AS [table_name],
    column_info.[column_id],
    column_info.[name] AS [column_name],
    type_info.[name] AS [data_type]
FROM [sys].[tables] AS table_info
INNER JOIN [sys].[schemas] AS schema_info
    ON schema_info.[schema_id] = table_info.[schema_id]
INNER JOIN [sys].[columns] AS column_info
    ON column_info.[object_id] = table_info.[object_id]
INNER JOIN [sys].[types] AS type_info
    ON type_info.[user_type_id] = column_info.[user_type_id]
INNER JOIN @objects AS requested
    ON requested.[schema_name] = schema_info.[name]
   AND requested.[table_name] = table_info.[name]
ORDER BY
    schema_info.[name],
    table_info.[name],
    column_info.[column_id];

SELECT
    schema_info.[name] AS [schema_name],
    table_info.[name] AS [table_name],
    SUM(partition_stats.[row_count]) AS [approximate_row_count]
FROM [sys].[tables] AS table_info
INNER JOIN [sys].[schemas] AS schema_info
    ON schema_info.[schema_id] = table_info.[schema_id]
INNER JOIN @objects AS requested
    ON requested.[schema_name] = schema_info.[name]
   AND requested.[table_name] = table_info.[name]
INNER JOIN [sys].[dm_db_partition_stats] AS partition_stats
    ON partition_stats.[object_id] = table_info.[object_id]
   AND partition_stats.[index_id] IN (0, 1)
GROUP BY
    schema_info.[name],
    table_info.[name]
ORDER BY
    schema_info.[name],
    table_info.[name];

SELECT
    schema_info.[name] AS [schema_name],
    table_info.[name] AS [table_name],
    column_info.[name] AS [column_name]
FROM [sys].[tables] AS table_info
INNER JOIN [sys].[schemas] AS schema_info
    ON schema_info.[schema_id] = table_info.[schema_id]
INNER JOIN [sys].[columns] AS column_info
    ON column_info.[object_id] = table_info.[object_id]
WHERE schema_info.[name] IN (N'dbo', N'DWD', N'DWS')
  AND (
       LOWER(column_info.[name]) LIKE N'%dispatch%'
    OR LOWER(column_info.[name]) LIKE N'%candidate%'
    OR LOWER(column_info.[name]) LIKE N'%score%'
    OR LOWER(column_info.[name]) LIKE N'%reject%'
    OR LOWER(column_info.[name]) LIKE N'%eligible%'
    OR LOWER(column_info.[name]) LIKE N'%capability%'
    OR LOWER(column_info.[name]) LIKE N'%distance%'
    OR LOWER(column_info.[name]) LIKE N'%mileage%'
)
ORDER BY
    schema_info.[name],
    table_info.[name],
    column_info.[name];
`;

async function main() {
  const pool = await getPool();
  const request = pool.request();
  request.multiple = true;
  const result = await request.query(query);
  process.stdout.write(`${JSON.stringify({
    columns: result.recordsets[0] || [],
    rowCounts: result.recordsets[1] || [],
    auditFields: result.recordsets[2] || []
  }, null, 2)}\n`);
}

main()
  .then(closePool)
  .catch(async (error) => {
    console.error(error);
    await closePool();
    process.exitCode = 1;
  });
