# AMR 智能监控 Web

本项目是 `IOT2020` 数据库的本地 AMR 监控面板。浏览器不直接连接 SQL Server，所有数据通过本地 Node.js API 从 `DWS` Schema 查询。

## 当前功能

- 手动刷新 DWS 面板数据。
- 手动执行 `DWS.sp_refresh_robot_current_snapshot_fast`，同步当前状态后重新查询。
- 当前机器人总数、在线/离线、任务、电量和告警概览。
- 最近 3/6/12 小时、最近 1 天、1 周和 30 天固定分析范围。
- 任务成功率、错误采样、电量、WiFi、任务和队列趋势。
- 基于 `position_x` / `position_y` 的机器人位置投影。
- 当前状态、运行模式、任务和按原因归组的告警明细。
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

Web 服务账号只需要：

- `DWS` Schema 的 `SELECT` 权限。
- `DWS.sp_refresh_robot_current_snapshot_fast` 的 `EXECUTE` 权限。

不需要直接授予浏览器或 Web 登录账号对 `ODS`、`DWD` 业务表的读写权限。授权操作需要由 DBA 或有权限的数据库管理员执行。

示例中的数据库用户应替换为真实用户：

```sql
USE [IOT2020];
GO

GRANT SELECT ON SCHEMA::[DWS] TO [amr_monitor_web];
GRANT EXECUTE ON OBJECT::[DWS].[sp_refresh_robot_current_snapshot_fast]
TO [amr_monitor_web];
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

- `GET /api/health`：检查数据库、DWS 当前快照表和快速同步过程。
- `GET /api/dashboard?hours=24&days=7`：读取面板数据。
- `POST /api/sync/current`：执行当前快照快速同步。

## 安全边界

- 默认只监听 `127.0.0.1`，适合本机使用。
- 尚未实现登录认证，不要直接改成 `0.0.0.0` 暴露到工厂网络或互联网。
- 正式部署前需要增加用户认证、HTTPS、请求审计和同步按钮权限控制。
- 页面位置图是坐标归一化投影，不是实际地图比例，也不会伪造机器人规划路径。
