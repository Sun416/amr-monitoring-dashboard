# 01_封面

This weekly update covers the current status of the AMR data monitoring and analytics project. The project is connecting raw operational data through ODS, DWD and DWS to the monitoring Web. The update covers the project background, current progress, this week's deliverables and next steps.

---

# 02_项目背景与当前架构

The IOT2020 source database contains approximately 281 tables, with AMR status, job, battery, location and WiFi data distributed across multiple business tables. ODS, DWD and DWS are now in place for ingestion, cleansing and monitoring-oriented aggregation. The AMR Web reads DWS through a Node.js API, providing a unified status and analysis entry point. The screenshots show the current source selection and warehouse-layer structures.

---

# 03_本周工作进展

This week's main focus was carrying out the complete data analysis process. We first reviewed the source tables and identified the AMR status, job, battery, location and WiFi data. We then modeled and processed the data through the ODS, DWD and DWS layers, completed cleansing and full-layer synchronization, analyzed the operational metrics, and validated data freshness and consistency. Finally, we delivered the analysis results through the AMR Analytics Web dashboard and prepared the project package. Business travel expense reimbursement was also completed.

---

# 04_下周工作与关键依赖

Next week starts with restoring continuous upstream telemetry, followed by obtaining SQL Server Agent and msdb permissions. Once access is available, we will install the fast snapshot and historical analysis jobs and validate end-to-end stability. CDC or Flink CDC will be assessed only after the scheduled jobs are stable. The two key dependencies are upstream telemetry recovery and Agent permission approval, while AMR_03 remains inactive until explicitly confirmed.
