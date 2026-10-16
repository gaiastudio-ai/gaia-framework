// Terminal escape sanitization for mod-rendered text.
// Strips CSI, OSC, control characters, replacement characters, lone
// surrogates, and invisible bidi / zero-width format characters, then
// truncates to a per-field limit on a code-point boundary.

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
// Limit for any other string in the cache, and for a maxLen that is not a
// finite number.
export const DEFAULT_MAX = 200;

// How much raw input is looked at per output character. Anything beyond is
// cut before the pattern passes run, so hostile input costs bounded time.
const INPUT_FACTOR = 16;
const INPUT_FLOOR = 256;

// CSI: introducer, parameter bytes (0x30-0x3F), intermediate bytes
// (0x20-0x2F), then the final byte (0x40-0x7E). The two byte classes do not
// overlap and the final byte is optional, so a sequence cut short anywhere
// (including at the end of the string) is consumed in one linear pass.
const CSI = /(?:\x1b\[|\u009b)[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]?/g;
// OSC: introducer, then a body that stops at BEL, ESC, U+009C (ST) or the
// next U+009D, then an optional terminator (BEL, ESC \ or U+009C). An OSC with
// no terminator is dropped up to wherever its body stopped.
const OSC = /(?:\x1b\]|\u009d)[^\x07\x1b\u009c\u009d]*(?:\x07|\x1b\\|\u009c)?/g;
// C0 controls except newline, and DEL.
const C0 = /[\x00-\x09\x0b-\x1f\x7f]/g;
// Remaining C1 controls.
const C1 = /[\u0080-\u009f]/g;
// Unicode replacement character.
const REPLACEMENT = /�/g;
// A high surrogate with no low surrogate after it, or a low surrogate with no
// high surrogate before it. Well-formed pairs (emoji and other characters
// beyond the basic plane) are kept.
const LONE_SURROGATE = /[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/g;
// Invisible format characters that can reorder or hide text: Arabic letter
// mark, LRM/RLM, bidi embeddings and overrides, bidi isolates, zero-width
// space, word joiner, and the byte-order mark. Zero-width joiner and
// non-joiner stay, since emoji sequences and some scripts need them.
const BIDI_AND_ZERO_WIDTH = /[؜​‎‏‪-‮⁠⁦-⁩﻿]/g;

function clampMaxLen(maxLen) {
  if (typeof maxLen !== 'number' || !Number.isFinite(maxLen)) return DEFAULT_MAX;
  return Math.floor(maxLen);
}

// Cuts s to at most n UTF-16 units without splitting a surrogate pair.
function cutCodePoints(s, n) {
  if (s.length <= n) return s;
  let end = n;
  const last = s.charCodeAt(end - 1);
  if (end > 0 && last >= 0xd800 && last <= 0xdbff) end -= 1;
  return s.slice(0, end);
}

/**
 * Sanitize text for safe terminal rendering.
 * @param {unknown} text - input text (coerced to string)
 * @param {number} maxLen - maximum output length in UTF-16 units; 0 or less
 *   gives an empty string, a non-finite value uses DEFAULT_MAX
 * @returns {string} sanitized text
 */
export function sanitize(text, maxLen) {
  const limit = clampMaxLen(maxLen);
  if (limit < 1) return '';
  let s = String(text ?? '');

  const inputCap = Math.max(limit * INPUT_FACTOR, INPUT_FLOOR);
  let cut = false;
  if (s.length > inputCap) {
    s = cutCodePoints(s, inputCap);
    cut = true;
  }

  s = s.replace(CSI, '');
  s = s.replace(OSC, '');
  s = s.replace(C0, '');
  s = s.replace(C1, '');
  s = s.replace(REPLACEMENT, '');
  s = s.replace(LONE_SURROGATE, '');
  s = s.replace(BIDI_AND_ZERO_WIDTH, '');

  // Truncate with the ellipsis inside maxLen.
  if (s.length > limit || (cut && s.length > 0)) {
    s = cutCodePoints(s, limit - 1) + '…';
  }
  return s;
}

// Per-field limits, by property name.
const FIELD_MAX = {
  id: SLUG_MAX,
  key: SLUG_MAX,
  slug: SLUG_MAX,
  status: SLUG_MAX,
  title: TITLE_MAX,
  goal: GOAL_MAX,
  capacity_utilization: DESCRIPTION_MAX,
  epic_focus: DESCRIPTION_MAX,
  description: DESCRIPTION_MAX,
  blocked_by: BLOCKED_BY_MAX,
  text: TASK_TEXT_MAX,
  name: GATE_NAME_MAX,
  detail: DRIFT_DETAIL_MAX,
  message: MESSAGE_MAX,
  command: COMMAND_MAX,
};

// Deeper than this, a value is replaced by null.
const MAX_DEPTH = 32;

function limitFor(prop) {
  return typeof prop === 'string' && Object.prototype.hasOwnProperty.call(FIELD_MAX, prop)
    ? FIELD_MAX[prop]
    : DEFAULT_MAX;
}

function clean(value, prop, depth) {
  if (typeof value === 'string') return sanitize(value, limitFor(prop));
  if (value === null || typeof value !== 'object') return value;
  if (depth >= MAX_DEPTH) return null;
  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i++) value[i] = clean(value[i], prop, depth + 1);
    return value;
  }
  for (const k of Object.keys(value)) {
    const v = clean(value[k], k, depth + 1);
    const nk = sanitize(k, SLUG_MAX);
    if (nk !== k) {
      delete value[k];
      if (nk === '' || Object.prototype.hasOwnProperty.call(value, nk)) continue;
    }
    // defineProperty, not assignment: a "__proto__" key from JSON.parse is an
    // own property, and assigning to it would change the prototype instead.
    Object.defineProperty(value, nk, { value: v, enumerable: true, writable: true, configurable: true });
  }
  return value;
}

/**
 * Sanitize every string in a parsed cache object, in place: values and
 * property names. Fields with a known limit (title, slug, message, ...) get
 * it; any other string gets DEFAULT_MAX. Array items take the limit of the
 * property that holds the array.
 * @param {object} data - parsed cache object
 * @returns {object} the same object with every string sanitized
 */
export function sanitizeCache(data) {
  if (!data || typeof data !== 'object') return data;
  return clean(data, null, 0);
}
