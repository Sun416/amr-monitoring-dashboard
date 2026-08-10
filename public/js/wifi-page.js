'use strict';

function aggregateTargetRowsForRobots(robotTargetRows, selectedRobotSet) {
  const byTarget = new Map();
  robotTargetRows
    .filter((row) => selectedRobotSet.has(String(row.robot_code)))
    .forEach((row) => {
      const key = String(row.poi_target || '');
      if (!key) return;
      const entry = byTarget.get(key) || {
        poi_target: row.poi_target,
        sample_count: 0,
        valid_signal_sample_count: 0,
        zero_signal_sample_count: 0,
        weightedSignalTotal: 0,
        minimum_valid_rssi: null,
        robots: new Set()
      };
      const validCount = asNumber(row.valid_signal_sample_count);
      const average = Number(row.average_valid_rssi);
      if (validCount > 0 && Number.isFinite(average)) {
        entry.weightedSignalTotal += average * validCount;
        entry.valid_signal_sample_count += validCount;
      }
      entry.sample_count += asNumber(row.sample_count);
      entry.zero_signal_sample_count += asNumber(row.zero_signal_sample_count);
      const minimum = Number(row.minimum_valid_rssi);
      if (Number.isFinite(minimum)) {
        entry.minimum_valid_rssi = entry.minimum_valid_rssi == null
          ? minimum
          : Math.min(entry.minimum_valid_rssi, minimum);
      }
      entry.robots.add(String(row.robot_code));
      byTarget.set(key, entry);
    });

  return [...byTarget.values()].map((entry) => ({
    poi_target: entry.poi_target,
    sample_count: entry.sample_count,
    valid_signal_sample_count: entry.valid_signal_sample_count,
    zero_signal_sample_count: entry.zero_signal_sample_count,
    minimum_valid_rssi: entry.minimum_valid_rssi,
    average_valid_rssi: entry.valid_signal_sample_count > 0
      ? entry.weightedSignalTotal / entry.valid_signal_sample_count
      : null,
    robot_count: entry.robots.size
  }));
}

/*
  Multi-select variant of aggregateRunningWifiTrend. An empty selection array
  means "no filter", matching the checkbox dropdown where nothing ticked = all.
*/
function aggregateRunningWifiTrendMulti(rows, selectedPois, selectedRobots) {
  const poiSet = new Set(selectedPois);
  const robotSet = new Set(selectedRobots);
  const filtered = rows.filter((row) => (
    (poiSet.size === 0 || poiSet.has(String(row.poi_target)))
    && (robotSet.size === 0 || robotSet.has(String(row.robot_code)))
  ));
  return aggregateRunningWifiTrend(filtered, 'ALL', 'ALL');
}

function aggregateRunningWifiTrend(rows, selectedPoi, selectedRobot) {
  const buckets = new Map();
  rows
    .filter((row) => (
      (selectedPoi === 'ALL' || String(row.poi_target) === selectedPoi)
      && (selectedRobot === 'ALL' || String(row.robot_code) === selectedRobot)
    ))
    .forEach((row) => {
      const key = String(row.bucket_start || '');
      if (!key) return;
      const bucket = buckets.get(key) || {
        bucket_start: row.bucket_start,
        weightedSignalTotal: 0,
        valid_signal_sample_count: 0,
        zero_signal_sample_count: 0,
        sample_count: 0,
        minimum_valid_rssi: null
      };
      const validCount = asNumber(row.valid_signal_sample_count);
      const average = Number(row.average_valid_rssi);
      if (validCount > 0 && Number.isFinite(average)) {
        bucket.weightedSignalTotal += average * validCount;
        bucket.valid_signal_sample_count += validCount;
      }
      bucket.zero_signal_sample_count += asNumber(row.zero_signal_sample_count);
      bucket.sample_count += asNumber(row.sample_count);
      const minimum = Number(row.minimum_valid_rssi);
      if (Number.isFinite(minimum)) {
        bucket.minimum_valid_rssi = bucket.minimum_valid_rssi == null
          ? minimum
          : Math.min(bucket.minimum_valid_rssi, minimum);
      }
      buckets.set(key, bucket);
    });

  return [...buckets.values()]
    .map((bucket) => ({
      ...bucket,
      average_valid_rssi: bucket.valid_signal_sample_count > 0
        ? bucket.weightedSignalTotal / bucket.valid_signal_sample_count
        : null
    }))
    .sort((a, b) => new Date(a.bucket_start) - new Date(b.bucket_start));
}

function renderRunningWifiTrend(host, rows) {
  host.replaceChildren();
  host.classList.remove('empty-state');
  const points = rows.filter((row) => Number.isFinite(Number(row.average_valid_rssi)));

  if (!points.length) {
    host.classList.add('empty-state');
    host.textContent = 'No negative RSSI samples can be plotted for the selected filters.';
    return;
  }

  if (points.length < 4) {
    const sparse = document.createElement('div');
    sparse.className = 'running-wifi-sparse';
    points.forEach((point) => {
      const item = document.createElement('div');
      item.append(
        textNode('span', '', formatShortTime(point.bucket_start)),
        textNode('strong', '', `${formatNumber(point.average_valid_rssi, 1)} dBm`),
        textNode('small', '', `${formatNumber(point.sample_count)} samples`)
      );
      sparse.append(item);
    });
    host.append(sparse);
    return;
  }

  const width = 760;
  const height = 286;
  const margin = { left: 56, right: 22, top: 16, bottom: 42 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  const values = points.flatMap((point) => [
    Number(point.average_valid_rssi),
    Number(point.minimum_valid_rssi)
  ]).filter(Number.isFinite);
  const observedMin = Math.min(...values);
  const observedMax = Math.max(...values);
  const min = Math.floor((observedMin - 4) / 5) * 5;
  const max = Math.ceil((observedMax + 4) / 5) * 5;
  const x = (index) => margin.left + (index / Math.max(points.length - 1, 1)) * plotWidth;
  const y = (value) => margin.top + (1 - (value - min) / (max - min || 1)) * plotHeight;
  const svg = svgElement('svg', {
    viewBox: `0 0 ${width} ${height}`,
    role: 'img',
    'aria-label': 'Average and minimum WiFi RSSI trend during Running tasks'
  });

  [0, 0.25, 0.5, 0.75, 1].forEach((ratio) => {
    const lineY = margin.top + ratio * plotHeight;
    svg.append(svgElement('line', {
      x1: margin.left,
      y1: lineY,
      x2: width - margin.right,
      y2: lineY,
      class: 'running-wifi-grid-line'
    }));
    const label = svgElement('text', {
      x: margin.left - 9,
      y: lineY + 4,
      'text-anchor': 'end',
      class: 'running-wifi-axis-label'
    });
    label.textContent = `${formatNumber(max - ratio * (max - min), 0)}`;
    svg.append(label);
  });

  const averagePath = points
    .map((point, index) => `${index ? 'L' : 'M'} ${x(index)} ${y(Number(point.average_valid_rssi))}`)
    .join(' ');
  const minimumPath = points
    .filter((point) => Number.isFinite(Number(point.minimum_valid_rssi)))
    .map((point) => {
      const index = points.indexOf(point);
      return `${index ? 'L' : 'M'} ${x(index)} ${y(Number(point.minimum_valid_rssi))}`;
    })
    .join(' ');
  svg.append(svgElement('path', { d: minimumPath, class: 'running-wifi-line minimum' }));
  svg.append(svgElement('path', { d: averagePath, class: 'running-wifi-line average' }));

  const markerInterval = Math.max(1, Math.ceil(points.length / 24));
  points.forEach((point, index) => {
    if (index % markerInterval === 0 || index === points.length - 1) {
      const averagePoint = svgElement('circle', {
        cx: x(index),
        cy: y(Number(point.average_valid_rssi)),
        r: 3,
        class: 'running-wifi-point average'
      });
      const title = svgElement('title');
      title.textContent = `${formatDateTime(point.bucket_start)} · Average ${formatNumber(point.average_valid_rssi, 1)} dBm · Minimum ${formatNumber(point.minimum_valid_rssi, 1)} dBm · ${formatNumber(point.sample_count)} samples`;
      averagePoint.append(title);
      svg.append(averagePoint);
    }
    if (asNumber(point.zero_signal_sample_count) > 0) {
      const zeroMarker = svgElement('path', {
        d: `M ${x(index) - 5} ${height - margin.bottom + 4} L ${x(index) + 5} ${height - margin.bottom + 4} L ${x(index)} ${height - margin.bottom - 5} Z`,
        class: 'running-wifi-zero-marker'
      });
      const title = svgElement('title');
      title.textContent = `${formatDateTime(point.bucket_start)} · ${formatNumber(point.zero_signal_sample_count)} zero-signal samples`;
      zeroMarker.append(title);
      svg.append(zeroMarker);
    }
  });

  const firstLabel = svgElement('text', {
    x: margin.left,
    y: height - 12,
    class: 'running-wifi-axis-label'
  });
  firstLabel.textContent = formatShortTime(points[0].bucket_start);
  const lastLabel = svgElement('text', {
    x: width - margin.right,
    y: height - 12,
    'text-anchor': 'end',
    class: 'running-wifi-axis-label'
  });
  lastLabel.textContent = formatShortTime(points[points.length - 1].bucket_start);
  svg.append(firstLabel, lastLabel);
  host.append(svg);
}

const WIFI_POINT_LINE_STYLES = [
  { color: '#2563eb', dash: '' },
  { color: '#7c3aed', dash: '8 4' },
  { color: '#d97706', dash: '3 4' },
  { color: '#059669', dash: '10 4 2 4' },
  { color: '#db2777', dash: '6 3' },
  { color: '#0891b2', dash: '2 3' },
  { color: '#9333ea', dash: '12 4' },
  { color: '#4d7c0f', dash: '7 3 2 3' },
  { color: '#c2410c', dash: '4 3' },
  { color: '#475569', dash: '10 3' }
];

function wifiPointLineStyle(index) {
  return WIFI_POINT_LINE_STYLES[index % WIFI_POINT_LINE_STYLES.length];
}

function renderWifiPointLineChart(host, rows, selectedRobots, availableRobots) {
  host.replaceChildren();
  const selected = new Set(selectedRobots);
  const validRows = rows.filter((row) => (
    selected.has(String(row.robot_code))
    && row.poi_target
    && Number.isFinite(Number(row.average_valid_rssi))
  ));

  if (!selectedRobots.length) {
    host.classList.add('empty-state');
    host.textContent = 'No selected robot has plottable target-POI signal data in this time range.';
    return;
  }
  if (!validRows.length) {
    host.classList.add('empty-state');
    host.textContent = 'The selected robots have no plottable target-POI signal data in this time range.';
    return;
  }

  host.classList.remove('empty-state');
  const rowsByRobot = new Map();
  validRows.forEach((row) => {
    const robotCode = String(row.robot_code);
    if (!rowsByRobot.has(robotCode)) rowsByRobot.set(robotCode, []);
    rowsByRobot.get(robotCode).push(row);
  });

  const chartList = document.createElement('div');
  chartList.className = 'wifi-point-small-multiples';

  selectedRobots.forEach((robotCode) => {
    const robotRows = (rowsByRobot.get(robotCode) || [])
      .sort((a, b) => String(a.poi_target).localeCompare(String(b.poi_target), 'en', { numeric: true }));
    if (!robotRows.length) return;

    const styleIndex = Math.max(0, availableRobots.indexOf(robotCode));
    const style = wifiPointLineStyle(styleIndex);
    const sampleCount = robotRows.reduce((total, row) => total + asNumber(row.sample_count), 0);
    const weightedRssi = sampleCount
      ? robotRows.reduce(
        (total, row) => total + Number(row.average_valid_rssi) * asNumber(row.sample_count),
        0
      ) / sampleCount
      : null;

    const card = document.createElement('article');
    card.className = 'wifi-point-robot-chart';
    card.style.setProperty('--robot-series-color', style.color);

    const header = document.createElement('header');
    header.className = 'wifi-point-robot-chart-header';
    const heading = document.createElement('div');
    heading.className = 'wifi-point-robot-chart-heading';
    const swatch = document.createElement('i');
    const headingText = document.createElement('div');
    headingText.append(
      textNode('h4', '', robotCode),
      textNode('p', '', `${formatNumber(robotRows.length)} observed target POIs · ${formatNumber(sampleCount)} strict matched samples`)
    );
    heading.append(swatch, headingText);
    const metric = document.createElement('div');
    metric.className = 'wifi-point-robot-chart-metric';
    metric.append(
      textNode('strong', '', `${formatNumber(weightedRssi, 1)} dBm`),
      textNode('span', '', 'Sample-weighted average')
    );
    header.append(heading, metric);
    card.append(header);

    const scaleMin = -90;
    const scaleMax = -30;
    const margin = { left: 62, right: 34, top: 28, bottom: 92 };
    const pointStep = 68;
    const width = Math.max(900, margin.left + margin.right + Math.max(robotRows.length - 1, 1) * pointStep);
    const height = 340;
    const plotWidth = width - margin.left - margin.right;
    const plotHeight = height - margin.top - margin.bottom;
    const x = (index) => robotRows.length === 1
      ? margin.left + plotWidth / 2
      : margin.left + (index / (robotRows.length - 1)) * plotWidth;
    const y = (value) => margin.top + (1 - (Number(value) - scaleMin) / (scaleMax - scaleMin)) * plotHeight;
    const svg = svgElement('svg', {
      viewBox: `0 0 ${width} ${height}`,
      width,
      height,
      role: 'img',
      'aria-label': `${robotCode} average WiFi RSSI line chart by observed target POI`
    });

    for (let tick = scaleMin; tick <= scaleMax; tick += 10) {
      const tickY = y(tick);
      svg.append(svgElement('line', {
        x1: margin.left,
        y1: tickY,
        x2: width - margin.right,
        y2: tickY,
        class: 'wifi-point-line-grid'
      }));
      const label = svgElement('text', {
        x: margin.left - 10,
        y: tickY + 4,
        'text-anchor': 'end',
        class: 'wifi-point-line-axis'
      });
      label.textContent = tick;
      svg.append(label);
    }

    const unit = svgElement('text', {
      x: margin.left,
      y: 16,
      class: 'wifi-point-line-unit'
    });
    unit.textContent = 'RSSI (dBm)';
    svg.append(unit);

    const points = robotRows.map((row, index) => {
      const pointName = String(row.poi_target);
      const pointX = x(index);
      const pointY = y(row.average_valid_rssi);
      const label = svgElement('text', {
        x: pointX,
        y: height - margin.bottom + 22,
        transform: `rotate(-48 ${pointX} ${height - margin.bottom + 22})`,
        'text-anchor': 'end',
        class: 'wifi-point-line-x-label'
      });
      label.textContent = pointName;
      svg.append(label);
      return { x: pointX, y: pointY, row, pointName };
    });

    if (points.length >= 2) {
      const path = points
        .map((point, index) => `${index ? 'L' : 'M'} ${point.x} ${point.y}`)
        .join(' ');
      svg.append(svgElement('path', {
        d: path,
        fill: 'none',
        stroke: style.color,
        'stroke-width': 2.5,
        class: 'wifi-point-series-line'
      }));
    }

    points.forEach((point) => {
      const marker = svgElement('circle', {
        cx: point.x,
        cy: point.y,
        r: 4,
        fill: '#fff',
        stroke: style.color,
        'stroke-width': 2.4,
        class: 'wifi-point-series-marker'
      });
      const title = svgElement('title');
      title.textContent = `${robotCode} · ${point.pointName} · Average ${formatNumber(point.row.average_valid_rssi, 1)} dBm · Minimum ${formatNumber(point.row.minimum_valid_rssi, 1)} dBm · Maximum ${formatNumber(point.row.maximum_valid_rssi, 1)} dBm · ${formatNumber(point.row.sample_count)} samples`;
      marker.append(title);
      svg.append(marker);

      if (robotRows.length <= 18) {
        const valueLabel = svgElement('text', {
          x: point.x,
          y: point.y - 9,
          'text-anchor': 'middle',
          fill: style.color,
          class: 'wifi-point-series-value'
        });
        valueLabel.textContent = formatNumber(point.row.average_valid_rssi, 0);
        svg.append(valueLabel);
      }
    });

    const chartScroll = document.createElement('div');
    chartScroll.className = 'wifi-point-line-scroll';
    chartScroll.append(svg);
    card.append(chartScroll);
    chartList.append(card);
  });

  host.append(chartList);
}

function renderWifiPointComparison(payload) {
  const availableRobots = (payload.byRobot || [])
    .map((row) => String(row.robot_code))
    .sort((a, b) => a.localeCompare(b, 'en', { numeric: true }));
  // Empty selection means all robots; otherwise honour the checkbox selection.
  const selectedRobots = state.selectedWifiRobots.length
    ? availableRobots.filter((robotCode) => state.selectedWifiRobots.includes(robotCode))
    : availableRobots;
  const selected = new Set(selectedRobots);
  const poiFilter = new Set(state.selectedWifiPois);
  const rows = (payload.byRobotTarget || []).filter((row) => (
    selected.has(String(row.robot_code))
    && (poiFilter.size === 0 || poiFilter.has(String(row.poi_target)))
  ));
  const sampleCount = rows.reduce((total, row) => total + asNumber(row.sample_count), 0);
  const scopeLabel = !state.selectedWifiRobots.length
    ? 'All eligible robots'
    : state.selectedWifiRobots.length === 1
      ? state.selectedWifiRobots[0]
      : `${state.selectedWifiRobots.length} selected robots`;
  elements.wifiPointStrengthSubtitle.textContent = `${scopeLabel} · ${formatNumber(selectedRobots.length)} robots · ${formatNumber(rows.length)} robot-target POI pairs · ${formatNumber(sampleCount)} strict matched samples · one chart per robot`;
  renderWifiPointLineChart(
    elements.wifiPointStrengthChart,
    payload.byRobotTarget || [],
    selectedRobots,
    availableRobots
  );
}

function weakSignalRowsForScope(payload, selectedRobot, selectedPoi) {
  const sourceRows = selectedPoi === 'ALL'
    ? (payload.byRobot || [])
    : (payload.byRobotTarget || []).filter((row) => String(row.poi_target) === selectedPoi);
  return sourceRows
    .filter((row) => selectedRobot === 'ALL' || String(row.robot_code) === selectedRobot)
    .filter((row) => asNumber(row.valid_signal_sample_count) > 0);
}

function aggregateWeakSignalTimeline(rows, selectedRobot, selectedPoi) {
  const buckets = new Map();
  rows
    .filter((row) => (
      (selectedRobot === 'ALL' || String(row.robot_code) === selectedRobot)
      && (selectedPoi === 'ALL' || String(row.poi_target) === selectedPoi)
    ))
    .forEach((row) => {
      const key = String(row.bucket_start || '');
      if (!key) return;
      const bucket = buckets.get(key) || {
        bucket_start: row.bucket_start,
        weak_signal_sample_count: 0,
        first_weak_time: null,
        last_weak_time: null,
        minimum_rssi: null,
        maximum_rssi: null
      };
      bucket.weak_signal_sample_count += asNumber(row.weak_signal_sample_count);
      if (!bucket.first_weak_time || new Date(row.first_weak_time) < new Date(bucket.first_weak_time)) {
        bucket.first_weak_time = row.first_weak_time;
      }
      if (!bucket.last_weak_time || new Date(row.last_weak_time) > new Date(bucket.last_weak_time)) {
        bucket.last_weak_time = row.last_weak_time;
      }
      const minimum = Number(row.minimum_rssi);
      const maximum = Number(row.maximum_rssi);
      if (Number.isFinite(minimum)) {
        bucket.minimum_rssi = bucket.minimum_rssi == null ? minimum : Math.min(bucket.minimum_rssi, minimum);
      }
      if (Number.isFinite(maximum)) {
        bucket.maximum_rssi = bucket.maximum_rssi == null ? maximum : Math.max(bucket.maximum_rssi, maximum);
      }
      buckets.set(key, bucket);
    });
  return [...buckets.values()].sort((left, right) => new Date(left.bucket_start) - new Date(right.bucket_start));
}

function weakBucketLabel(value, analysisHours) {
  if (!value) return '--';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  const options = analysisHours <= 24
    ? { hour: '2-digit', minute: '2-digit', hour12: false }
    : analysisHours <= 168
      ? { day: '2-digit', month: 'short', hour: '2-digit', hour12: false }
      : { day: '2-digit', month: 'short' };
  return new Intl.DateTimeFormat('en-GB', options).format(date);
}

function renderWeakSignalBarChart(host, rows, {
  valueKey,
  labelForRow,
  tooltipForRow,
  yAxisLabel,
  formatValue,
  emptyMessage
}) {
  host.replaceChildren();
  host.classList.remove('empty-state');
  const points = rows.filter((row) => Number.isFinite(Number(row[valueKey])));
  if (!points.length) {
    host.classList.add('empty-state');
    host.textContent = emptyMessage;
    return;
  }

  const width = Math.max(620, points.length * 96 + 100);
  const height = 292;
  const margin = { left: 58, right: 18, top: 28, bottom: 72 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  const observedMax = Math.max(...points.map((row) => Number(row[valueKey])), 0);
  const max = observedMax <= 5
    ? 5
    : Math.ceil((observedMax * 1.15) / (observedMax <= 100 ? 5 : 10)) * (observedMax <= 100 ? 5 : 10);
  const barWidth = Math.min(62, (plotWidth / points.length) * 0.62);
  const x = (index) => margin.left + ((index + 0.5) / points.length) * plotWidth;
  const y = (value) => margin.top + (1 - value / (max || 1)) * plotHeight;
  const svg = svgElement('svg', {
    viewBox: `0 0 ${width} ${height}`,
    role: 'img',
    'aria-label': yAxisLabel
  });
  const ticks = 4;
  for (let index = 0; index <= ticks; index += 1) {
    const value = (max / ticks) * index;
    const tickY = y(value);
    svg.append(svgElement('line', {
      x1: margin.left,
      y1: tickY,
      x2: width - margin.right,
      y2: tickY,
      class: 'weak-signal-grid-line'
    }));
    const label = svgElement('text', {
      x: margin.left - 8,
      y: tickY + 4,
      'text-anchor': 'end',
      class: 'weak-signal-axis-label'
    });
    label.textContent = formatValue(value);
    svg.append(label);
  }
  const yTitle = svgElement('text', {
    x: 16,
    y: margin.top + plotHeight / 2,
    transform: `rotate(-90 16 ${margin.top + plotHeight / 2})`,
    'text-anchor': 'middle',
    class: 'weak-signal-axis-title'
  });
  yTitle.textContent = yAxisLabel;
  svg.append(yTitle);

  points.forEach((row, index) => {
    const value = Math.max(0, Number(row[valueKey]));
    const barTop = y(value);
    const bar = svgElement('rect', {
      x: x(index) - barWidth / 2,
      y: barTop,
      width: barWidth,
      height: Math.max(0, margin.top + plotHeight - barTop),
      rx: 5,
      class: 'weak-signal-bar'
    });
    const title = svgElement('title');
    title.textContent = tooltipForRow(row);
    bar.append(title);
    svg.append(bar);

    const valueLabel = svgElement('text', {
      x: x(index),
      y: Math.max(margin.top + 13, barTop - 7),
      'text-anchor': 'middle',
      class: 'weak-signal-value-label'
    });
    valueLabel.textContent = formatValue(value);
    svg.append(valueLabel);

    const axisLabel = svgElement('text', {
      x: x(index),
      y: margin.top + plotHeight + 20,
      'text-anchor': 'end',
      transform: `rotate(-42 ${x(index)} ${margin.top + plotHeight + 20})`,
      class: 'weak-signal-axis-label'
    });
    axisLabel.textContent = labelForRow(row);
    svg.append(axisLabel);
  });

  const scroll = document.createElement('div');
  scroll.className = 'weak-signal-chart-scroll';
  scroll.append(svg);
  host.append(scroll);
}

function renderWeakSignalRate(payload, selectedRobot, selectedPoi) {
  const summary = payload.summary || {};
  const threshold = asNumber(summary.weak_rssi_threshold || -67);
  const rows = weakSignalRowsForScope(payload, selectedRobot, selectedPoi)
    .slice()
    .sort((left, right) => (
      asNumber(right.weak_signal_rate) - asNumber(left.weak_signal_rate)
      || asNumber(right.weak_signal_sample_count) - asNumber(left.weak_signal_sample_count)
      || String(left.robot_code).localeCompare(String(right.robot_code), 'en')
    ));
  elements.weakSignalRateSubtitle.textContent = `Weak means RSSI ≤ ${formatNumber(threshold)} dBm · valid negative RSSI samples are the denominator · zero-signal rows are excluded`;
  renderWeakSignalBarChart(elements.weakSignalRateChart, rows, {
    valueKey: 'weak_signal_rate',
    labelForRow: (row) => String(row.robot_code),
    tooltipForRow: (row) => `${row.robot_code} · ${formatPercent(row.weak_signal_rate, 1)} weak · ${formatNumber(row.weak_signal_sample_count)} weak / ${formatNumber(row.valid_signal_sample_count)} valid samples`,
    yAxisLabel: 'Weak-signal rate (%)',
    formatValue: (value) => formatPercent(value, 1),
    emptyMessage: 'No valid strict Running-task WiFi samples are available for the selected filters.'
  });
}

function renderWeakSignalTimeline(payload, selectedRobot, selectedPoi) {
  const summary = payload.summary || {};
  const rows = aggregateWeakSignalTimeline(payload.weakTimeline || [], selectedRobot, selectedPoi);
  const scopeLabel = [
    selectedRobot === 'ALL' ? 'All robots' : selectedRobot,
    selectedPoi === 'ALL' ? 'All targets' : selectedPoi
  ].join(' · ');
  const busiest = rows.reduce((highest, row) => (
    !highest || asNumber(row.weak_signal_sample_count) > asNumber(highest.weak_signal_sample_count)
      ? row
      : highest
  ), null);
  const totalWeak = rows.reduce((total, row) => total + asNumber(row.weak_signal_sample_count), 0);
  const peakShare = busiest && totalWeak > 0
    ? (100 * asNumber(busiest.weak_signal_sample_count)) / totalWeak
    : null;
  elements.weakSignalTimelineSubtitle.textContent = busiest
    ? `X = time; Y = weak-signal sample count. Peak: ${weakBucketLabel(busiest.bucket_start, asNumber(summary.analysis_window_hours))} · ${formatNumber(busiest.weak_signal_sample_count)} rows${peakShare == null ? '' : ` (${formatPercent(peakShare, 1)} of weak rows)`}.`
    : `No strict sample with RSSI <= ${formatNumber(summary.weak_rssi_threshold || -67)} dBm in the selected filters.`;
  renderWeakSignalBarChart(elements.weakSignalTimelineChart, rows, {
    valueKey: 'weak_signal_sample_count',
    labelForRow: (row) => weakBucketLabel(row.bucket_start, asNumber(summary.analysis_window_hours)),
    tooltipForRow: (row) => `Time: ${formatDateTime(row.first_weak_time)} to ${formatDateTime(row.last_weak_time)} · Weak rows: ${formatNumber(row.weak_signal_sample_count)} · RSSI: ${formatNumber(row.minimum_rssi)} to ${formatNumber(row.maximum_rssi)} dBm`,
    yAxisLabel: 'Weak-signal sample count',
    formatValue: (value) => formatNumber(value),
    emptyMessage: 'No weak-signal observation meets the RSSI ≤ -67 dBm threshold for the selected filters.'
  });
}

function findWeakSignalDiagnostic(payload, selectedRobot, selectedPoi) {
  const diagnostics = payload.weakSignalDiagnostics || [];
  if (selectedRobot !== 'ALL') {
    return diagnostics.find((item) => (
      item.scope_type === 'ROBOT'
      && String(item.scope_robot_code) === selectedRobot
    )) || null;
  }
  if (selectedPoi !== 'ALL') {
    return diagnostics.find((item) => (
      item.scope_type === 'TARGET'
      && String(item.scope_poi_target) === selectedPoi
    )) || null;
  }
  return diagnostics[0] || null;
}

function renderWeakSignalDiagnosis(payload, selectedRobot, selectedPoi) {
  const host = elements.weakSignalDiagnosis;
  const summary = payload.summary || {};
  const diagnostic = findWeakSignalDiagnostic(payload, selectedRobot, selectedPoi);
  host.replaceChildren();
  host.classList.remove('empty-state');
  if (!asNumber(summary.running_matched_sample_count)) {
    host.classList.add('empty-state');
    host.textContent = 'No strict Running-task WiFi sample is available, so a weak-signal cause cannot be assessed.';
    return;
  }
  if (!diagnostic) {
    host.classList.add('empty-state');
    host.textContent = `No weak-signal sample (RSSI ≤ ${formatNumber(summary.weak_rssi_threshold || -67)} dBm) exists in the selected filters; no cause rule was triggered.`;
    return;
  }

  host.dataset.confidence = String(diagnostic.confidence || 'LOW').toLowerCase();
  const header = document.createElement('header');
  header.append(
    textNode('span', 'weak-signal-diagnosis-kicker', diagnostic.cause_status.replaceAll('_', ' ')),
    textNode('strong', '', diagnostic.scope_type === 'ROBOT'
      ? `${diagnostic.scope_robot_code} weak-signal assessment`
      : `${diagnostic.scope_poi_target} route/area assessment`),
    textNode('span', 'wifi-minimum-confidence', `${diagnostic.confidence} confidence`)
  );
  const facts = document.createElement('div');
  facts.className = 'weak-signal-facts';
  [
    ['Weak rate', diagnostic.weak_signal_rate == null ? '--' : formatPercent(diagnostic.weak_signal_rate, 1)],
    ['Weak samples', formatNumber(diagnostic.weak_signal_sample_count)],
    ['Threshold', `≤ ${formatNumber(summary.weak_rssi_threshold || -67)} dBm`]
  ].forEach(([label, value]) => {
    const fact = document.createElement('div');
    fact.append(textNode('span', '', label), textNode('strong', '', value));
    facts.append(fact);
  });
  const cause = document.createElement('div');
  cause.className = 'weak-signal-cause';
  cause.append(textNode('h5', '', 'What the evidence supports'), textNode('p', '', diagnostic.cause));
  const evidence = document.createElement('div');
  evidence.className = 'weak-signal-evidence';
  evidence.append(textNode('h5', '', 'Evidence'));
  const evidenceList = document.createElement('ul');
  (diagnostic.evidence || []).forEach((item) => evidenceList.append(textNode('li', '', item)));
  evidence.append(evidenceList);
  const actions = document.createElement('div');
  actions.className = 'weak-signal-actions';
  actions.append(textNode('h5', '', 'Recommended checks'));
  const actionList = document.createElement('ol');
  (diagnostic.actions || []).forEach((item) => actionList.append(textNode('li', '', item)));
  actions.append(actionList);
  const rule = textNode('p', 'weak-signal-rule', `Transparent rule: ${diagnostic.rule_id} · Version ${diagnostic.rule_version}`);
  host.append(header, facts, cause, evidence, actions, rule);
}

function findWifiMinimumDiagnostic(payload, selectedRobot, selectedPoi) {
  const scopeType = selectedRobot === 'ALL'
    ? (selectedPoi === 'ALL' ? 'ALL' : 'TARGET')
    : (selectedPoi === 'ALL' ? 'ROBOT' : 'ROBOT_TARGET');
  return (payload.minimumDiagnostics || []).find((item) => (
    String(item.scope_type) === scopeType
    && (scopeType === 'ALL' || scopeType === 'TARGET' || String(item.scope_robot_code) === selectedRobot)
    && (scopeType === 'ALL' || scopeType === 'ROBOT' || String(item.scope_poi_target) === selectedPoi)
  )) || null;
}

function renderWifiMinimumDiagnostic(diagnostic) {
  const panel = document.createElement('section');
  panel.className = 'wifi-minimum-diagnostic';
  if (!diagnostic) {
    panel.classList.add('empty-inline');
    panel.textContent = 'No traceable negative-RSSI minimum record exists for the current filters.';
    return panel;
  }

  panel.dataset.confidence = String(diagnostic.confidence || 'LOW').toLowerCase();
  const header = document.createElement('header');
  header.append(
    textNode('h5', '', 'Minimum Location and Cause Assessment'),
    textNode('span', 'wifi-minimum-confidence', `${diagnostic.confidence || 'LOW'} confidence`)
  );

  const facts = document.createElement('div');
  facts.className = 'wifi-minimum-facts';
  [
    ['Minimum', `${formatNumber(diagnostic.minimum_rssi, 1)} dBm`],
    ['Robot', diagnostic.robot_code || '--'],
    ['Event time', formatExactDateTime(diagnostic.event_time)],
    ['Related target POI', diagnostic.poi_target || '--']
  ].forEach(([label, value]) => {
    const fact = document.createElement('div');
    fact.append(textNode('span', '', label), textNode('strong', '', value));
    facts.append(fact);
  });

  const cause = document.createElement('div');
  cause.className = 'wifi-minimum-cause';
  cause.append(
    textNode('h6', '', 'Cause assessment'),
    textNode('p', '', diagnostic.cause || 'Cause not confirmed.')
  );

  const evidence = document.createElement('div');
  evidence.className = 'wifi-minimum-evidence';
  evidence.append(textNode('h6', '', 'Evidence'));
  const evidenceList = document.createElement('ul');
  (diagnostic.evidence || []).forEach((item) => evidenceList.append(textNode('li', '', item)));
  evidence.append(evidenceList);

  const resolution = document.createElement('div');
  resolution.className = 'wifi-minimum-resolution';
  resolution.append(textNode('h6', '', 'Recommended actions'));
  const resolutionList = document.createElement('ol');
  (diagnostic.actions || []).forEach((item) => resolutionList.append(textNode('li', '', item)));
  resolution.append(resolutionList);

  const footer = textNode(
    'p',
    'wifi-minimum-rule',
    `Transparent rule: ${diagnostic.rule_id || '--'} · Version ${diagnostic.rule_version || '--'}`
  );
  const rationale = document.createElement('div');
  rationale.className = 'wifi-minimum-rationale';
  rationale.append(cause, evidence);

  const body = document.createElement('div');
  body.className = 'wifi-minimum-body';
  body.append(rationale, resolution);

  panel.append(header, facts, body, footer);
  return panel;
}

function renderWifiCombinedDiagnostic(minimumDiagnostic, weakSignalDiagnostic, summary = {}) {
  const panel = document.createElement('section');
  panel.className = 'wifi-minimum-diagnostic';
  if (!minimumDiagnostic && !weakSignalDiagnostic) {
    panel.classList.add('empty-inline');
    panel.textContent = 'No traceable negative-RSSI minimum or weak-signal pattern exists for the current filters.';
    return panel;
  }

  const minimumConfidence = String(minimumDiagnostic?.confidence || 'LOW').toUpperCase();
  const patternConfidence = weakSignalDiagnostic
    ? String(weakSignalDiagnostic.confidence || 'LOW').toUpperCase()
    : null;
  panel.dataset.confidence = (patternConfidence || minimumConfidence).toLowerCase();

  const header = document.createElement('header');
  const confidenceLabel = minimumDiagnostic && weakSignalDiagnostic
    ? `Pattern: ${patternConfidence} | Minimum event: ${minimumConfidence}`
    : weakSignalDiagnostic
      ? `Pattern: ${patternConfidence}`
      : `Minimum event: ${minimumConfidence}`;
  header.append(
    textNode('h5', '', 'Lowest Signal: Evidence and Next Step'),
    textNode('span', 'wifi-minimum-confidence', confidenceLabel)
  );

  const facts = document.createElement('div');
  facts.className = 'wifi-minimum-facts';
  const factRows = [];
  if (minimumDiagnostic) {
    factRows.push(
      ['Minimum event', `${formatNumber(minimumDiagnostic.minimum_rssi, 1)} dBm`],
      ['Robot', minimumDiagnostic.robot_code || '--'],
      ['Event time', formatExactDateTime(minimumDiagnostic.event_time)],
      ['Related target POI', minimumDiagnostic.poi_target || '--']
    );
  }
  if (weakSignalDiagnostic) {
    factRows.push(
      ['Weak rate', weakSignalDiagnostic.weak_signal_rate == null ? '--' : formatPercent(weakSignalDiagnostic.weak_signal_rate, 1)],
      ['Weak samples', formatNumber(weakSignalDiagnostic.weak_signal_sample_count)],
      ['Weak threshold', `<= ${formatNumber(summary.weak_rssi_threshold || -67)} dBm`]
    );
  }
  factRows.forEach(([label, value]) => {
    const fact = document.createElement('div');
    fact.append(textNode('span', '', label), textNode('strong', '', value));
    facts.append(fact);
  });

  const cause = document.createElement('div');
  cause.className = 'wifi-minimum-cause';
  cause.append(textNode('h6', '', 'What this means'));
  if (weakSignalDiagnostic) {
    cause.append(
      textNode('strong', 'wifi-diagnostic-label', `Repeated pattern (${patternConfidence})`),
      textNode('p', '', compactDiagnosticCause(weakSignalDiagnostic))
    );
  }
  if (minimumDiagnostic) {
    cause.append(
      textNode('strong', 'wifi-diagnostic-label', `Lowest single event (${minimumConfidence})`),
      textNode('p', '', 'This identifies the record to retest. One lowest value alone cannot prove a point, AP, or robot fault.')
    );
  }

  const actions = document.createElement('div');
  actions.className = 'wifi-minimum-resolution';
  actions.append(textNode('h6', '', 'Do this next'));
  const actionList = document.createElement('ol');
  conciseWifiActions(weakSignalDiagnostic || minimumDiagnostic).slice(0, 3).forEach((item) => (
    actionList.append(textNode('li', '', item))
  ));
  actions.append(actionList);

  const evidence = document.createElement('details');
  evidence.className = 'wifi-evidence-details';
  evidence.append(textNode('summary', '', 'View evidence and rules'));
  const evidenceList = document.createElement('ul');
  if (weakSignalDiagnostic) {
    (weakSignalDiagnostic.evidence || []).forEach((item) => (
      evidenceList.append(textNode('li', '', `Repeated pattern: ${item}`))
    ));
  }
  if (minimumDiagnostic) {
    (minimumDiagnostic.evidence || []).forEach((item) => (
      evidenceList.append(textNode('li', '', `Minimum event: ${item}`))
    ));
  }
  evidence.append(evidenceList);

  const rules = [
    minimumDiagnostic && `Minimum event: ${minimumDiagnostic.rule_id || '--'} (v${minimumDiagnostic.rule_version || '--'})`,
    weakSignalDiagnostic && `Repeated pattern: ${weakSignalDiagnostic.rule_id || '--'} (v${weakSignalDiagnostic.rule_version || '--'})`
  ].filter(Boolean);
  const footer = textNode('p', 'wifi-minimum-rule', `Transparent rules: ${rules.join(' | ')}`);

  const rationale = document.createElement('div');
  rationale.className = 'wifi-minimum-rationale';
  rationale.append(cause, evidence);
  const body = document.createElement('div');
  body.className = 'wifi-minimum-body';
  body.append(rationale, actions);
  panel.append(header, facts, body, footer);
  return panel;
}

function renderRunningWifiNarrative(payload, selectedPoi, selectedRobot, targetRows) {
  const host = elements.runningWifiNarrative;
  const minimumHost = elements.runningWifiMinimumDiagnostic;
  const summary = payload.summary || {};
  const robotRows = selectedPoi === 'ALL'
    ? (payload.byRobot || [])
    : (payload.byRobotTarget || []).filter((row) => String(row.poi_target) === selectedPoi);
  host.replaceChildren();
  host.classList.remove('empty-state');

  if (!asNumber(summary.running_matched_sample_count)) {
    minimumHost.replaceChildren();
    minimumHost.classList.add('empty-state');
    minimumHost.textContent = 'No locatable minimum RSSI record exists in the current analysis window.';
    host.classList.add('empty-state');
    host.textContent = 'No job and WiFi records share the same robot, timestamp, and Running status in the current analysis window.';
    return;
  }

  const selectedRow = selectedPoi === 'ALL'
    ? null
    : targetRows.find((row) => String(row.poi_target) === selectedPoi);
  const selectedRobotRow = selectedRobot === 'ALL'
    ? null
    : (payload.byRobot || []).find((row) => String(row.robot_code) === selectedRobot);
  const scope = selectedRow || selectedRobotRow || summary;
  const sampleCount = asNumber(scope.sample_count ?? summary.running_matched_sample_count);
  const validCount = asNumber(scope.valid_signal_sample_count);
  const zeroCount = asNumber(scope.zero_signal_sample_count);
  const zeroRate = sampleCount > 0 ? (zeroCount / sampleCount) * 100 : 0;
  const minimumDiagnostic = findWifiMinimumDiagnostic(payload, selectedRobot, selectedPoi);
  const weakSignalDiagnostic = findWeakSignalDiagnostic(payload, selectedRobot, selectedPoi);
  const title = textNode('h4', '', 'Data Scope');
  const lead = textNode(
    'p',
    'wifi-analysis-lead',
    summary.is_current
      ? `${formatNumber(sampleCount)} Running-task WiFi samples match the current filters.`
      : summary.source_is_current
        ? `ODS source data is current, but the latest matched Running sample is ${formatNumber(summary.running_sample_age_minutes)} minutes old.`
        : `This view shows historical data: the latest ODS record is ${formatNumber(summary.source_age_minutes)} minutes old.`
  );

  const sourceRobots = robotRows
    .filter((row) => selectedRobot === 'ALL' || String(row.robot_code) === selectedRobot)
    .sort((a, b) => asNumber(b.sample_count) - asNumber(a.sample_count));
  const robotSource = document.createElement('div');
  robotSource.className = 'wifi-source-robots';
  robotSource.append(textNode('span', '', 'Robots contributing signal data'));
  const robotChips = document.createElement('div');
  robotChips.className = 'wifi-source-robot-chips';
  sourceRobots.forEach((row) => {
    const chip = textNode(
      'button',
      '',
      `${row.robot_code} · ${formatNumber(row.sample_count)} samples · ${formatNumber(row.average_valid_rssi, 1)} dBm`
    );
    chip.type = 'button';
    chip.addEventListener('click', () => {
      // Drill-down chip: narrow to this one robot and reset the target scope.
      state.selectedWifiRobots = [String(row.robot_code)];
      state.selectedWifiPois = [];
      renderRunningWifiAnalysis(state.dashboard?.wifiRunningAnalysis || {});
    });
    robotChips.append(chip);
  });
  if (!sourceRobots.length) robotChips.append(textNode('span', 'empty-inline', 'No matched robots'));
  robotSource.append(robotChips);

  const metrics = document.createElement('div');
  metrics.className = 'wifi-analysis-metrics';
  [
    ['Matched samples', formatNumber(sampleCount), 'Running + exact timestamp match'],
    ['Average RSSI', `${formatNumber(scope.average_valid_rssi, 1)} dBm`, `${formatNumber(validCount)} valid negative-RSSI samples`],
    [
      'Minimum RSSI',
      `${formatNumber(scope.minimum_valid_rssi, 1)} dBm`,
      minimumDiagnostic
        ? `${minimumDiagnostic.robot_code} · ${minimumDiagnostic.poi_target} · ${formatDateTime(minimumDiagnostic.event_time)}`
        : 'Observed minimum in the window'
    ],
    ['Confirmed zero signal', `${formatNumber(zeroCount)} · ${formatPercent(zeroRate, 1)}`, 'wifi_signal_level = 0']
  ].forEach(([label, value, detail]) => {
    const item = document.createElement('div');
    item.append(textNode('span', '', label), textNode('strong', '', value), textNode('small', '', detail));
    metrics.append(item);
  });
  minimumHost.replaceChildren(renderWifiCombinedDiagnostic(minimumDiagnostic, weakSignalDiagnostic, summary));
  minimumHost.classList.remove('empty-state');

  const boundary = textNode(
    'p',
    'wifi-scope-note',
    `Scope: ${formatNumber(sourceRobots.length)} robots, ${formatNumber(targetRows.length)} target POIs, ${formatNumber(validCount)} valid RSSI rows. Target POI is a task destination, not a measured physical RF position. Use the conclusion above for the rule and next step.`
  );

  host.append(title, lead, robotSource, metrics, boundary);
}

function primaryWifiDiagnostic(payload, selectedRobot, selectedPoi) {
  if (selectedRobot !== 'ALL' || selectedPoi !== 'ALL') {
    return findWeakSignalDiagnostic(payload, selectedRobot, selectedPoi);
  }
  const confidenceRank = { HIGH: 3, MEDIUM: 2, LOW: 1 };
  const robotRows = new Map((payload.byRobot || []).map((row) => [String(row.robot_code), row]));
  return (payload.weakSignalDiagnostics || [])
    .filter((item) => item.scope_type === 'ROBOT')
    .slice()
    .sort((left, right) => {
      const confidenceGap = asNumber(confidenceRank[String(right.confidence || 'LOW').toUpperCase()])
        - asNumber(confidenceRank[String(left.confidence || 'LOW').toUpperCase()]);
      if (confidenceGap) return confidenceGap;
      const leftRow = robotRows.get(String(left.scope_robot_code)) || {};
      const rightRow = robotRows.get(String(right.scope_robot_code)) || {};
      return asNumber(rightRow.weak_signal_rate) - asNumber(leftRow.weak_signal_rate)
        || asNumber(rightRow.weak_signal_sample_count) - asNumber(leftRow.weak_signal_sample_count);
    })[0] || null;
}

function conciseWifiCause(diagnostic, payload) {
  if (!diagnostic) return 'No weak-signal rule was triggered in the selected strict samples.';
  if (diagnostic.cause_status === 'DATA_QUALITY_RISK') {
    return 'The RSSI value remains fixed across many samples. Validate the telemetry stream before changing wireless hardware.';
  }
  if (diagnostic.scope_type === 'ROBOT') {
    const robotRow = (payload.byRobot || []).find((row) => String(row.robot_code) === String(diagnostic.scope_robot_code)) || {};
    return `${diagnostic.scope_robot_code} has weak samples across ${formatNumber(robotRow.weak_target_count)} task destinations. This is a robot-side candidate, not a confirmed hardware fault.`;
  }
  const targetRow = (payload.byTarget || []).find((row) => String(row.poi_target) === String(diagnostic.scope_poi_target)) || {};
  return `${diagnostic.scope_poi_target} is associated with weak samples from ${formatNumber(targetRow.weak_robot_count)} robots. This is a route/area candidate, not proof of the exact physical point.`;
}

function conciseWifiActions(diagnostic) {
  if (!diagnostic) return ['Collect more strict Running-task WiFi samples before scheduling maintenance.'];
  if (diagnostic.cause_status === 'DATA_QUALITY_RISK') {
    return [
      'Verify that raw RSSI changes on the robot and in ODS.',
      'Repair collection or publishing if only the ODS value is fixed.',
      'Retest the route after telemetry is validated.'
    ];
  }
  if (diagnostic.scope_type === 'ROBOT') {
    return [
      `Run ${diagnostic.scope_robot_code} and one comparison robot on the same route.`,
      `Inspect ${diagnostic.scope_robot_code}'s antenna, cable, WiFi adapter, and roaming configuration.`,
      'Check controller association, retry, and roaming logs during the peak window.'
    ];
  }
  return [
    `Run at least two robots on the route associated with ${diagnostic.scope_poi_target}.`,
    'Check AP coverage, channel plan, interference, and roaming during the peak window.',
    'Make physical changes only after the pattern repeats across robots.'
  ];
}

function compactDiagnosticCause(diagnostic) {
  if (!diagnostic) return 'No repeatable weak-signal pattern is available in this filter.';
  if (diagnostic.cause_status === 'DATA_QUALITY_RISK') {
    return 'RSSI is fixed across many samples. Check telemetry before changing WiFi hardware.';
  }
  if (diagnostic.scope_type === 'ROBOT') {
    return 'Weak readings repeat across several task destinations. Check this robot first, then compare it on the same route with another robot.';
  }
  return 'Weak readings repeat across several robots. Check the route area and AP behavior; target POI is not an exact RF position.';
}

function renderWifiConclusion(payload, selectedRobot, selectedPoi) {
  const host = elements.wifiConclusion;
  const summary = payload.summary || {};
  const threshold = asNumber(summary.weak_rssi_threshold || -67);
  host.replaceChildren();
  host.classList.remove('empty-state');

  if (!asNumber(summary.running_matched_sample_count)) {
    host.classList.add('empty-state');
    host.textContent = 'No conclusion: this time period has no strict match of Running task, robot ID, timestamp, and target POI.';
    return;
  }

  const diagnostic = primaryWifiDiagnostic(payload, selectedRobot, selectedPoi);
  const timeline = aggregateWeakSignalTimeline(payload.weakTimeline || [], selectedRobot, selectedPoi);
  const peak = timeline.reduce((current, row) => (
    !current || asNumber(row.weak_signal_sample_count) > asNumber(current.weak_signal_sample_count) ? row : current
  ), null);
  const totalWeak = timeline.reduce((total, row) => total + asNumber(row.weak_signal_sample_count), 0);
  const peakShare = peak && totalWeak > 0
    ? (100 * asNumber(peak.weak_signal_sample_count)) / totalWeak
    : null;
  const scope = selectedRobot !== 'ALL' ? selectedRobot : selectedPoi !== 'ALL' ? selectedPoi : 'Fleet';
  const hasWeakSignal = asNumber(summary.weak_signal_sample_count) > 0;

  const heading = textNode(
    'h3',
    '',
    hasWeakSignal
      ? `${scope}: WiFi follow-up is needed`
      : `${scope}: no weak-signal threshold was reached`
  );
  const summaryText = textNode(
    'p',
    'wifi-conclusion-summary',
    hasWeakSignal
      ? conciseWifiCause(diagnostic, payload)
      : `No strict Running-task sample is at or below ${formatNumber(threshold)} dBm. This does not assess periods without matched task and WiFi records.`
  );
  const header = document.createElement('header');
  header.append(textNode('span', 'section-kicker', 'WIFI CONCLUSION'), heading, summaryText);

  const metrics = document.createElement('div');
  metrics.className = 'wifi-conclusion-metrics';
  [
    ['Weak rate', hasWeakSignal ? formatPercent(summary.weak_signal_rate, 1) : '0%', `RSSI <= ${formatNumber(threshold)} dBm`],
    ['Priority scope', diagnostic ? (diagnostic.scope_robot_code || diagnostic.scope_poi_target || scope) : scope, diagnostic?.cause_status?.replaceAll('_', ' ') || 'No weak pattern'],
    ['Peak time', peak ? weakBucketLabel(peak.bucket_start, asNumber(summary.analysis_window_hours)) : '--', peak ? `${formatNumber(peak.weak_signal_sample_count)} weak rows${peakShare == null ? '' : ` (${formatPercent(peakShare, 1)})`}` : 'No weak rows'],
    ['Next action', conciseWifiActions(diagnostic)[0], 'Complete this before hardware replacement']
  ].forEach(([label, value, detail]) => {
    const metric = document.createElement('div');
    metric.append(textNode('span', '', label), textNode('strong', '', value), textNode('small', '', detail));
    metrics.append(metric);
  });

  const details = document.createElement('details');
  details.className = 'wifi-method-details';
  details.append(textNode('summary', '', 'How this conclusion is determined'));
  const methodList = document.createElement('ul');
  [
    'Data scope: ODS job and WiFi rows must have the same robot ID and exact timestamp; job_status must be Running and target POI must exist.',
    `Weak signal: negative RSSI <= ${formatNumber(threshold)} dBm. The rate is weak rows divided by valid negative-RSSI rows; zero-signal rows are excluded.`,
    'Confidence: a single minimum is LOW; repeated weak samples across multiple task destinations or across robots can be MEDIUM; fixed RSSI values are a HIGH data-quality risk.',
    diagnostic ? `Triggered rule: ${diagnostic.rule_id} (version ${diagnostic.rule_version}).` : 'No weak-signal rule was triggered.'
  ].forEach((item) => methodList.append(textNode('li', '', item)));
  details.append(methodList);

  host.append(header, metrics, details);
}

/*
  Checkbox dropdown for the Running-task WiFi filters.

  No checkbox ticked means "all", which matches the previous 'ALL' option
  without needing a sentinel entry in the list.
*/
function renderMultiSelect(menuHost, toggle, toggleText, values, selected, allLabel, onChange) {
  if (!menuHost || !toggle || !toggleText) return;
  menuHost.replaceChildren();

  if (!values.length) {
    toggle.disabled = true;
    toggleText.textContent = allLabel;
    menuHost.append(textNode('div', 'multi-select-empty', 'No options are available for the current range.'));
    return;
  }
  toggle.disabled = false;

  const actions = document.createElement('div');
  actions.className = 'multi-select-actions';
  const selectAll = document.createElement('button');
  selectAll.type = 'button';
  selectAll.textContent = 'Select all';
  selectAll.addEventListener('click', () => onChange([...values]));
  const clear = document.createElement('button');
  clear.type = 'button';
  clear.textContent = 'Clear';
  clear.addEventListener('click', () => onChange([]));
  actions.append(selectAll, clear);
  menuHost.append(actions);

  const selectedSet = new Set(selected);
  values.forEach((value) => {
    const option = document.createElement('label');
    option.className = 'multi-select-option';
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.value = value;
    box.checked = selectedSet.has(value);
    box.addEventListener('change', () => {
      const next = new Set(selectedSet);
      if (box.checked) next.add(value);
      else next.delete(value);
      onChange(values.filter((item) => next.has(item)));
    });
    const caption = document.createElement('span');
    caption.textContent = value;
    caption.title = value;
    option.append(box, caption);
    menuHost.append(option);
  });

  // No selection and every option selected both mean "no filter".
  if (!selected.length || selected.length === values.length) {
    toggleText.textContent = allLabel;
  } else if (selected.length === 1) {
    toggleText.textContent = selected[0];
  } else {
    toggleText.textContent = `${selected.length} selected`;
  }
  toggleText.parentElement.title = selected.length ? selected.join(', ') : allLabel;
}

function closeMultiSelectMenus(except) {
  [
    [elements.wifiRobotToggle, elements.wifiRobotMenu],
    [elements.wifiPoiToggle, elements.wifiPoiMenu],
    [elements.projectToggle, elements.projectMenu],
    [elements.taskToggle, elements.taskMenu],
    [elements.robotToggle, elements.robotMenu],
    [elements.analysisProjectToggle, elements.analysisProjectMenu],
    [elements.analysisTaskToggle, elements.analysisTaskMenu],
    [elements.analysisRobotToggle, elements.analysisRobotMenu]
  ]
    .forEach(([toggle, menu]) => {
      if (!toggle || !menu || menu === except) return;
      menu.hidden = true;
      toggle.setAttribute('aria-expanded', 'false');
    });
}

function bindMultiSelectToggle(toggle, menu) {
  if (!toggle || !menu) return;
  toggle.addEventListener('click', (event) => {
    event.stopPropagation();
    const open = menu.hidden;
    closeMultiSelectMenus(open ? menu : null);
    menu.hidden = !open;
    toggle.setAttribute('aria-expanded', String(open));
  });
  menu.addEventListener('click', (event) => event.stopPropagation());
}

/*
  Keep the legacy single-value state in sync so the existing renderers keep
  working: one selection behaves exactly as before, zero or several fall back
  to 'ALL' and the array is applied by the callers that support it.
*/
function syncWifiLegacySelection(values, availableCount) {
  if (values.length === 1) return values[0];
  if (values.length && values.length < availableCount) return 'ALL';
  return 'ALL';
}

function renderRunningWifiAnalysis(payload) {
  if (!elements.runningWifiTrendChart || !elements.wifiPoiToggle || !elements.wifiRobotToggle) return;
  const summary = payload.summary || {};
  const trendGrain = payload.trendGrain || {
    label: `${formatNumber(summary.bucket_minutes || 15)} Minutes`,
    bucketLabel: `${formatNumber(summary.bucket_minutes || 15)}-minute buckets`
  };
  const byRobot = payload.byRobot || [];
  const robotTargets = payload.byRobotTarget || [];
  const actualAnalysisHours = asNumber(summary.analysis_window_hours);
  const requestedAnalysisHours = asNumber(payload.window?.hours, state.window.hours);
  const rangeIsLimited = actualAnalysisHours > 0 && actualAnalysisHours < requestedAnalysisHours;

  const sourceAge = asNumber(summary.source_age_minutes);
  const sourceIsCurrent = summary.source_is_current === true || asNumber(summary.source_is_current) === 1;
  elements.runningWifiFreshness.dataset.tone = sourceIsCurrent ? 'current' : 'stale';
  elements.runningWifiFreshness.textContent = sourceIsCurrent
    ? `Analysis data: Current · ${formatNumber(sourceAge)} min`
    : `Analysis data: Stale · ${formatNumber(sourceAge)} min`;
  elements.runningWifiFreshness.title = 'Freshness of the records used by this Running-task WiFi analysis.';
  renderWifiConclusion(payload, state.selectedWifiRobot, state.selectedWifiPoi);

  if (rangeIsLimited) {
    state.selectedWifiRobot = 'ALL';
    state.selectedWifiPoi = 'ALL';
    state.selectedWifiRobots = [];
    state.selectedWifiPois = [];
    elements.wifiRobotMenu.replaceChildren();
    elements.wifiPoiMenu.replaceChildren();
    elements.wifiRobotMenu.append(textNode('div', 'multi-select-empty', 'Long-range data not loaded'));
    elements.wifiPoiMenu.append(textNode('div', 'multi-select-empty', 'Long-range data not loaded'));
    elements.wifiRobotToggleText.textContent = 'Long-range data not loaded';
    elements.wifiPoiToggleText.textContent = 'Long-range data not loaded';
    elements.wifiRobotToggle.disabled = true;
    elements.wifiPoiToggle.disabled = true;
    closeMultiSelectMenus(null);
    elements.runningWifiFreshness.dataset.tone = 'stale';
    elements.runningWifiFreshness.textContent = 'Long-range query is not enabled';
    elements.runningWifiChartSubtitle.textContent = `${state.window.label} is synchronized; the current safe ODS query limit is ${formatNumber(actualAnalysisHours)} hours.`;
    elements.wifiPointStrengthSubtitle.textContent = 'No 24-hour data is used as a substitute for the selected long-range result.';
    [
      [elements.runningWifiTrendChart, 'WiFi trend data for the current time range is not loaded.'],
      [elements.runningWifiMinimumDiagnostic, 'Minimum-value diagnostics for the current time range are not loaded.'],
      [elements.runningWifiNarrative, 'An ODS long-range query index is required before findings can be generated for this time range.'],
      [elements.weakSignalRateChart, 'Weak-signal rates for the current time range are not loaded.'],
      [elements.weakSignalTimelineChart, 'Weak-signal timing for the current time range is not loaded.'],
      [elements.wifiPointStrengthChart, 'Target-POI signal data for the current time range is not loaded.']
    ].forEach(([host, message]) => {
      host.replaceChildren();
      host.classList.add('empty-state');
      host.textContent = message;
    });
    return;
  }

  elements.wifiRobotToggle.disabled = false;
  elements.wifiPoiToggle.disabled = false;

  const robotValues = byRobot
    .map((row) => String(row.robot_code))
    .sort((a, b) => a.localeCompare(b, 'en'));
  const availableRobots = new Set(robotValues);
  // Drop selections that the current time range no longer offers.
  state.selectedWifiRobots = state.selectedWifiRobots.filter((code) => availableRobots.has(code));
  state.selectedWifiRobot = syncWifiLegacySelection(state.selectedWifiRobots, robotValues.length);

  // A single robot selection keeps the per-robot target rows; otherwise use the
  // fleet-wide target rows and narrow them by the selected robots.
  const robotFilterActive = state.selectedWifiRobots.length > 0
    && state.selectedWifiRobots.length < robotValues.length;
  const selectedRobotSet = new Set(state.selectedWifiRobots);
  const targetRows = !robotFilterActive
    ? (payload.byTarget || [])
    : state.selectedWifiRobots.length === 1
      ? robotTargets
        .filter((row) => selectedRobotSet.has(String(row.robot_code)))
        .map((row) => ({ ...row, robot_count: 1 }))
      : aggregateTargetRowsForRobots(robotTargets, selectedRobotSet);

  const targetValues = targetRows
    .map((row) => String(row.poi_target))
    .sort((a, b) => a.localeCompare(b, 'en'));
  const availableTargets = new Set(targetValues);
  state.selectedWifiPois = state.selectedWifiPois.filter((poi) => availableTargets.has(poi));
  state.selectedWifiPoi = syncWifiLegacySelection(state.selectedWifiPois, targetValues.length);

  const activeRobotCount = asNumber(state.dashboard?.summary?.active_robot_count);
  const allRobotsLabel = activeRobotCount > 0
    ? `All eligible (${formatNumber(byRobot.length)} / ${formatNumber(activeRobotCount)})`
    : `All eligible (${formatNumber(byRobot.length)})`;

  renderMultiSelect(
    elements.wifiRobotMenu,
    elements.wifiRobotToggle,
    elements.wifiRobotToggleText,
    robotValues,
    state.selectedWifiRobots,
    allRobotsLabel,
    (next) => {
      state.selectedWifiRobots = next;
      // Robot scope changed, so target options are recomputed on the next pass.
      state.selectedWifiPois = [];
      renderRunningWifiAnalysis(state.dashboard?.wifiRunningAnalysis || {});
    }
  );

  renderMultiSelect(
    elements.wifiPoiMenu,
    elements.wifiPoiToggle,
    elements.wifiPoiToggleText,
    targetValues,
    state.selectedWifiPois,
    `All targets (${formatNumber(targetValues.length)})`,
    (next) => {
      state.selectedWifiPois = next;
      renderRunningWifiAnalysis(state.dashboard?.wifiRunningAnalysis || {});
    }
  );

  const robotScopeLabel = !robotFilterActive
    ? 'All robots'
    : state.selectedWifiRobots.length === 1
      ? state.selectedWifiRobots[0]
      : `${state.selectedWifiRobots.length} robots`;
  const poiFilterActive = state.selectedWifiPois.length > 0
    && state.selectedWifiPois.length < targetValues.length;
  const poiScopeLabel = !poiFilterActive
    ? 'All targets'
    : state.selectedWifiPois.length === 1
      ? state.selectedWifiPois[0]
      : `${state.selectedWifiPois.length} targets`;
  const scopeLabel = [robotScopeLabel, poiScopeLabel].join(' · ');
  if (elements.runningWifiTrendTitle) elements.runningWifiTrendTitle.textContent = `RSSI Trend by ${trendGrain.label} During Running Tasks`;
  if (elements.weakSignalTimelineTitle) elements.weakSignalTimelineTitle.textContent = `Weak-Signal Time Distribution by ${trendGrain.label}`;
  elements.runningWifiChartSubtitle.textContent = `${scopeLabel} · ${formatNumber(summary.analysis_window_hours)} hours · ${trendGrain.bucketLabel} · averages exclude zero-signal samples`;

  const trend = aggregateRunningWifiTrendMulti(
    payload.trend || [],
    state.selectedWifiPois,
    state.selectedWifiRobots
  );
  renderRunningWifiTrend(elements.runningWifiTrendChart, trend);
  renderRunningWifiNarrative(payload, state.selectedWifiPoi, state.selectedWifiRobot, targetRows);
  renderWeakSignalRate(payload, state.selectedWifiRobot, state.selectedWifiPoi);
  renderWeakSignalTimeline(payload, state.selectedWifiRobot, state.selectedWifiPoi);
  renderWifiPointComparison(payload);
}
