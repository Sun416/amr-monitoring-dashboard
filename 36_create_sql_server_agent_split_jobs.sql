USE IOT2020;
GO

/*
    Create two disabled SQL Server Agent jobs.

    Jobs are intentionally disabled after creation:
      1. Verify both procedures manually.
      2. Confirm Agent permissions and duration.
      3. Enable the jobs with the commands at the bottom of this file.

    Schedule:
      - AMR - Fast Current Snapshot: every 1 minute.
      - AMR - Historical Analytics: every 10 minutes, starting at minute 03.
*/

IF OBJECT_ID(N'[DWS].[sp_refresh_robot_current_snapshot_fast]', N'P') IS NULL
   OR OBJECT_ID(N'[DWS].[sp_run_amr_historical_pipeline]', N'P') IS NULL
BEGIN
    RAISERROR(N'Missing split-sync procedures. Execute scripts 02, 21, 26, 35, and 46 first.', 16, 1);
    RETURN;
END;
GO

USE msdb;
GO

DECLARE @today INT = CONVERT(INT, CONVERT(CHAR(8), GETDATE(), 112));

IF NOT EXISTS (
    SELECT 1
    FROM [msdb].[dbo].[sysjobs]
    WHERE [name] = N'AMR - Fast Current Snapshot'
)
BEGIN
    EXEC [msdb].[dbo].[sp_add_job]
        @job_name = N'AMR - Fast Current Snapshot',
        @enabled = 0,
        @description = N'Refresh dbo/ODS/DWD/DWS AMR current snapshot every minute for the monitoring Web.';

    EXEC [msdb].[dbo].[sp_add_jobstep]
        @job_name = N'AMR - Fast Current Snapshot',
        @step_name = N'Refresh current snapshot',
        @subsystem = N'TSQL',
        @database_name = N'IOT2020',
        @command = N'EXEC [DWS].[sp_refresh_robot_current_snapshot_fast];',
        @retry_attempts = 2,
        @retry_interval = 1,
        @on_success_action = 1,
        @on_fail_action = 2;

    EXEC [msdb].[dbo].[sp_add_jobschedule]
        @job_name = N'AMR - Fast Current Snapshot',
        @name = N'AMR - Every 1 Minute',
        @enabled = 1,
        @freq_type = 4,
        @freq_interval = 1,
        @freq_subday_type = 4,
        @freq_subday_interval = 1,
        @active_start_date = @today,
        @active_start_time = 0;

    EXEC [msdb].[dbo].[sp_add_jobserver]
        @job_name = N'AMR - Fast Current Snapshot';
END;

IF NOT EXISTS (
    SELECT 1
    FROM [msdb].[dbo].[sysjobs]
    WHERE [name] = N'AMR - Historical Analytics'
)
BEGIN
    EXEC [msdb].[dbo].[sp_add_job]
        @job_name = N'AMR - Historical Analytics',
        @enabled = 0,
        @description = N'Run ODS, DWD and DWS historical analytics synchronization every 10 minutes.';

    EXEC [msdb].[dbo].[sp_add_jobstep]
        @job_name = N'AMR - Historical Analytics',
        @step_name = N'Run historical pipeline',
        @subsystem = N'TSQL',
        @database_name = N'IOT2020',
        @command = N'EXEC [DWS].[sp_run_amr_historical_pipeline];',
        @retry_attempts = 1,
        @retry_interval = 2,
        @on_success_action = 1,
        @on_fail_action = 2;

    EXEC [msdb].[dbo].[sp_add_jobschedule]
        @job_name = N'AMR - Historical Analytics',
        @name = N'AMR - Every 10 Minutes',
        @enabled = 1,
        @freq_type = 4,
        @freq_interval = 1,
        @freq_subday_type = 4,
        @freq_subday_interval = 10,
        @active_start_date = @today,
        @active_start_time = 300;

    EXEC [msdb].[dbo].[sp_add_jobserver]
        @job_name = N'AMR - Historical Analytics';
END;

SELECT
    j.[name] AS [job_name],
    j.[enabled] AS [job_enabled],
    s.[step_id],
    s.[step_name],
    s.[database_name],
    s.[command]
FROM [msdb].[dbo].[sysjobs] AS j
INNER JOIN [msdb].[dbo].[sysjobsteps] AS s
    ON s.[job_id] = j.[job_id]
WHERE j.[name] IN (
    N'AMR - Fast Current Snapshot',
    N'AMR - Historical Analytics'
)
ORDER BY j.[name], s.[step_id];
GO

/*
    Enable only after scripts 37 and 38 pass.

    EXEC [msdb].[dbo].[sp_update_job]
        @job_name = N'AMR - Fast Current Snapshot',
        @enabled = 1;

    EXEC [msdb].[dbo].[sp_update_job]
        @job_name = N'AMR - Historical Analytics',
        @enabled = 1;
*/
