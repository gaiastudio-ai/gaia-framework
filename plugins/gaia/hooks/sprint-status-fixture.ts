// Writer-generated fixture: produced by running sprint-progress-snapshot.sh on
// a fixture project (E900-S1..S9, sprint-84, 2026-10-12..2026-10-18) with the
// real writer.  Time-dependent fields (generated_at, day.current, day.pace)
// are pinned to known values for deterministic tests.
//
// Statuses include ready-for-dev (the canonical writer value), gate names use
// the 6 canonical forms, and sprint.id starts with "sprint-".

export const WRITER_CACHE = {
  schema_version: '1.0',
  generated_at: '2026-10-15T00:00:00Z',
  sprint: {
    id: 'sprint-84', goal: 'Ship the dashboard',
    start_date: '2026-10-12', end_date: '2026-10-18',
    status: 'active', total_days: 7,
    capacity_utilization: null, epic_focus: null
  },
  totals: {
    done_points: 8, total_points: 40,
    done_stories: 2, total_stories: 9, progress_pct: 20
  },
  by_status: {
    done: { count: 2, points: 8 },
    'in-progress': { count: 2, points: 13 },
    review: { count: 1, points: 5 },
    'ready-for-dev': { count: 2, points: 5 },
    blocked: { count: 1, points: 5 },
    backlog: { count: 1, points: 4 }
  },
  day: { current: 3, total: 7, pace: 'behind-pace' },
  active_phase: 2,
  phases: [
    { phase: 1, status: 'done', stories: ['E900-S1', 'E900-S2'], done_count: 2, total_count: 2 },
    { phase: 2, status: 'active', stories: ['E900-S3', 'E900-S4', 'E900-S5'], done_count: 0, total_count: 3 },
    { phase: 3, status: 'future', stories: ['E900-S6', 'E900-S7'], done_count: 0, total_count: 2 }
  ],
  unphased_stories: ['E900-S8', 'E900-S9'],
  stories: [
    { key: 'E900-S1', title: 'First story done', slug: 'E900-S1', status: 'done', points: 5, phase: 1, risk_level: 'low', blocked_by: null, blocked_since: null,
      tasks: { done: 2, total: 2, items: [{ text: 'Task A', done: true }, { text: 'Task B', done: true }] },
      gates: { passed: 6, total: 6, rows: [
        { name: 'Code Review', status: 'PASSED' }, { name: 'QA Tests', status: 'PASSED' },
        { name: 'Security Review', status: 'PASSED' }, { name: 'Test Automation', status: 'PASSED' },
        { name: 'Test Review', status: 'PASSED' }, { name: 'Performance Review', status: 'PASSED' }
      ] },
      manual_test: { required: false, verdict: null } },
    { key: 'E900-S2', title: 'Second story done', slug: 'E900-S2', status: 'done', points: 3, phase: 1, risk_level: 'low', blocked_by: null, blocked_since: null,
      tasks: { done: 0, total: 0, items: [] },
      gates: { passed: 6, total: 6, rows: [
        { name: 'Code Review', status: 'PASSED' }, { name: 'QA Tests', status: 'PASSED' },
        { name: 'Security Review', status: 'PASSED' }, { name: 'Test Automation', status: 'PASSED' },
        { name: 'Test Review', status: 'PASSED' }, { name: 'Performance Review', status: 'PASSED' }
      ] },
      manual_test: { required: false, verdict: null } },
    { key: 'E900-S3', title: 'Third story in progress', slug: 'E900-S3', status: 'in-progress', points: 8, phase: 2, risk_level: 'high', blocked_by: null, blocked_since: null,
      tasks: { done: 1, total: 3, items: [{ text: 'Implement feature', done: true }, { text: 'Write tests', done: false }, { text: 'Document', done: false }] },
      gates: { passed: 2, total: 6, rows: [
        { name: 'Code Review', status: 'PASSED' }, { name: 'QA Tests', status: 'PASSED' },
        { name: 'Security Review', status: 'UNVERIFIED' }, { name: 'Test Automation', status: 'UNVERIFIED' },
        { name: 'Test Review', status: 'UNVERIFIED' }, { name: 'Performance Review', status: 'UNVERIFIED' }
      ] },
      manual_test: { required: true, verdict: null } },
    { key: 'E900-S4', title: 'Fourth story review', slug: 'E900-S4', status: 'review', points: 5, phase: 2, risk_level: 'medium', blocked_by: null, blocked_since: null,
      tasks: { done: 2, total: 2, items: [{ text: 'Implement', done: true }, { text: 'Test', done: true }] },
      gates: { passed: 6, total: 6, rows: [
        { name: 'Code Review', status: 'PASSED' }, { name: 'QA Tests', status: 'PASSED' },
        { name: 'Security Review', status: 'PASSED' }, { name: 'Test Automation', status: 'PASSED' },
        { name: 'Test Review', status: 'PASSED' }, { name: 'Performance Review', status: 'PASSED' }
      ] },
      manual_test: { required: true, verdict: 'PASSED' } },
    { key: 'E900-S5', title: 'Fifth story in progress', slug: 'E900-S5', status: 'in-progress', points: 5, phase: 2, risk_level: 'low', blocked_by: null, blocked_since: null,
      tasks: { done: 0, total: 1, items: [{ text: 'Start work', done: false }] },
      gates: { passed: 0, total: 6, rows: [
        { name: 'Code Review', status: 'UNVERIFIED' }, { name: 'QA Tests', status: 'UNVERIFIED' },
        { name: 'Security Review', status: 'UNVERIFIED' }, { name: 'Test Automation', status: 'UNVERIFIED' },
        { name: 'Test Review', status: 'UNVERIFIED' }, { name: 'Performance Review', status: 'UNVERIFIED' }
      ] },
      manual_test: { required: false, verdict: null } },
    { key: 'E900-S6', title: 'Sixth story ready for dev', slug: 'E900-S6', status: 'ready-for-dev', points: 3, phase: 3, risk_level: 'low', blocked_by: null, blocked_since: null,
      tasks: { done: 0, total: 0, items: [] },
      gates: { passed: 0, total: 6, rows: [
        { name: 'Code Review', status: 'UNVERIFIED' }, { name: 'QA Tests', status: 'UNVERIFIED' },
        { name: 'Security Review', status: 'UNVERIFIED' }, { name: 'Test Automation', status: 'UNVERIFIED' },
        { name: 'Test Review', status: 'UNVERIFIED' }, { name: 'Performance Review', status: 'UNVERIFIED' }
      ] },
      manual_test: { required: false, verdict: null } },
    { key: 'E900-S7', title: 'Seventh story ready for dev', slug: 'E900-S7', status: 'ready-for-dev', points: 2, phase: 3, risk_level: 'low', blocked_by: null, blocked_since: null,
      tasks: { done: 0, total: 0, items: [] },
      gates: { passed: 0, total: 6, rows: [
        { name: 'Code Review', status: 'UNVERIFIED' }, { name: 'QA Tests', status: 'UNVERIFIED' },
        { name: 'Security Review', status: 'UNVERIFIED' }, { name: 'Test Automation', status: 'UNVERIFIED' },
        { name: 'Test Review', status: 'UNVERIFIED' }, { name: 'Performance Review', status: 'UNVERIFIED' }
      ] },
      manual_test: { required: false, verdict: null } },
    { key: 'E900-S8', title: 'Eighth story blocked', slug: 'E900-S8', status: 'blocked', points: 5, phase: null, risk_level: 'low', blocked_by: null, blocked_since: '2026-10-15',
      tasks: { done: 0, total: 0, items: [] },
      gates: { passed: 0, total: 6, rows: [
        { name: 'Code Review', status: 'UNVERIFIED' }, { name: 'QA Tests', status: 'UNVERIFIED' },
        { name: 'Security Review', status: 'UNVERIFIED' }, { name: 'Test Automation', status: 'UNVERIFIED' },
        { name: 'Test Review', status: 'UNVERIFIED' }, { name: 'Performance Review', status: 'UNVERIFIED' }
      ] },
      manual_test: { required: false, verdict: null } },
    { key: 'E900-S9', title: 'Ninth story backlog', slug: 'E900-S9', status: 'backlog', points: 4, phase: null, risk_level: 'low', blocked_by: null, blocked_since: null,
      tasks: { done: 0, total: 0, items: [] },
      gates: { passed: 0, total: 6, rows: [
        { name: 'Code Review', status: 'UNVERIFIED' }, { name: 'QA Tests', status: 'UNVERIFIED' },
        { name: 'Security Review', status: 'UNVERIFIED' }, { name: 'Test Automation', status: 'UNVERIFIED' },
        { name: 'Test Review', status: 'UNVERIFIED' }, { name: 'Performance Review', status: 'UNVERIFIED' }
      ] },
      manual_test: { required: false, verdict: null } }
  ],
  action_needed: [] as any[],
  drift: [] as any[],
  readiness: { sprint_review: false, sprint_close: false },
  user_aliases: ['user'],
  waiting_agent_threshold_seconds: 120
}

export const GAIA_ROOT = '/project'
export const OK_RUN = { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }

export function deepCopy<T>(obj: T): T {
  return JSON.parse(JSON.stringify(obj))
}
