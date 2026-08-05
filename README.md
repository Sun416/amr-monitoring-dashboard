# AMR 智能监控 Web

本项目是 `IOT2020` 数据库的本地 AMR 分析面板。浏览器不直接连接 SQL Server，所有数据通过本地 Node.js API 查询。车队状态、电量和 WiFi 概览使用非快照 DWS 小时汇总；任务、队列、电量覆盖率和机器人档案仍读取现有 DWS/DWD 及必要的只读业务历史表。

## 当前功能

- 分析中心使用版本化的透明规则，输出“现象、最可能原因、证据、置信度、维护动作、备选原因”。
- 断连分析分别比较状态、WiFi、电池和设备错误的独立时间戳，避免用一条新数据掩盖另一条数据源已过期。
- 任务负载按 AMR / AMB 类型分别比较，识别任务集中、零任务机器人及下一步需要检查的调度证据。
- 使用 `TA_AMR` 起止时间和 `AMR_Subjob_Analyze.limit` 计算带假设标签的准时率与任务耗时；时限单位未确认前不会把结果包装成全车队确定结论。
- 通过 `AMR_Queue.enqueued_at -> TA_AMR.start_time` 推导队列等待时间，并明确区分源表空的 `duration_seconds`。
- 按相邻电池采样时间加权计算“电量高于 60% 时间占比”，同时显示窗口覆盖率；超过 5 分钟的遥测断档不计入分母。
- 显示已完成子任务段的时长，但在没有路线占用和站点到达/上下料/离开事件时，不将长耗时直接归因为堵车或上下料。
- 调度分析使用项目分配、优先级、在线状态和任务结果作为代理证据；没有候选、资格、得分和拒绝原因时明确标为部分可分析。
- 任务累计里程仍明确标记不可计算，直到任务关联里程表或起止里程计进入数据链路。
- 当前状态不再读取 `DWS.dws_robot_current_snapshot`，也不会自动或手动执行快照同步过程。
- 非快照 DWS 数据必须同时满足“源事件时间、DWS 装载时间、源到 DWS 管道延迟均不超过 30 分钟”，才会被视为当前数据。
- 超过 30 分钟时，页面显示 `DWS refresh timeout`，隐藏旧状态、电量、位置和当前任务值，并给出 DWS 批次、装载计划和恢复后复核等维修动作。
- 当前精确位置、机器人状态和机器人上报的作业名称需要 `DWS.v_robot_live_state` 只读非持久化视图；安装脚本为项目根目录的 `64_install_dws_robot_live_state_view.sql`。该脚本尚需明确授权后执行。
- `robot_job_history.job_name` 不是已证明的业务任务 ID。业务任务 ID 与业务状态应从 `TA_AMR` 接入，但必须先确认页面采用 `TA_AMR.id/status` 还是 `TA_AMR.job_id + robot_job_history.job_status` 作为业务口径。
- 当前机器人总数、DWS 新鲜度、历史任务、电量和告警分析概览。
- 最近 3/6/12 小时、最近 1 天、1 周和 30 天固定分析范围。
- 任务成功率、错误采样、电量、WiFi、任务和队列趋势。
- 在实时只读视图安装前，位置、运行模式和当前任务明确显示为不可用，不从旧快照回填。
- 按原因归组的告警明细，以及每条规则的证据、置信度和维护动作。
- 每个数据板块独立导出 UTF-8 CSV；当前报表全部数据导出 JSON。
- DWS 最近同步批次及数据新鲜度。

任务和队列来自每日汇总表；WiFi 明细查询最多读取最近 24 小时。页面会显示这些数据粒度限制，避免把短时窗口误解为所有主题都具备小时级数据。

历史全层同步不会由 Web 按钮触发。需要时仍在 DataGrip 执行项目根目录的 `39_run_all_layers_manual_sync.sql`。

## 1. 安装依赖

PowerShell 的脚本策略可能阻止 `npm.ps1`，因此使用 `npm.cmd`：

```powershell
cd "C:\Users\Hz_Tao\Documents\ROBOT database analyse\amr-monitoring-web"
npm.cmd install
```

## 2. 配置数据库

复制配置模板：

```powershell
Copy-Item .env.example .env
```

编辑 `.env`，至少填写：

```text
DB_SERVER=SQL Server地址
DB_DATABASE=IOT2020
DB_USER=SQL登录名
DB_PASSWORD=SQL登录密码
```

命名实例可填写 `DB_INSTANCE`，使用命名实例时会忽略 `DB_PORT`。

第一版使用 SQL Server 登录认证。不要将 `.env` 提交到 Git，也不要把数据库密码写进前端文件。

## 3. 最小数据库权限

Web 服务账号只需要只读查询权限：

- `dbo.MA_AMR`、`dbo.AMR_Robot_Mode`、`dbo.robot_wifi_history` 和 `dbo.robot_battery_history` 的 `SELECT` 权限。
- `dbo.TA_AMR`、`dbo.AMR_Queue`、`dbo.AMR_Subjob_Analyze`、`dbo.MA_AMR_Subjob`、`dbo.MA_AMR_Subjob_Type` 与 `dbo.MA_AMR_Project_Assignment` 的 `SELECT` 权限。
- `DWD.fact_amr_queue`、`DWD.fact_amr_subjob` 的 `SELECT` 权限，用于分析能力检查。
- 统一审计表的 `SELECT` 权限。
- `DWS` Schema 的 `SELECT` 权限。

不需要授予浏览器或 Web 登录账号任何数据库权限，也不需要给 Web 账号 `ODS` 或业务表写权限。授权操作需要由 DBA 或有权限的数据库管理员执行。

示例中的数据库用户应替换为真实用户：

```sql
USE [IOT2020];
GO

GRANT SELECT ON SCHEMA::[DWS] TO [amr_monitor_web];
GRANT SELECT ON OBJECT::[dbo].[MA_AMR] TO [amr_monitor_web];
GRANT SELECT ON OBJECT::[dbo].[AMR_Robot_Mode] TO [amr_monitor_web];
GRANT SELECT ON OBJECT::[dbo].[robot_wifi_history] TO [amr_monitor_web];
GRANT SELECT ON OBJECT::[dbo].[robot_battery_history] TO [amr_monitor_web];
GRANT SELECT ON OBJECT::[dbo].[TA_AMR] TO [amr_monitor_web];
GRANT SELECT ON OBJECT::[dbo].[AMR_Queue] TO [amr_monitor_web];
GRANT SELECT ON OBJECT::[dbo].[AMR_Subjob_Analyze] TO [amr_monitor_web];
GRANT SELECT ON OBJECT::[dbo].[MA_AMR_Subjob] TO [amr_monitor_web];
GRANT SELECT ON OBJECT::[dbo].[MA_AMR_Subjob_Type] TO [amr_monitor_web];
GRANT SELECT ON OBJECT::[dbo].[MA_AMR_Project_Assignment] TO [amr_monitor_web];
GRANT SELECT ON OBJECT::[DWD].[fact_amr_queue] TO [amr_monitor_web];
GRANT SELECT ON OBJECT::[DWD].[fact_amr_subjob] TO [amr_monitor_web];
GRANT SELECT ON OBJECT::[DWD].[fact_robot_operation_event] TO [amr_monitor_web];
GRANT SELECT ON OBJECT::[DWD].[fact_dispatch_decision_candidate] TO [amr_monitor_web];
GRANT SELECT ON OBJECT::[DWD].[fact_robot_incident] TO [amr_monitor_web];
GRANT SELECT ON OBJECT::[DWD].[fact_robot_incident_evidence] TO [amr_monitor_web];
GRANT SELECT ON OBJECT::[DWD].[robot_event_watermark] TO [amr_monitor_web];
GO
```

## 4. 启动

双击 `start.cmd`，或者执行：

```powershell
npm.cmd start
```

浏览器打开：

```text
http://127.0.0.1:3080
```

## 接口

- `GET /api/health`：检查数据库和非快照 DWS 小时汇总表。
- `GET /api/dashboard?hours=24&days=7&robotType=ALL`：读取监控数据及透明规则分析结果。
- `POST /api/sync/current`：已停用，固定返回 `410 SNAPSHOT_SYNC_DISABLED`，防止旧快照重新进入当前状态链路。

## 安全边界

- 默认只监听 `127.0.0.1`，适合本机使用。
- 尚未实现登录认证，不要直接改成 `0.0.0.0` 暴露到工厂网络或互联网。
- 正式部署前需要增加用户认证、HTTPS、请求审计和同步按钮权限控制。
- 页面位置图是坐标归一化投影，不是实际地图比例，也不会伪造机器人规划路径。
