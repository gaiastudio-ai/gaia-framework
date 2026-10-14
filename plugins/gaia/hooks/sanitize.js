// Terminal escape sanitization for mod-rendered text.
// Strips CSI, OSC, control characters, replacement characters,
// and lone surrogates, then truncates to a per-field limit.

// Per-field length constants.
export const TITLE_MAX = 80;
export const SLUG_MAX = 60;
export const MESSAGE_MAX = 200;
export const COMMAND_MAX = 120;
export const DESCRIPTION_MAX = 120;
export const DETAIL_MAX = 200;
export const GOAL_MAX = 200;
export const TASK_TEXT_MAX = 200;
export const GATE_NAME_MAX = 60;
export const BLOCKED_BY_MAX = 80;
export const DRIFT_DETAIL_MAX = 200;

/**
 * Sanitize text for safe terminal rendering.
 * @param {unknown} text - input text (coerced to string)
 * @param {number} maxLen - maximum output length
 * @returns {string} sanitized text
 */
export function sanitize(text, maxLen) {
  let s = String(text ?? '');

  // (b) Strip CSI sequences: ESC[ ... final-byte or U+009B ... final-byte.
  // Params: 0x30-0x3F, intermediates: 0x20-0x2F, final: 0x40-0x7E.
  // Incomplete trailing sequences (no final byte) are also stripped.
  s = s.replace(/(?:\x1b\[|\u009b)[\x20-\x3f]*[\x20-\x2f]*[\x40-\x7e]/g, '');
  // Strip incomplete trailing CSI (ESC[ or U+009B followed by params/intermediates but no final byte before end).
  s = s.replace(/(?:\x1b\[|\u009b)[\x20-\x3f]*[\x20-\x2f]*$/g, '');

  // (c) Strip OSC sequences: ESC] ... (BEL | ST) or U+009D ... (BEL | ST).
  // ST = ESC\ (0x1b 0x5c). Handle incomplete trailing sequences.
  s = s.replace(/(?:\x1b\]|\u009d)(?:[^\x07\x1b]|\x1b(?!\x5c))*(?:\x07|\x1b\x5c)/g, '');
  // Strip incomplete trailing OSC (no terminator before end).
  s = s.replace(/(?:\x1b\]|\u009d)(?:[^\x07\x1b]|\x1b(?!\x5c))*$/g, '');

  // (d) Strip control characters 0x00-0x1F (except 0x0A newline) and DEL (0x7F).
  s = s.replace(/[\x00-\x09\x0b-\x1f\x7f]/g, '');

  // (e) Strip remaining C1 control characters U+0080-U+009F.
  // U+009B and U+009D were already consumed by CSI/OSC stripping above,
  // but any remaining ones (standalone or after partial consumption) are removed here.
  s = s.replace(/[\u0080-\u009f]/g, '');

  // (f) Strip U+FFFD replacement characters.
  s = s.replace(/�/g, '');

  // (g) Strip lone surrogates U+D800-U+DFFF.
  // In JS strings these appear as individual code units.
  s = s.replace(/[\ud800-\udfff]/g, '');

  // (h) Truncate to maxLen with ellipsis.
  if (s.length > maxLen) {
    s = s.slice(0, maxLen - 1) + '…';
  }

  return s;
}

/**
 * Sanitize all dynamic text fields in a parsed cache object.
 * Operates in place and returns the same object for chaining.
 * Field paths derived from sprint-progress-snapshot.sh jq output.
 * @param {object} data - parsed cache object
 * @returns {object} the same object with fields sanitized
 */
export function sanitizeCache(data) {
  if (!data || typeof data !== 'object') return data;

  // Sprint-level fields
  if (data.sprint && typeof data.sprint === 'object') {
    if (data.sprint.id != null) data.sprint.id = sanitize(data.sprint.id, SLUG_MAX);
    if (data.sprint.goal != null) data.sprint.goal = sanitize(data.sprint.goal, GOAL_MAX);
    if (data.sprint.status != null) data.sprint.status = sanitize(data.sprint.status, SLUG_MAX);
    if (data.sprint.capacity_utilization != null) data.sprint.capacity_utilization = sanitize(data.sprint.capacity_utilization, DESCRIPTION_MAX);
    if (data.sprint.epic_focus != null) data.sprint.epic_focus = sanitize(data.sprint.epic_focus, DESCRIPTION_MAX);
  }

  // Per-story fields
  if (Array.isArray(data.stories)) {
    for (const s of data.stories) {
      if (s.title != null) s.title = sanitize(s.title, TITLE_MAX);
      if (s.key != null) s.key = sanitize(s.key, SLUG_MAX);
      if (s.slug != null) s.slug = sanitize(s.slug, SLUG_MAX);
      if (s.blocked_by != null) s.blocked_by = sanitize(s.blocked_by, BLOCKED_BY_MAX);
      // tasks.items[].text
      if (s.tasks && Array.isArray(s.tasks.items)) {
        for (const t of s.tasks.items) {
          if (t.text != null) t.text = sanitize(t.text, TASK_TEXT_MAX);
        }
      }
      // gates.rows[].name
      if (s.gates && Array.isArray(s.gates.rows)) {
        for (const g of s.gates.rows) {
          if (g.name != null) g.name = sanitize(g.name, GATE_NAME_MAX);
        }
      }
    }
  }

  // Drift fields
  if (Array.isArray(data.drift)) {
    for (const d of data.drift) {
      if (d.detail != null) d.detail = sanitize(d.detail, DRIFT_DETAIL_MAX);
    }
  }

  // Action needed fields
  if (Array.isArray(data.action_needed)) {
    for (const a of data.action_needed) {
      if (a.message != null) a.message = sanitize(a.message, MESSAGE_MAX);
      if (a.command != null) a.command = sanitize(a.command, COMMAND_MAX);
    }
  }

  return data;
}
