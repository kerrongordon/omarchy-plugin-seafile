// Marker between the two JSON arrays `seaf-cli list --json` and
// `seaf-cli status --json` print back to back from Service's single refresh
// process -- cheaper than two round trips through Quickshell's Process type.
var SPLIT_MARKER = "@@STATUS@@"

var STATE_META = {
  "synchronized": { label: "Synced", glyph: "", tone: "ok" },
  "waiting for sync": { label: "Waiting", glyph: "", tone: "dim" },
  "indexing": { label: "Indexing", glyph: "", tone: "busy" },
  "uploading": { label: "Uploading", glyph: "", tone: "busy" },
  "downloading": { label: "Downloading", glyph: "", tone: "busy" },
  "merging": { label: "Merging", glyph: "", tone: "busy" },
  "relay not connected": { label: "Relay offline", glyph: "", tone: "dim" },
  "error": { label: "Error", glyph: "", tone: "error" },
  "disk full": { label: "Disk full", glyph: "", tone: "error" },
  "read only": { label: "Read only", glyph: "", tone: "dim" }
}

function parseJsonArray(text) {
  var value = String(text || "").trim()
  if (value === "") return []
  try {
    var parsed = JSON.parse(value)
    return Array.isArray(parsed) ? parsed : []
  } catch (e) {
    return []
  }
}

function parseRefresh(raw) {
  var text = String(raw || "")
  var index = text.indexOf(SPLIT_MARKER)
  var listPart = index >= 0 ? text.substring(0, index) : text
  var statusPart = index >= 0 ? text.substring(index + SPLIT_MARKER.length) : ""
  return {
    list: parseJsonArray(listPart),
    status: parseJsonArray(statusPart)
  }
}

// `list` has id/name/path, `status` has id/name/state -- joined on id so
// each row carries both the local path and the live sync state.
function mergeLibraries(listArr, statusArr) {
  var byId = {}
  var order = []

  for (var i = 0; i < listArr.length; i++) {
    var entry = listArr[i]
    if (!entry || !entry.id) continue
    byId[entry.id] = { id: entry.id, name: String(entry.name || "Untitled"), path: String(entry.path || ""), state: "" }
    order.push(entry.id)
  }
  for (var j = 0; j < statusArr.length; j++) {
    var s = statusArr[j]
    if (!s || !s.id) continue
    if (byId[s.id]) {
      byId[s.id].state = String(s.state || "")
    } else {
      byId[s.id] = { id: s.id, name: String(s.name || "Untitled"), path: "", state: String(s.state || "") }
      order.push(s.id)
    }
  }

  var out = []
  for (var k = 0; k < order.length; k++) out.push(byId[order[k]])
  out.sort(function(a, b) { return a.name.localeCompare(b.name) })
  return out
}

function stateMeta(state) {
  var key = String(state || "").toLowerCase().trim()
  return STATE_META[key] || { label: key === "" ? "Unknown" : String(state), glyph: "", tone: "dim" }
}

function overallTone(libraries, installed, daemonRunning) {
  if (!installed) return "error"
  if (!daemonRunning) return "dim"
  var busy = false
  for (var i = 0; i < libraries.length; i++) {
    var tone = stateMeta(libraries[i].state).tone
    if (tone === "error") return "error"
    if (tone === "busy") busy = true
  }
  return busy ? "busy" : "ok"
}

function summaryText(libraries, installed, daemonRunning) {
  if (!installed) return "seaf-cli not found"
  if (!daemonRunning) return "Daemon stopped"
  if (libraries.length === 0) return "No libraries"

  var busyCount = 0
  var errorCount = 0
  for (var i = 0; i < libraries.length; i++) {
    var tone = stateMeta(libraries[i].state).tone
    if (tone === "busy") busyCount++
    if (tone === "error") errorCount++
  }
  if (errorCount > 0) return errorCount + " " + (errorCount === 1 ? "library" : "libraries") + " with errors"
  if (busyCount > 0) return "Syncing " + busyCount + " of " + libraries.length
  return libraries.length + " " + (libraries.length === 1 ? "library" : "libraries") + " synced"
}

function isLinked(libraries, id) {
  for (var i = 0; i < libraries.length; i++) {
    if (libraries[i].id === id) return true
  }
  return false
}

function formatBytes(bytes) {
  var value = Number(bytes || 0)
  if (!isFinite(value) || value <= 0) return "0 B"
  var units = ["B", "KB", "MB", "GB", "TB"]
  var index = 0
  while (value >= 1000 && index < units.length - 1) {
    value = value / 1000
    index++
  }
  var decimals = value >= 100 || index === 0 ? 0 : (value >= 10 ? 1 : 2)
  return value.toFixed(decimals).replace(/\.0+$/, "") + " " + units[index]
}

function relativeTime(timestampSec, nowMs) {
  var ts = Number(timestampSec || 0)
  if (!isFinite(ts) || ts <= 0) return "Unknown time"
  var now = nowMs === undefined ? Date.now() : Number(nowMs)
  var diff = Math.max(0, Math.floor((now - ts * 1000) / 1000))
  if (diff < 60) return "Just now"
  var minutes = Math.floor(diff / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.floor(hours / 24)
  if (days < 30) return days + "d ago"
  var months = Math.floor(days / 30)
  if (months < 12) return months + "mo ago"
  return Math.floor(days / 365) + "y ago"
}

function libraryName(libraries, id) {
  for (var i = 0; i < libraries.length; i++) {
    if (libraries[i].id === id) return libraries[i].name
  }
  return "Unknown library"
}

if (typeof module !== "undefined") {
  module.exports = {
    parseRefresh: parseRefresh,
    mergeLibraries: mergeLibraries,
    stateMeta: stateMeta,
    overallTone: overallTone,
    relativeTime: relativeTime,
    libraryName: libraryName,
    summaryText: summaryText,
    isLinked: isLinked,
    formatBytes: formatBytes
  }
}
