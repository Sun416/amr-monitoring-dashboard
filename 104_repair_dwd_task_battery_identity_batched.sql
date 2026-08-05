USE [IOT2020];

/*
  Approved repair: map the last 30 days of DWD battery rows to the exact
  ODS robot identity. It does not write dbo or ODS and does not alter robot
  enablement. Each batch is separately committed to bound locks and log use.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'IOT2020'
BEGIN
    THROW 58510, N'Expected database IOT2020.', 1;
END;

DECLARE @window_end DATETIME2(3) = SYSDATETIME();
DECLARE @window_start DATETIME2(3) = DATEADD(DAY, -30, @window_end);
DECLARE @batch_size INT = 25000;
DECLARE @batch_number INT = 0;
DECLARE @candidate_count INT = 1;
DECLARE @updated_count INT;

CREATE TABLE #master_robot
(
    [amr_id] INT NOT NULL PRIMARY KEY,
    [robot_code] NVARCHAR(100) NOT NULL
);

;WITH latest_master AS
(
    SELECT
        master_row.[id],
        master_row.[name],
        ROW_NUMBER() OVER (PARTITION BY master_row.[id] ORDER BY master_row.[ods_row_id] DESC) AS [rn]
    FROM [ODS].[MA_AMR] AS master_row
)
INSERT INTO #master_robot ([amr_id], [robot_code])
SELECT
    latest_master.[id],
    latest_master.[name]
FROM latest_master
WHERE latest_master.[rn] = 1
  AND NULLIF(LTRIM(RTRIM(latest_master.[name])), N'') IS NOT NULL;

CREATE TABLE #candidate
(
    [battery_fact_id] BIGINT NOT NULL PRIMARY KEY,
    [amr_id] INT NOT NULL,
    [robot_code] NVARCHAR(100) NOT NULL
);

CREATE TABLE #batch
(
    [battery_fact_id] BIGINT NOT NULL PRIMARY KEY,
    [amr_id] INT NOT NULL,
    [robot_code] NVARCHAR(100) NOT NULL
);

CREATE TABLE #repair_audit
(
    [batch_number] INT NOT NULL,
    [candidate_count] INT NOT NULL,
    [updated_count] INT NOT NULL,
    [committed_at] DATETIME2(3) NOT NULL
);

/* Materialize the exact remaining set once; batches then seek by the DWD primary key. */
INSERT INTO #candidate ([battery_fact_id], [amr_id], [robot_code])
SELECT
        battery_fact.[battery_fact_id],
        master_robot.[amr_id],
        master_robot.[robot_code]
    FROM [DWD].[fact_robot_battery] AS battery_fact
    INNER JOIN [ODS].[robot_battery_history] AS ods_battery
        ON ods_battery.[ods_row_id] = battery_fact.[source_ods_row_id]
    INNER JOIN #master_robot AS master_robot
        ON master_robot.[amr_id] = ods_battery.[amr_id]
    WHERE battery_fact.[sample_time] >= @window_start
      AND battery_fact.[sample_time] < @window_end
      AND battery_fact.[source_schema] = N'ODS'
      AND battery_fact.[source_table] = N'robot_battery_history'
      AND (ISNULL(battery_fact.[robot_id], N'') <> CONVERT(NVARCHAR(100), master_robot.[amr_id])
        OR ISNULL(battery_fact.[robot_code], N'') <> master_robot.[robot_code])
;

WHILE EXISTS (SELECT 1 FROM #candidate)
BEGIN
    DELETE FROM #batch;

    BEGIN TRY
        BEGIN TRANSACTION;

        ;WITH next_batch AS
        (
            SELECT TOP (@batch_size)
                candidate.[battery_fact_id],
                candidate.[amr_id],
                candidate.[robot_code]
            FROM #candidate AS candidate
            ORDER BY candidate.[battery_fact_id]
        )
        DELETE FROM next_batch
        OUTPUT deleted.[battery_fact_id], deleted.[amr_id], deleted.[robot_code]
            INTO #batch ([battery_fact_id], [amr_id], [robot_code]);

        SET @candidate_count = @@ROWCOUNT;
        SET @batch_number += 1;

        UPDATE battery_fact
        SET
            battery_fact.[robot_id] = CONVERT(NVARCHAR(100), batch_row.[amr_id]),
            battery_fact.[robot_code] = batch_row.[robot_code],
            battery_fact.[dwd_load_time] = SYSDATETIME()
        FROM [DWD].[fact_robot_battery] AS battery_fact
        INNER JOIN #batch AS batch_row
            ON batch_row.[battery_fact_id] = battery_fact.[battery_fact_id]
        WHERE ISNULL(battery_fact.[robot_id], N'') <> CONVERT(NVARCHAR(100), batch_row.[amr_id])
           OR ISNULL(battery_fact.[robot_code], N'') <> batch_row.[robot_code];

        SET @updated_count = @@ROWCOUNT;

        IF @updated_count <> @candidate_count
        BEGIN
            THROW 58511, N'Batch update count differs from the exact candidate count.', 1;
        END;

        COMMIT TRANSACTION;

        INSERT INTO #repair_audit ([batch_number], [candidate_count], [updated_count], [committed_at])
        VALUES (@batch_number, @candidate_count, @updated_count, SYSDATETIME());
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
        BEGIN
            ROLLBACK TRANSACTION;
        END;
        THROW;
    END CATCH;
END;

SELECT
    @window_start AS [repaired_window_start],
    @window_end AS [repaired_window_end],
    COALESCE(SUM(CONVERT(BIGINT, repair_audit.[updated_count])), CONVERT(BIGINT, 0)) AS [total_rows_updated],
    COUNT_BIG(*) AS [batches_committed],
    MIN(repair_audit.[committed_at]) AS [first_batch_committed_at],
    MAX(repair_audit.[committed_at]) AS [last_batch_committed_at]
FROM #repair_audit AS repair_audit;

SELECT
    repair_audit.[batch_number],
    repair_audit.[candidate_count],
    repair_audit.[updated_count],
    repair_audit.[committed_at]
FROM #repair_audit AS repair_audit
ORDER BY repair_audit.[batch_number];
