import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import "lib/Api.js" as Api

Item {
  id: root

  property var shell: null
  property string server: ""
  property string token: ""
  property string error: ""
  property bool loading: false
  property bool connected: false
  property string authenticationMethod: ""
  property var libraries: []
  property var books: []
  property var libraryBooks: []
  property var continueBooks: []
  property var recentBooks: []
  property var searchBooks: []
  property string searchQuery: ""
  property var mediaProgress: ({})
  property bool searching: false
  property string selectedLibraryId: ""
  property var currentItem: null
  property var currentTracks: []
  property var currentChapters: []
  property int currentTrackIndex: 0
  property string sessionId: ""
  property real sessionDuration: 0
  property double playbackStartedAt: 0
  property real listenedSinceSync: 0
  property bool localPlayback: false
  property real pendingSeekPosition: -1
  property string downloadStatus: ""
  property var requestQueue: []
  property var activeRequest: null
  property bool requestOutputHandled: false
  property string tokenToStore: ""
  property var offlineBooks: ({})
  property var queuedSessions: []
  property var user: null
  property bool browsingOffline: false
  property int downloadTrackIndex: -1
  property string localSessionId: ""
  property real localSessionStartTime: 0
  property double localSessionStartedAt: 0
  property real localTimeListening: 0
  property bool syncingOfflineSessions: false
  property alias playbackVolume: audioOutput.volume
  property double downloadBytes: 0
  property double downloadCompletedBytes: 0
  property double downloadTotalBytes: 0
  property string downloadPath: ""
  property var downloadItem: null
  property var downloadTracks: []
  property var downloadChapters: []
  property string downloadServer: ""
  property string downloadToken: ""
  property string downloadUserId: ""
  property bool loggingOut: false
  property bool promptAfterLogout: false
  property bool clearingCredentials: false
  property string localSessionServer: ""
  property string localSessionUserId: ""

  readonly property bool isPlaying: player.playbackState === MediaPlayer.PlayingState
  readonly property real trackStartOffset: currentTracks.length > currentTrackIndex ? Number(currentTracks[currentTrackIndex].startOffset || 0) : 0
  readonly property real position: trackStartOffset + player.position / 1000
  readonly property real duration: sessionDuration > 0 ? sessionDuration : player.duration / 1000
  readonly property string title: currentItem && currentItem.media && currentItem.media.metadata ? currentItem.media.metadata.title : ""
  readonly property string author: currentItem && currentItem.media && currentItem.media.metadata ? currentItem.media.metadata.authorName || "" : ""
  readonly property string progressLabel: Api.secondsLabel(position) + " / " + Api.secondsLabel(duration)
  readonly property string positionLabel: Api.secondsLabel(position)
  readonly property string durationLabel: Api.secondsLabel(duration)
  readonly property string remainingLabel: "-" + Api.secondsLabel(Math.max(0, duration - position))
  readonly property string chapterTitle: chapterAt(position)
  readonly property var currentChapter: chapterFor(position)
  readonly property real chapterStart: currentChapter ? Number(currentChapter.start || 0) : 0
  readonly property real chapterDuration: currentChapter ? Math.max(0, Number(currentChapter.end || duration) - chapterStart) : 0
  readonly property real chapterPosition: currentChapter ? Math.max(0, Math.min(chapterDuration, position - chapterStart)) : 0
  readonly property real chapterProgress: chapterDuration > 0 ? chapterPosition / chapterDuration : 0
  readonly property int chapterNumber: currentChapter ? currentChapters.indexOf(currentChapter) + 1 : 0
  readonly property real bookProgress: duration > 0 ? Math.max(0, Math.min(1, position / duration)) : 0
  readonly property string stateDirectory: Quickshell.env("HOME") + "/.local/state/omarchy-audiobookshelf"
  readonly property string serverName: server.replace(/^https?:\/\//, "").split("/")[0]
  readonly property bool downloading: downloadProcess.running || downloadTrackIndex >= 0
  readonly property bool currentDownloaded: currentItem && isDownloaded(currentItem.id)
  readonly property real downloadProgress: downloadTotalBytes > 0 ? Math.min(downloadBytes / downloadTotalBytes, 1) : 0
  readonly property string downloadProgressLabel: Math.round(downloadProgress * 100) + "% - " + formatBytes(downloadBytes) + " / " + formatBytes(downloadTotalBytes)

  function apiUrl(path) { return server + path }

  function selectServer(serverUrl) {
    var normalized = Api.normalizeServer(serverUrl)
    if (server !== "" && normalized !== server) mediaProgress = ({})
    server = normalized
    return server
  }

  function coverUrl(item, width) {
    if (!item || !item.id) return ""
    var itemServer = item._omashelfServer || server
    if (itemServer === "") return ""
    return itemServer + "/api/items/" + encodeURIComponent(item.id) + "/cover?width=" + Number(width || 160) + "&format=webp&ts=" + Number(item.updatedAt || 0)
  }

  function progressForItem(itemId) {
    return mediaProgress[itemId] || null
  }

  function isDownloaded(itemId) {
    return offlineBooks[offlineKey(itemId)] !== undefined
  }

  function offlineKey(itemId) {
    return server + "|" + itemId
  }

  function offlineEntry(itemId, itemServer) {
    var scoped = offlineBooks[(itemServer || server) + "|" + itemId]
    if (scoped) return scoped
    return !connected && !itemServer ? offlineBooks[itemId] || null : null
  }

  function offlineBookList() {
    var items = []
    for (var id in offlineBooks) {
      var entry = offlineBooks[id]
      if (!connected || !entry.server || entry.server === server) {
        var item = Object.assign({}, entry.item)
        item._omashelfServer = entry.server || ""
        items.push(item)
      }
    }
    return items
  }

  function downloadDirectory(itemId, itemServer) {
    var value = String(itemServer || server)
    var hash = 2166136261
    for (var i = 0; i < value.length; i++) hash = Math.imul(hash ^ value.charCodeAt(i), 16777619)
    return stateDirectory + "/downloads/" + (hash >>> 0).toString(16) + "/" + safeItemId(itemId)
  }

  function migrateOfflineBooks(entries) {
    var migrated = ({})
    var changed = false
    for (var key in entries) {
      var entry = entries[key]
      if (key.indexOf("|") === -1 && entry && entry.server && entry.item && entry.item.id) {
        migrated[entry.server + "|" + entry.item.id] = entry
        changed = true
      } else {
        migrated[key] = entry
      }
    }
    if (changed) offlineIndex.setText(JSON.stringify(migrated, null, 2) + "\n")
    return migrated
  }

  function safeItemId(itemId) {
    var value = String(itemId || "")
    return /^[A-Za-z0-9._-]+$/.test(value) ? value : ""
  }

  function trustedMediaUrl(contentUrl, expectedServer) {
    var value = String(contentUrl || "")
    var origin = expectedServer || server
    if (value.indexOf("http") !== 0) return origin + value
    return value === origin || value.indexOf(origin + "/") === 0 ? value : ""
  }

  function chapterFor(seconds) {
    for (var i = 0; i < currentChapters.length; i++) {
      var chapter = currentChapters[i]
      if (seconds >= Number(chapter.start || 0) && seconds < Number(chapter.end || duration)) return chapter
    }
    return null
  }

  function chapterAt(seconds) {
    var chapter = chapterFor(seconds)
    return chapter ? chapter.title || "" : ""
  }

  function chaptersFromTracks(tracks) {
    var chapters = []
    for (var i = 0; i < tracks.length; i++) {
      var track = tracks[i]
      var trackChapters = track.metadata && track.metadata.chapters ? track.metadata.chapters : (track.chapters || [])
      var offset = Number(track.startOffset || 0)
      for (var j = 0; j < trackChapters.length; j++) {
        var chapter = Object.assign({}, trackChapters[j])
        chapter.start = Number(chapter.start || 0) + offset
        chapter.end = Number(chapter.end || 0) + offset
        chapters.push(chapter)
      }
    }
    return chapters
  }

  function formatBytes(bytes) {
    var value = Number(bytes || 0)
    if (value < 1024) return Math.round(value) + " B"
    if (value < 1024 * 1024) return (value / 1024).toFixed(1) + " KB"
    if (value < 1024 * 1024 * 1024) return (value / (1024 * 1024)).toFixed(1) + " MB"
    return (value / (1024 * 1024 * 1024)).toFixed(1) + " GB"
  }

  function formatDuration(seconds) {
    return Api.secondsLabel(Number(seconds || 0))
  }

  function setVolume(value) {
    audioOutput.volume = Math.max(0, Math.min(1, Number(value || 0)))
  }

  function request(method, path, body, callback) {
    requestQueue.push({ method: method, path: path, body: body, callback: callback })
    runNextRequest()
  }

  function runNextRequest() {
    if (apiProcess.running || requestQueue.length === 0) return
    activeRequest = requestQueue.shift()
    requestOutputHandled = false
    apiProcess.payload = token + "\n" + (activeRequest.body !== null && activeRequest.body !== undefined ? JSON.stringify(activeRequest.body) : "") + "\n"
    apiProcess.command = [
      "sh", "-c",
      "set -eu; tmp=$(mktemp -d); trap 'rm -rf \"$tmp\"' EXIT; chmod 700 \"$tmp\"; IFS= read -r token; IFS= read -r body; printf '%s\\n' 'Accept: application/json' > \"$tmp/headers\"; if [ -n \"$token\" ]; then printf 'Authorization: Bearer %s\\n' \"$token\" >> \"$tmp/headers\"; fi; if [ -n \"$body\" ]; then printf '%s' \"$body\" > \"$tmp/body\"; chmod 600 \"$tmp/body\"; curl --silent --show-error --request \"$1\" --url \"$2\" --header @\"$tmp/headers\" --header 'Content-Type: application/json' --data-binary @\"$tmp/body\" --write-out '\\n%{http_code}'; else curl --silent --show-error --request \"$1\" --url \"$2\" --header @\"$tmp/headers\" --write-out '\\n%{http_code}'; fi",
      "omashelf-api", activeRequest.method, apiUrl(activeRequest.path)
    ]
    apiProcess.running = true
  }

  function finishRequest(rawOutput) {
    if (loggingOut) {
      activeRequest = null
      requestOutputHandled = true
      return
    }
    if (requestOutputHandled || !activeRequest) return
    requestOutputHandled = true
    var raw = String(rawOutput || "")
    var marker = raw.lastIndexOf("\n")
    var status = marker >= 0 ? Number(raw.slice(marker + 1).trim()) : 0
    var body = marker >= 0 ? raw.slice(0, marker) : raw
    var ok = status >= 200 && status < 300
    var data = null
    if (body.trim() !== "") {
      try { data = JSON.parse(body) } catch (_) { data = body.trim() }
    }
    var callback = activeRequest.callback
    activeRequest = null
    if (callback) callback(ok, ok ? (data || {}) : apiErrorMessage(status, data))
    runNextRequest()
  }

  function apiErrorMessage(status, data) {
    if (data && typeof data === "object") return String(data.error || data.message || ("Server returned HTTP " + status))
    if (data) return String(data)
    return status ? "Server returned HTTP " + status : "Could not reach the Audiobookshelf server"
  }

  function connect(serverUrl) {
    selectServer(serverUrl)
    error = ""
    if (server === "") { error = "Enter an Audiobookshelf server URL"; return }
    tokenLookup.command = ["secret-tool", "lookup"].concat(Api.keyringAttributes(server))
    tokenLookup.running = true
  }

  function authenticateWithToken(serverUrl, apiToken, method) {
    selectServer(serverUrl)
    token = String(apiToken || "").trim()
    connected = false
    if (server === "" || token === "") { error = "Server URL and API token are required"; return }
    tokenToStore = token
    authenticationMethod = method || "api-token"
    authorize()
  }

  function authenticateWithPassword(serverUrl, username, password) {
    selectServer(serverUrl)
    token = ""
    connected = false
    error = ""
    if (server === "" || String(username || "").trim() === "" || password === "") {
      error = "Server URL, username, and password are required"
      return
    }
    if (loginProcess.running) return
    loading = true
    loginProcess.payload = JSON.stringify({ username: String(username).trim(), password: password })
    loginProcess.command = [
      "sh", "-c",
      "set -eu; tmp=$(mktemp); trap 'rm -f \"$tmp\"' EXIT; chmod 600 \"$tmp\"; IFS= read -r body; printf '%s' \"$body\" > \"$tmp\"; curl --silent --show-error --request POST --header 'Accept: application/json' --header 'Content-Type: application/json' --data-binary @\"$tmp\" --write-out '\\n%{http_code}' --url \"$1\"",
      "omashelf-login", server + "/login"
    ]
    loginProcess.running = true
  }

  function finishPasswordLogin(rawOutput) {
    if (loggingOut) return
    loading = false
    var raw = String(rawOutput || "")
    var marker = raw.lastIndexOf("\n")
    var status = marker >= 0 ? Number(raw.slice(marker + 1).trim()) : 0
    var body = marker >= 0 ? raw.slice(0, marker) : raw
    var data = null
    if (body.trim() !== "") {
      try { data = JSON.parse(body) } catch (_) { data = body.trim() }
    }
    if (status < 200 || status >= 300) {
      error = apiErrorMessage(status, data)
      return
    }
    var accessToken = data && data.user ? (data.user.token || data.user.accessToken || "") : ""
    if (accessToken === "") { error = "The server did not return an access token"; return }
    authenticateWithToken(server, accessToken, "password")
  }

  function promptForCredentials() {
    if (credentialPrompt.running) return
    credentialPrompt.command = [
      "zenity", "--forms", "--title=OmaShelf", "--text=Connect to your Audiobookshelf server",
      "--add-entry=Server URL", "--add-entry=Username (optional)", "--add-password=Password (optional)",
      "--add-password=API token (alternative)", "--separator=\t"
    ]
    credentialPrompt.running = true
  }

  function handleCredentialOutput(output) {
    var values = String(output || "").replace(/\r?\n$/, "").split("\t")
    if (values.length !== 4 || !values[0]) {
      error = "Enter a server URL and either login credentials or an API token"
      return
    }
    if (values[3]) authenticateWithToken(values[0], values[3], "api-token")
    else if (values[1] && values[2]) authenticateWithPassword(values[0], values[1], values[2])
    else error = "Enter a username and password, or an API token"
  }

  function authorize() {
    loading = true
    request("GET", "/api/me", null, function(ok, data) {
      loading = false
      if (!ok) {
        connected = false
        tokenToStore = ""
        error = data
        connectionErrorDialog.command = ["zenity", "--error", "--title=OmaShelf", "--text=" + data]
        connectionErrorDialog.running = true
        return
      }
      connected = true
      user = data.user || data
      error = ""
      serverFile.setText(server + "\n")
      if (tokenToStore !== "") {
        tokenStore.payload = tokenToStore
        tokenStore.command = ["sh", "-c", "IFS= read -r token; printf %s \"$token\" | secret-tool store --label=\"OmaShelf ($1)\" service omarchy-audiobookshelf server \"$1\"", "omashelf-store", server]
        tokenStore.running = true
      }
      loadLibraries()
      syncOfflineSessions()
    })
  }

  function logout(promptForNewServer) {
    if (loggingOut) return
    loggingOut = true
    promptAfterLogout = Boolean(promptForNewServer)
    requestQueue = []
    activeRequest = null
    requestOutputHandled = true
    syncingOfflineSessions = false
    apiProcess.running = false
    tokenLookup.running = false
    loginProcess.running = false

    if (currentItem && localPlayback) syncProgress(true)
    else if (currentItem && duration > 0 && token !== "" && server !== "") startLogoutSync()
    player.stop()
    maybeFinishLogout()
  }

  function startLogoutSync() {
    var now = Date.now()
    var currentPosition = position
    var progress = Api.progressFor(currentPosition, duration)
    var body = { currentTime: currentPosition, duration: duration, timeListened: listenedSinceSync }
    var path = sessionId !== ""
      ? "/api/session/" + encodeURIComponent(sessionId) + "/close"
      : "/api/me/progress/" + encodeURIComponent(currentItem.id)
    var method = sessionId !== "" ? "POST" : "PATCH"
    if (sessionId === "") body.progress = progress

    var nextProgress = Object.assign({}, mediaProgress)
    nextProgress[currentItem.id] = Object.assign({}, nextProgress[currentItem.id] || {}, {
      libraryItemId: currentItem.id, duration: duration, currentTime: currentPosition,
      progress: progress, isFinished: progress >= 0.995, lastUpdate: now
    })
    mediaProgress = nextProgress
    listenedSinceSync = 0
    logoutSyncProcess.payload = token + "\n" + JSON.stringify(body) + "\n"
    logoutSyncProcess.command = [
      "sh", "-c",
      "set -eu; tmp=$(mktemp -d); trap 'rm -rf \"$tmp\"' EXIT; chmod 700 \"$tmp\"; IFS= read -r token; IFS= read -r body; printf 'Authorization: Bearer %s\\n' \"$token\" > \"$tmp/headers\"; printf '%s' \"$body\" > \"$tmp/body\"; chmod 600 \"$tmp/body\"; curl --silent --show-error --connect-timeout 3 --max-time 5 --request \"$1\" --url \"$2\" --header @\"$tmp/headers\" --header 'Content-Type: application/json' --data-binary @\"$tmp/body\" >/dev/null",
      "omashelf-logout-sync", method, apiUrl(path)
    ]
    logoutSyncProcess.running = true
  }

  function maybeFinishLogout() {
    if (!tokenStore.running && !logoutSyncProcess.running) finishLogout()
  }

  function finishLogout() {
    if (clearingCredentials) return
    clearingCredentials = true
    var previousServer = server
    player.stop()
    player.source = ""
    pendingSeekPosition = -1
    token = ""
    tokenToStore = ""
    connected = false
    authenticationMethod = ""
    loading = false
    error = ""
    user = null
    libraries = []
    books = []
    libraryBooks = []
    continueBooks = []
    recentBooks = []
    searchBooks = []
    searchQuery = ""
    searching = false
    mediaProgress = ({})
    selectedLibraryId = ""
    currentItem = null
    currentTracks = []
    currentChapters = []
    currentTrackIndex = 0
    sessionId = ""
    sessionDuration = 0
    listenedSinceSync = 0
    localSessionId = ""
    localSessionStartTime = 0
    localSessionStartedAt = 0
    localTimeListening = 0
    localSessionServer = ""
    localSessionUserId = ""
    browsingOffline = false
    requestQueue = []
    activeRequest = null
    requestOutputHandled = true
    apiProcess.running = false
    tokenLookup.running = false
    loginProcess.running = false
    serverFile.setText("")

    if (previousServer === "") {
      completeLogout()
      return
    }
    tokenClear.command = ["secret-tool", "clear"].concat(Api.keyringAttributes(previousServer))
    tokenClear.running = true
  }

  function completeLogout() {
    if (apiProcess.running || loginProcess.running || tokenLookup.running || tokenStore.running) {
      logoutCompletionTimer.restart()
      return
    }
    clearingCredentials = false
    loggingOut = false
    if (promptAfterLogout) {
      promptAfterLogout = false
      promptForCredentials()
    }
  }

  function loadLibraries() {
    request("GET", "/api/libraries", null, function(ok, data) {
      if (!ok) { error = data; return }
      libraries = data.libraries || []
      for (var i = 0; i < libraries.length; i++) {
        if (libraries[i].mediaType === "book") { loadLibrary(libraries[i].id); return }
      }
      if (libraries.length > 0) error = "No audiobook library is available"
    })
  }

  function loadLibrary(id) {
    browsingOffline = false
    selectedLibraryId = id
    loading = true
    request("GET", "/api/libraries/" + encodeURIComponent(id) + "/items?mediaType=book&sort=media.metadata.title&limit=0", null, function(ok, data) {
      loading = false
      if (!ok) { error = data; return }
      libraryBooks = data.results || []
      books = libraryBooks
    })
    loadHome(id)
    loadProgress()
  }

  function loadHome(id) {
    request("GET", "/api/libraries/" + encodeURIComponent(id) + "/personalized?limit=8", null, function(ok, data) {
      if (!ok) { error = data; return }
      var shelves = Array.isArray(data) ? data : []
      var inProgress = []
      var recent = []
      for (var i = 0; i < shelves.length; i++) {
        if (shelves[i].id === "continue-listening") inProgress = shelves[i].entities || []
        else if (shelves[i].id === "recently-added") recent = shelves[i].entities || []
      }
      continueBooks = inProgress
      recentBooks = recent
    })
  }

  function loadProgress() {
    request("GET", "/api/me/progress", null, function(ok, data) {
      if (!ok) return
      var next = ({})
      var records = data.mediaProgress || []
      for (var i = 0; i < records.length; i++) next[records[i].libraryItemId] = records[i]
      mediaProgress = next
    })
  }

  function searchLibrary(query) {
    var term = String(query || "").trim()
    searchQuery = term
    if (term === "") {
      searching = false
      searchBooks = []
      return
    }
    searching = true
    request("GET", "/api/libraries/" + encodeURIComponent(selectedLibraryId) + "/search?q=" + encodeURIComponent(term) + "&limit=50", null, function(ok, data) {
      if (term !== searchQuery) return
      searching = false
      if (!ok) { error = data; return }
      var results = data.book || []
      var items = []
      for (var i = 0; i < results.length; i++) if (results[i].libraryItem) items.push(results[i].libraryItem)
      searchBooks = items
    })
  }

  function playItem(item) {
    if (currentItem) syncProgress(true)
    loading = true
    request("POST", "/api/items/" + encodeURIComponent(item.id) + "/play", {
      deviceInfo: { deviceId: "omashelf", clientName: "OmaShelf", clientVersion: "1.0.0" },
      supportedMimeTypes: ["audio/mpeg", "audio/mp4", "audio/aac", "audio/ogg", "audio/flac"],
      forceDirectPlay: true,
      forceTranscode: false,
      mediaPlayer: "QtMultimedia"
    }, function(ok, data) {
      loading = false
      if (!ok) { error = data; return }
      currentItem = data.libraryItem || item
      currentTracks = data.audioTracks || data.mediaTracks || []
      currentChapters = data.chapters || []
      sessionId = data.id || ""
      sessionDuration = Number(data.duration || item.media.duration || 0)
      playbackStartedAt = Number(data.startedAt || Date.now())
      localPlayback = false
      if (currentTracks.length === 0) { error = "The server did not return playable audio tracks"; return }
      startAt(data.currentTime || 0)
    })
  }

  function startAt(seconds) {
    var target = Math.max(0, Number(seconds || 0))
    for (var i = 0; i < currentTracks.length; i++) {
      var track = currentTracks[i]
      var start = Number(track.startOffset || 0)
      var end = start + Number(track.duration || 0)
      if (target >= start && (target < end || i === currentTracks.length - 1)) {
        startTrack(i, target)
        return
      }
    }
    startTrack(0, 0)
  }

  function startTrack(index, seekSeconds) {
    if (index < 0 || index >= currentTracks.length) return
    currentTrackIndex = index
    var track = currentTracks[index]
    var source = localPlayback && track.localPath ? "file://" + track.localPath : trustedMediaUrl(track.contentUrl)
    if (!localPlayback) {
      if (source === "") { error = "The server returned an untrusted audio URL"; return }
      source += (source.indexOf("?") === -1 ? "?" : "&") + "token=" + encodeURIComponent(token)
    }
    player.source = source
    pendingSeekPosition = seekSeconds > 0 ? Math.max(0, seekSeconds - Number(track.startOffset || 0)) * 1000 : -1
    player.play()
  }

  function togglePlayback() {
    if (isPlaying) {
      player.pause()
      syncProgress(false)
    } else {
      player.play()
    }
  }
  function seek(seconds) {
    var target = Math.max(0, Math.min(duration, seconds))
    for (var i = 0; i < currentTracks.length; i++) {
      var track = currentTracks[i]
      var start = Number(track.startOffset || 0)
      var end = start + Number(track.duration || 0)
      if (target >= start && (target < end || i === currentTracks.length - 1)) {
        if (i === currentTrackIndex) player.position = (target - start) * 1000
        else startTrack(i, target)
        return
      }
    }
  }
  function skip(seconds) { seek(position + seconds) }
  function seekChapter(seconds) { seek(chapterStart + Math.max(0, Math.min(chapterDuration, seconds))) }

  function syncProgress(finalSync) {
    if (!currentItem || duration <= 0) return
    var now = Date.now()
    var progress = Api.progressFor(position, duration)
    var payload = { duration: duration, currentTime: position, progress: progress, isFinished: progress >= 0.995,
                    startedAt: playbackStartedAt || now, finishedAt: progress >= 0.995 ? now : null }
    var nextProgress = Object.assign({}, mediaProgress)
    nextProgress[currentItem.id] = Object.assign({}, nextProgress[currentItem.id] || {}, payload, { libraryItemId: currentItem.id, lastUpdate: now })
    mediaProgress = nextProgress
    if (localPlayback) {
      queueOfflineSession(payload, now)
      if (connected && !loggingOut) syncOfflineSessions()
      return
    }
    if (sessionId !== "") {
      request("POST", "/api/session/" + encodeURIComponent(sessionId) + (finalSync ? "/close" : "/sync"),
              { currentTime: position, duration: duration, timeListened: listenedSinceSync }, function() {})
      listenedSinceSync = 0
    } else {
      request("PATCH", "/api/me/progress/" + encodeURIComponent(currentItem.id),
              { duration: duration, currentTime: position, progress: progress }, function() {})
    }
  }

  function downloadBook() {
    if (!currentItem || currentTracks.length === 0 || currentDownloaded) return
    var itemId = safeItemId(currentItem.id)
    if (itemId === "") { error = "The server returned an unsafe item ID"; return }
    downloadItem = currentItem
    downloadTracks = currentTracks.slice()
    downloadChapters = currentChapters.slice()
    downloadServer = server
    downloadToken = token
    downloadUserId = user ? user.id : ""
    downloadStatus = "Downloading " + title
    downloadBytes = 0
    downloadCompletedBytes = 0
    downloadTotalBytes = 0
    for (var i = 0; i < downloadTracks.length; i++) {
      var track = downloadTracks[i]
      downloadTotalBytes += Number(track.metadata && track.metadata.size ? track.metadata.size : track.bitRate * track.duration / 8 || 0)
    }
    downloadTrackIndex = 0
    downloadTrack()
  }

  function downloadTrack() {
    if (!downloadItem) return
    if (downloadTrackIndex >= downloadTracks.length) {
      var next = Object.assign({}, offlineBooks)
      next[downloadServer + "|" + downloadItem.id] = {
        server: downloadServer, userId: downloadUserId, item: downloadItem,
        tracks: downloadTracks, chapters: downloadChapters
      }
      offlineBooks = next
      offlineIndex.setText(JSON.stringify(offlineBooks, null, 2) + "\n")
      downloadStatus = "Downloaded " + downloadItem.media.metadata.title
      downloadBytes = downloadTotalBytes
      downloadPath = ""
      downloadTrackIndex = -1
      downloadItem = null
      downloadTracks = []
      downloadChapters = []
      downloadServer = ""
      downloadToken = ""
      downloadUserId = ""
      return
    }
    var track = downloadTracks[downloadTrackIndex]
    var url = trustedMediaUrl(track.contentUrl, downloadServer)
    var itemId = safeItemId(downloadItem.id)
    if (url === "" || itemId === "") {
      error = "Download rejected an unsafe server response"
      downloadTrackIndex = -1
      downloadItem = null
      downloadTracks = []
      downloadChapters = []
      downloadServer = ""
      downloadToken = ""
      downloadUserId = ""
      return
    }
    var destination = downloadDirectory(itemId, downloadServer) + "/" + downloadTrackIndex + ".audio"
    downloadPath = destination
    downloadProcess.payload = downloadToken + "\n"
    downloadProcess.command = ["sh", "-c", "set -eu; umask 077; IFS= read -r token; mkdir -p \"$(dirname \"$1\")\"; tmp=$(mktemp); trap 'rm -f \"$tmp\"' EXIT; chmod 600 \"$tmp\"; printf 'Authorization: Bearer %s\\n' \"$token\" > \"$tmp\"; curl --fail --silent --show-error --continue-at - --output \"$1\" --header @\"$tmp\" --url \"$2\"", "omashelf-download", destination, url]
    downloadProcess.running = true
  }

  function playOffline(itemId, itemServer) {
    var saved = offlineEntry(itemId, itemServer)
    if (!saved) return
    if (currentItem) syncProgress(true)
    if (saved.server) selectServer(saved.server)
    currentItem = saved.item
    currentTracks = saved.tracks
    currentChapters = saved.chapters && saved.chapters.length > 0 ? saved.chapters : chaptersFromTracks(saved.tracks)
    localPlayback = true
    sessionId = ""
    sessionDuration = Number(saved.item.media.duration || 0)
    playbackStartedAt = Date.now()
    localSessionId = newUuid()
    localSessionServer = saved.server || itemServer || server
    localSessionUserId = saved.userId || ""
    var savedProgress = progressForItem(itemId)
    var resumeTime = savedProgress && !savedProgress.isFinished ? Number(savedProgress.currentTime || 0) : 0
    localSessionStartTime = resumeTime
    localSessionStartedAt = playbackStartedAt
    localTimeListening = 0
    startAt(resumeTime)
  }

  function showOfflineBooks() {
    browsingOffline = true
    books = offlineBookList()
  }

  function newUuid() {
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function(c) {
      var r = Math.floor(Math.random() * 16)
      return (c === "x" ? r : (r & 0x3) | 0x8).toString(16)
    })
  }

  function queueOfflineSession(progress, timestamp) {
    var session = {
      id: localSessionId || newUuid(), userId: localSessionUserId, libraryId: currentItem.libraryId,
      libraryItemId: currentItem.id, episodeId: null, mediaType: "book", playMethod: 3,
      bookId: currentItem.media ? currentItem.media.id : null,
      displayTitle: title, displayAuthor: author, duration: duration, currentTime: position,
      timeListening: localTimeListening, startTime: localSessionStartTime,
      startedAt: localSessionStartedAt || timestamp, updatedAt: timestamp,
      serverUrl: localSessionServer,
      mediaPlayer: "QtMultimedia",
      deviceInfo: { deviceId: "omashelf", clientName: "OmaShelf", clientVersion: "1.0.0" },
      mediaMetadata: currentItem.media ? currentItem.media.metadata : null
    }
    localSessionId = session.id
    var next = []
    var replaced = false
    for (var i = 0; i < queuedSessions.length; i++) {
      if (queuedSessions[i].id === session.id) {
        next.push(session)
        replaced = true
      } else {
        next.push(queuedSessions[i])
      }
    }
    if (!replaced) next.push(session)
    queuedSessions = next
    offlineSessionsFile.setText(JSON.stringify(queuedSessions, null, 2) + "\n")
    listenedSinceSync = 0
  }

  function syncOfflineSessions() {
    if (queuedSessions.length === 0 || syncingOfflineSessions) return
    syncingOfflineSessions = true
    var sent = []
    for (var index = 0; index < queuedSessions.length; index++) {
      var queued = queuedSessions[index]
      if (queued.serverUrl === server && user && queued.userId && queued.userId === user.id) sent.push(queued)
    }
    if (sent.length === 0) { syncingOfflineSessions = false; return }
    request("POST", "/api/session/local-all", {
      deviceInfo: { deviceId: "omashelf", clientName: "OmaShelf", clientVersion: "1.0.0" },
      sessions: sent
    }, function(ok, data) {
      syncingOfflineSessions = false
      if (!ok) return
      var results = data.sessions || data.results || []
      var remaining = []
      for (var i = 0; i < queuedSessions.length; i++) {
        var current = queuedSessions[i]
        var sentSession = null
        var result = null
        if (current.serverUrl !== server || !user || !current.userId || current.userId !== user.id) { remaining.push(current); continue }
        for (var j = 0; j < sent.length; j++) if (sent[j].id === current.id) { sentSession = sent[j]; break }
        for (var k = 0; k < results.length; k++) if (results[k].id === current.id) { result = results[k]; break }
        if (!sentSession || !result || !result.success || current.updatedAt > sentSession.updatedAt) remaining.push(current)
      }
      queuedSessions = remaining
      offlineSessionsFile.setText(JSON.stringify(queuedSessions, null, 2) + "\n")
    })
  }

  MediaPlayer {
    id: player
    audioOutput: AudioOutput { id: audioOutput; volume: 1 }
    onMediaStatusChanged: {
      if ((mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferedMedia) && root.pendingSeekPosition >= 0) {
        position = root.pendingSeekPosition
        root.pendingSeekPosition = -1
      } else if (mediaStatus === MediaPlayer.EndOfMedia) {
        if (root.currentTrackIndex + 1 < root.currentTracks.length) root.startTrack(root.currentTrackIndex + 1, 0)
        else root.syncProgress(true)
      }
    }
    onErrorOccurred: function(error, errorString) { root.error = "Playback failed: " + errorString }
  }

  Timer {
    interval: 1000
    running: root.isPlaying
    repeat: true
    onTriggered: {
      root.listenedSinceSync += 1
      if (root.localPlayback) root.localTimeListening += 1
    }
  }
  Timer { interval: 30000; running: root.isPlaying; repeat: true; onTriggered: root.syncProgress(false) }

  Process {
    id: apiProcess
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload)
      payload = ""
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishRequest(text)
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: loginProcess
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload + "\n")
      payload = ""
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishPasswordLogin(text)
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: tokenLookup
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.loggingOut) return
        root.token = String(text || "").trim()
        if (root.token === "") root.error = "Not connected"
        else {
          root.authenticationMethod = "keyring"
          root.authorize()
        }
      }
    }
    onExited: function(code) {
      if (root.loggingOut) return
      if (code !== 0) root.error = "Not connected"
    }
  }

  Process {
    id: credentialPrompt
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "") !== "") root.handleCredentialOutput(text)
    }
  }

  Process { id: connectionErrorDialog }

  Process {
    id: tokenStore
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload + "\n")
      payload = ""
    }
    onExited: {
      root.tokenToStore = ""
      if (root.loggingOut) root.maybeFinishLogout()
    }
  }

  Process {
    id: logoutSyncProcess
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload)
      payload = ""
    }
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: root.maybeFinishLogout()
  }

  Process {
    id: tokenClear
    onExited: function(code) {
      if (code === 0 || code === 1) root.completeLogout()
      else {
        root.clearingCredentials = false
        root.loggingOut = false
        root.promptAfterLogout = false
        root.error = "Could not remove the saved credential"
      }
    }
  }

  Timer { id: logoutCompletionTimer; interval: 50; repeat: false; onTriggered: root.completeLogout() }

  IpcHandler {
    target: "omashelf"

    function status(): string {
      return JSON.stringify({
        server: root.server,
        connected: root.connected,
        authenticationMethod: root.authenticationMethod,
        loading: root.loading,
        error: root.error,
        libraries: root.libraries.length,
        books: root.books.length,
        continueBooks: root.continueBooks.length,
        recentBooks: root.recentBooks.length,
        progressRecords: Object.keys(root.mediaProgress).length,
        playing: root.isPlaying,
        title: root.title,
        author: root.author,
        cover: root.currentItem ? root.coverUrl(root.currentItem, 260) : "",
        itemId: root.currentItem ? root.currentItem.id : "",
        savedPosition: root.currentItem && root.progressForItem(root.currentItem.id) ? root.progressForItem(root.currentItem.id).currentTime : 0,
        position: root.position,
        duration: root.duration,
        chapter: root.chapterTitle,
        chapterPosition: root.chapterPosition,
        chapterDuration: root.chapterDuration,
        localPlayback: root.localPlayback,
        queuedSessions: root.queuedSessions.length,
        downloading: root.downloading,
        volume: root.playbackVolume
      })
    }

    function playPause(): string {
      if (!root.currentItem) return "unhandled"
      root.togglePlayback()
      return "ok"
    }

    function play(): string {
      if (!root.currentItem) return "unhandled"
      if (!root.isPlaying) root.togglePlayback()
      return "ok"
    }

    function pause(): string {
      if (!root.currentItem) return "unhandled"
      if (root.isPlaying) root.togglePlayback()
      return "ok"
    }

    function skip(seconds: real): string {
      if (!root.currentItem) return "unhandled"
      root.skip(seconds)
      return "ok"
    }

    function seek(seconds: real): string {
      if (!root.currentItem) return "unhandled"
      root.seek(seconds)
      return "ok"
    }

    function volume(value: real): string {
      root.setVolume(value)
      return "ok"
    }

    function connect(): string {
      root.promptForCredentials()
      return "ok"
    }
  }
  Process {
    id: downloadProcess
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload)
      payload = ""
    }
    stderr: StdioCollector { id: downloadError; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) {
        root.downloadStatus = "Download failed: " + String(downloadError.text || "unknown error").trim()
        root.downloadTrackIndex = -1
        root.downloadItem = null
        root.downloadTracks = []
        root.downloadChapters = []
        root.downloadServer = ""
        root.downloadToken = ""
        root.downloadUserId = ""
        return
      }
      var tracks = root.downloadTracks.slice()
      var track = Object.assign({}, tracks[root.downloadTrackIndex])
      track.localPath = root.downloadDirectory(root.downloadItem.id, root.downloadServer) + "/" + root.downloadTrackIndex + ".audio"
      tracks[root.downloadTrackIndex] = track
      root.downloadTracks = tracks
      root.downloadCompletedBytes += Number(track.metadata && track.metadata.size ? track.metadata.size : track.bitRate * track.duration / 8 || 0)
      root.downloadBytes = root.downloadCompletedBytes
      root.downloadTrackIndex += 1
      root.downloadStatus = "Downloaded track " + root.downloadTrackIndex + " of " + root.downloadTracks.length
      root.downloadTrack()
    }
  }

  Timer {
    interval: 500
    running: root.downloading
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!downloadSizeProcess.running && root.downloadPath !== "") {
        downloadSizeProcess.command = ["stat", "--format=%s", root.downloadPath]
        downloadSizeProcess.running = true
      }
    }
  }

  Process {
    id: downloadSizeProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var size = Number(text.trim())
        if (!isNaN(size)) root.downloadBytes = root.downloadCompletedBytes + size
      }
    }
  }

  FileView {
    id: offlineIndex
    path: root.stateDirectory + "/downloads.json"
    printErrors: false
    onLoaded: {
      try { root.offlineBooks = root.migrateOfflineBooks(JSON.parse(text())) } catch (_) { root.offlineBooks = ({}) }
    }
    onLoadFailed: root.offlineBooks = ({})
  }

  FileView {
    id: offlineSessionsFile
    path: root.stateDirectory + "/offline-sessions.json"
    printErrors: false
    onLoaded: {
      try { root.queuedSessions = JSON.parse(text()) } catch (_) { root.queuedSessions = [] }
    }
    onLoadFailed: root.queuedSessions = []
  }

  FileView {
    id: serverFile
    path: root.stateDirectory + "/server-url"
    printErrors: false
    onLoaded: {
      var savedServer = Api.normalizeServer(text())
      if (savedServer !== "") root.connect(savedServer)
    }
  }

  Component.onCompleted: {
    stateDirectoryInit.running = true
    mprisBridge.running = true
    serverFile.reload()
  }
  Component.onDestruction: syncProgress(true)

  Process {
    id: stateDirectoryInit
    command: ["sh", "-c", "umask 077; mkdir -p \"$1/downloads\"; chmod 700 \"$1\" \"$1/downloads\"; touch \"$1/downloads.json\" \"$1/offline-sessions.json\" \"$1/server-url\"; chmod 600 \"$1/downloads.json\" \"$1/offline-sessions.json\" \"$1/server-url\"", "omashelf-state", root.stateDirectory]
  }

  Process {
    id: mprisBridge
    command: ["python", Qt.resolvedUrl("mpris.py").toString().replace(/^file:\/\//, "")]
    onExited: mprisRestart.restart()
  }

  Timer { id: mprisRestart; interval: 5000; repeat: false; onTriggered: if (!mprisBridge.running) mprisBridge.running = true }
}
