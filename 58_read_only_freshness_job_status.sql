USE [msdb];

SET NOCOUNT ON;

SELECT
    ISNULL(IS_SRVROLEMEMBER(N'sysadmin'), 0) AS [is_sysadmin],
    ISNULL(IS_ROLEMEMBER(N'SQLAgentUserRole'), 0) AS [is_sql_agent_user],
    ISNULL(IS_ROLEMEMBER(N'SQLAgentReaderRole'), 0) AS [is_sql_agent_reader],
    ISNULL(IS_ROLEMEMBER(N'SQLAgentOperatorRole'), 0) AS [is_sql_agent_operator];

BEGIN TRY
    EXEC sys.sp_executesql N'
        SELECT
            job.[name] AS [job_name],
            job.[enabled] AS [job_enabled],
            job.[date_created],
            job.[date_modified]
        FROM [msdb].[dbo].[sysjobs] AS job
        WHERE job.[name] = N''AMR - ETL Freshness Monitor'';';
END TRY
BEGIN CATCH
    SELECT
        N'ACCESS_DENIED' AS [job_metadata_status],
        ERROR_NUMBER() AS [error_number],
        ERROR_MESSAGE() AS [error_message];
END CATCH;
