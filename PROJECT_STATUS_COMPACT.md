# IOT2020 AMR 项目精简状态

更新时间：2026-07-21

> 后续继续本项目时，先读本文件和 `AGENTS.md`；除非需要追查旧故障，不再重读长对话。时间、行数、在线数等易变化信息应实时复核。

## 1. 项目目标与架构

- 数据库：Microsoft SQL Server `IOT2020`。
- AMR 范围：表名包含 `robot` 或 `AMR`；机器人主数据以 `dbo.MA_AMR.id` 为关联键，名称来自 `dbo.MA_AMR.name`，禁止按编号猜测。
- 历史分析链路：`dbo -> ODS -> DWD -> DWS`；ADS 暂未建设，当前监控 Web 不依赖 ADS。
- 监控链路：浏览器 -> Node.js API -> `DWS`；“Sync Latest Status”会执行快速快照过程，将 `dbo` 最新状态汇入 DWS。
- 低延迟后续方案：SQL Server Agent 稳定后再建设 SQL Server CDC / Flink CDC；CDC 不替代 ODS/DWD/DWS 转换、校验、水位线和重试。

## 2. 当前完成状态

### ODS

- ODS 架构、机器人相关源表镜像和 `ODS.etl_watermark` 已建立。
- 历史数据已做首次导入、缺口回补和多轮质量修复。
- ID/时间增量入口：`21_run_ods_id_time_incremental.sql`。
- `FULL_REPLACE`、`SNAPSHOT` 和历史链路由后续总控过程/脚本负责；旧修复脚本不能当日常任务。

### DWD

- 核心维度、事实、快照和 ETL 控制表已建立。
- 核心过程：`DWD.sp_load_dwd_all_incremental`，安装脚本 `02_create_dwd_load_procedure.sql`。
- 手动入口：`22_run_dwd_incremental_and_verify.sql`。
- `fact_robot_job`、`fact_robot_battery`、`fact_robot_wifi` 的历史映射/空值问题已修复并回补。
- 任务类型和机器人 Mode enrichment（40–45号脚本）已安装并执行。

### DWS

- 核心表：电量小时、状态小时、WiFi小时、任务日、队列日、机器人当前快照。
- 建表：`25_create_dws_core_tables.sql`；历史聚合：`26_load_dws_core_upsert.sql`；校验：`27_check_dws_core.sql`。
- 当前生产快照入口：`DWS.sp_refresh_robot_current_snapshot_fast`。
- 正确安装脚本：`46_install_dws_operational_snapshot_v2.sql`。
- `34_install_fast_current_snapshot_sync.sql` 已降级为 legacy，仅保留审计/回退参考，不应用于监控 Web。
- v2 快照按 `MA_AMR.id` 获取最新状态、电量、任务、Mode、地图、坐标、当前/目标 POI，并以 `MA_AMR.name` 写入 DWS。

### AMR Web

- 项目目录：`amr-monitoring-web`。
- 地址：`http://127.0.0.1:3080/`。
- 当前版本为英文界面，深色工业指挥中心风格；数据库原始业务值不翻译。
- 支持手动刷新面板和手动同步最新状态。
- 已验证：19 行机器人、19 行任务、位置投影、电量趋势、WiFi 风险和 DWS 批次可正常渲染；页面无中文 UI 残留及整体横向溢出。

## 3. 当前已知数据事实（最后核验快照）

- `dbo.MA_AMR` 中 `is_active='Y'` 为 19 台。
- `AMR_03`：`id=6`、`serial=SDR0100D2024SV00501`、`is_active='N'`、`status='Avaliable'`，且仍有近期遥测；是否启用必须由用户确认，未获确认不得修改。
- 快照：19/19 台已匹配；位置坐标 19 台；电量/电压/电流/Mode/RSSI 19 台。
- 源字段缺失：3 台运动状态为空；2 台 WiFi AP 为空；部分机器人无当前/目标 POI。界面显示明确占位，不用主数据或目标值冒充实时状态。
- “Recently Online”口径：相对最新状态源锚点 5 分钟内上报；最后核验为 7 台。它不等于严格现实时间在线数。
- 最后核验时 `dbo.robot_status_history` 停在 `2026-07-20 12:51:59`，已落后数据库当前时间；真实实时在线需先恢复上游遥测写入。
- 电量历史趋势最后核验锚点为 `2026-07-17 14:00`，说明历史 DWS 聚合仍可能滞后。

## 4. 正式执行入口

- 快速当前快照：`EXEC DWS.sp_refresh_robot_current_snapshot_fast;`
- ODS ID/时间增量：`21_run_ods_id_time_incremental.sql`
- DWD 增量与验证：`22_run_dwd_incremental_and_verify.sql`
- DWS 历史聚合：重新安装/执行 `26_load_dws_core_upsert.sql` 中定义的过程。
- 全层手动总控：`39_run_all_layers_manual_sync.sql`。
- 历史分析总控安装：`35_install_historical_analysis_sync.sql`。
- Agent 拆分任务草案：`36_create_sql_server_agent_split_jobs.sql`。

## 5. 禁止误用

- 04、06、10、13、24、29、43、44 等历史回补/修复脚本不是日常同步入口。
- 不得重新用 34 号 legacy 过程覆盖 46 号 v2 快照。
- 不得用 `AMR_Currentdata` 的旧 9 行作为全车队实时来源。
- 不得用机器人名称、序号或相近时间猜测关联；优先使用 `MA_AMR.id = *_history.amr_id`。
- 未经确认不得启用 `AMR_03`、删除旧快照行或执行大规模回补。

## 6. 下一步（按优先级）

1. 用户确认 `AMR_03` 是否应从 `is_active=N` 改为 `Y`；否则总数 19 正确。
2. 排查并恢复 `dbo.robot_*_history` 上游遥测写入，解决“严格实时在线为 0”和数据锚点持续滞后。
3. 获取 SQL Server Agent / msdb 权限，安装并验证：快速快照任务（约1分钟）与历史分析任务（约10分钟）。
4. 追平 ODS/DWD/DWS 历史链路并复核趋势锚点。
5. Agent 稳定后建设 SQL Server CDC / Flink CDC，覆盖更新、删除、checkpoint、重试和监控。
6. 只有出现明确 Power BI/分析交付需求时，再按指标需求设计 ADS。

## 7. 安全规则

- 所有非平凡 `UPDATE`/`DELETE` 必须先给同条件 `SELECT` 预览。
- 大表回补要分批，评估日志、锁、磁盘和中断恢复。
- 使用显式列、显式 JOIN、Schema 限定名；不要用 `DISTINCT` 掩盖错误关联。
- 当前数据库/权限/行数/时间属于易变状态，执行写操作前必须重新只读验证。

## 8. 2026-07-22 工程基线与新鲜度监控

- Git 根仓库基线提交：`ed55c12`；Web 子仓库基线提交：`29ea933`。
- Web 目录作为正式 Git 子模块记录，远端为 `https://github.com/Sun416/amr-monitoring-dashboard.git`。
- 已安装 `DWS.etl_freshness_log`、`DWS.v_etl_freshness_latest` 和 `DWS.sp_check_etl_freshness`。
- 手动检查入口：`48_run_etl_freshness_check.sql`。
- Agent 新鲜度任务草案：`49_create_sql_server_agent_freshness_job.sql`，当前因 msdb Agent 角色未授权而不能安装。
- 首次检查的 12 条核心链路均为 `STALE`；当时 dbo 到 ODS 四张历史表约落后 55 万个 ID，历史锚点停在 2026-07-17。
- 2026-07-22 已手动执行全层同步，耗时约 6 分 15 秒；随后 12 条监控链路全部恢复为 `SUCCESS`。
- `estimated_rows_behind` 是最大 ID 与目标水位线之差，不等同于精确缺失行数。持续写入时允许存在少量 ID 差；只有事件时间延迟超过分层阈值才判为 `STALE`。
