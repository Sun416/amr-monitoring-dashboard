# IOT2020 AMR 项目交接说明（给 DeepSeek）

导出日期：2026-07-24  
导出类型：源码与分析资料快照，不包含数据库数据、Git 历史或真实连接凭据。

## 先读顺序

1. `AGENTS.md`：SQL Server 开发、安全和回答规范。
2. `PROJECT_STATUS_COMPACT.md`：项目当前状态、正式入口、已知问题和禁止事项。
3. 本文件：导出包范围与项目地图。
4. `01_FILE_MAP.md`：SQL 脚本分类和推荐阅读顺序。
5. `amr-monitoring-web/README.md`：Web 安装、配置、权限和运行方法。

## 项目目标

项目面向 Microsoft SQL Server 数据库 `IOT2020`，用于 AMR 机器人数据仓库与监控 Web：

```text
历史分析：dbo -> ODS -> DWD -> DWS
监控读取：浏览器 -> Node.js API -> DWS
快速状态：dbo 最新遥测 -> DWS.sp_refresh_robot_current_snapshot_fast -> Web
```

ADS 尚未建设，当前 Web 不依赖 ADS。CDC / Flink CDC 属于后续低延迟方案，不替代 ODS、DWD、DWS 的清洗、转换、水位线、重试和质量校验。

## 最重要的业务和安全边界

- 机器人关联键是 `dbo.MA_AMR.id = robot_*_history.amr_id`。
- 机器人名称来自 `dbo.MA_AMR.name`，不得按编号、名称或相近时间猜测关联。
- `AMR_03` 对应 `dbo.MA_AMR.id = 6`，当前为非启用状态。未经用户明确确认，不得改为启用。
- 生产当前快照使用 `46_install_dws_operational_snapshot_v2.sql`。
- `34_install_fast_current_snapshot_sync.sql` 是 legacy，只能用于审计或回退参考，不得覆盖 46 号脚本安装的过程。
- 04、06、10、13、24、29、43、44 等修复或回补脚本不是日常同步入口。
- 所有易变化事实（在线数、行数、最新时间、批次状态、权限）必须在真实数据库中重新只读验证。
- 不要直接执行写入、回补、删除、DROP、Agent 安装或权限修改；先解释影响并提供同条件预览和验证方案。

## 正式入口

- ODS 增量：`21_run_ods_id_time_incremental.sql`
- DWD 增量与验证：`22_run_dwd_incremental_and_verify.sql`
- DWS 建表：`25_create_dws_core_tables.sql`
- DWS 历史聚合：`26_load_dws_core_upsert.sql`
- DWS 校验：`27_check_dws_core.sql`
- 全层手动同步：`39_run_all_layers_manual_sync.sql`
- 生产快速快照安装：`46_install_dws_operational_snapshot_v2.sql`
- ETL 新鲜度监控安装：`47_install_etl_freshness_monitor.sql`
- 新鲜度手动检查：`48_run_etl_freshness_check.sql`
- SQL Server Agent 新鲜度任务草案：`49_create_sql_server_agent_freshness_job.sql`

## Web 项目

`amr-monitoring-web/` 是当前 Web 源码快照，包含截至导出时尚未提交到 Git 的最新修改。

- Node.js 20+
- Express 5
- `mssql`
- 默认地址：`http://127.0.0.1:3080/`
- 数据源：DWS
- 当前界面：英文、深色工业指挥中心风格

真实 `.env` 已排除，只保留 `.env.example`。请勿将服务绑定到 `0.0.0.0` 或暴露到工厂网络/互联网，除非先补充身份认证、HTTPS、审计和权限控制。

## 导出包包含

- 根目录 01–49 号 SQL 脚本及其他 SQL 工具脚本。
- 当前项目状态、下一步和开发规范。
- 当前 Web 源码、`package.json`、锁文件和配置模板。
- `audit_results/`：历史只读审计 CSV，可能已经过期，只能作为证据快照。
- `outputs/`：分析 SQL、构建脚本和轻量文本/JSON 源资料。
- `.codex/agents/sql-reviewer.toml`：只读 SQL 审查规则。
- `FILE_MANIFEST_SHA256.csv`：除清单自身外，所有导出文件的路径、大小和 SHA-256。

## 导出包不包含

- `.git/` 与 Web 子仓库 `.git/`
- `node_modules/`
- 真实 `.env` 和数据库密码
- 运行日志与 DataGrip 临时文本
- 旧 ZIP、旧 Web 重复副本
- PPTX、PNG 等可再生二进制产物
- SQL Server 数据库备份或真实业务数据导出

## 对 DeepSeek 的工作要求

默认仅做静态分析。若需要修改：

1. 先说明要改哪些文件、原因和影响。
2. SQL 写操作必须先给只读预览。
3. 不得把旧审计 CSV 当作当前数据库事实。
4. 不得用 34 号脚本替代 46 号生产快照。
5. 不得擅自启用 `AMR_03`。
6. 对非平凡 SQL，输出应包含：SQL、执行逻辑、风险、索引建议、执行前验证。
