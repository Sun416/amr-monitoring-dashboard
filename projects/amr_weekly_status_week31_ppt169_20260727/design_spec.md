# AMR 数据监控与分析项目周报 - Design Spec

## I. Project Information

| Item | Value |
| ---- | ----- |
| **Project Name** | AMR 数据监控与分析项目周报 |
| **Canvas Format** | PPT 16:9 (1280×720) |
| **Page Count** | 4 |
| **Design Style** | briefing × swiss-minimal，蓝白企业科技风 |
| **Target Audience** | 部门主管、Automation 团队及 AMR 项目相关人员 |
| **Use Case** | Week 31 周工作汇报，现场讲解并可会后阅读 |
| **Delivery Purpose** | balanced |
| **Content Strategy** | 保留现有事实与三段式汇报要求，重新组织成更清晰、适合口头汇报的四页结构；不把易变化的在线数和时间锚点写成长期结论 |
| **Created Date** | 2026-07-27 |

---

## II. Canvas Specification

| Property | Value |
| -------- | ----- |
| **Format** | PPT 16:9 |
| **Dimensions** | 1280×720 |
| **viewBox** | `0 0 1280 720` |
| **Margins** | 左右 56，上 44，下 36 |
| **Content Area** | 1168×640 |

---

## III. Visual Theme

### Theme Style

- **Mode**: briefing
- **Visual style**: swiss-minimal
- **Theme**: Light theme
- **Tone**: 专业、工程化、克制、易扫描

### Color Scheme

| Role | HEX | Purpose |
| ---- | --- | ------- |
| **Background** | `#F8FBFD` | 页面背景 |
| **Secondary bg** | `#EEF5F9` | 区域底色 |
| **Surface** | `#FFFFFF` | 表格、截图承载面 |
| **Primary** | `#0076A8` | 标题、主链路、关键标签 |
| **Accent** | `#18A5D6` | 当前进度、活跃节点 |
| **Secondary accent** | `#75B9D6` | 次级模块、辅助线 |
| **Body text** | `#142434` | 正文 |
| **Secondary text** | `#526575` | 说明、注释 |
| **Tertiary text** | `#7D8E9A` | 页码、来源 |
| **Border/divider** | `#C8DAE4` | 分隔线、截图边框 |
| **Grid** | `#DCE8EF` | 架构辅助线 |
| **Success** | `#2E8B57` | 已完成 |
| **Warning** | `#D97706` | 依赖、待确认 |
| **Danger** | `#C43D3D` | 风险、阻塞 |

### Gradient Scheme

不使用渐变。采用纯色、直线和严格网格，保持 swiss-minimal 的平面纪律。

---

## IV. Typography System

### Font Plan

**Typography direction**: 单一无衬线体系，通过字号和字重建立层级。

| Role | Chinese | English | Fallback tail |
| ---- | ------- | ------- | ------------- |
| **Title** | Microsoft YaHei | Arial | sans-serif |
| **Body** | Microsoft YaHei | Arial | sans-serif |
| **Emphasis** | Microsoft YaHei | Arial | sans-serif |
| **Code** | — | Consolas, Courier New | monospace |

**Per-role font stacks**:

- Title: `"Microsoft YaHei", Arial, sans-serif`
- Body: `"Microsoft YaHei", Arial, sans-serif`
- Emphasis: `"Microsoft YaHei", Arial, sans-serif`
- Code: `Consolas, "Courier New", monospace`

### Font Size Hierarchy

| Role | Size | Weight |
| ---- | ---: | ------ |
| Cover title | 72 | Bold |
| Page title | 42 | Bold |
| Subtitle | 32 | SemiBold |
| Lead/core-message | 30 | Medium |
| Subheading | 28 | SemiBold |
| Body | 24 | Regular |
| Annotation/chart label | 18 | Regular |
| Footnote/page number | 16 | Regular |

---

## V. Layout Principles

### Page Structure

- **Header area**: 44–112，页码、章节标签和页面标题。
- **Content area**: 128–660，按 12 列隐形网格组织。
- **Footer area**: 676–704，仅保留更新时间或数据口径提示。

### Layout Pattern Library

- P01：负空间驱动 + 左对齐大标题 + 右侧垂直数据链路。
- P02：上部原始数据到 Web 的水平分层架构，下部双截图证据带。
- P03：左侧 2×2 进展清单，右侧大幅监控 Web 截图。
- P04：左侧纵向路线图，右侧依赖与风险栏。

### Spacing Specification

| Element | Current Project |
| ------- | --------------- |
| Safe margin | 56 |
| Content block gap | 32 |
| Icon-text gap | 12 |
| Card gap | 20 |
| Card padding | 24 |
| Card radius | 4 |

---

## VI. Icon Usage Specification

### Source

- **Built-in icon library**: `tabler-outline`
- **Stroke width**: 2
- **Usage method**: `<use data-icon="tabler-outline/icon-name" .../>`

### Recommended Icon List

| Purpose | Icon Path | Page |
| ------- | --------- | ---- |
| 数据库与源表 | `tabler-outline/database` | P01, P02 |
| 数据梳理 | `tabler-outline/database-search` | P03 |
| 服务与数据层 | `tabler-outline/server` | P02 |
| 数据活跃度 | `tabler-outline/activity` | P03 |
| AMR 设备 | `tabler-outline/robot` | P01, P02 |
| 监控分析 | `tabler-outline/chart-infographic` | P03 |
| 同步刷新 | `tabler-outline/refresh` | P03, P04 |
| WiFi 数据 | `tabler-outline/wifi` | P02 |
| 路线与计划 | `tabler-outline/route` | P04 |
| 完成事项 | `tabler-outline/calendar-check` | P03 |
| 调度频率 | `tabler-outline/clock` | P04 |
| 风险提示 | `tabler-outline/alert-triangle` | P04 |
| 流向箭头 | `tabler-outline/arrow-right` | P01, P02 |

---

## VII. Visualization Reference List

Catalog read: 71 templates

| Page | Template | Path | Summary-quote (verbatim from `charts_index.json`) | Usage |
| ---- | -------- | ---- | ------------------------------------------------- | ----- |
| P02 | layered_architecture | `templates/charts/layered_architecture.svg` | "Pick for 3-4 horizontal architecture layers (presentation/service/data), 2-4 module cards per layer, each card = title + 1-line description (description required, even if source brief). Skip if no per-module descriptions (use icon_grid) or no horizontal layering (use module_composition)." | 表达 dbo、ODS、DWD、DWS 与 Web 的分层关系 |
| P03 | icon_grid | `templates/charts/icon_grid.svg` | "Pick for 4-9 parallel features/capabilities/services as icon cards — feature grid, service lineup, benefits matrix, brand values, product highlights. Skip for sequential ordering (use numbered_steps) or hierarchical layers (use pyramid_chart)." | 并列展示本周四项主要成果 |
| P04 | roadmap_vertical | `templates/charts/roadmap_vertical.svg` | "Pick for 4-8 milestones on a vertical timeline with status indicators. Skip for horizontal time emphasis (use timeline) or tasks with durations (use gantt_chart)." | 展示下周工作顺序、依赖和状态 |

**Runners-up considered**:

- `pipeline_with_stages` | rejected for P02: 本页重点是数据仓库层级和职责，不是每阶段输出物。
- `kpi_cards` | rejected for P03: 当前实时数字具有波动性，本周成果以交付项而不是数值 KPI 表达。
- `numbered_steps` | rejected for P04: 下周任务存在权限和上游遥测依赖，不是单一路径操作教程。

---

## VIII. Image Resource List

| Filename | Dimensions | Ratio | Purpose | Type | Layout pattern | Acquire Via | Status | Reference | text_policy | page_role |
| -------- | ---------- | ----- | ------- | ---- | -------------- | ----------- | ------ | --------- | ----------- | --------- |
| codex-clipboard-f62fbebd-fd43-46fa-87c0-04abb60bcdc2.png | 1090×619 | 1.76 | P02 原始表与 ODS 层截图 | Screenshot | #48 Side-by-side comparison (before/after, A/B, then/now) + #70 Image with thin colored matte frame | user | Existing | 原始 281 张表与已筛选 ODS 表结构证据 | | |
| codex-clipboard-f02c6311-e33f-4dfa-8184-7b13649c0b04.png | 1101×601 | 1.83 | P02 DWD/DWS 层截图 | Screenshot | #48 Side-by-side comparison (before/after, A/B, then/now) + #70 Image with thin colored matte frame | user | Existing | DWD 清洗层与 DWS 汇总层结构证据 | | |
| codex-clipboard-dde4b7b4-2d2c-4042-b2fa-2561fd69435c.png | 1131×597 | 1.89 | P03 AMR Web 阶段性成果截图 | Screenshot | #19 Image floating in whitespace with thin frame and caption + #70 Image with thin colored matte frame | user | Existing | AMR Analytics 监控 Web 页面 | | |

Image-as-canvas patterns不适用：这三张图都是包含密集文本和界面信息的证据截图，必须完整显示且不裁切；信息主体由截图本身承载，页面说明使用独立 SVG 文本。

---

## IX. Content Outline

### Part 1: Status & Progress

#### Slide 01 - Cover

- **Cover impact**: 以 `dbo → ODS → DWD → DWS → Web` 作为项目进展钩子；左侧大标题、右侧纵向链路和三项阶段标签，形成高对比抽象几何封面。
- **Layout**: 左 65% 大标题与汇报信息，右 35% 垂直数据链路；不使用卡片网格。
- **Title**: AMR 数据监控与分析项目周报
- **Subtitle**: Week 31 · Status & Progress
- **Info**: Automation · 2026.07
- **Core message**: 本周汇报覆盖项目背景、当前进度、本周成果及下周工作。

#### Slide 02 - 项目背景与当前架构

- **Layout**: 上部数据分层架构，下部两张结构截图作为证据。
- **Title**: 项目背景与当前架构
- **Core message**: AMR 项目正在把分散的原始业务表整理为可监控、可分析的数据链路。
- **Visualization**: layered_architecture
- **Content**:
  - 背景：IOT2020 原始库约 281 张表，AMR 数据分散在状态、任务、电量、位置和 WiFi 等业务表中。
  - `dbo`：原始业务与遥测数据。
  - `ODS`：接入机器人相关源表并维护增量水位线。
  - `DWD`：清洗、标准化并形成维度、事实和快照。
  - `DWS`：汇总电量、状态、任务、队列、WiFi 和当前快照。
  - `AMR Web`：通过 Node.js API 读取 DWS，提供状态与分析入口。

#### Slide 03 - Complete Data Analysis Process

- **Layout**: Four analysis-process stages on the left, AMR Analytics Web evidence on the right, and one supporting task at the bottom.
- **Title**: Carrying Out the Complete Data Analysis Process
- **Core message**: This week's main focus was completing the end-to-end workflow from source review and data processing to analysis, validation and visualization.
- **Visualization**: icon_grid
- **Content**:
  - **Data Source Review**: Reviewed the source tables and identified AMR status, job, battery, location and WiFi data.
  - **Data Modeling & Processing**: Built the ODS, DWD and DWS layers and completed cleansing and full-layer synchronization.
  - **Analysis & Validation**: Analyzed operational metrics and validated data freshness and consistency.
  - **Visualization & Delivery**: Delivered the analysis through the AMR Analytics Web dashboard and prepared the project package.
  - **Other**: Completed business travel expense reimbursement.

#### Slide 04 - 下周工作与关键依赖

- **Closing impact**: 以“先恢复数据持续写入，再实现自动调度，最后评估低延迟方案”为离场信息；左侧路线图、右侧依赖和风险栏明确执行顺序。
- **Layout**: 左侧 5 个纵向里程碑，右侧依赖、风险和完成标准。
- **Title**: 下周工作与关键依赖
- **Core message**: 下周工作按数据恢复、权限获取、任务自动化、链路验证和 CDC 评估顺序推进。
- **Visualization**: roadmap_vertical
- **Content**:
  - **01 恢复上游遥测写入**：排查 `dbo.robot_*_history` 数据锚点滞后。
  - **02 获取 Agent 权限**：申请 SQL Server Agent / msdb 所需角色。
  - **03 安装自动任务**：快速快照约 1 分钟、历史分析约 10 分钟。
  - **04 验证全链路稳定性**：持续检查 ODS/DWD/DWS 水位、批次和趋势锚点。
  - **05 评估 CDC / Flink CDC**：仅在 Agent 任务稳定后进入低延迟变更捕获阶段。
  - **关键依赖**：上游遥测恢复、Agent 权限审批。
  - **风险提示**：在线数和时间锚点属于动态数据；`AMR_03` 保持 inactive，未经确认不修改。

---

## X. Speaker Notes Requirements

- **Filename**: 与 SVG 文件名一致。
- **Total duration**: 4–6 分钟。
- **Style**: 简洁、事实化、适合周会汇报。
- **Purpose**: report。
- **Structure**: 每页 45–90 秒，说明页面覆盖范围、当前状态和下一步，不逐字朗读。

---

## XI. Technical Constraints Reminder

1. viewBox: `0 0 1280 720`
2. 背景使用 `<rect>`。
3. 文本换行使用 `<tspan>`；禁止 `<foreignObject>`。
4. 禁止 `rgba()`、`<style>`、`class`、`textPath`、`animate*`、`script`。
5. 禁止 `<g opacity>`，透明度写在子元素上。
6. 图标仅使用 `tabler-outline`，统一 `stroke-width="2"`。
7. 三张截图均使用 `preserveAspectRatio="xMidYMid meet"`，不得裁切。
8. XML 保留字符必须转义，普通符号直接使用 Unicode。
