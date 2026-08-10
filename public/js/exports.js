'use strict';

function buildExportRows(dataset) {
  const data = state.dashboard || {};
  const summary = data.summary || {};
  const robots = data.robots || [];
  const profile = state.robotProfile || {};
  const selectedProfileRobot = robots.find(
    (robot) => String(robot.master_robot_id) === String(state.selectedRobotId)
  );

  switch (dataset) {
    case 'project-analytics': {
      /*
        Export the task rows of the current scope: the project/task axis is what
        this view is about, and each row already carries its robot count.
      */
      const projectData = state.projectAnalytics || {};
      return (projectData.tasks || []).map((row) => ({
        Project: row.project_name,
        Project_ID: row.project_id,
        Task: row.task_name,
        Job_ID: row.job_id,
        Task_Records: row.queue_count,
        Robots: row.robot_count,
        Completed: row.completed_count,
        Unsuccessful: row.unsuccessful_count,
        Open: row.open_count,
        Execution_Seconds: row.execution_seconds,
        Average_Execution_Seconds: row.average_execution_seconds,
        Subjob_Runs: row.subjob_run_count,
        Latest_Record: row.latest_event_time,
        Analysis_Start: projectData.summary?.analysis_start,
        Analysis_End: projectData.summary?.analysis_end,
        Selected_Projects: state.selectedProjectIds.join(',') || 'ALL',
        Selected_Jobs: state.selectedJobIds.join(',') || 'ALL',
        Selected_Robots: state.selectedRobotCodes.join(',') || 'ALL',
        Identity_Rule: projectData.identityRule
      }));
    }
    case 'analysis':
      return (data.analysis?.priorityDiagnostics || []).map((diagnostic) => ({
        Robot_ID: diagnostic.robotId,
        Robot_Type: diagnostic.robotType,
        Phenomenon: diagnostic.phenomenon,
        Most_Likely_Explanation: diagnostic.diagnosis,
        Confidence: diagnostic.confidence,
        Severity: diagnostic.severity,
        Evidence: (diagnostic.evidence || []).join('; '),
        Recommended_Actions: (diagnostic.recommendedActions || []).join('; '),
        Alternative_Causes: (diagnostic.alternativeCauses || []).join('; '),
        Triggered_Rules: (diagnostic.ruleIds || []).join('; '),
        Rule_Version: data.analysis?.ruleVersion,
        Analysis_Generated_At: data.analysis?.generatedAt
      }));
    case 'overview': {
      const totals = (data.jobTrend || []).reduce((result, row) => ({
        completed: result.completed + asNumber(row.completed_status_count),
        failed: result.failed + asNumber(row.failed_status_count)
      }), { completed: 0, failed: 0 });
      const finished = totals.completed + totals.failed;
      return [{
        Robot_Type_Filter: robotTypeLabel(),
        Analysis_Window: state.window.label,
        Dashboard_Generated_At: data.generatedAt,
        Status_Data_Time: summary.source_anchor_time || summary.latest_source_event_time,
        DWS_Refresh_Time: summary.latest_dws_load_time,
        Enabled_Robots: summary.total_robot_count,
        Commissioned_Robots: summary.commissioned_robot_count,
        Online_Robots: summary.online_robot_count,
        Offline_Robots: summary.offline_robot_count,
        Offline_Robot_IDs: robots.filter((robot) => normalizedOnlineStatus(robot.online_status) !== 'online').map(robotIdentifier).join(', '),
        Active_Job_Robots: summary.active_job_robot_count,
        Active_Job_Robot_IDs: robots.filter(hasActiveJob).map(robotIdentifier).join(', '),
        Completed_Task_States: totals.completed,
        Failed_Task_States: totals.failed,
        Task_Success_Rate_Percent: finished > 0 ? Number(((totals.completed / finished) * 100).toFixed(2)) : null,
        Average_Battery_Percent: summary.avg_battery_soc,
        Low_Battery_Robots: summary.low_battery_robot_count,
        Low_Battery_Robot_IDs: robots.filter(isLowBattery).map(robotIdentifier).join(', '),
        Current_Average_RSSI: summary.avg_current_rssi,
        Zero_Signal_Sample_Rate_Percent: summary.zero_signal_rate,
        Alert_Robots: robots.filter(hasOperationalAlert).length,
        Alert_Robot_IDs: robots.filter(hasOperationalAlert).map(robotIdentifier).join(', '),
        No_Signal_Robot_IDs: robots.filter(isNoSignal).map(robotIdentifier).join(', '),
        Device_Error_Robot_IDs: robots.filter(hasAlarm).map(robotIdentifier).join(', ')
      }];
    }
    case 'status-distribution':
      return (data.statusDistribution || []).map((row) => ({ Status: row.status_name, Robot_Count: row.robot_count }));
    case 'mode-distribution':
      return (data.modeDistribution || []).map((row) => ({ Mode: row.mode_name, Robot_Count: row.robot_count }));
    case 'low-battery-risk':
      return robots.filter(isLowBattery).map((robot) => ({
        Robot_ID: robotIdentifier(robot),
        Robot_Type: robot.robot_type,
        Master_Data_ID: robot.master_robot_id,
        Battery_Percent: robot.battery_soc,
        Battery_Voltage_V: robot.battery_voltage,
        Battery_Current_A: robot.battery_current,
        Operating_Status: robot.current_status,
        Online_Status: robot.online_status,
        Charging_Status: robot.charging_status,
        Current_Position: robot.station_code,
        Target_Position: robot.target_station_code,
        Battery_Data_Time: robot.battery_event_time || robot.source_event_time
      }));
    case 'battery-trend':
      return (data.batteryTrend || []).map((row) => ({
        Statistical_Hour: row.stat_hour,
        Sample_Count: row.sample_count,
        Average_Battery_Percent: row.avg_battery_soc,
        Minimum_Battery_Percent: row.min_battery_soc,
        Maximum_Battery_Percent: row.max_battery_soc,
        Charging_Sample_Count: row.charging_sample_count
      }));
    case 'wifi-trend':
      return (data.wifiTrend || []).map((row) => ({
        Statistical_Hour: row.stat_hour,
        Sample_Count: row.sample_count,
        Average_RSSI: row.avg_rssi,
        Minimum_RSSI: row.min_rssi,
        Maximum_RSSI: row.max_rssi,
        Zero_Signal_Sample_Count: row.zero_signal_sample_count,
        Zero_Signal_Rate_Percent: row.zero_signal_rate,
        Weak_Signal_Sample_Count: row.weak_signal_sample_count
      }));
    case 'job-trend':
      return (data.jobTrend || []).map((row) => {
        const completed = asNumber(row.completed_status_count);
        const failed = asNumber(row.failed_status_count);
        return {
          Statistical_Date: row.stat_date,
          Job_Record_Count: row.job_count,
          Distinct_Job_Count: row.distinct_job_count,
          Completed_Status_Count: row.completed_status_count,
          Failed_Status_Count: row.failed_status_count,
          Success_Rate_Percent: completed + failed > 0 ? Number(((completed / (completed + failed)) * 100).toFixed(2)) : null
        };
      });
    case 'alarm-trend':
      return (data.statusTrend || []).map((row) => ({
        Statistical_Hour: row.stat_hour,
        Status_Sample_Count: row.sample_count,
        Online_Sample_Count: row.online_sample_count,
        Error_Sample_Count: row.error_sample_count,
        Average_Speed_Meters_Per_Second: row.avg_speed_mps,
        Maximum_Speed_Meters_Per_Second: row.max_speed_mps
      }));
    case 'queue-trend':
      return (data.queueTrend || []).map((row) => ({
        Statistical_Date: row.stat_date,
        Queue_Record_Count: row.queue_count,
        Distinct_Queue_Count: row.distinct_queue_count,
        Completed_Status_Count: row.completed_status_count,
        Failed_Status_Count: row.failed_status_count,
        Average_Duration_Seconds: row.avg_duration_seconds
      }));
    case 'task-failure-outcomes':
      return (data.taskFailureOutcomes || []).map((row) => ({
        Recorded_Outcome: row.failure_outcome,
        Robot_ID: row.robot_code,
        Source_Robot_Reference: row.source_robot_reference,
        Failed_Task_Count: row.failure_count,
        Latest_Failure_Time: row.latest_failure_time,
        Root_Cause: 'Not captured by the source queue table'
      }));
    case 'alerts':
      return robots.flatMap((robot) => robotAlertCauses(robot).map((cause) => ({
        Robot_ID: robotIdentifier(robot),
        Alert_Code: cause.code,
        Alert_Cause: cause.reason,
        Cause_Type: cause.type,
        Current_Status: robot.current_status,
        Current_Job: robot.job_id,
        Current_Position: robotPoiSummary(robot),
        Battery_Percent: robot.battery_soc,
        Current_RSSI: robot.current_rssi,
        Cause_Data_Time: cause.dataTime
      })));
    case 'robot-profile':
      return selectedProfileRobot ? [{
        Analysis_Window: state.window.label,
        Robot_Type: selectedProfileRobot.robot_type,
        Robot_ID: robotIdentifier(selectedProfileRobot),
        Master_Data_ID: selectedProfileRobot.master_robot_id,
        Serial_Number: selectedProfileRobot.robot_serial_number,
        Current_Status: selectedProfileRobot.current_status,
        Online_Status: selectedProfileRobot.online_status,
        Battery_Percent: selectedProfileRobot.battery_soc,
        Voltage_V: selectedProfileRobot.battery_voltage,
        Current_A: selectedProfileRobot.battery_current,
        Charging_Status: selectedProfileRobot.charging_status,
        Current_Job: selectedProfileRobot.job_id,
        Job_Status: selectedProfileRobot.job_status,
        Operating_Mode_ID: selectedProfileRobot.current_mode_id,
        Operating_Mode: selectedProfileRobot.current_mode,
        Current_RSSI: selectedProfileRobot.current_rssi,
        WiFi_Quality: selectedProfileRobot.current_wifi_quality,
        Access_Point: selectedProfileRobot.current_wifi_ap,
        Map: selectedProfileRobot.map_code,
        Current_Position: selectedProfileRobot.station_code,
        Target_Position: selectedProfileRobot.target_station_code,
        Alert_Causes: robotAlertCauses(selectedProfileRobot).map((cause) => `${cause.code}: ${cause.reason}`).join('; '),
        Latest_Data_Time: selectedProfileRobot.latest_data_time,
        Status_Data_Time: selectedProfileRobot.status_event_time || selectedProfileRobot.source_event_time,
        Battery_Data_Time: selectedProfileRobot.battery_event_time,
        WiFi_Data_Time: selectedProfileRobot.latest_wifi_time,
        Task_Data_Time: selectedProfileRobot.job_event_time,
        DWS_Load_Time: selectedProfileRobot.dws_load_time
      }] : [];
    case 'profile-battery':
      return (profile.batteryTrend || []).map((row) => ({
        Robot_ID: robotIdentifier(selectedProfileRobot),
        Statistical_Hour: row.stat_hour,
        Sample_Count: row.sample_count,
        Average_Battery_Percent: row.avg_battery_soc,
        Minimum_Battery_Percent: row.min_battery_soc,
        Maximum_Battery_Percent: row.max_battery_soc,
        Charging_Sample_Count: row.charging_sample_count
      }));
    case 'profile-wifi':
      return (profile.wifiTrend || []).map((row) => ({
        Robot_ID: robotIdentifier(selectedProfileRobot),
        Statistical_Hour: row.stat_hour,
        Sample_Count: row.sample_count,
        Average_RSSI: row.avg_rssi,
        Minimum_RSSI: row.min_rssi,
        Maximum_RSSI: row.max_rssi,
        Zero_Signal_Sample_Count: row.zero_signal_sample_count,
        Zero_Signal_Rate_Percent: row.zero_signal_rate,
        Weak_Signal_Sample_Count: row.weak_signal_sample_count
      }));
    case 'profile-status':
      return (profile.statusTrend || []).map((row) => ({
        Robot_ID: robotIdentifier(selectedProfileRobot),
        Statistical_Hour: row.stat_hour,
        Status_Sample_Count: row.sample_count,
        Online_Sample_Count: row.online_sample_count,
        Error_Sample_Count: row.error_sample_count,
        Average_Speed_Meters_Per_Second: row.avg_speed_mps,
        Maximum_Speed_Meters_Per_Second: row.max_speed_mps
      }));
    case 'profile-jobs':
      return (profile.jobTrend || []).map((row) => ({
        Robot_ID: robotIdentifier(selectedProfileRobot),
        Statistical_Date: row.stat_date,
        Job_Record_Count: row.job_count,
        Distinct_Job_Count: row.distinct_job_count,
        Completed_Status_Count: row.completed_status_count,
        Failed_Status_Count: row.failed_status_count
      }));
    case 'profile-task-breakdown':
      return (profile.taskBreakdown || []).map((row) => ({
        Robot_ID: robotIdentifier(selectedProfileRobot),
        Task_Type: row.job_type_code,
        Operating_Mode_ID: row.robot_mode_id,
        Operating_Mode: row.robot_mode_detail,
        Task_Count: row.job_count,
        Completed_Status_Count: row.completed_status_count,
        Failed_Status_Count: row.failed_status_count,
        Latest_Task_Time: row.latest_job_time,
        Failure_Root_Cause: 'Not captured by the source job history table'
      }));
    case 'tasks':
      return robots.map((robot) => ({
        Robot_ID: robotIdentifier(robot),
        Robot_Type: robot.robot_type,
        Job_ID: robot.job_id,
        Subjob_ID: robot.subjob_id,
        Job_Status: robot.job_status,
        Has_Active_Job: hasActiveJob(robot) ? 1 : 0,
        Operating_Mode_ID: robot.current_mode_id,
        Operating_Mode: robot.current_mode,
        Current_Position: robot.station_code,
        Target_Position: robot.target_station_code,
        Job_Data_Time: robot.job_event_time
      }));
    case 'robots':
      return filteredRobots().map((robot) => ({
        Robot_ID: robotIdentifier(robot),
        Robot_Type: robot.robot_type,
        Master_Data_ID: robot.master_robot_id,
        Serial_Number: robot.robot_serial_number,
        Current_Status: robot.current_status,
        Online_Status: robot.online_status,
        Battery_Percent: robot.battery_soc,
        Voltage_V: robot.battery_voltage,
        Current_A: robot.battery_current,
        Charging_Status: robot.charging_status,
        Current_Job: robot.job_id,
        Job_Status: robot.job_status,
        Operating_Mode_ID: robot.current_mode_id,
        Operating_Mode: robot.current_mode,
        Current_RSSI: robot.current_rssi,
        WiFi_Quality: robot.current_wifi_quality,
        Zero_Signal_Rate_Percent: robot.zero_signal_rate,
        Current_Access_Point: robot.current_wifi_ap,
        Map: robot.map_code,
        Current_Position: robot.station_code,
        Target_Position: robot.target_station_code,
        Alarm_Code: robot.error_code,
        Alarm_Reason: robot.error_message,
        Derived_Alert_Causes: robotAlertCauses(robot).map((cause) => cause.reason).join('; '),
        Latest_Data_Time: robot.latest_data_time,
        Status_Data_Time: robot.status_event_time || robot.source_event_time,
        Battery_Data_Time: robot.battery_event_time,
        WiFi_Data_Time: robot.latest_wifi_time
      }));
    case 'map':
      return robots
        .filter((robot) => hasCoordinate(robot.position_x) && hasCoordinate(robot.position_y))
        .filter((robot) => normalizedMapCode(robot) === state.selectedMapCode)
        .map((robot) => ({
          Map: mapLabel(normalizedMapCode(robot)),
          Robot_ID: robotIdentifier(robot),
          X_Coordinate: robot.position_x,
          Y_Coordinate: robot.position_y,
          Heading: robot.position_theta,
          Current_Status: robot.current_status,
          Online_Status: robot.online_status,
          Alarm_Reason: robot.error_message,
          Current_Position: robot.station_code,
          Target_Position: robot.target_station_code,
          Data_Time: robot.source_event_time
        }));
    case 'wifi-risk':
      return (data.wifiAccessPointRisk || []).map((row) => ({
        Wireless_Access_Point: row.wifi_ap,
        Risk_Level: row.risk_level,
        Sample_Count: row.wifi_sample_count,
        Zero_Signal_Sample_Count: row.zero_signal_sample_count,
        Zero_Signal_Rate_Percent: row.zero_signal_rate,
        Weak_Signal_Sample_Count: row.weak_signal_sample_count,
        Weak_Signal_Rate_Percent: row.weak_signal_rate,
        Affected_Robot_Count: row.affected_robot_count,
        Average_RSSI: row.avg_valid_rssi,
        Latest_Sample_Time: row.last_sample_time
      }));
    case 'batches':
      return (data.recentBatches || []).map((row) => ({
        Batch_ID: row.batch_id,
        Start_Time: row.batch_start_time,
        End_Time: row.batch_end_time,
        Status: row.batch_status,
        Error_Message: row.error_message
      }));
    default:
      return [];
  }
}

function csvCell(value) {
  if (value === null || value === undefined) return '';
  const text = String(value);
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

function downloadBlob(content, mimeType, filename) {
  const blob = new Blob([content], { type: mimeType });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.append(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 0);
}

function exportDataset(dataset) {
  if (!state.dashboard) {
    showToast('Data has not loaded yet, so the export is unavailable', 'error');
    return;
  }
  const rows = buildExportRows(dataset);
  if (!rows.length) {
    showToast('There is no downloadable data in the current filter range', 'error');
    return;
  }
  const columns = [...new Set(rows.flatMap((row) => Object.keys(row)))];
  const lines = [columns.map(csvCell).join(',')];
  rows.forEach((row) => lines.push(columns.map((column) => csvCell(row[column])).join(',')));
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  downloadBlob(`\uFEFF${lines.join('\r\n')}`, 'text/csv;charset=utf-8', `robot-${state.robotType.toLowerCase()}-${dataset}-${state.window.key}-${stamp}.csv`);
  showToast(`Downloaded: ${rows.length} rows`);
}

function exportAllData() {
  if (!state.dashboard) {
    showToast('Data has not loaded yet, so the export is unavailable', 'error');
    return;
  }
  const payload = {
    exportedAt: new Date().toISOString(),
    selectedRobotType: state.robotType,
    selectedWindow: state.window,
    sourceNote: 'IOT2020 DWS dashboard response; WiFi detail uses strict ODS Running-task matching and supports an exact window up to 30 days.',
    dashboard: state.dashboard
  };
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  downloadBlob(JSON.stringify(payload, null, 2), 'application/json;charset=utf-8', `robot-dashboard-${state.robotType.toLowerCase()}-${state.window.key}-${stamp}.json`);
  showToast('Downloaded all current dashboard data');
}
