'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { describeTrendGrain, trendBucketMinutesForDuration } = require('../src/trend-grain');

test('uses 5-minute buckets through six hours', () => {
  assert.equal(trendBucketMinutesForDuration(1), 5);
  assert.equal(trendBucketMinutesForDuration(360), 5);
});

test('uses 15-minute buckets above six hours through 24 hours', () => {
  assert.equal(trendBucketMinutesForDuration(361), 15);
  assert.equal(trendBucketMinutesForDuration(1440), 15);
});

test('uses hourly buckets above 24 hours through seven days', () => {
  assert.equal(trendBucketMinutesForDuration(1441), 60);
  assert.equal(trendBucketMinutesForDuration(10080), 60);
});

test('uses daily buckets above seven days', () => {
  assert.equal(trendBucketMinutesForDuration(10081), 1440);
  assert.deepEqual(describeTrendGrain(1440), {
    bucketMinutes: 1440,
    label: 'Day',
    bucketLabel: 'daily buckets'
  });
});

test('all three SQL trend sources implement the same duration boundaries', () => {
  const queryFiles = [
    'project-analytics-query.sql',
    'task-trend-query.sql',
    'wifi-running-analysis-query.sql'
  ];
  queryFiles.forEach((fileName) => {
    const source = fs.readFileSync(path.join(__dirname, '..', 'src', fileName), 'utf8');
    assert.match(source, /<= 21600 THEN 5/);
    assert.match(source, /<= 86400 THEN 15/);
    assert.match(source, /<= 604800 THEN 60/);
    assert.match(source, /ELSE 1440/);
  });
});

test('WiFi RSSI and weak-signal timelines share one bucket variable', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'src', 'wifi-running-analysis-query.sql'), 'utf8');
  assert.doesNotMatch(source, /weak_time_bucket_minutes/);
  assert.equal((source.match(/\/ @bucket_minutes/g) || []).length >= 3, true);
});
