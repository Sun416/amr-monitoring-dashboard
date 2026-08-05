# IOT2020 AMR 项目全对话整合

更新时间：2026-07-28

## 0. 文档定位

本文件整合本项目在 Codex 中的历史对话、已落地文件和当前决策，用于回答“项目为什么这样设计、已经做过什么、哪些结论不能再误用”。

- 日常继续工作：先读 `AGENTS.md` 和 `PROJECT_STATUS_COMPACT.md`。
- 需要理解完整项目、制定跨模块方案或追查历史决策：再读本文件。
- 需要调查某次旧故障的精确命令、报错和执行输出：最后才回看原对话。
- 行数、时间、在线机器人、批次、权限和数据库连接均为易变事实，必须实时只读复核。

## 1. 项目最终目标

项目不是单纯做一个“实时数字大屏”，而是建设一套可追溯、可解释、可持续运行的 AMR 数据分析系统：

1. 从 `IOT2020` 中识别并接入 Robot/AMR 业务数据。
2. 建立 `dbo -> ODS -> DWD -> DWS` 历史分析链路。
3. 用 Web 将状态、任务、电量、WiFi、位置和数据质量统一呈现。
4. 从“显示异常”升级到“解释异常现象、列出证据、给出置信度和维护动作”。
5. 保存任务、调度、故障和维修证据，使未来能够复盘“为什么这样调度、为什么断连、怎样修复”。
6. 把报表分析与低延迟数字孪生分开，避免一条数据库链路同时承担两个不同延迟目标。

## 2. 项目演进主线

### 阶段 A：数据库盘点与分层方向

- 目标数据库确定为 SQL Server `IOT2020`。
- 初期用“表名含 `robot` 或 `AMR`”筛选项目候选表，历史盘点曾得到 47 张源表；该数字属于历史结果，不应当作当前实时数量。
- 确立同库分 Schema 的数据仓库结构：
  - `dbo`：源业务表，不修改。
  - `ODS`：源表镜像与装载元数据。
  - `DWD`：清洗后的维度、事实、事件和快照。
  - `DWS`：当前快照、小时/日主题汇总和监控服务数据。
  - `ADS`：仅在明确 Power BI 或专题分析交付出现后建设。
- 早期“自动生成 ODS 建表 SQL”只是生成器，后来项目已形成正式 ODS 结构、装载方式和水位管理；不能再把早期生成器当作日常同步入口。

### 阶段 B：ODS、DWD、DWS 建设与数据修复

- ODS 已建立镜像表、装载元数据和 `ODS.etl_watermark`。
- DWD 已建立机器人维度、状态/电池/WiFi/任务等核心事实，以及批次与水位控制。
- 修复过的重点问题包括：
  - `ODS.robot_wifi_history.wifi_signal_level` 到 `DWD.fact_robot_wifi.rssi` 的映射。
  - WiFi 冗余字段和下游依赖。
  - 任务事实历史映射、空值和重复问题。
  - `job_type_code`、`robot_mode_id`、`robot_mode_detail` 的增量与历史补充。
- DWS 已建立电量小时、状态小时、WiFi 小时、任务日、队列日和机器人当前快照。
- 正式生产快照为 `DWS.sp_refresh_robot_current_snapshot_fast`，安装脚本是 `46_install_dws_operational_snapshot_v2.sql`。
- `34_install_fast_current_snapshot_sync.sql` 已是 legacy，只保留回退和审计参考。

### 阶段 C：增量同步、数据质量与运维

- 正式手动入口已经分开：
  - ODS 增量：`21_run_ods_id_time_incremental.sql`
  - DWD 增量：`22_run_dwd_incremental_and_verify.sql`
  - 全层手动同步：`39_run_all_layers_manual_sync.sql`
  - 快速快照验证：`37_run_fast_current_snapshot_and_verify.sql`
  - 历史分析验证：`38_run_historical_analysis_and_verify.sql`
- 2026-07-22 增加了 ETL 新鲜度体系：
  - `DWS.etl_freshness_log`
  - `DWS.v_etl_freshness_latest`
  - `DWS.sp_check_etl_freshness`
  - 安装/检查脚本：47、48 号
- 曾发现 12 条链路全部 `STALE`，dbo 到 ODS 历史表落后约 55 万个 ID；手动全层同步约 6 分 15 秒后恢复为 `SUCCESS`。
- `estimated_rows_behind` 是最大 ID 与水位线之差，不是精确缺失行数。
- SQL Server Agent 拆分任务和新鲜度任务已经有草案，但 `msdb`/Agent 角色权限仍是关键外部依赖。
- CDC / Flink CDC 被明确排在 Agent 作业稳定之后；CDC 负责更完整、更低延迟的变更捕获，不替代 ODS/DWD/DWS 的清洗、转换、水位、幂等、校验和重试。

### 阶段 D：Web 监控面板

- Web 技术链路：

```text
Browser
  -> Node.js / Express API
  -> dashboard-service / analysis-engine
  -> SQL Server IOT2020 DWS + 只读证据表
```

- 当前项目目录：`amr-monitoring-web`。
- 当前正式本机地址：`http://127.0.0.1:3080/`。
- 页面已从“所有数字堆在一页”演进为目录式、分析优先的 Web：
  - 运营总览/分析中心
  - 运行状态
  - 任务分析
  - 能源分析
  - 网络质量
  - 告警原因
  - 单车 Robot Profile
  - 数据质量
- 已支持：
  - 固定时间窗口。
  - `ALL / AMR / AMB` 类型筛选。
  - 单车详情和 Robot ID 选择。
  - 状态、电量、任务、WiFi、位置、数据时间和告警证据。
  - 分板块 CSV 和全量 JSON 下载。
  - 60 秒自动刷新及手动同步当前快照。
- 当前界面为英文；数据库原始业务值不翻译。
- 分享封面 `public/og.png` 和分享元数据已经加入；它们不改变运行架构。

### 阶段 E：透明规则分析

- Web 的重心已经从“监控”转向“分析”。
- 当前透明规则版本为 `2026.07.5`。
- 核心输出包括：
  - 现象。
  - 最可能原因。
  - 规则和证据。
  - 高/中/低置信度。
  - 维护动作。
  - 备选原因。
  - 当前不能计算的指标。
- 断连规则分别比较状态、WiFi、电池、充电和错误时间戳，不用一条较新的数据掩盖另一条来源已停止。
- 当状态、WiFi、电池三路在两分钟内同时停止时，规则标记 `SOURCE_TELEMETRY_ALL_TOPICS_STOPPED`。
- 该规则只能证明问题在 Web/DWS 上游，不能在缺少 AP、机器人电源、发布器和采集器日志时强行区分：
  - 机器人断电。
  - WiFi 脱网。
  - 机器人发布进程停止。
  - 中央采集服务停止或漏采。
- `robot_emer_status=0/1` 不再直接等同于设备故障。
- `RSSI=0` 只有结合 AP、扫描网络、WiFi 时间和其他证据后才可解释，不能单独判为无线断连。
- `ping` 结果不能单独判定机器人在线或离线。

### 阶段 F：统一事件与审计证据

- 对话中识别出的最大缺口是“只保存结果，没有保存决策与故障证据链”。
- 已建立：
  - `DWD.fact_robot_operation_event`
  - `DWD.fact_dispatch_decision_candidate`
  - `DWD.fact_robot_incident`
  - `DWD.fact_robot_incident_evidence`
  - `DWD.robot_event_watermark`
  - `DWS.v_robot_event_audit_coverage`
- 安装、预览、装载、验证入口分别为 50、51、52、53 号脚本。
- `DWD.sp_load_robot_operation_event_incremental` 使用 ODS `ods_row_id` 水位、每来源独立事务和应用锁。
- 最后一次记录的有界首次装载形成 15,437 条可追溯事件；该数字为历史验证快照，后续需实时复核。
- 当前审计能力仍为 `PARTIAL`：
  - 调度候选、资格、得分、选择和拒绝原因契约存在，但上游历史没有保存候选评分。
  - 禁止用最终指派结果反推或伪造候选评分。
  - 故障与证据表已建立，但维护确认、维修动作和关闭结果尚未形成稳定写入闭环。

### 阶段 G：图表化与信息层级

- 参考过 `amr-fleet-management-main.zip` 和 `amr-gateway-service-main.zip` 的呈现方式。
- 只借鉴 KPI、趋势、构成、连接摘要、对象卡片和“图表在前、明细在后”的层级，不复制其数据模型或无数据支撑的指标。
- Analysis Center 当前顺序：

```text
车队结论
  -> 四项关键判断
  -> 原因构成 / 任务分布
  -> 准时率 / 排队等待 / 电量覆盖
  -> 维护动作
  -> 可展开的逐车证据和明细
```

- 重复诊断按“原因 + 规则”聚合，避免同一原因生成大量重复卡片。
- 当前数据无法支持的里程、堵车根因、上下料时长和虚构调度效率不进入正式结论。

## 3. 当前架构决策

### 3.1 报表与数字孪生分开

```text
历史分析：
dbo -> ODS -> DWD -> DWS -> Web / Power BI / 报表

低延迟数字孪生：
Robot / Dispatch -> MQTT -> Realtime State Service
                               -> WebSocket -> Twin UI
                               -> Current-state Cache
                               -> Async history write
```

- Power BI、历史分析和管理报表走仓库分层。
- 机器人实时位置和状态不应依赖大表轮询或 Power BI。
- 浏览器不直接暴露 MQTT Broker 或 SQL Server 账号。

### 3.2 一主题一共享表，不按机器人拆表

- 同一主题使用共享事实表，通过 `robot_id`/`amr_id` 区分机器人。
- 优先优化方式：
  - `(robot_id, sample_time)` 索引。
  - 时间分区。
  - 热冷数据分离。
  - 小时/日聚合。
  - 归档。
- 不采用 `battery_AMR01`、`wifi_AMR02` 等每机器人一张物理表的设计。

### 3.3 机器人身份关联

- 主关联键：`dbo.MA_AMR.id = robot_*_history.amr_id`。
- 展示名：`dbo.MA_AMR.name`。
- 禁止通过名称编号、序号或相近时间猜测关联。
- `AMR_03` 为 `MA_AMR.id=6`，当前业务状态是 `is_active='N'`；未经用户明确确认不得启用。

## 4. 当前分析口径

### 4.1 任务分析

- 准时率与预计时间准确率必须分开。
- 任务总周期应拆为：

```text
排队
+ 调度等待
+ 空驶到取货点
+ 上料等待
+ 载货行驶
+ 交通/阻塞
+ 下料等待
+ WiFi/故障中断
```

- 当前能计算的主要内容：
  - 有开始/结束时间的任务或子任务时长。
  - 基于 `AMR_Queue.enqueued_at -> TA_AMR.start_time` 的推导排队等待。
  - 配置时限参考子集的准时率。
  - 按机器人和类型的任务分配集中度。
- 当前不能可靠计算：
  - 完整路线拥堵原因。
  - 上下料时长。
  - 任务累计里程。
  - 调度是否为当时最优选择。
- `AMR_Subjob_Analyze.limit` 的业务单位仍需确认，未确认前只能作为“时限参考子集”。

### 4.2 利用率与车辆数量

- 不能只用 Idle 数量判断“车辆太多”。
- 至少需要联合：
  - 工作/任务占用时间。
  - 车辆可用时间。
  - 任务积压。
  - P90 排队时间。
  - 充电和故障时间。
  - 任务需求与班次。
- “每天工作比例 >70%”和“任务准时率 >90%”目前是业务目标草案，不是数据库已经确认的正式 KPI。

### 4.3 电池

- “电量高于 60% 的时间占比”按相邻采样的时间区间加权，不按采样行数直接计数。
- 超过允许断档的区间不计入有效分母，并显示窗口覆盖率。
- 要判断电池硬件问题、充电效率低或充电策略不合理，还需要充电会话、电压/电流/功率、等待和任务能耗证据。

### 4.4 数据时间

- `Latest Data Time` 是状态、电池、WiFi 等来源中最新的数据时间，不等于“同步过程执行时间”。
- “Recently Online”是相对最新源数据锚点的分析口径，不等于严格现实时间在线。
- 如果上游历史表停更，即使 DWS 同步成功，也不能把旧数据包装为实时在线。

## 5. 当前完成状态与正式入口

| 模块 | 当前状态 | 正式入口 |
|---|---|---|
| ODS | 已建立镜像、元数据和增量水位 | `21_run_ods_id_time_incremental.sql` |
| DWD | 已建立核心维度/事实/增量过程 | `DWD.sp_load_dwd_all_incremental`、`22_run_dwd_incremental_and_verify.sql` |
| DWS 历史 | 已建立核心小时/日主题汇总 | `25_create_dws_core_tables.sql`、`26_load_dws_core_upsert.sql` |
| DWS 当前快照 | v2 为正式生产版本 | `46_install_dws_operational_snapshot_v2.sql` |
| 全层手动同步 | 可用 | `39_run_all_layers_manual_sync.sql` |
| 新鲜度监控 | 已安装，Agent 自动执行待权限 | 47、48、49 号脚本 |
| 统一事件审计 | 契约和增量已安装，闭环不完整 | 50、51、52、53 号脚本 |
| Web | 本机运行、英文、分析优先 | `amr-monitoring-web/start.cmd` 或 `npm.cmd start` |
| Git | 根仓库与 Web 子仓库已有基线 | 根 `4a02d09`，Web `29ea933` 为最后已提交基线 |

## 6. 当前未完成与阻塞

### P0：数据与运行可信度

1. 恢复并持续验证 `dbo.robot_*_history` 上游遥测写入。
2. 用 AP 控制器、机器人电源、发布器和采集器日志确认多路遥测停止的真实根因。
3. 获得 SQL Server Agent / `msdb` 所需角色，安装并验证快速快照、历史同步和新鲜度作业。
4. 确认作业在连续运行、失败重试、并发和数据库增长下稳定。

### P1：分析证据闭环

1. 在调度发生时写入候选机器人、资格、距离/SOC/负载、评分、选择和拒绝原因。
2. 建立“诊断产生 -> 故障事件 -> 人工确认 -> 维修动作 -> 恢复验证 -> 关闭”的证据写入流程。
3. 补路线段、到站、上料开始/结束、下料开始/结束、离站和任务里程数据。
4. 由业务确认 `limit` 单位、班次边界、准时率目标、工作率目标和机器人可调度资格。

### P2：低延迟与正式部署

1. Agent 稳定后再设计 SQL Server CDC / Flink CDC。
2. 正式内网部署前增加：
   - 长期运行的公司服务器。
   - 固定内网地址或内网域名。
   - 用户认证和角色授权。
   - HTTPS。
   - 请求与同步操作审计。
   - 服务自动启动和失败重启。
3. 当前 README 的正式安全基线仍是仅监听 `127.0.0.1`；历史对话中测试过局域网地址，不代表当前允许直接暴露。
4. GitHub Pages、纯静态 HTML 或 Sites 无法直接承载依赖内网 SQL Server 的实时版；可另做脱敏快照演示版。

### P3：后续分析交付

- 只有在出现明确 Power BI、周报、专题分析或稳定消费契约后，再按指标建设 ADS。
- 报表源文件应保留可编辑版本，并从源文件重新生成 PPT/PDF/HTML。

## 7. 禁止事项与历史误区

- 不得用 34 号 legacy 快照覆盖 46 号 v2。
- 不得把 04、06、10、13、24、29、43、44 等回补/修复脚本当日常入口。
- 不得把存储过程执行成功等同于数据新鲜。
- 不得用 `AMR_Currentdata` 的旧 9 行代表完整车队。
- 不得只用 RSSI、ping、主数据状态或单一时间戳判定在线/离线。
- 不得在无候选评分源数据时声称调度最优或反推评分。
- 不得在缺少路线和站点事件时把慢任务归因为堵车或上下料。
- 不得把采样行比例当作时间占比。
- 不得未经确认启用 `AMR_03`。
- 不得把 GitHub Pages、静态 HTML 或前端重写误认为可以替代实时 Node.js API 和数据库连接。
- 不得将 `.env`、数据库密码、日志或 `node_modules` 放入源码交付包。

## 8. 交付与项目资产

### Web 与源码

- 正式源码：`amr-monitoring-web`
- GitHub 私有仓库：`Sun416/amr-monitoring-dashboard`
- 历史源码包：`AMR-Monitoring-Web-Source-2026-07-23.zip`
- 当前实时版本依赖内网 SQL Server，不能仅靠静态托管保持实时。

### 项目导出

- DeepSeek 目录导出：`DeepSeek-AMR-Project-2026-07-24`
- DeepSeek 全量文本：`DeepSeek-AMR-Project-2026-07-24-All-In-One.txt`
- 导出包排除了 `.env`、真实密码、`.git`、`node_modules` 和日志。

### 周报

- 可编辑周报项目：`projects/amr_weekly_status_week31_ppt169_20260727`
- 当前可见的最新英文导出：
  `projects/amr_weekly_status_week31_ppt169_20260727/exports/amr_weekly_status_week31_20260727_102500.pptx`
- 根目录另保留早期中文导出：`AMR项目周报_Week31_2026-07-27.pptx`
- 本周工作主线已调整为：

```text
Carrying Out the Complete Data Analysis Process
1. Data Source Review
2. Data Modeling & Processing
3. Analysis & Validation
4. Visualization & Delivery
```

## 9. 原对话索引

| 对话 | Thread ID | 主要内容 |
|---|---|---|
| 迁移DBeaver数据对话 | `019ed8bc-a7fd-70a3-a60f-174e80e7ae01` | 数据盘点、ODS/DWD/DWS、修复、Web、同步、新鲜度、Git 基线 |
| Explain SQL Server Agent | `019efdd2-61a7-7741-a7f5-d7b1a483dbe8` | Agent 解释、WiFi RSSI 映射、字段删除、数据库网络连接 |
| 推荐 SQL 数据库 Agent | `019f3a8b-aa51-7d21-b959-bd1a1c346769` | `AGENTS.md`、SQL skill、只读审查 agent |
| 设计机器人历史数据指标 | `019f7e73-a8ac-7300-bf60-29ba491d9434` | Web 指标、页面重构、单车详情、下载、GitHub/内网部署 |
| 导出项目 | `019f9336-e7bf-72d1-9f8b-6db0a31a3e60` | DeepSeek 安全导出和提示词 |
| 总结项目并制作周报 | `019fa119-db2b-7c10-a523-4b24b224de1a` | 周报内容、PPT、英文版 |
| 查找网页开发技能与插件 | `019fa750-fb32-7cc1-a378-b880c5b8fb3f` | Web 能力、Figma、分享封面和响应式检查 |
| 规划AMR监控数据分析体系 | `019f8e54-6e57-75e3-83fc-865e2793a289` | 透明规则分析、统一审计、图表化和当前分析中心 |
| 整合项目全部对话 | `019fa7c7-f7de-7d23-b4fd-b918347e8ede` | 本整合文档 |

## 10. 后续工作的读取顺序

```text
1. AGENTS.md
2. PROJECT_STATUS_COMPACT.md
3. 若是跨模块规划或历史追溯，再读 PROJECT_CONTEXT_INTEGRATED.md
4. 检查 git status，保护未提交工作
5. 实时只读复核易变数据库事实
6. 再设计或执行具体改动
```
