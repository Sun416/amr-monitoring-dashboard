# 可直接粘贴给 DeepSeek

请先完整阅读以下文件，不要立即修改代码：

1. `AGENTS.md`
2. `PROJECT_STATUS_COMPACT.md`
3. `00_README_FOR_DEEPSEEK.md`
4. `01_FILE_MAP.md`
5. `amr-monitoring-web/README.md`

这是 Microsoft SQL Server `IOT2020` 的 AMR 数据仓库与监控 Web 项目。请先输出：

1. 你理解的系统架构和数据流。
2. ODS、DWD、DWS 与 Web 的职责边界。
3. 日常正式入口、历史修复脚本、legacy 脚本的区分。
4. 你识别到的五个最高风险点。
5. 在没有连接真实数据库的情况下，哪些结论只能视为静态推断。

必须遵守：

- 默认只做静态和只读分析。
- 易变化事实必须在真实库中重新验证。
- 机器人必须用 `MA_AMR.id = *_history.amr_id` 关联。
- `46_install_dws_operational_snapshot_v2.sql` 是生产快照安装脚本。
- `34_install_fast_current_snapshot_sync.sql` 是 legacy，不得覆盖 46 号脚本。
- 未经明确确认不得启用 `AMR_03`（`MA_AMR.id=6`）。
- 不得直接执行 DROP、DELETE、UPDATE、大规模回补、权限修改或 SQL Server Agent 安装。
- 若提出 SQL 修改，先给相同条件的只读预览，并说明执行逻辑、风险、索引建议和验证方法。

完成项目理解后停下来，等待我给出具体任务。

