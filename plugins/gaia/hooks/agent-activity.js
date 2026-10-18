// Pure agent-activity computation module.
// Maps $.agent.list() results to story-keyed activity records.
// No side effects, no $.* calls — all inputs are plain values so the module
// can be unit-tested directly.

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
 * Compute agent activity data from a list of agent records.
 *
 * @param {object} opts
 * @param {Array} opts.agents - raw agent records from $.agent.list()
 * @param {Set<string>} opts.storyKeys - set of story keys present in the cache
 * @returns {{ activityByStory: Map, unlinkedActivity: object }}
 */
export function computeAgentActivity(opts) {
  var agents = opts.agents || []
  var storyKeys = opts.storyKeys || new Set()

  // Intermediate collections.
  var byStory = new Map()      // storyKey -> [{ agentId, label, status }]
  var unlinked = []            // [{ agentId, label, status }]

  for (var i = 0; i < agents.length; i++) {
    var agent = agents[i]
    var status = agent.status

    // Only running and waiting produce activity lines.
    if (status !== 'running' && status !== 'waiting') continue

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
    unlinkedActivity: unlinkedActivity
  }
}
