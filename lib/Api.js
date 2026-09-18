.pragma library

function normalizeServer(value) {
  var server = String(value || "").trim().replace(/\/+$/, "")
  var match = server.match(/^https?:\/\/([^\/?#]+)(\/[^?#]*)?$/i)
  if (!match || match[1].indexOf("@") !== -1) return ""
  return server
}

function keyringAttributes(server) {
  return ["service", "omarchy-audiobookshelf", "server", normalizeServer(server)]
}

function secondsLabel(seconds) {
  seconds = Math.max(0, Math.floor(Number(seconds) || 0))
  var hours = Math.floor(seconds / 3600)
  var minutes = Math.floor((seconds % 3600) / 60)
  var remainder = seconds % 60
  return (hours ? hours + ":" + String(minutes).padStart(2, "0") : minutes) + ":" + String(remainder).padStart(2, "0")
}

function progressFor(position, duration) {
  return duration > 0 ? Math.min(1, Math.max(0, position / duration)) : 0
}

function cacheDirectory(itemId) {
  return ".local/state/omarchy-audiobookshelf/downloads/" + itemId
}
