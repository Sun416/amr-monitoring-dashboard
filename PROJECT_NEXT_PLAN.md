# AMR 项目下一步

更新时间：2026-07-21

完整当前状态统一以 `PROJECT_STATUS_COMPACT.md` 为准。本文件只保留近期动作：

1. 等用户确认是否启用 `dbo.MA_AMR.id=6 (AMR_03)`；未确认不修改。
2. 排查 `dbo.robot_*_history` 上游遥测停止/延迟问题。
3. 获得 SQL Server Agent 权限后执行并验证 `36_create_sql_server_agent_split_jobs.sql`。
4. 追平历史 ODS/DWD/DWS 聚合并核验趋势时间锚点。
5. Agent 稳定后追加 SQL Server CDC / Flink CDC。
6. 有明确分析交付需求后再决定是否建设 ADS。

监控 Web：`http://127.0.0.1:3080/`，当前为英文界面。
