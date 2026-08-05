USE IOT2020;
GO

/*
    Read-only inventory for the Robot / AMR project.

    Current inclusion rule:
      1. Table name starts with "robot"; or
      2. Table name contains "AMR".

    This script only reads SQL Server system catalog views. It does not create,
    update, or delete objects or business data in IOT2020.
*/

/* 1. Project tables with approximate row counts and total storage size. */
WITH project_tables AS (
    SELECT
        t.object_id,
        t.schema_id,
        t.name,
        t.create_date,
        t.modify_date
    FROM sys.tables AS t
    WHERE LOWER(t.name) LIKE 'robot%'
       OR UPPER(t.name) LIKE '%AMR%'
),
row_counts AS (
    SELECT
        p.object_id,
        SUM(p.rows) AS approximate_row_count
    FROM sys.partitions AS p
    WHERE p.index_id IN (0, 1)
    GROUP BY p.object_id
),
storage_sizes AS (
    SELECT
        p.object_id,
        SUM(a.total_pages) AS total_pages
    FROM sys.partitions AS p
    JOIN sys.allocation_units AS a
        ON a.container_id = CASE
            WHEN a.type IN (1, 3) THEN p.hobt_id
            WHEN a.type = 2 THEN p.partition_id
        END
    GROUP BY p.object_id
)
SELECT
    s.name AS schema_name,
    pt.name AS table_name,
    COALESCE(rc.approximate_row_count, 0) AS approximate_row_count,
    CAST(COALESCE(ss.total_pages, 0) * 8.0 / 1024 AS DECIMAL(18, 2)) AS total_size_mb,
    pt.create_date,
    pt.modify_date
FROM project_tables AS pt
JOIN sys.schemas AS s
    ON s.schema_id = pt.schema_id
LEFT JOIN row_counts AS rc
    ON rc.object_id = pt.object_id
LEFT JOIN storage_sizes AS ss
    ON ss.object_id = pt.object_id
ORDER BY approximate_row_count DESC, s.name, pt.name;

/* 2. Complete column dictionary for the selected project tables. */
SELECT
    s.name AS schema_name,
    t.name AS table_name,
    c.column_id,
    c.name AS column_name,
    ty.name AS data_type,
    CASE
        WHEN c.max_length = -1 THEN -1
        WHEN ty.name IN ('nvarchar', 'nchar') THEN c.max_length / 2
        ELSE c.max_length
    END AS max_length,
    c.precision,
    c.scale,
    c.is_nullable,
    c.is_identity
FROM sys.tables AS t
JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
JOIN sys.columns AS c
    ON c.object_id = t.object_id
JOIN sys.types AS ty
    ON ty.user_type_id = c.user_type_id
WHERE LOWER(t.name) LIKE 'robot%'
   OR UPPER(t.name) LIKE '%AMR%'
ORDER BY s.name, t.name, c.column_id;

/* 3. Candidate business columns within the selected project tables. */
SELECT
    s.name AS schema_name,
    t.name AS table_name,
    c.column_id,
    c.name AS column_name,
    ty.name AS data_type,
    c.max_length,
    c.precision,
    c.scale
FROM sys.tables AS t
JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
JOIN sys.columns AS c
    ON c.object_id = t.object_id
JOIN sys.types AS ty
    ON ty.user_type_id = c.user_type_id
WHERE
    (
        LOWER(t.name) LIKE 'robot%'
        OR UPPER(t.name) LIKE '%AMR%'
    )
    AND
    (
           LOWER(c.name) LIKE '%robot%'
        OR LOWER(c.name) LIKE '%amr%'
        OR LOWER(c.name) LIKE '%charge%'
        OR LOWER(c.name) LIKE '%battery%'
        OR LOWER(c.name) LIKE '%voltage%'
        OR LOWER(c.name) LIKE '%volt%'
        OR LOWER(c.name) LIKE '%current%'
        OR LOWER(c.name) LIKE '%amp%'
        OR LOWER(c.name) LIKE '%power%'
        OR LOWER(c.name) LIKE '%soc%'
        OR LOWER(c.name) LIKE '%status%'
        OR LOWER(c.name) LIKE '%position%'
        OR LOWER(c.name) LIKE '%location%'
        OR LOWER(c.name) LIKE '%speed%'
        OR LOWER(c.name) LIKE '%time%'
        OR LOWER(c.name) LIKE '%date%'
    )
ORDER BY s.name, t.name, c.column_id;

/* 4. Primary-key columns for the selected project tables. */
SELECT
    s.name AS schema_name,
    t.name AS table_name,
    kc.name AS primary_key_name,
    c.name AS key_column,
    ic.key_ordinal
FROM sys.key_constraints AS kc
JOIN sys.tables AS t
    ON t.object_id = kc.parent_object_id
JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
JOIN sys.index_columns AS ic
    ON ic.object_id = t.object_id
   AND ic.index_id = kc.unique_index_id
JOIN sys.columns AS c
    ON c.object_id = t.object_id
   AND c.column_id = ic.column_id
WHERE kc.type = 'PK'
  AND (
        LOWER(t.name) LIKE 'robot%'
        OR UPPER(t.name) LIKE '%AMR%'
  )
ORDER BY s.name, t.name, ic.key_ordinal;

/*
   5. Foreign-key relationships where either side is a selected project table.
      External reference tables remain visible so valid model relationships are
      not accidentally discarded.
*/
SELECT
    child_schema.name AS child_schema,
    child_table.name AS child_table,
    child_col.name AS child_column,
    parent_schema.name AS parent_schema,
    parent_table.name AS parent_table,
    parent_col.name AS parent_column,
    fk.name AS foreign_key_name,
    CASE
        WHEN (
                LOWER(child_table.name) LIKE 'robot%'
                OR UPPER(child_table.name) LIKE '%AMR%'
             )
         AND (
                LOWER(parent_table.name) LIKE 'robot%'
                OR UPPER(parent_table.name) LIKE '%AMR%'
             )
            THEN 'PROJECT_TO_PROJECT'
        ELSE 'PROJECT_TO_EXTERNAL'
    END AS relationship_scope
FROM sys.foreign_keys AS fk
JOIN sys.foreign_key_columns AS fkc
    ON fkc.constraint_object_id = fk.object_id
JOIN sys.tables AS child_table
    ON child_table.object_id = fkc.parent_object_id
JOIN sys.schemas AS child_schema
    ON child_schema.schema_id = child_table.schema_id
JOIN sys.columns AS child_col
    ON child_col.object_id = fkc.parent_object_id
   AND child_col.column_id = fkc.parent_column_id
JOIN sys.tables AS parent_table
    ON parent_table.object_id = fkc.referenced_object_id
JOIN sys.schemas AS parent_schema
    ON parent_schema.schema_id = parent_table.schema_id
JOIN sys.columns AS parent_col
    ON parent_col.object_id = fkc.referenced_object_id
   AND parent_col.column_id = fkc.referenced_column_id
WHERE
       LOWER(child_table.name) LIKE 'robot%'
    OR UPPER(child_table.name) LIKE '%AMR%'
    OR LOWER(parent_table.name) LIKE 'robot%'
    OR UPPER(parent_table.name) LIKE '%AMR%'
ORDER BY
    child_schema.name,
    child_table.name,
    fk.name,
    fkc.constraint_column_id;
