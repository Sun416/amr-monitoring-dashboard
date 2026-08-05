# IOT2020 AMR 项目交接说明（给 Claude）

交接日期：2026-08-05（Asia/Bangkok）

这是一份当前工作区交接说明。请把根目录当前文件视为“工作区快照”，不要把旧导出目录或旧压缩包当作正式版本。

## 1. 先读顺序

1. `AGENTS.md`：SQL Server、安全和变更规则。
2. `PROJECT_STATUS_COMPACT.md`：已确认的架构、正式入口、禁止误用和历史状态。
3. 本文件：本次交接的当前工作区说明。
4. `PROJECT_CONTEXT_INTEGRATED.md`：跨模块决策、分析口径和历史背景。
5. `amr-monitoring-web/README.md`：Web 安装、权限、接口和运行方式。
6. 执行只读检查前先检查工作区状态，并重新验证数据库中的行数、时间、水位、批次和权限。

## 2. 项目目标与架构

目标是维护 Microsoft SQL Server `IOT2020` 的 AMR 数据仓库和分析监控 Web：

```text
生产源 dbo
   -> ODS 镜像与水位线
   -> DWD 维度/事实/事件审计
   -> DWS 小时/日主题汇总
   -> Node.js API
   -> amr-monitoring-web
```

ADS 尚未建设。Web 浏览器不直接连接 SQL Server；Web 仅使用只读查询。报表历史分析与低延迟数字孪生是两条边界不同的链路：后续可以用 MQTT/WebSocket 提供实时状态，但不能用 CDC 替代 ODS/DWD/DWS 的转换、校验、水位线和重试。

机器人身份必须使用：

```text
dbo.MA_AMR.id = robot_*_history.amr_id
显示名称来自 dbo.MA_AMR.name
```

禁止按名称编号、序号或相近时间猜测关联。

## 3. 已确定的生产安全边界

- `AMR_03` 对应 `dbo.MA_AMR.id = 6`，当前 `is_active='N'`；没有用户明确确认时不得启用。
- `46_install_dws_operational_snapshot_v2.sql` 是当前快照生产版本；`34_install_fast_current_snapshot_sync.sql` 仅是 legacy 参考，不能覆盖 v2。
- Web 当前不读取 `DWS.dws_robot_current_snapshot`，也不执行当前快照同步；`POST /api/sync/current` 固定返回 `410 SNAPSHOT_SYNC_DISABLED`。
- Web 当前车队状态、电量和 WiFi 概览读取非快照 DWS 小时汇总，并使用 30 分钟新鲜度门禁。源事件时间、DWS 装载时间或事件到装载延迟任一超时，就隐藏旧值并显示超时，不把超时猜成断电、断网或机器人故障。
- 当前实时位置、机器人状态和机器人上报作业名需要 `64_install_dws_robot_live_state_view.sql` 创建的只读视图；该脚本此前只完成生成/预演，未得到上线授权前不要执行。
- 非平凡 `UPDATE`/`DELETE`、大批量回补、DDL、Agent 安装和权限变更都必须先做同条件只读预览、说明影响并保留验证/恢复方案。
- 旧审计 CSV、历史导出和数据库快照只可作为证据快照，不能当作当前事实。

## 4. 已完成的核心能力

### 数据仓库

- ODS 镜像、`ODS.etl_watermark` 和 ID/时间增量入口已建立。
- DWD 核心维度、事实、增量过程、任务类型/Mode enrichment 和统一事件审计契约已建立。
- DWS 电量小时、状态小时、WiFi 小时、任务日、队列日和机器人当前快照结构已建立。
- 新鲜度记录、视图和检查过程已安装；SQL Server Agent 自动调度仍受 `msdb` 权限限制，不能把一次手动成功同步说成已自动化。

### Web

`amr-monitoring-web/` 是当前正式源码，当前界面为英文、深色导航 + 浅色分析工作区。已经包含：

- 透明规则分析：现象、原因、证据、置信度、维修动作、备选原因和规则版本。
- DWS 新鲜度状态、车队状态、任务/队列/电量分析、数据质量和批次检查。
- Running 任务期间 WiFi 长周期分析、最低 RSSI 透明诊断和按机器人拆分的点位折线图。
- 任务分析中的空闲时间、任务状态、Calling Box/assigned-task 小时排行榜和证据缺口提示。
- 前端导出 CSV/JSON；后端为 Node.js + Express + `mssql`。

默认运行：

```powershell
cd amr-monitoring-web
Copy-Item .env.example .env
# 编辑 .env，填写真实 SQL Server 连接；不要提交 .env
npm.cmd install
npm.cmd run check
npm.cmd test
npm.cmd start
```

默认地址：`http://127.0.0.1:3080/`。未实现身份认证、HTTPS 和操作审计前，不要改为对工厂网络或互联网开放。

## 5. 2026-08-03 至 2026-08-05 的当前进行中内容

这些内容存在于当前工作区，但尚未全部提交到 Git，也不能仅凭文件存在判断已经在目标数据库成功执行：

- `80`–`83`、`97`–`101`：Task Analytics 的数据就绪检查、DWS 小时任务表、ODS 源重conciliation、DWD 窗口刷新、Calling Box/assigned-task 小时排行榜。
- `102`、`108`–`110`：任务状态异常和 `data_unavailable` 的只读诊断、窗口预览、索引检查。
- `103`–`106`：DWD 电池事实的机器人身份回补预览、分批修复、验证和按机器人管道缺口检查。
- `107`：授权的历史 ODS -> DWD -> DWS 刷新与验证入口，不刷新旧当前快照。
- `111`–`113`：队列/任务时间戳的时区语义审计，以及将 DWD 派生时间规范为泰国本地墙上时间的安装脚本。
- `114`：针对被客户端 120 秒限制中断的 DWS batch 402 的定向审计修复；执行前必须确认脚本要求的唯一 `RUNNING` 行和无活动锁条件。
- 根仓库中 `02`、`08`、`22`、`35` 等核心脚本和状态/计划文档也有未提交修改；Web 子仓库有大范围未提交 UI、API、SQL、规则和测试改动。

处理上述脚本时，先读脚本头部的 scope、preview、batch、transaction 和 validation 说明；优先按“预览 -> 执行 -> 验证”顺序，不要按文件编号盲目全量执行。

## 6. 当前数据事实与阻塞（可能随实时数据变化）

- 历史状态文档最后一轮已知口径为启用机器人 19 台；`AMR_03` 不计入启用数。
- 2026-07-31 的边界复核认为 10 台机器人在 dbo 源端长期停更，另有机器人仍在写入；这只能把问题边界缩小到逐车上报链路，不能仅凭数据库证据判定断电、WiFi、发布进程或网关订阅映射的唯一根因。
- SQL Server Agent / `msdb` 权限是自动化的主要阻塞；在得到 DBA 授权前只能手动执行总控并重新验证。
- `DWS.v_robot_live_state` 尚未确认上线；当前任务 ID/业务状态仍需业务确认 `TA_AMR.id`、`job_id`、`subjob_id` 和状态字段的展示口径。
- 调度候选评分、资格、拒绝原因和维护确认闭环尚未形成可靠历史证据；不要从最终指派结果反推评分或“最优调度”。

## 7. 当前工作区与版本边界

- 根仓库已提交基线：`4a02d09`；其更早基线为 `ed55c12`、`a2c414f`。
- Web 子仓库已提交基线：`29ea933`，远端为 `https://github.com/Sun416/amr-monitoring-dashboard.git`。
- 本次交接时根仓库和 Web 子仓库均有未提交修改；交接包保留工作区文件，但不包含 `.git` 历史。恢复到 Git 工作区后应重新检查 `git status` 和差异。
- `DeepSeek-AMR-Project-2026-07-24/`、`AMR-Monitoring-Web-Source-2026-07-23/` 是历史快照，不是当前 canonical 源码。
- `projects/` 是周报/可视化源项目；`audit_results/` 和 `outputs/` 是历史分析证据/报告资产，时间可能过期。

## 8. 交接包的范围

压缩包保留当前根目录 SQL、文档、Web 源码、分析资产、周报源文件和历史快照，方便继续开发；同时排除：

- `.git/`、Web 子仓库 `.git/`、`.codex/`、`.agents/`；
- `node_modules/` 和临时 `.pptx-build-*`；
- 本机真实 `.env`、数据库密码、日志和临时连接信息；
- 已存在的旧 ZIP、All-In-One 重复快照和其他可由源文件重新生成的重复包。

因此 Claude 收到的是可审阅、可继续开发的源码交接包，而不是可直接连接生产数据库的凭据包。收到后需要重新创建 `amr-monitoring-web/.env`，并从真实数据库只读复核所有易变事实。

## 9. 继续工作的推荐顺序

1. 先读取本文件、`AGENTS.md`、`PROJECT_STATUS_COMPACT.md`、`PROJECT_CONTEXT_INTEGRATED.md`。
2. 运行 `git status`；保护当前未提交改动，不要 reset/checkout 覆盖它们。
3. 在 `IOT2020` 中先执行只读门禁和水位检查，确认当前数据库、源事件时间、DWS 批次、Agent 权限和 Task Analytics 对象。
4. 对 111–114 相关时区与中断批次工作逐个完成预览、授权执行和验证，记录批次与影响范围。
5. 再运行 Web `npm.cmd run check`、`npm.cmd test`，最后在本机浏览器验证 `/api/health` 和 `/api/dashboard`。
6. 只有数据新鲜度和证据闭环稳定后，再处理 Agent、CDC/Flink CDC、正式内网部署或 ADS。

## 10. 重要提醒

不要因为页面能渲染、过程返回 `SUCCESS` 或 DWS 有行，就直接下结论说机器人在线、数据实时、调度最优或故障根因已确定。这个项目的核心设计原则是：每个结论都必须带来源、时间、新鲜度、覆盖范围和证据等级。
