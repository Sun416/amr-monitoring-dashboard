USE [IOT2020];
GO

SET NOCOUNT ON;
GO

/*
    Prepare the disabled SQL Server Agent freshness-monitor job.

    Current blocker:
      The current login is not yet a member of an msdb SQL Server Agent role.

    After permission is granted:
      1. Execute this whole file once.
      2. Confirm the job exists and remains disabled.
      3. Run 48_run_etl_freshness_check.sql manually.
      4. Enable the job with the commented command at the bottom.

    STALE or FAILED results are persisted first, then the Agent run is failed.
*/

IF OBJECT_ID(N'[DWS].[sp_check_etl_freshness]', N'P') IS NULL
BEGIN
    RAISERROR(N'Missing DWS.sp_check_etl_freshness. Execute script 47 first.', 16, 1);
    RETURN;
END;
GO

USE [msdb];
GO

IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'), 0) <> 1
   AND ISNULL(IS_ROLEMEMBER(N'SQLAgentUserRole'), 0) <> 1
   AND ISNULL(IS_ROLEMEMBER(N'SQLAgentReaderRole'), 0) <> 1
   AND ISNULL(IS_ROLEMEMBER(N'SQLAgentOperatorRole'), 0) <> 1
BEGIN
    RAISERROR(N'Current login has no SQL Server Agent role in msdb. Ask the DBA to grant an appropriate Agent role, then rerun this script.', 16, 1);
    RETURN;
END;
GO

DECLARE @today INT = CONVERT(INT, CONVERT(CHAR(8), GETDATE(), 112));

IF NOT EXISTS
(
    SELECT 1
    FROM [msdb].[dbo].[sysjobs]
    WHERE [name] = N'AMR - ETL Freshness Monitor'
)
BEGIN
    EXEC [msdb].[dbo].[sp_add_job]
        @job_name = N'AMR - ETL Freshness Monitor',
        @enabled = 0,
        @description = N'Check dbo to ODS to DWD to DWS freshness every five minutes. STALE or FAILED checks fail the Agent run.';

    EXEC [msdb].[dbo].[sp_add_jobstep]
        @job_name = N'AMR - ETL Freshness Monitor',
        @step_name = N'Check core ETL freshness',
        @subsystem = N'TSQL',
        @database_name = N'IOT2020',
        @command = N'EXEC [DWS].[sp_check_etl_freshness]
    @ods_threshold_minutes = 10,
    @dwd_threshold_minutes = 20,
    @dws_threshold_minutes = 30,
    @fail_on_stale = 1;',
        @retry_attempts = 1,
        @retry_interval = 1,
        @on_success_action = 1,
        @on_fail_action = 2;

    EXEC [msdb].[dbo].[sp_add_jobschedule]
        @job_name = N'AMR - ETL Freshness Monitor',
        @name = N'AMR - Freshness Every 5 Minutes',
        @enabled = 1,
        @freq_type = 4,
        @freq_interval = 1,
        @freq_subday_type = 4,
        @freq_subday_interval = 5,
        @active_start_date = @today,
        @active_start_time = 0;

    EXEC [msdb].[dbo].[sp_add_jobserver]
        @job_name = N'AMR - ETL Freshness Monitor';
END;
GO

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
WHERE j.[name] = N'AMR - ETL Freshness Monitor'
ORDER BY s.[step_id];
GO

/*
    Enable only after the manual check returns the expected results and the
    historical synchronization has caught up:

    EXEC [msdb].[dbo].[sp_update_job]
        @job_name = N'AMR - ETL Freshness Monitor',
        @enabled = 1;
*/

