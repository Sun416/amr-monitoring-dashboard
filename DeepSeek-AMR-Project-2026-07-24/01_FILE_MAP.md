# 文件地图

## 核心上下文

| 文件 | 用途 |
|---|---|
| `AGENTS.md` | SQL Server 开发与安全规范，优先级最高 |
| `PROJECT_STATUS_COMPACT.md` | 当前架构、已完成状态、正式入口、已知问题 |
| `PROJECT_NEXT_PLAN.md` | 近期动作摘要 |
| `00_README_FOR_DEEPSEEK.md` | 导出范围和阅读入口 |
| `02_PROMPT_FOR_DEEPSEEK.md` | 可直接粘贴给 DeepSeek 的首轮提示词 |

## SQL 主链路

| 阶段 | 关键文件 | 说明 |
|---|---|---|
| 只读盘点 | `iot2020_robot_amr_readonly_inventory.sql` | 先了解真实库对象，不写数据 |
| DWD 建模 | `01_create_dwd_core_tables.sql` | DWD 核心表 |
| DWD 过程 | `02_create_dwd_load_procedure.sql` | 增量加载过程 |
| ODS 增量 | `21_run_ods_id_time_incremental.sql` | 日常 ODS ID/时间增量入口 |
| DWD 增量 | `22_run_dwd_incremental_and_verify.sql` | 日常 DWD 增量与验证 |
| DWS 建模 | `25_create_dws_core_tables.sql` | DWS 核心表 |
| DWS 聚合 | `26_load_dws_core_upsert.sql` | 历史聚合过程 |
| DWS 校验 | `27_check_dws_core.sql` | 只读校验 |
| 全层同步 | `39_run_all_layers_manual_sync.sql` | 手动总控，执行前复核 |
| 当前快照 | `46_install_dws_operational_snapshot_v2.sql` | 当前生产安装脚本 |
| 新鲜度 | `47_install_etl_freshness_monitor.sql` | 新鲜度表、视图和过程 |
| 手动检查 | `48_run_etl_freshness_check.sql` | 新鲜度检查入口 |
| Agent 草案 | `49_create_sql_server_agent_freshness_job.sql` | 需要 msdb/Agent 权限 |

## 功能增强与诊断

- `28_dws_current_snapshot_diagnosis.sql`：当前快照诊断。
- `28_refresh_dws_robot_wifi_hourly.sql`：WiFi 小时聚合。
- `30_diagnose_dws_robot_job_zero_metrics.sql`：任务指标为零诊断。
- `32_diagnose_existing_dws_job_metric_sources.sql`：任务指标来源诊断。
- `33_update_existing_dws_robot_job_daily_metrics.sql`：任务日指标更新。
- `35_install_historical_analysis_sync.sql`：历史分析同步过程。
- `36_create_sql_server_agent_split_jobs.sql`：拆分 Agent 任务草案。
- `37_run_fast_current_snapshot_and_verify.sql`：快速快照运行与验证。
- `38_run_historical_analysis_and_verify.sql`：历史同步运行与验证。
- `40_preview_robot_job_type_mode_mapping.sql`：类型和 Mode 映射预览。
- `41_install_robot_job_mode_schema.sql`：类型和 Mode Schema。
- `42_install_robot_job_mode_incremental_enrichment.sql`：增量 enrichment。
- `45_verify_robot_job_type_mode_pipeline.sql`：只读验证。

## 历史修复、回补或高风险脚本

以下文件需要结合历史故障背景阅读，不能作为日常入口直接执行：

```text
03, 04, 06, 08, 10, 11, 13, 14, 15, 16, 17, 18, 19,
24, 29_fix, 31, 43, 44
```

执行任何回补前必须重新确认源键、水位线、时间边界、重复处理、晚到数据、日志增长、锁和恢复策略。

## Legacy

- `34_install_fast_current_snapshot_sync.sql`：旧快速快照，只保留审计/回退参考。
- 正式生产快照必须以 `46_install_dws_operational_snapshot_v2.sql` 为准。

## Web 目录

| 路径 | 用途 |
|---|---|
| `amr-monitoring-web/server.js` | Express 服务入口和 API |
| `amr-monitoring-web/src/db.js` | SQL Server 连接配置 |
| `amr-monitoring-web/src/dashboard-service.js` | 服务层与查询编排 |
| `amr-monitoring-web/src/dashboard-query.sql` | 仪表盘数据查询 |
| `amr-monitoring-web/src/robot-profile-query.sql` | 机器人档案查询 |
| `amr-monitoring-web/src/wifi-monitor-query.sql` | WiFi 监控查询 |
| `amr-monitoring-web/public/` | 前端 HTML、CSS、JavaScript |
| `amr-monitoring-web/.env.example` | 无真实密码的配置模板 |

## 历史证据

- `audit_results/` 中 CSV 是历史审计快照，不能证明当前实时状态。
- `outputs/` 中主要是分析与报告源文件；应优先阅读 `.sql`、`.mjs`、`.ps1` 和 README/JSON。

