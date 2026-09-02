function isChromiumDerived(app, appIcon) {
  var source = (String(app || "") + "\n" + String(appIcon || "")).toLowerCase()
  return source.indexOf("chrom") >= 0 || source.indexOf("brave") >= 0 ||
         source.indexOf("vivaldi") >= 0 || source.indexOf("microsoft-edge") >= 0 ||
         source.indexOf("opera") >= 0
}

function sanitizeBody(body, app, appIcon) {
  var text = String(body || "").replace(/<img[^>]*>/gi, "")
  if (!isChromiumDerived(app, appIcon)) return text

  return text
    .replace(/^\s*<a\b[^>]*>\s*(?:https?:\/\/|www\.)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/[^<\s]*)?\s*<\/a>\s*/i, "")
    .replace(/^\s*(?:https?:\/\/|www\.)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/\S*)?\s+/i, "")
}

function summaryStartsWithGlyph(summary) {
  var text = String(summary || "").replace(/^\s+/, "")
  if (!text) return false

  var offset = 1
  var first = text.charCodeAt(0)
  if (first >= 0xd800 && first <= 0xdbff && text.length > 1) offset = 2

  var spaces = 0
  while (offset < text.length && text.charAt(offset) === " ") {
    spaces++
    offset++
  }

  return spaces >= 2
}

function shouldBypassDnd(notification, criticalUrgency) {
  var appName = String((notification && notification.appName) || "")
  if (appName === "omarchy-action") return true
  return appName === "notify-send" && notification && notification.urgency === criticalUrgency
}

function isEphemeralApp(appName) {
  var name = String(appName || "")
  return name === "notify-send" || name === "omarchy-action"
}

function stringHint(hints, name) {
  try {
    if (hints) {
      var value = hints[name]
      if (value !== undefined && value !== null) return String(value)
    }
  } catch (e) {
  }
  return ""
}

function glyphFromHints(hints) {
  return stringHint(hints, "omarchy-glyph")
}

// Hard limits for producer-side safety
var MAX_APP_CHARS = 64
var MAX_SUMMARY_CHARS = 256
var MAX_BODY_CHARS = 2048
var MAX_GLYPH_CHARS = 8
var MAX_CHANNEL_CHARS = 64
var MAX_ICON_CHARS = 256
var MAX_IMAGE_CHARS = 512

function sanitizeText(val, maxChars) {
  if (val === undefined || val === null) return ""
  // Strip Unicode directional formatting isolates (FSI, PDI, LRI, RLI, LTR, RTL marks) used by apps like Signal
  var s = String(val).replace(/[\u200E\u200F\u202A-\u202E\u2066-\u2069]/g, "")
  // Strip Unicode directional formatting isolates (FSI, PDI, LRI, RLI, LTR, RTL marks) used by apps like Signal
  var s = String(val).replace(/[\u200E\u200F\u202A-\u202E\u2066-\u2069]/g, "")
  if (s.length > maxChars) {
    s = s.slice(0, maxChars)
  }
  // Strip dangerous control characters except newline and tab
  return s.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, "").trim()
  return s.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, "").trim()
}

function validateImageSource(src) {
  var s = String(src || "").trim()
  if (!s || s.length > MAX_IMAGE_CHARS) return ""
  // Reject remote and unsafe schemes
  if (/^(https?|ftp|data|javascript|qrc):/i.test(s)) return ""
  // Reject path traversal
  if (s.indexOf("..") !== -1) return ""
  // Safe local schemes
  if (s.indexOf("file://") === 0 || s.indexOf("/") === 0 || s.indexOf("image://") === 0) {
    return s
  }
  // Standard icon names: alphanumeric, -, _, .
  if (/^[a-zA-Z0-9_\-\.]+$/.test(s)) {
    return s
  }
  return ""
}

function shouldRenderCompactGlyph(glyph, iconSource, singleLineToast) {
  return String(glyph || "").length > 0 && String(iconSource || "").length === 0 && !!singleLineToast
}

function extractChannel(app, summary, body, hints) {
  hints = hints || {}
  var tag = (stringHint(hints, "x-kde-tag") || stringHint(hints, "tag") || stringHint(hints, "group") || stringHint(hints, "thread-id") || "").trim()
  if (tag) {
    var cleanedTag = tag.replace(/^slack-channel-/, "#").replace(/^channel_/, "#")
    if (cleanedTag.length > 0) return cleanedTag
  }

  var s = sanitizeText(summary, MAX_SUMMARY_CHARS)
  if (!s) return ""

  // 1. Bracketed channel/workspace (Slack, IRC, Discord):
  // e.g. "[server] from user", "[dev] Alice: hi"
  var bracketMatch = s.match(/^\[([^\]]{2,50})\](?:\s+(?:from|:)\s+.+)?$/i)
  if (bracketMatch) {
    var ch = bracketMatch[1].trim()
    return ch.indexOf("#") === 0 ? ch : ("#" + ch)
  }

  // 2. "... in <channel/group>" (Signal, Slack, Discord, Teams, Telegram):
  // e.g. "Andrew in family chat", "Alice in #dev", "Bob in Project Alpha"
  var inMatch = s.match(/(?:^|\s+)in\s+([^\(\)\[\]:]{2,50})$/i)
  if (inMatch) {
    return inMatch[1].trim()
  }

  // 3. Parenthesized channel or group:
  // e.g. "Bob (#general)", "Alice (family chat)"
  var parenMatch = s.match(/\(([^)]+)\)/)
  if (parenMatch && parenMatch[1].trim().length >= 2) {
    return parenMatch[1].trim()
  }

  // 4. Group chat prefix with colon (Signal, Telegram, WhatsApp):
  // e.g. "family chat: Andrew", "Dev Team: Alice"
  var colonMatch = s.match(/^([^:\n]{2,35}):\s+(.+)$/)
  if (colonMatch && colonMatch[1].indexOf("http") === -1) {
    return colonMatch[1].trim()
  }

  // 5. Channel/hierarchy prefix with ">" (Discord, Slack, Matrix):
  // e.g. "MyServer > family-chat > Alice"
  var arrowMatch = s.match(/(?:^|>\s*)([a-zA-Z0-9_\-# ]{2,35})\s*>\s*[^>]+$/)
  if (arrowMatch) {
    return arrowMatch[1].trim()
  }

  return ""
}

function snapshotOf(notification, timestamp) {
  var n = notification || {}
  var id = Number(n.id || 0)
  if (!isFinite(id) || id < 0) id = 0

  var expireTimeout = Number(n.expireTimeout || 0)
  if (!isFinite(expireTimeout) || expireTimeout < 0) expireTimeout = 0
  if (expireTimeout > 86400000) expireTimeout = 86400000

  var urgency = Number(n.urgency || 0)
  if (!isFinite(urgency) || urgency < 0 || urgency > 2) urgency = 1

  var app = sanitizeText(n.appName, MAX_APP_CHARS)
  var summary = sanitizeText(n.summary, MAX_SUMMARY_CHARS)
  var body = sanitizeText(n.body, MAX_BODY_CHARS)
  var glyph = sanitizeText(glyphFromHints(n.hints), MAX_GLYPH_CHARS)
  var channel = sanitizeText(extractChannel(app, summary, body, n.hints), MAX_CHANNEL_CHARS)
  var appIcon = validateImageSource(n.appIcon)
  var image = validateImageSource(n.image)

  var ts = Number(timestamp === undefined ? Date.now() : timestamp)
  if (!isFinite(ts) || ts <= 0) ts = Date.now()

  return {
    id: id,
    originalId: id,
    app: app,
    appIcon: appIcon,
    summary: summary,
    body: body,
    image: image,
    glyph: glyph,
    channel: channel,
    urgency: urgency,
    expireTimeout: expireTimeout,
    timestamp: ts
  }
}

// Everything the popup card draws, and therefore everything an in-place
// update has to write through to the row and its file.
var POPUP_ROLES = ["app", "appIcon", "summary", "body", "image", "glyph", "channel", "urgency", "expireTimeout"]

function popupRoles() {
  return POPUP_ROLES
}

// Whether a refresh has anything to write. Each property a client updates
// emits its own signal, and the catch-up refresh after a row is inserted
// usually finds the object exactly as it was snapshotted — without this,
// one update would rewrite the file several times over.
function popupRowChanged(row, updated) {
  var current = row || {}
  var next = updated || {}
  for (var i = 0; i < POPUP_ROLES.length; i++) {
    var role = POPUP_ROLES[i]
    if (current[role] !== next[role]) return true
  }
  return false
}

// A client updating a notification through replaces_id keeps the identity of
// the popup it took over: the file name is the timestamp and id the popup was
// first persisted under, and the restore, replace and archive paths all key
// off that name. Only what the card draws comes from the updated object.
function replacementSnapshot(notification, originalId, timestamp) {
  var updated = snapshotOf(notification, timestamp)
  updated.id = originalId
  updated.originalId = originalId
  return updated
}

function historyEntry(value, normalUrgency) {
  var e = value || {}
  var id = Number(e.id || 0)
  var originalId = Number(e.originalId || e.id || 0)
  var urgency = typeof e.urgency === "number" ? Math.max(0, Math.min(2, e.urgency)) : normalUrgency
  var ts = Number(e.timestamp || 0)

  return {
    id: isFinite(id) ? id : 0,
    originalId: isFinite(originalId) ? originalId : 0,
    app: sanitizeText(e.app, MAX_APP_CHARS),
    appIcon: validateImageSource(e.appIcon),
    summary: sanitizeText(e.summary, MAX_SUMMARY_CHARS),
    body: sanitizeText(e.body, MAX_BODY_CHARS),
    image: validateImageSource(e.image),
    glyph: sanitizeText(e.glyph, MAX_GLYPH_CHARS),
    channel: sanitizeText(e.channel, MAX_CHANNEL_CHARS),
    urgency: urgency,
    expireTimeout: 0,
    timestamp: isFinite(ts) ? ts : 0
  }
}

// notifications.json holds settings.
function parseSettings(raw) {
  var text = String(raw || "").trim()
  if (!text) {
    return {
      error: false,
      dnd: null,
      position: "bottom-center",
      timeoutSeconds: 8,
      groupingMode: "channel",
      infiniteChat: true,
      otpCopy: true,
      legacy: false
    }
  }

  try {
    var parsed = JSON.parse(text)
    var group = "channel"
    if (parsed && parsed.groupingMode) {
      group = String(parsed.groupingMode)
    } else if (parsed && typeof parsed.onePerApp === "boolean") {
      group = parsed.onePerApp ? "app" : "all"
    }

    return {
      error: false,
      dnd: parsed && typeof parsed.dnd === "boolean" ? parsed.dnd : null,
      position: parsed && parsed.position ? String(parsed.position) : "bottom-center",
      timeoutSeconds: parsed && typeof parsed.timeoutSeconds === "number" ? parsed.timeoutSeconds : 8,
      groupingMode: group,
      infiniteChat: parsed && typeof parsed.infiniteChat === "boolean" ? parsed.infiniteChat : true,
      otpCopy: parsed && typeof parsed.otpCopy === "boolean" ? parsed.otpCopy : true,
      legacy: !!(parsed && (parsed.pending || parsed.past || parsed.entries))
    }
  } catch (e) {
    return {
      error: true,
      errorMessage: String(e),
      dnd: null,
      position: "bottom-center",
      timeoutSeconds: 8,
      groupingMode: "channel",
      infiniteChat: true,
      otpCopy: true,
      legacy: false
    }
  }
}

// ---------------------------------------------------- popup persistence
//
// Each on-screen popup is mirrored to its own file under
// ~/.local/state/omarchy/notifications/ so toasts survive shell restarts
// (e.g. the restart `omarchy-update` performs). The file exists exactly as
// long as the popup is on screen: it is written when the toast appears and
// moved into the history/ subdirectory when the toast expires, is dismissed,
// or its action is invoked. History is those moved files, newest last-10.

function popupEntry(value, normalUrgency) {
  var entry = historyEntry(value, normalUrgency)
  var expire = Number((value || {}).expireTimeout || 0)
  if (!isFinite(expire) || expire < 0) expire = 0
  entry.expireTimeout = expire
  // Absolute expiry deadline, set only when a restore resets a surviving
  // popup's display lifetime. Kept out of the entry entirely when unset so
  // restored rows match the roles of freshly received ones.
  var deadline = Number((value || {}).deadline || 0)
  if (isFinite(deadline) && deadline > 0) entry.deadline = deadline
  return entry
}

function popupFileName(entry) {
  return imageStem(entry) + ".json"
}

// ---------------------------------------------------- persisted images
//
// A notification's images only exist while it is live: Chromium-family
// senders (all Omarchy web apps) delete their scoped /tmp files on close,
// and image-data hints surface as in-process image:// URLs that die with
// the server object. Persisted entries therefore reference their own
// copies, named by the entry's file stem so cleanup can find them from
// the JSON file name alone.

var PERSISTED_IMAGE_ROLES = ["appIcon", "image"]

function imageStem(entry) {
  var e = entry || {}
  return String(e.timestamp || 0) + "-" + String(e.originalId || 0)
}

// The filesystem path behind a file-backed image value, or "" for anything
// a copy can't capture: themed icon names, in-process image:// URLs, empty.
function localImageFile(value) {
  var s = String(value || "")
  if (s.indexOf("file://") === 0) {
    s = s.slice(7)
    try { s = decodeURIComponent(s) } catch (e) {}
  }
  return s.charAt(0) === "/" ? s : ""
}

// The entry as it should hit the disk, plus the copies that make it true.
// File-backed images redirect to their copy under imagesDir; dead image://
// URLs drop to "" (the card falls back to the app icon). Already-redirected
// values map onto themselves and produce no copy, keeping restores no-ops.
function persistablePopup(entry, imagesDir) {
  var e = entry || {}
  var out = {}
  for (var key in e) out[key] = e[key]
  var copies = []
  for (var i = 0; i < PERSISTED_IMAGE_ROLES.length; i++) {
    var role = PERSISTED_IMAGE_ROLES[i]
    var value = String(out[role] || "")
    if (!value) continue
    var source = localImageFile(value)
    if (source) {
      var copy = String(imagesDir || "") + imageStem(e) + "-" + role
      if (source !== copy) copies.push({ from: source, to: copy })
      out[role] = "file://" + copy
    } else if (value.indexOf("image://") === 0) {
      out[role] = ""
    }
  }
  return { entry: out, copies: copies }
}

function serializePopup(entry, normalUrgency) {
  // Compact (single-line) on purpose: restore cats every file together and
  // parses line by line, which only works when each file is one line.
  return JSON.stringify(popupEntry(entry, normalUrgency))
}

// Parse the concatenation of every persisted popup file into entries,
// newest-first. Deliberately NO dedupe by originalId: ids restart from 1
// with every server process, so two files sharing an id are usually
// different generations — dropping the older one would silently discard a
// restored critical alert the moment a fresh notification reuses its id.
// The one case that leaves a genuine duplicate (a crash between a
// replacement's write and the replaced file's delete) merely re-shows a
// superseded toast, which expires or is dismissed and cleans itself up.
function parsePopupFiles(raw, normalUrgency) {
  var lines = String(raw || "").split("\n")
  var entries = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    try {
      var value = JSON.parse(line)
      if (value && typeof value === "object") entries.push(popupEntry(value, normalUrgency))
    } catch (e) {
      // A torn write from a crash mid-save — skip the line, keep the rest.
    }
  }
  entries.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
  return entries
}

// A persisted popup whose lifetime already ran out would have expired on
// screen had the shell kept running, so it is not restored. duration 0 means
// the popup never expires (critical urgency) and always survives restarts.
// A restore-reset deadline outranks the original timestamp: without it, a
// second restart would judge a re-shown toast by a clock that no longer
// governs its display and drop it while it is still on screen.
function popupExpired(entry, duration, now) {
  var deadline = Number((entry || {}).deadline || 0)
  if (isFinite(deadline) && deadline > 0) return Number(now) >= deadline
  var lifetime = Number(duration || 0)
  if (!isFinite(lifetime) || lifetime <= 0) return false
  return (Number(now) - Number((entry || {}).timestamp || 0)) >= lifetime
}

function isNeverTimeoutApp(app, appIcon) {
  var name = (String(app || "") + " " + String(appIcon || "")).toLowerCase()
  return name.indexOf("slack") !== -1 || name.indexOf("signal") !== -1
}

function popupPlacement(barPosition, barClearance, gapsOut, userPosition) {
  var barPos = String(barPosition || "top")
  var pos = String(userPosition || "bottom-center").toLowerCase()
  var clearance = Number(barClearance)
  var gap = Number(gapsOut)
  if (!isFinite(clearance)) clearance = 0
  if (!isFinite(gap)) gap = 0

  var isTop = pos.indexOf("top") !== -1
  var isBottom = pos.indexOf("bottom") !== -1 || (!isTop)
  var isLeft = pos.indexOf("left") !== -1
  var isRight = pos.indexOf("right") !== -1
  var isCenter = pos.indexOf("center") !== -1 || (!isLeft && !isRight)

  var topMargin = (isTop && barPos.indexOf("top") !== -1) ? clearance : gap
  var bottomMargin = (isBottom && barPos.indexOf("bottom") !== -1) ? clearance : gap
  var leftMargin = (isLeft && barPos.indexOf("left") !== -1) ? clearance : gap
  var rightMargin = (isRight && barPos.indexOf("right") !== -1) ? clearance : gap

  return {
    isTop: isTop,
    isBottom: isBottom,
    isLeft: isLeft,
    isRight: isRight,
    isCenter: isCenter,
    anchors: {
      top: isTop,
      bottom: isBottom,
      left: isLeft,
      right: isRight
    },
    margins: {
      top: topMargin,
      bottom: bottomMargin,
      left: leftMargin,
      right: rightMargin
    }
  }
}

// The archived files are the history. They are read back exactly like the
// live popup files, then normalized into history rows: replaying a toast
// must not inherit the original's expire timeout or restore deadline, so it
// gets the standard on-screen lifetime for its urgency instead.
//
// liveRows are the toasts still on screen when the replay was asked for.
// They belong in it — they're the newest notifications there are — but the
// directory read races their archival, so they're carried across by hand and
// keyed by file name (timestamp + id) to drop the copy the read already saw.
function historyRows(raw, liveRows, normalUrgency, limit) {
  var max = limit === undefined || limit === null ? 10 : Number(limit)
  if (isNaN(max)) max = 10
  max = Math.max(0, max)

  var out = []
  var seen = {}
  function collect(rows) {
    for (var i = 0; i < rows.length; i++) {
      var entry = rows[i]
      if (!entry) continue
      var key = popupFileName(entry)
      if (seen[key]) continue
      seen[key] = true
      out.push(historyEntry(entry, normalUrgency))
    }
  }

  collect(Array.isArray(liveRows) ? liveRows : [])
  collect(parsePopupFiles(raw, normalUrgency))
  out.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
  return out.slice(0, max)
}

function extractOtp(summary, body) {
  var text = (String(summary || "") + " " + String(body || "")).replace(/<[^>]*>/g, " ")
  if (!text.trim()) return null

  // 1. Google verification codes: "G-123456 is your code" or "Google: G-123456"
  var gMatch = text.match(/\bG-([0-9]{6})\b/i)
  if (gMatch) return { code: gMatch[1], raw: gMatch[1] }

  // 2. High-confidence contextual patterns:
  // Requires explicit delimiter (: = is -) or strong framing.
  // OTP codes are strictly numeric (4-8 digits, e.g. 123456 or 123-456).
  // Pure alphabetic English words (like "review", "request", "login") MUST NEVER match.
  var numPattern = "(?:[A-Z]-)?([0-9]{4,8}|[0-9]{3}[-\\s][0-9]{3})"
  // Requires explicit delimiter (: = is -) or strong framing.
  // OTP codes are strictly numeric (4-8 digits, e.g. 123456 or 123-456).
  // Pure alphabetic English words (like "review", "request", "login") MUST NEVER match.
  var numPattern = "(?:[A-Z]-)?([0-9]{4,8}|[0-9]{3}[-\\s][0-9]{3})"
  var patterns = [
    new RegExp("(?:verification|security|authentication|auth|confirmation|login|access|one-time|otp|passcode|pin)\\s+code\\s*(?:is|:|=|-)\\s*[:#]?\\s*" + numPattern + "\\b", "i"),
    new RegExp("\\b(?:code|otp|passcode|pin)\\s*(?:is|:|=)\\s*[:#]?\\s*" + numPattern + "\\b", "i"),
    new RegExp("\\b" + numPattern + "\\s+is\\s+your\\s+(?:[a-z0-9_-]+\\s+)?(?:verification|security|authentication|login|confirmation|access|one-time|otp|code)\\b", "i"),
    new RegExp("(?:use|enter|type|input)\\s+(?:code\\s+)?" + numPattern + "\\s+to\\s+(?:verify|log\\s*in|sign\\s*in|authenticate|confirm|continue|access)\\b", "i"),
    // Steam Guard specifically uses 5 alphanumeric characters
    /\bSteam\s+Guard\s*(?:code)?\s*[:=]\s*([A-Z0-9]{5})\b/i
    new RegExp("(?:verification|security|authentication|auth|confirmation|login|access|one-time|otp|passcode|pin)\\s+code\\s*(?:is|:|=|-)\\s*[:#]?\\s*" + numPattern + "\\b", "i"),
    new RegExp("\\b(?:code|otp|passcode|pin)\\s*(?:is|:|=)\\s*[:#]?\\s*" + numPattern + "\\b", "i"),
    new RegExp("\\b" + numPattern + "\\s+is\\s+your\\s+(?:[a-z0-9_-]+\\s+)?(?:verification|security|authentication|login|confirmation|access|one-time|otp|code)\\b", "i"),
    new RegExp("(?:use|enter|type|input)\\s+(?:code\\s+)?" + numPattern + "\\s+to\\s+(?:verify|log\\s*in|sign\\s*in|authenticate|confirm|continue|access)\\b", "i"),
    // Steam Guard specifically uses 5 alphanumeric characters
    /\bSteam\s+Guard\s*(?:code)?\s*[:=]\s*([A-Z0-9]{5})\b/i
  ]

  for (var i = 0; i < patterns.length; i++) {
    var match = text.match(patterns[i])
    if (match && match[1]) {
      var rawCode = match[1].trim()
      // Strip any single-letter prefix with hyphen (e.g. V-123456 -> 123456)
      var cleanCode = rawCode.replace(/^[A-Za-z]-/, "").replace(/[-\s]/g, "")
      // Strip any single-letter prefix with hyphen (e.g. V-123456 -> 123456)
      var cleanCode = rawCode.replace(/^[A-Za-z]-/, "").replace(/[-\s]/g, "")
      // Avoid matching years
      if (cleanCode.length === 4 && (cleanCode.indexOf("19") === 0 || cleanCode.indexOf("20") === 0)) {
        continue
      }
      return { code: cleanCode, raw: cleanCode }
    }
  }

  // 3. Fallback: If text contains strong OTP keywords, find 4-8 digit numbers
  if (/\b(?:your\s+one-time\s+password|your\s+otp|your\s+passcode|2fa\s+code|mfa\s+code)\b/i.test(text)) {
    var fallbackMatch = text.match(/\b([0-9]{3}[-\s][0-9]{3}|[0-9]{4,8})\b/)
  if (/\b(?:your\s+one-time\s+password|your\s+otp|your\s+passcode|2fa\s+code|mfa\s+code)\b/i.test(text)) {
    var fallbackMatch = text.match(/\b([0-9]{3}[-\s][0-9]{3}|[0-9]{4,8})\b/)
    if (fallbackMatch) {
      var clean = fallbackMatch[1].replace(/[-\s]/g, "")
      var clean = fallbackMatch[1].replace(/[-\s]/g, "")
      if (!(clean.length === 4 && (clean.indexOf("19") === 0 || clean.indexOf("20") === 0))) {
        return { code: clean, raw: clean }
      }
    }
  }

  return null
}

if (typeof module !== "undefined") {
  module.exports = {
    isChromiumDerived: isChromiumDerived,
    sanitizeBody: sanitizeBody,
    summaryStartsWithGlyph: summaryStartsWithGlyph,
    shouldBypassDnd: shouldBypassDnd,
    isEphemeralApp: isEphemeralApp,
    stringHint: stringHint,
    glyphFromHints: glyphFromHints,
    validateImageSource: validateImageSource,
    sanitizeText: sanitizeText,
    shouldRenderCompactGlyph: shouldRenderCompactGlyph,
    snapshotOf: snapshotOf,
    popupRoles: popupRoles,
    popupRowChanged: popupRowChanged,
    replacementSnapshot: replacementSnapshot,
    historyEntry: historyEntry,
    parseSettings: parseSettings,
    historyRows: historyRows,
    popupEntry: popupEntry,
    popupFileName: popupFileName,
    imageStem: imageStem,
    localImageFile: localImageFile,
    persistablePopup: persistablePopup,
    serializePopup: serializePopup,
    parsePopupFiles: parsePopupFiles,
    popupExpired: popupExpired,
    isNeverTimeoutApp: isNeverTimeoutApp,
    popupPlacement: popupPlacement,
    extractOtp: extractOtp,
    extractChannel: extractChannel
  }
}
