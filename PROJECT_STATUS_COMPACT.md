# IOT2020 AMR 项目精简状态

更新时间：2026-07-30

> 后续继续本项目时，先读本文件和 `AGENTS.md`；跨模块规划或历史决策追溯再读 `PROJECT_CONTEXT_INTEGRATED.md`。除非需要追查旧故障，不再重读长对话。时间、行数、在线数等易变化信息应实时复核。

## 1. 项目目标与架构

- 数据库：Microsoft SQL Server `IOT2020`。
- AMR 范围：表名包含 `robot` 或 `AMR`；机器人主数据以 `dbo.MA_AMR.id` 为关联键，名称来自 `dbo.MA_AMR.name`，禁止按编号猜测。
- 历史分析链路：`dbo -> ODS -> DWD -> DWS`；ADS 暂未建设，当前监控 Web 不依赖 ADS。
- 当前 Web 主监控链路：浏览器 -> Node.js API -> 非快照 DWS 小时汇总；只有通过 10 分钟新鲜度门禁的数据才可作为当前值，Web 不再调用当前快照过程。
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
- 当前版本为英文界面，深色导航配合浅色分析工作区；数据库原始业务值不翻译。
- 支持手动刷新面板和手动同步最新状态。
- 已验证：19 行机器人、19 行任务、位置投影、电量趋势、WiFi 风险和 DWS 批次可正常渲染；页面无中文 UI 残留及整体横向溢出。
- 首页已升级为透明规则分析中心：每条诊断显示现象、最可能原因、证据、置信度、维护动作、备选原因和规则版本。
- 分析 API 同时返回断连诊断、按 AMR/AMB 分组的任务分配集中度、逐车下一步检查项、状态历史覆盖率及不可计算指标清单。
- 首版规则文件：`amr-monitoring-web/src/analysis-engine.js`；只读证据查询：`amr-monitoring-web/src/analysis-query.sql`。

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

## 9. 2026-07-28 Web 透明规则分析

- 透明规则版本：`2026.07.5`；不使用黑盒 AI 直接判定故障。
- 断连规则独立比较状态、WiFi、电池、充电和设备错误的时间戳，分为高/中/低置信度；证据不足时结论必须为“原因未解决”，不能强行归因。
- `robot_emer_status=0/1` 不再直接当作设备故障；AMR_04 的 RSSI=0 但存在 AP 和扫描网络时标记为“RSSI 不可用”，不再误报无线断连。
- 状态、WiFi、电池三路时间戳在 2 分钟内同时停止时，触发 `SOURCE_TELEMETRY_ALL_TOPICS_STOPPED`；只能证明故障在 Web/DWS 上游，不能在没有现场/AP/采集器日志时强行区分断电、网络或发布/采集进程停止。
- 2026-07-28 最新只读核验时，19 台启用机器人中 AMR_04、AMR_09 持续上报，另外 17 台三路遥测同时停更；ICMP 对两台正常上报机器人也失败，因此禁止用 ping 结果单独判断机器人离线。该事实易变，后续必须实时复核。
- 任务分配按机器人类型比较，并区分“当前遥测不可用”和“当前在线但无任务”。最近 7 天 AMR_04 占 AMR 指派 100%；8 台零任务 AMR 中 7 台遥测不可用，AMR_09 当前在线无活动任务，需继续核验调度资格和候选评分。
- `TA_AMR` 起止时间、`AMR_Subjob_Analyze.limit`、`AMR_Queue.enqueued_at` 和电池明细已接入分析 API：时限参考子集准时率 99.88%（单位仍待业务确认）、推导队列等待平均约 74 秒、AMR_04/09 的 24 小时电量高于 60% 时间占比分别约 77.22%/53.75%。以上数值随数据变化。
- 子任务段时长可计算，但没有路线占用和站点到达/上下料/离开事件，不能可靠归因堵车或上下料；任务累计里程仍缺少任务关联里程计/路段距离。
- 统一事件/审计契约已经安装：`DWD.fact_robot_operation_event`、`DWD.fact_dispatch_decision_candidate`、`DWD.fact_robot_incident`、`DWD.fact_robot_incident_evidence`、`DWD.robot_event_watermark` 及 `DWS.v_robot_event_audit_coverage`。
- 首次有界装载保留最近 5,000 条队列源行、最近 5,000 条任务源行和全部 242 条项目资格源行，共形成 15,437 条可回溯事件，其中 15,390 条带来源记录的机器人；三个来源水位均已追平，重复来源键为 0，立即重跑新增为 0。
- `DWD.sp_load_robot_operation_event_incremental` 使用 ODS `ods_row_id` 水位、每来源独立事务和应用锁；Web 当前快照同步会同时执行该增量过程。安装/预览/执行/验证入口依次为 50、51、52、53 号脚本。
- 调度候选、资格、得分、选择和拒绝原因的字段契约已建但仍为 0 行；历史源没有保存候选评分，禁止用最终指派结果反推或伪造。故障/证据表已建但尚无维护确认写入，因此页面明确标记统一审计能力为 `PARTIAL`。
- Web 当前快照默认每 60 秒自动刷新；代码检查、10 项规则单元测试、实时 SQL/API 均已通过。

## 10. 2026-07-28 Web 图表化与信息层级

- 参考 `amr-fleet-management-main.zip` 的 KPI、趋势图、占比图和“图表在前、明细在后”结构，以及 `amr-gateway-service-main.zip` 的连接摘要和机器人卡片层级；只借鉴呈现方式，不复制其数据模型。
- Analysis Center 已改为分析优先的阅读顺序：车队结论 -> 四项关键判断 -> 原因构成/任务分布 -> 准时率/队列等待/电量覆盖 -> 维护动作 -> 明细证据。
- 新增 5 组由现有分析 API 驱动的图表：最强诊断原因影响台数、各机器人任务分配、配置时限参考子集准时率、关联任务平均排队等待、电量高于 60% 的时间占比及遥测覆盖率。
- 重复诊断按“原因 + 规则”聚合；当前 17 台相同的上游遥测停更不再显示为 17 张重复卡片，而是一个原因组，并保留受影响机器人、维护动作和可展开的逐车证据。
- 逐车运行证据、完整任务分类、测量能力和辅助车队指标默认折叠，避免首页继续堆叠大量数字；精确值仍可展开核验。
- 不展示当前数据无法支持的里程、路线拥堵原因、上下料时长或虚构调度效率；相应能力缺口继续在测量能力中明确标记。
- 已完成 1280px 桌面和窄屏响应式验收；窄屏筛选器、操作按钮、结论卡和条形图均可换行，无横向溢出。

## 11. 2026-07-28 数据质量准入门禁

- 新增只读检查入口：`54_read_only_data_quality_gate.sql`。它不更新业务表、ETL 水位或监控日志，用于在生产分析和外部系统接入前检查快照覆盖、新鲜度、批次、主数据映射、遥测时效、字段完整性和 DWS 分析锚点。
- 最新只读检查时，19 台启用机器人均有当前快照，DWS 快照装载时间小于 1 分钟，最近 20 个 DWS 快照批次均为 `SUCCESS`；这只能证明快照过程运行正常。
- 只有 AMR_04、AMR_09 的状态、WiFi 和电池遥测通过当前时效门禁；其余 17 台三路数据均已停更。因此当前不能把 17 台的零任务、离线或调度结果当作完整车队生产结论。
- 2026-07-28 08:50 数据库时间已用 `55_restart_freshness_monitor_and_verify.sql` 重启持久化新鲜度检查；12 项 dbo→ODS→DWD→DWS 检查均为 `SUCCESS`。当前登录仍没有 sysadmin 或任何 msdb SQL Agent 角色，因此每 5 分钟自动检查任务尚不能安装/启用。
- 已用 `56_run_authorized_all_layer_sync_and_verify.sql` 完成 ODS→DWD→DWS 补载：包含首次客户端超时前已提交的电池增量，四张核心 ODS 历史表累计补入约 30,400 行；DWD 批次 29 和 DWS 历史批次 181 均为 `SUCCESS`，状态/电量小时锚点恢复到 2026-07-28 08:00，并通过 120 分钟门禁。
- DWS 当前快照中存在 9 个无法关联 `dbo.MA_AMR` 的遗留 robot_code；未获用户明确确认前不得删除。启用机器人没有缺失快照，也没有发现重复启用 robot_code。
- `57_compare_source_and_snapshot_missing_fields.sql` 已逐台比对最新 dbo 原表与 DWS 快照；没有发现原表有值而 DWS 丢值。缺口均来自最新源记录为空或占位符：状态 4 台（AMR_06/07/08/10）、地图 3 台（AMB-09/10、AMR_10）、电量 1 台（AMR_10）、WiFi AP 3 台（AMB-09/10、AMR_10，其中 AMR_10 为 `-` 占位符）。位置、Mode 和 RSSI 当前均有值。
- 当前总门禁结论为 `ANALYSIS_BLOCKED`：允许显示数据质量故障和有限的逐车证据，但不应发布完整车队效率、调度公平性或根因结论。

## 12. 2026-07-29 Web 主视图精简与透明维修指引

- Analysis Center 首屏改为“车队遥测状态 + 优先告警与维修动作”双主区，不再用大量独立数字卡占据主要显示区域。
- 车队状态使用环形图展示 `Current`、`Delayed`、`Missing` 的占比，并以 19 张紧凑机器人状态卡保留逐车入口；这里表达的是时间戳新鲜度，不把停更直接猜测为断电、断网或机器人故障。
- 优先告警只选择现有透明规则中影响范围和严重度最高的诊断组，原因、置信度、受影响机器人和前三条维修动作均直接来自分析 API；证据不足时继续显示需要现场确认。
- 重复说明、逐车证据、测量能力和辅助指标继续放入默认折叠的明细区；主要图表标签和维修动作字号已增大。
- 已通过 `npm.cmd run check`、11 项规则单元测试、桌面端和 390px 窄屏浏览器验收；19 张机器人卡、状态环形图、优先维修卡均正常渲染，页面无横向溢出。

## 13. 2026-07-29 非快照 DWS 门禁与实时明细方案

- Web 已停止读取 `DWS.dws_robot_current_snapshot`，也不再自动或手动执行 `DWS.sp_refresh_robot_current_snapshot_fast`；`POST /api/sync/current` 固定返回 `410 SNAPSHOT_SYNC_DISABLED`。
- 当前车队状态、电量和 WiFi 概览读取 `DWS.dws_robot_status_hourly`、`DWS.dws_robot_battery_hourly` 和 `DWS.dws_robot_wifi_hourly`。只有源事件时间、DWS 装载时间和事件到装载延迟均不超过 10 分钟时，才显示为当前数据。
- 最新只读复核时，19 台启用机器人在非快照 DWS 中均能匹配，但 DWS 最新装载约落后 130 至 135 分钟，因此 0 台通过当前门禁、19 台显示 `DWS refresh timeout`、0 台为缺失。该数值是易变事实，后续必须实时复核。
- 超时机器人不再显示旧状态、电量、位置和当前任务；透明规则 `DWS_REFRESH_TIMEOUT` 只证明 DWS 服务层刷新失败，不把它猜测为机器人断电、断网或离线。
- `63_read_only_dws_live_freshness.sql` 是非快照 DWS 新鲜度只读检查入口；`65_read_only_preview_dws_robot_live_state.sql` 是精确状态/位置/当前任务只读预览。最近一次预览中 9 台在 10 分钟内有精确实时字段，10 台超时；该结果同样是易变事实。
- 现有 DWS 小时/每日汇总物理上不保存精确当前位置、机器人状态和机器人上报的作业名称。解决方案为 `64_install_dws_robot_live_state_view.sql`：创建 `DWS.v_robot_live_state` 只读非持久化视图，按 `MA_AMR.id` 从已有索引的历史表取每台最新记录，并按主题执行 10 分钟门禁；它不会创建或回填快照表。
- `66_read_only_inspect_current_task_identity.sql` 已确认 `robot_job_history.job_name` 是机器人上报的作业/指令名称，不能冒充业务任务 ID；`TA_AMR` 同时存在 `id`、`job_id`、`subjob_id` 与 `status`，当前任务 ID 和业务状态的展示口径必须由用户确认后才能接入。
- `64_install_dws_robot_live_state_view.sql` 当前仅已生成和只读预演，尚未执行。安装属于数据库 DDL，必须获得用户对该脚本的明确授权后才能上线，并在安装后再把 Web 精确位置、机器人状态和上报作业字段接到该视图。
- 当前代码已通过 `npm.cmd run check`、14 项透明规则单元测试、实时 API 校验和桌面浏览器验收；页面主结论为 19 台 DWS 刷新超时，控制台无 Web 错误。

## 14. 2026-07-30 Running 任务 WiFi 长周期分析

- Analysis Center 的 Running 任务 WiFi 板块使用顶部总时间范围，不再保留独立时间下拉框；3/6/12/24 小时、7 天和 30 天共用同一个筛选入口。
- 数据关联规则保持严格：`ODS.robot_job_history.amr_id = ODS.robot_wifi_history.amr_id`、两表 `pc_timestamp` 完全相同、任务状态为 `Running`，点位字段使用 `robot_job_history.poi_target`。
- 已安装并验证 `IX_ODS_robot_job_history_running_amr_time` 过滤索引和 `IX_ODS_robot_wifi_history_amr_time` 覆盖索引；两者均未禁用。任务索引约 64,538 行/2.51 MB，WiFi 索引约 44,126,425 行/1,239.95 MB。
- Web 查询已移除最近 300,000 行和 24 小时上限，最长支持 720 小时；趋势粒度依次为 5、10、60 和 240 分钟，避免长周期图表返回过多点。
- 最新实测：24 小时为 1,724 个样本/4 台，7 天为 8,440 个样本/6 台，30 天为 58,703 个样本/8 台；对应 WiFi 查询约 3.61、1.45、3.54 秒，完整 Dashboard API 的 7 天/30 天约 6.2/12.1 秒。以上计数和耗时属于易变事实，后续应实时复核。
- 当前覆盖原因已按三段窗口复核：24 小时纳入 AMB-01/03/04/08；7 天增加 AMB-02/07；30 天再增加 AMB-05/06。其余启用机器人在对应窗口内没有 `job_status = Running` 记录，并非 Web 隐藏；已提供只读核验入口 `75_read_only_explain_wifi_robot_coverage_by_range.sql`。
- 各目标点位比较已改为多系列折线图：目标 POI 为 X 轴、平均 RSSI 为 Y 轴，每台机器人使用独立颜色和线型；机器人通过复选下拉框多选，缺失的机器人-POI 组合保留为空档，不进行插值或补造。
- 验收时 ODS 最新事件已落后数据库时间约 47 分钟，因此页面正确显示“数据过期”；长周期数据可用不代表当前遥测已恢复新鲜。

## 15. 2026-07-30 WiFi 点位独立折线图

- “各目标点位的 WiFi 信号强度”已从多机器人共用横轴改为小多图：每台选中机器人独立一张折线图。
- 每张图只使用该机器人实际存在严格匹配样本的 `poi_target`，不再把其他机器人经过的点位放入横轴，因此不会因“未经过该点位”产生折线空档。
- 所有独立图统一使用 -90 至 -30 dBm 的 Y 轴范围，便于跨机器人目视比较；点位多时只在该机器人自己的图内横向滚动。
- 机器人复选下拉框继续控制显示哪些独立图。30 天范围浏览器验收时为 8 台机器人、8 张图；每张图的 X 轴标签数与该机器人有效点位数、标记数一致，页面无整体横向溢出且控制台无错误。数量属于易变事实，后续应随实时数据复核。

## 16. 2026-07-30 WiFi 最低值定位与透明诊断

- Running WiFi 查询新增只读最低值结果集，分别返回全局、每台机器人、每个目标点位和每个机器人-目标点位组合的最低负值 RSSI 原始记录；字段包含机器人、精确事件时间、关联任务目标点位和 RSSI。
- 新增 `src/wifi-minimum-diagnostic.js`，透明规则优先级依次为：RSSI 长期固定的数据质量风险、多车同点偏弱的点位覆盖风险、单车跨点偏弱的机器人侧风险、证据不足的未确认原因。规则不会仅凭单个最低值断言 AP、天线或网卡故障。
- Analysis Center 的“最低 RSSI”下方新增诊断卡，展示最低值、机器人、产生时间、关联目标点位、原因判断、判断依据、处理步骤、置信度、规则编号和版本；机器人/点位筛选会切换到对应范围的最低记录。
- 2026-07-30 只读验收时，24 小时最低值为 `-69 dBm`，来自 `AMB-08`，页面本地时间显示 `2026-07-30 15:34:17`，关联目标点位 `LM91`。LM91 当前只有 1 台机器人覆盖，规则 `WIFI_MINIMUM_CAUSE_UNRESOLVED` 以 LOW 置信度标记原因未确认，并要求同点跨车复测和无线控制器日志核查。该结果属于易变事实，后续应随实时数据复核。
- 已通过 18 项单元测试、真实 SQL/API 校验和桌面浏览器验收；页面无整体横向溢出和控制台错误。

## 17. 2026-07-30 Running WiFi 独立栏目

- 左侧第05栏已从 `Network Quality` 更名为“运行任务期间 WiFi 信号分析”，顶部页面标题和说明同步更新。
- 原第05页的 DWS小时 RSSI概览、旧 WiFi 趋势图、AP 风险表及对应前端渲染代码均已删除，不保留隐藏副本。
- 完整 Running WiFi 分析已从 Analysis Center 移至第05页，包含顶部时间范围同步、机器人/目标点位筛选、RSSI趋势、最低值透明诊断、处理措施和逐机器人点位独立折线图；Analysis Center 不再重复显示该模块。
- 浏览器验收确认第05页可正常渲染 1 张趋势图、最低值诊断和当前符合条件机器人的独立点位图；旧组件不存在、页面无整体横向溢出且控制台无错误。18 项单元测试继续通过。

## 18. 2026-07-30 Running WiFi 最低值诊断布局

- “最低值定位与原因判断”已从右侧分析结论栏移到左侧 RSSI 趋势折线图正下方，右侧不再保留重复诊断卡。
- 桌面端利用左栏宽度将最低值、机器人、产生时间和关联目标点位横向排列，并将“原因判断与判断依据”和“怎么解决”分为两列；窄屏自动恢复单列。
- 机器人和目标点位筛选仍会同步刷新最低值、时间、点位、原因、依据、解决步骤、置信度与透明规则。浏览器实测切换到 `AMB-01` 时规则正确更新为 `WIFI_RSSI_VALUE_STUCK`，恢复全部机器人后正常。
- 已通过代码语法检查、18 项单元测试和桌面浏览器验收；诊断卡仅渲染一份，位于折线图面板内，页面无整体横向溢出。

## 19. 2026-07-31 Web 新鲜度门禁调整

- Web 的非快照 DWS 新鲜度门禁已从 10 分钟统一调整为 30 分钟；运行配置、后端默认值、前端回退值、透明诊断文案、页面指标定义、接口说明和 Running WiFi 基准查询保持一致。
- 门禁同时检查源事件时间、DWS 装载时间和源到 DWS 的管道延迟；任一项超过 30 分钟仍判定为超时。门限变化只改变 Web 是否接受数据为“当前值”，不会刷新或修复数据库上游数据。
- 运行态 API 已确认 `staleMinutes=30`、`freshnessTimeoutMinutes=30`、`freshness_timeout_minutes=30`。验收时数据库当前时间相对最新源事件约 44 分钟、相对最新 DWS 装载约 39 分钟，因此 19 台启用机器人仍正确显示 `DWS refresh timeout`。
- 已重启本地 Web（`http://127.0.0.1:3080/`），通过代码语法检查、18 项单元测试、实时 API 和浏览器验收；页面显示 30 分钟门禁及对应维修步骤，浏览器控制台无错误。

## 20. 2026-07-31 ODS/DWD/DWS 全层增量追赶

- 用户确认生产链路必须持续执行 `dbo -> ODS -> DWD -> DWS`，不能依靠放宽 Web 门限掩盖分层停更。
- 已执行正式授权入口 `56_run_authorized_all_layer_sync_and_verify.sql`，总耗时 298 秒并返回 `SUCCESS`。四张核心 ODS 历史表分别新增约 8,830、8,834、8,782、8,787 行；DWD 批次 40 和 DWS 批次 389 均为 `SUCCESS`。
- DWS 批次 389 已完成电量小时、状态小时、WiFi 小时、任务日和队列日聚合；同步后 Web API 的 DWS 装载年龄约 2 分钟、源事件年龄约 5 分钟，8 台机器人通过 30 分钟当前门禁，11 台仍因各自源事件较旧或事件到装载延迟过大而超时。
- 已新增无 `GO` 分隔符的 Node 兼容监控入口 `77_run_etl_freshness_check_node.sql` 并成功写入最新检查。12 条 `dbo -> ODS -> DWD -> DWS` 检查全部为 `SUCCESS`：DWD 四条水位差为 0，DWS 四条水位差为 0；ODS 因 dbo 持续写入保留约 1,173 至 1,241 个 ID 尾差，但事件时间仅落后 6 至 7 分钟，处于 10 分钟 ODS 阈值内。
- 自动持续刷新仍被 SQL Server Agent 权限阻塞：当前登录不是 `sysadmin`，也不是 `SQLAgentUserRole`、`SQLAgentReaderRole` 或 `SQLAgentOperatorRole` 成员，并且读取 `msdb.dbo.sysjobs` 返回错误 229。未获得 DBA 授权前只能手动执行总控，不能把一次成功同步表述为已具备持续调度。

## 21. 2026-07-31 逐车源端停更边界复核

- 新增只读入口 `78_read_only_explain_stale_robot_sources.sql`，按 `dbo.MA_AMR.id = robot_*_history.amr_id` 比较 dbo 最新状态、电池、WiFi、任务时间与非快照 DWS 最新事件时间，不通过机器人编号猜测关联。
- 最新复核修正了“11 台源数据很旧”的笼统说法：10 台在 dbo 源表中确实长期停更；`AMB-07` 的 dbo 状态、电池、WiFi和任务当前仍在更新，只是新行产生于上一轮增量批次结束之后，属于仓库尚未追上。
- 10 台源端停更机器人为 `AMR_01`、`AMR_02`、`AMR_05`、`AMR_06`、`AMR_07`、`AMR_08`、`AMR_10`、`AMB-04`、`AMB-09`、`AMB-10`。它们的状态、电池和 WiFi 最后时间完全相同或处于同一采集时刻；除 `AMB-09/10` 没有任务历史外，其余机器人的任务时间也在同一时刻停止。
- 同期另有 9 台机器人继续向相同 dbo 历史表写入，因此数据库写入端和公共采集链路没有整体停止。现有证据把故障边界定位到逐车上报链路，但不足以在断电、机器人 WiFi/网络、机器人发布进程和网关逐车订阅/映射之间唯一归因；需要机器人现场状态、无线控制器关联记录和网关/采集器逐车日志。
- `AMR_01` 主数据状态为 `Test`，其余 9 台停更机器人的主数据状态为 `Avaliable` 且仍标记启用。主数据状态不能证明机器人当前通电或联网，应由运维确认这些设备是否仍属于生产运行范围。
