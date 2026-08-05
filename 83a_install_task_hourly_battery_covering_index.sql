USE [IOT2020];

/*
    Cover the DWS Task Analytics battery-interval loader.

    Read benefit: avoids key lookups for charging_status while seeking one
    robot and a bounded sample-time range.
    Write cost: every DWD battery insert also maintains this small additional
    nonclustered index.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes AS index_row
    WHERE index_row.[object_id] = OBJECT_ID(N'[DWD].[fact_robot_battery]')
      AND index_row.[name] = N'IX_DWD_fact_robot_battery_task_hourly'
)
BEGIN
    CREATE NONCLUSTERED INDEX [IX_DWD_fact_robot_battery_task_hourly]
        ON [DWD].[fact_robot_battery] ([robot_code], [sample_time])
        INCLUDE ([charging_status]);
END;
