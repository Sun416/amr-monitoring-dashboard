USE IOT2020;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
    Fix DWD.fact_robot_battery NULL battery fields.

    Root cause:
      ODS.robot_battery_history uses:
        batt_level
        batt_volt
        batt_current
        batt_charge_status

      The original generic DWD loader only looked for names like:
        battery_soc / voltage / current / charge_status

    This script does two things:
      1. Recreates DWD.sp_load_dwd_all_incremental after you execute the patched
         02_create_dwd_load_procedure.sql file.
      2. Repairs already-loaded historical rows in DWD.fact_robot_battery in batches.

    Important:
      - This updates about 39.6M existing DWD rows if all battery fields are currently NULL.
      - Run during a low-load period if possible.
      - Default batch size is 100,000 rows.

    Note:
      - battery_status is intentionally not filled here because the source table has
        batt_charge_status, not a separate battery health/status field.
      - charging_status will be filled from batt_charge_status.
      - battery_power is calculated as batt_volt * batt_current.
*/

/* 1. Confirm current null profile before repair. */
SELECT
    COUNT_BIG(*) AS total_rows,
    SUM(CASE WHEN battery_soc IS NULL THEN 1 ELSE 0 END) AS battery_soc_null_rows,
    SUM(CASE WHEN battery_voltage IS NULL THEN 1 ELSE 0 END) AS battery_voltage_null_rows,
    SUM(CASE WHEN battery_current IS NULL THEN 1 ELSE 0 END) AS battery_current_null_rows,
    SUM(CASE WHEN battery_power IS NULL THEN 1 ELSE 0 END) AS battery_power_null_rows,
    SUM(CASE WHEN charging_status IS NULL THEN 1 ELSE 0 END) AS charging_status_null_rows,
    SUM(CASE WHEN battery_status IS NULL THEN 1 ELSE 0 END) AS battery_status_null_rows
FROM [DWD].[fact_robot_battery];
GO

/* 2. Create a resumable batch repair procedure. */
CREATE OR ALTER PROCEDURE [DWD].[sp_repair_fact_robot_battery_fields]
    @batch_size BIGINT = 500000,
    @max_batches INT = NULL,
    @start_ods_row_id BIGINT = 0,
    @end_ods_row_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @rows INT = 0,
        @total_rows BIGINT = 0,
        @batch_no INT = 0,
        @elapsed_seconds INT = 0,
        @current_start BIGINT,
        @current_end BIGINT,
        @max_source_ods_row_id BIGINT,
        @current_start_text NVARCHAR(30),
        @current_end_text NVARCHAR(30),
        @total_rows_text NVARCHAR(30),
        @start_time DATETIME2(3) = SYSDATETIME();

    SELECT @max_source_ods_row_id = COALESCE(
        @end_ods_row_id,
        MAX(source_ods_row_id)
    )
    FROM [DWD].[fact_robot_battery]
    WHERE source_schema = N'ODS'
      AND source_table = N'robot_battery_history';

    SET @current_start = ISNULL(@start_ods_row_id, 0);

    WHILE @current_start < @max_source_ods_row_id
      AND (@max_batches IS NULL OR @batch_no < @max_batches)
    BEGIN
        SET @current_end = @current_start + @batch_size;

        IF @current_end > @max_source_ods_row_id
            SET @current_end = @max_source_ods_row_id;

        UPDATE tgt
        SET
            battery_soc = COALESCE(tgt.battery_soc, x.battery_soc),
            battery_voltage = COALESCE(tgt.battery_voltage, x.battery_voltage),
            battery_current = COALESCE(tgt.battery_current, x.battery_current),
            battery_power = COALESCE(tgt.battery_power, x.battery_power),
            charging_status = COALESCE(tgt.charging_status, x.charging_status)
        FROM [DWD].[fact_robot_battery] AS tgt
            , [ODS].[robot_battery_history] AS src
        CROSS APPLY (
            SELECT
                TRY_CONVERT(DECIMAL(9,4), src.[batt_level]) AS battery_soc,
                TRY_CONVERT(DECIMAL(18,6), src.[batt_volt]) AS battery_voltage,
                TRY_CONVERT(DECIMAL(18,6), src.[batt_current]) AS battery_current,
                CASE
                    WHEN TRY_CONVERT(DECIMAL(18,6), src.[batt_volt]) IS NOT NULL
                     AND TRY_CONVERT(DECIMAL(18,6), src.[batt_current]) IS NOT NULL
                        THEN TRY_CONVERT(DECIMAL(18,6), src.[batt_volt])
                           * TRY_CONVERT(DECIMAL(18,6), src.[batt_current])
                    ELSE NULL
                END AS battery_power,
                NULLIF(LTRIM(RTRIM(TRY_CONVERT(NVARCHAR(100), src.[batt_charge_status]))), N'') AS charging_status
        ) AS x
        WHERE tgt.[source_schema] = N'ODS'
          AND tgt.[source_table] = N'robot_battery_history'
          AND src.[ods_row_id] = tgt.[source_ods_row_id]
          AND tgt.[source_ods_row_id] > @current_start
          AND tgt.[source_ods_row_id] <= @current_end
          AND (
                 (tgt.[battery_soc] IS NULL AND x.battery_soc IS NOT NULL)
              OR (tgt.[battery_voltage] IS NULL AND x.battery_voltage IS NOT NULL)
              OR (tgt.[battery_current] IS NULL AND x.battery_current IS NOT NULL)
              OR (tgt.[battery_power] IS NULL AND x.battery_power IS NOT NULL)
              OR (tgt.[charging_status] IS NULL AND x.charging_status IS NOT NULL)
          );

        SET @rows = @@ROWCOUNT;
        SET @batch_no += 1;
        SET @total_rows += @rows;
        SET @elapsed_seconds = DATEDIFF(SECOND, @start_time, SYSDATETIME());
        SET @current_start_text = CONVERT(NVARCHAR(30), @current_start);
        SET @current_end_text = CONVERT(NVARCHAR(30), @current_end);
        SET @total_rows_text = CONVERT(NVARCHAR(30), @total_rows);

        RAISERROR(
            N'Battery repair range batch %d finished, ods_row_id (%s, %s], rows updated = %d, total updated = %s, elapsed seconds = %d',
            10,
            1,
            @batch_no,
            @current_start_text,
            @current_end_text,
            @rows,
            @total_rows_text,
            @elapsed_seconds
        ) WITH NOWAIT;

        SET @current_start = @current_end;
    END;
END;
GO

/* 3. Run repair.
      For a full repair, keep @max_batches = NULL.
      For a quick test first, use @max_batches = 1. */
EXEC [DWD].[sp_repair_fact_robot_battery_fields]
    @batch_size = 500000,
    @max_batches = NULL,
    @start_ods_row_id = 0,
    @end_ods_row_id = NULL;
GO

/* 4. Confirm final null profile after repair. */
SELECT
    COUNT_BIG(*) AS total_rows,
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

/* 4b. Remaining rows that still have fillable source values.
       This should be 0 after the repair finishes. */
SELECT
    COUNT_BIG(*) AS remaining_fillable_rows
FROM [DWD].[fact_robot_battery] AS tgt
    , [ODS].[robot_battery_history] AS src
CROSS APPLY (
    SELECT
        TRY_CONVERT(DECIMAL(9,4), src.[batt_level]) AS battery_soc,
        TRY_CONVERT(DECIMAL(18,6), src.[batt_volt]) AS battery_voltage,
        TRY_CONVERT(DECIMAL(18,6), src.[batt_current]) AS battery_current,
        CASE
            WHEN TRY_CONVERT(DECIMAL(18,6), src.[batt_volt]) IS NOT NULL
             AND TRY_CONVERT(DECIMAL(18,6), src.[batt_current]) IS NOT NULL
                THEN TRY_CONVERT(DECIMAL(18,6), src.[batt_volt])
                   * TRY_CONVERT(DECIMAL(18,6), src.[batt_current])
            ELSE NULL
        END AS battery_power,
        NULLIF(LTRIM(RTRIM(TRY_CONVERT(NVARCHAR(100), src.[batt_charge_status]))), N'') AS charging_status
) AS x
WHERE tgt.[source_schema] = N'ODS'
  AND tgt.[source_table] = N'robot_battery_history'
  AND src.[ods_row_id] = tgt.[source_ods_row_id]
  AND (
         (tgt.[battery_soc] IS NULL AND x.battery_soc IS NOT NULL)
      OR (tgt.[battery_voltage] IS NULL AND x.battery_voltage IS NOT NULL)
      OR (tgt.[battery_current] IS NULL AND x.battery_current IS NOT NULL)
      OR (tgt.[battery_power] IS NULL AND x.battery_power IS NOT NULL)
      OR (tgt.[charging_status] IS NULL AND x.charging_status IS NOT NULL)
  );
GO

/* 5. Sample repaired rows. */
SELECT TOP 100
    battery_fact_id,
    sample_time,
    robot_id,
    robot_code,
    battery_soc,
    battery_voltage,
    battery_current,
    battery_power,
    charging_status,
    battery_status,
    source_ods_row_id
FROM [DWD].[fact_robot_battery]
ORDER BY source_ods_row_id DESC;
GO

-- END OF SCRIPT.
