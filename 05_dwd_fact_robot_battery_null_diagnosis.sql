USE IOT2020;
GO

SET NOCOUNT ON;
GO

/*
    Diagnose NULL fields in DWD.fact_robot_battery.

    Read-only script.

    Goal:
      1. Confirm which DWD battery fields are NULL.
      2. Check whether ODS.robot_battery_history has matching source columns.
      3. Show likely source columns that should be mapped into DWD.

    After reviewing this output, update DWD.sp_load_dwd_all_incremental mapping
    and then reload or backfill DWD.fact_robot_battery if needed.
*/

/* 1. DWD null profile. */
SELECT
    COUNT_BIG(*) AS total_rows,
    SUM(CASE WHEN sample_time IS NULL THEN 1 ELSE 0 END) AS sample_time_null_rows,
    SUM(CASE WHEN robot_id IS NULL THEN 1 ELSE 0 END) AS robot_id_null_rows,
    SUM(CASE WHEN robot_code IS NULL THEN 1 ELSE 0 END) AS robot_code_null_rows,
    SUM(CASE WHEN battery_soc IS NULL THEN 1 ELSE 0 END) AS battery_soc_null_rows,
    SUM(CASE WHEN battery_voltage IS NULL THEN 1 ELSE 0 END) AS battery_voltage_null_rows,
    SUM(CASE WHEN battery_current IS NULL THEN 1 ELSE 0 END) AS battery_current_null_rows,
    SUM(CASE WHEN battery_power IS NULL THEN 1 ELSE 0 END) AS battery_power_null_rows,
    SUM(CASE WHEN charging_status IS NULL THEN 1 ELSE 0 END) AS charging_status_null_rows,
    SUM(CASE WHEN battery_status IS NULL THEN 1 ELSE 0 END) AS battery_status_null_rows,
    MIN(source_ods_row_id) AS min_source_ods_row_id,
    MAX(source_ods_row_id) AS max_source_ods_row_id
FROM [DWD].[fact_robot_battery];
GO

/* 2. Latest DWD load logs for battery fact. */
SELECT TOP 20
    batch_id,
    source_table,
    target_table,
    load_mode,
    rows_inserted,
    rows_deleted,
    load_status,
    error_message
FROM [DWD].[etl_load_log]
WHERE target_schema = N'DWD'
  AND target_table = N'fact_robot_battery'
ORDER BY batch_id DESC;
GO

/* 3. Source ODS column dictionary. */
SELECT
    c.column_id,
    c.name AS column_name,
    ty.name AS data_type,
    CASE
        WHEN ty.name IN (N'nvarchar', N'nchar') AND c.max_length > 0 THEN c.max_length / 2
        ELSE c.max_length
    END AS max_length,
    c.precision,
    c.scale,
    c.is_nullable
FROM sys.columns AS c
JOIN sys.types AS ty
    ON ty.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID(N'[ODS].[robot_battery_history]', N'U')
ORDER BY c.column_id;
GO

/* 4. Exact candidate-column matching used by the current generic DWD loader. */
WITH candidate AS (
    SELECT *
    FROM (VALUES
        (N'sample_time',      N'datetime',    N'sample_time',      10),
        (N'sample_time',      N'datetime',    N'robot_datetime',   20),
        (N'sample_time',      N'datetime',    N'created_at',       30),
        (N'robot_id',         N'nvarchar100', N'robot_id',         10),
        (N'robot_id',         N'nvarchar100', N'RobotID',          20),
        (N'robot_id',         N'nvarchar100', N'amr_id',           30),
        (N'robot_id',         N'nvarchar100', N'AMR_ID',           40),
        (N'robot_id',         N'nvarchar100', N'agv_id',           50),
        (N'robot_id',         N'nvarchar100', N'device_id',        60),
        (N'robot_code',       N'nvarchar100', N'robot_code',       10),
        (N'robot_code',       N'nvarchar100', N'robot_no',         20),
        (N'robot_code',       N'nvarchar100', N'robot_sn',         30),
        (N'robot_code',       N'nvarchar100', N'robot_id',         40),
        (N'robot_code',       N'nvarchar100', N'RobotID',          50),
        (N'robot_code',       N'nvarchar100', N'amr_id',           60),
        (N'robot_code',       N'nvarchar100', N'AMR_ID',           70),
        (N'robot_code',       N'nvarchar100', N'AMR',              80),
        (N'battery_soc',      N'decimal9',    N'battery_soc',      10),
        (N'battery_soc',      N'decimal9',    N'soc',              20),
        (N'battery_soc',      N'decimal9',    N'battery',          30),
        (N'battery_soc',      N'decimal9',    N'battery_level',    40),
        (N'battery_voltage',  N'decimal18',   N'battery_voltage',  10),
        (N'battery_voltage',  N'decimal18',   N'voltage',          20),
        (N'battery_current',  N'decimal18',   N'battery_current',  10),
        (N'battery_current',  N'decimal18',   N'current',          20),
        (N'battery_power',    N'decimal18',   N'battery_power',    10),
        (N'battery_power',    N'decimal18',   N'power',            20),
        (N'charging_status',  N'nvarchar100', N'charging_status',  10),
        (N'charging_status',  N'nvarchar100', N'charge_status',    20),
        (N'battery_status',   N'nvarchar100', N'battery_status',   10)
    ) AS v(target_column, target_type, candidate_name, priority)
)
SELECT
    c.target_column,
    c.target_type,
    c.candidate_name,
    c.priority,
    sc.name AS matched_source_column,
    ty.name AS matched_data_type,
    CASE
        WHEN sc.name IS NULL THEN N'NO_EXACT_MATCH'
        ELSE N'MATCHED'
    END AS match_status
FROM candidate AS c
LEFT JOIN sys.columns AS sc
    ON sc.object_id = OBJECT_ID(N'[ODS].[robot_battery_history]', N'U')
   AND LOWER(sc.name) = LOWER(c.candidate_name)
LEFT JOIN sys.types AS ty
    ON ty.user_type_id = sc.user_type_id
ORDER BY
    c.target_column,
    c.priority;
GO

/* 5. Likely battery-related source columns that may need to be added to the loader candidates. */
SELECT
    c.column_id,
    c.name AS source_column,
    ty.name AS data_type,
    CASE
        WHEN ty.name IN (N'nvarchar', N'nchar') AND c.max_length > 0 THEN c.max_length / 2
        ELSE c.max_length
    END AS max_length,
    c.precision,
    c.scale
FROM sys.columns AS c
JOIN sys.types AS ty
    ON ty.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID(N'[ODS].[robot_battery_history]', N'U')
  AND (
         LOWER(c.name) LIKE N'%battery%'
      OR LOWER(c.name) LIKE N'%soc%'
      OR LOWER(c.name) LIKE N'%volt%'
      OR LOWER(c.name) LIKE N'%current%'
      OR LOWER(c.name) LIKE N'%amp%'
      OR LOWER(c.name) LIKE N'%power%'
      OR LOWER(c.name) LIKE N'%charge%'
      OR LOWER(c.name) LIKE N'%robot%'
      OR LOWER(c.name) LIKE N'%amr%'
      OR LOWER(c.name) LIKE N'%time%'
      OR LOWER(c.name) LIKE N'%date%'
  )
ORDER BY c.column_id;
GO

/* 6. Compare DWD rows with the corresponding ODS source rows for a small NULL sample. */
WITH null_dwd_sample AS (
    SELECT TOP 20
        source_ods_row_id,
        sample_time,
        robot_id,
        robot_code,
        battery_soc,
        battery_voltage,
        battery_current,
        battery_power,
        charging_status,
        battery_status
    FROM [DWD].[fact_robot_battery]
    WHERE sample_time IS NULL
       OR robot_id IS NULL
       OR robot_code IS NULL
       OR battery_soc IS NULL
       OR battery_voltage IS NULL
       OR battery_current IS NULL
       OR battery_power IS NULL
       OR charging_status IS NULL
       OR battery_status IS NULL
    ORDER BY source_ods_row_id DESC
)
SELECT
    d.source_ods_row_id,
    d.sample_time AS dwd_sample_time,
    d.robot_id AS dwd_robot_id,
    d.robot_code AS dwd_robot_code,
    d.battery_soc AS dwd_battery_soc,
    d.battery_voltage AS dwd_battery_voltage,
    d.battery_current AS dwd_battery_current,
    d.battery_power AS dwd_battery_power,
    d.charging_status AS dwd_charging_status,
    d.battery_status AS dwd_battery_status,
    src.*
FROM null_dwd_sample AS d
JOIN [ODS].[robot_battery_history] AS src
    ON src.ods_row_id = d.source_ods_row_id
ORDER BY d.source_ods_row_id DESC;
GO

/* 7. Show recent source rows directly. */
SELECT TOP 20
    *
FROM [ODS].[robot_battery_history]
ORDER BY ods_row_id DESC;
GO

-- END OF SCRIPT.
