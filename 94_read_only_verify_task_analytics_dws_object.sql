/* Read-only object-location and row-count verification for Task Analytics. */
SET NOCOUNT ON;

SELECT
    DB_NAME() AS connected_database,
    s.name AS schema_name,
    t.name AS table_name,
    t.create_date,
    t.modify_date
FROM sys.tables AS t
INNER JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
WHERE s.name = N'DWS'
  AND t.name = N'dws_robot_task_hourly';

SELECT
    COUNT_BIG(1) AS row_count,
    MIN(h.stat_hour) AS earliest_stat_hour,
    MAX(h.stat_hour) AS latest_stat_hour,
    MAX(h.dws_load_time) AS latest_dws_load_time
FROM DWS.dws_robot_task_hourly AS h;

SELECT
    c.column_id,
    c.name AS column_name,
    TYPE_NAME(c.user_type_id) AS data_type,
    c.max_length,
    c.is_nullable
FROM sys.columns AS c
WHERE c.object_id = OBJECT_ID(N'DWS.dws_robot_task_hourly', N'U')
ORDER BY c.column_id;
