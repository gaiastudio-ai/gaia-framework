// Pure agent-activity computation module.
// Maps $.agent.list() results to story-keyed activity records and rule-b
// waiting-on-user items.  No side effects, no $.* calls — all inputs are
// plain values so the module can be unit-tested directly.

import { sanitize, DESCRIPTION_MAX } from './sanitize.js'

// Story-key extraction regexes (anchored).
var DESC_KEY_RE = /^(E[0-9]+-S[0-9]+):/
var MATE_KEY_RE = /-(E[0-9]+-S[0-9]+)$/

// Maximum activity sub-lines per story or in the unlinked bucket before
// the rest are collapsed into an "+N more" overflow count.
var ACTIVITY_CAP = 5

/**
 * Extract a story key from an agent record.
 *
 * Precedence: teammateId (dispatcher-set, trusted) > description (anchored).
 * Returns null when neither matches.
 *
 * @param {object} agent - agent record from $.agent.list()
 * @returns {string|null} story key or null
 */
export function extractStoryKey(agent) {
  // teammateId: end-anchored, only fires when the engine's teammateId
  // carries the GAIA handle.
  if (agent.teammateId) {
    var m = MATE_KEY_RE.exec(agent.teammateId)
    if (m) return m[1]
  }
  // description: start-anchored on the raw (unsanitised) text.
  if (agent.description) {
    var d = DESC_KEY_RE.exec(agent.description)
    if (d) return d[1]
  }
  return null
}

/**
 * Format an epoch-ms timestamp as a YYYY-MM-DD date string.
 * @param {number} epochMs
 * @returns {string}
 */
function toDateStr(epochMs) {
  var d = new Date(epochMs)
  var y = d.getUTCFullYear()
  var m = String(d.getUTCMonth() + 1)
  var day = String(d.getUTCDate())
  if (m.length < 2) m = '0' + m
  if (day.length < 2) day = '0' + day
  return y + '-' + m + '-' + day
}

/**
 * Compute agent activity data from a list of agent records.
 *
 * @param {object} opts
 * @param {Array} opts.agents - raw agent records from $.agent.list()
 * @param {number} opts.nowMs - current time in epoch milliseconds
 * @param {number} opts.threshold - waiting_agent_threshold_seconds (default 120)
 * @param {Set<string>} opts.storyKeys - set of story keys present in the cache
 * @param {Map<string,number>} opts.waitingMap - mutable map agentId -> firstSeenWaitingAt (epoch ms)
 * @returns {{ activityByStory: Map, unlinkedActivity: object, ruleBItems: Array }}
 */
export function computeAgentActivity(opts) {
  var agents = opts.agents || []
  var nowMs = opts.nowMs || 0
  var threshold = opts.threshold != null ? opts.threshold : 120
  var storyKeys = opts.storyKeys || new Set()
  var waitingMap = opts.waitingMap || new Map()

  // Track which agent ids are still active so stale waitingMap entries can
  // be pruned at the end.
  var activeIds = new Set()

  // Intermediate collections.
  var byStory = new Map()      // storyKey -> [{ agentId, label, status }]
  var unlinked = []            // [{ agentId, label, status }]
  var ruleBItems = []

  // Build a lookup of running children by parentId for the child filter.
  var runningChildParents = new Set()
  for (var c = 0; c < agents.length; c++) {
    if (agents[c].status === 'running' && agents[c].parentId) {
      runningChildParents.add(agents[c].parentId)
    }
  }

  for (var i = 0; i < agents.length; i++) {
    var agent = agents[i]
    var status = agent.status

    // Only running and waiting produce activity lines.
    if (status !== 'running' && status !== 'waiting') continue

    activeIds.add(agent.id)

    var key = extractStoryKey(agent)
    var label = sanitize(agent.description || '', DESCRIPTION_MAX)

    // Activity record.
    var rec = { agentId: agent.id, label: label, status: status }

    if (key !== null && storyKeys.has(key)) {
      var list = byStory.get(key)
      if (!list) { list = []; byStory.set(key, list) }
      list.push(rec)
    } else {
      unlinked.push(rec)
    }

    // Waiting-map maintenance.
    if (status === 'waiting') {
      if (!waitingMap.has(agent.id)) {
        waitingMap.set(agent.id, nowMs)
      }

      // Rule (b): waiting agent with no running child, above threshold.
      if (!runningChildParents.has(agent.id)) {
        var firstSeen = waitingMap.get(agent.id)
        var waitSec = (nowMs - firstSeen) / 1000

        if (waitSec >= threshold) {
          ruleBItems.push({
            rule: 'b',
            type: 'agent_waiting',
            story_keys: key !== null ? [key] : [],
            message: label,
            command: null,
            since: toDateStr(firstSeen),
            source: 'agent-list'
          })
        }
      }
    } else {
      // Agent left waiting — remove from map.
      waitingMap.delete(agent.id)
    }
  }

  // Prune agents that disappeared from the list.
  var mapKeys = []
  waitingMap.forEach(function (_v, k) { mapKeys.push(k) })
  for (var p = 0; p < mapKeys.length; p++) {
    if (!activeIds.has(mapKeys[p])) waitingMap.delete(mapKeys[p])
  }

  // Build capped activityByStory with overflow counts.
  var activityByStory = new Map()
  byStory.forEach(function (items, sk) {
    if (items.length <= ACTIVITY_CAP) {
      activityByStory.set(sk, { items: items, overflow: 0 })
    } else {
      activityByStory.set(sk, {
        items: items.slice(0, ACTIVITY_CAP),
        overflow: items.length - ACTIVITY_CAP
      })
    }
  })

  // Build capped unlinkedActivity with overflow count.
  var unlinkedActivity
  if (unlinked.length <= ACTIVITY_CAP) {
    unlinkedActivity = { items: unlinked, overflow: 0 }
  } else {
    unlinkedActivity = {
      items: unlinked.slice(0, ACTIVITY_CAP),
      overflow: unlinked.length - ACTIVITY_CAP
    }
  }

  return {
    activityByStory: activityByStory,
    unlinkedActivity: unlinkedActivity,
    ruleBItems: ruleBItems
  }
}
