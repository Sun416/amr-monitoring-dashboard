'use strict';

const GRAIN_BY_MINUTES = new Map([
  [5, { bucketMinutes: 5, label: '5 Minutes', bucketLabel: '5-minute buckets' }],
  [15, { bucketMinutes: 15, label: '15 Minutes', bucketLabel: '15-minute buckets' }],
  [60, { bucketMinutes: 60, label: 'Hour', bucketLabel: 'hourly buckets' }],
  [1440, { bucketMinutes: 1440, label: 'Day', bucketLabel: 'daily buckets' }]
]);

function trendBucketMinutesForDuration(durationMinutes) {
  const minutes = Number(durationMinutes);
  if (!Number.isFinite(minutes) || minutes <= 0) return 15;
  if (minutes <= 6 * 60) return 5;
  if (minutes <= 24 * 60) return 15;
  if (minutes <= 7 * 24 * 60) return 60;
  return 1440;
}

function describeTrendGrain(bucketMinutes) {
  const normalized = Number(bucketMinutes);
  return GRAIN_BY_MINUTES.get(normalized) || {
    bucketMinutes: normalized,
    label: `${normalized} Minutes`,
    bucketLabel: `${normalized}-minute buckets`
  };
}

module.exports = {
  describeTrendGrain,
  trendBucketMinutesForDuration
};
