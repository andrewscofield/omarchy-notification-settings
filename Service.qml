// Notification service for the omarchy shell.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Notifications
import qs.Commons

import "components"
import "NotificationLogic.js" as NotificationLogic

Item {
  id: service

  // Injected by omarchy-shell (the first-party service loader).
  property var shell: null

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  readonly property string home: Quickshell.env("HOME")
  // History + DND live under XDG_STATE_HOME: they're persistent user state
  // (the notifications received, the last-set DND preference), not
  // regeneratable cache that a `rm -rf ~/.cache` should wipe.
  readonly property string stateDir: home + "/.local/state/omarchy/"
  readonly property string settingsPath: stateDir + "notifications.json"
  // One file per on-screen popup, so live toasts survive shell restarts.
  // A file exists exactly as long as its popup is showing: written when the
  // toast appears, moved into historyDir when it expires, is dismissed, or is
  // acted upon.
  readonly property string popupStateDir: stateDir + "notifications/"
  // The notifications that already left the screen, one file each, trimmed to
  // the newest historyLimit. This directory IS the history: `showHistory`
  // replays exactly what has been moved in here.
  readonly property string historyDir: popupStateDir + "history/"
  // Copies of the avatars/images persisted entries reference — the sender's
  // originals don't outlive the notification (see persistablePopup). Each
  // copy lives and dies with the JSON file whose stem it carries.
  readonly property string imagesDir: popupStateDir + "images/"
  readonly property string storageScript: home + "/.config/omarchy/plugins/andrewscofield.notifications-settings/scripts/storage.sh"
  readonly property int maxActivePopups: 20
  // Corner radius is shared with the menu and shell panels.
  // It mirrors Hyprland's current decoration:rounding value.
  readonly property int cornerRadius: Style.cornerRadius
  // Toasts are fixed to the top-right corner. They only clear the omarchy bar
  // when the bar occupies the top or right edge, so left/bottom bars do not
  // pull notification popups away from the expected top-right location.
  // Falls back to the bar's default size (26 horizontal / 28 vertical) when
  // shell.bar isn't reachable so the popup never lands on top of the bar.
  readonly property string barPosition: shell && shell.barConfig ? String(shell.barConfig.position || "top") : "top"
  readonly property bool barVertical: barPosition === "left" || barPosition === "right"
  readonly property int defaultBarSize: barVertical ? Style.bar.sizeVertical : Style.bar.sizeHorizontal
  readonly property int liveBarSize: shell && shell.bar && !shell.bar.barHidden ? Math.max(0, shell.bar.barSize) : defaultBarSize
  readonly property int barClearance: liveBarSize + Style.gapsOut

  // Live Notification objects by originalId, kept OUT of the ListModels: a
  // QObject stored in a model role becomes a dangling C++ pointer when the
  // server destroys the notification (sender close, DND untrack, dismiss),
  // and the next read of that role segfaults in QQmlListModel::data. A JS
  // map only holds a wrapper, which degrades to a catchable error instead.
  property var liveRefs: ({})

  // PersistentProperties handles in-process QML reloads. The on-disk
  // notifications.json file is the cross-restart backstop — its `dnd` key
  // is hydrated into persisted.doNotDisturb on startup and written back via
  // a debounced save timer.
  PersistentProperties {
    id: persisted
    reloadableId: "omarchy-notifications"
    property bool doNotDisturb: false
    property string position: "bottom-center"
    property int timeoutSeconds: 8
    property string groupingMode: "channel"
    property bool onePerApp: groupingMode === "app"
    property bool infiniteChat: true
    property bool otpCopy: true

    onDoNotDisturbChanged: if (!service._hydrating) service.scheduleSettingsSave()
    onPositionChanged: if (!service._hydrating) service.scheduleSettingsSave()
    onTimeoutSecondsChanged: if (!service._hydrating) service.scheduleSettingsSave()
    onGroupingModeChanged: if (!service._hydrating) service.scheduleSettingsSave()
    onInfiniteChatChanged: if (!service._hydrating) service.scheduleSettingsSave()
    onOtpCopyChanged: if (!service._hydrating) service.scheduleSettingsSave()
  }

  // Guards change handlers while hydrating from disk so load doesn't trigger immediate write-backs
  property bool _hydrating: false

  readonly property alias doNotDisturb: persisted.doNotDisturb
  readonly property alias position: persisted.position
  readonly property alias timeoutSeconds: persisted.timeoutSeconds
  readonly property alias groupingMode: persisted.groupingMode
  readonly property alias onePerApp: persisted.onePerApp
  readonly property alias infiniteChat: persisted.infiniteChat
  readonly property alias otpCopy: persisted.otpCopy

  function setDoNotDisturb(value) { persisted.doNotDisturb = !!value }
  function setPosition(value) { persisted.position = String(value || "bottom-center") }
  function setTimeoutSeconds(value) { persisted.timeoutSeconds = Math.max(1, Number(value) || 8) }
  function setGroupingMode(value) {
    var mode = String(value || "channel").toLowerCase()
    if (mode !== "all" && mode !== "app" && mode !== "channel") mode = "channel"
    persisted.groupingMode = mode
  }
  function setOnePerApp(value) { persisted.groupingMode = value ? "app" : "all" }
  function setInfiniteChat(value) { persisted.infiniteChat = !!value }
  function setOtpCopy(value) { persisted.otpCopy = !!value }

  function dismissAll() {
    for (var i = popupModel.count - 1; i >= 0; i--) {
      dismissPopup(i)
    }
  }

  // popupModel feeds the on-screen toast stack — the only model the service
  // keeps. Everything a toast leaves behind lives on disk under historyDir.
  //
  // Aliased as a property so consumers outside this Item's id scope can bind
  // to it. QML ids aren't visible to external consumers without the alias.
  property alias popupModel: popupModel
  ListModel { id: popupModel }

  // How many notifications the history directory keeps, and therefore how
  // many `showHistory` can replay.
  readonly property int historyLimit: 10

  readonly property int lowPopupDuration: 5000
  readonly property int normalPopupDuration: 8000
  readonly property int maxPopupDuration: 30000

  function durationFor(urgency, expireTimeout, app, appIcon) {
    if (persisted.infiniteChat && NotificationLogic.isNeverTimeoutApp(app, appIcon)) {
      return 0
    }
    var normalDuration = Math.max(1000, persisted.timeoutSeconds * 1000)
    switch (urgency) {
    case NotificationUrgency.Critical:
      return 0
    case NotificationUrgency.Low:
      return Math.min(maxPopupDuration, Math.max(lowPopupDuration, requestedDuration(expireTimeout)))
    default:
      return Math.min(maxPopupDuration, Math.max(normalDuration, requestedDuration(expireTimeout)))
    }
  }

  function requestedDuration(expireTimeout) {
    // FreeDesktop notification spec (and Quickshell) report expireTimeout in
    // milliseconds, so pass it through directly.
    var ms = Number(expireTimeout || 0)
    if (!isFinite(ms) || ms <= 0) return 0
    return Math.round(ms)
  }

  // DND bypass: only let through notifications we trust to be intentional
  // and rare.
  //   - omarchy-action: a user-action confirmation toast ("Theme changed",
  //     "Screenshot saved"). The user JUST did something — their feedback
  //     should show.
  //   - urgency=critical AND app_name=notify-send: bare-CLI emergency alerts.
  //     Trusted because it's almost always omarchy or system shell scripts —
  //     chat apps set app_name to their brand (Discord/Slack/Vesktop), which
  //     falls outside this rule.
  function shouldBypassDnd(notification) {
    return NotificationLogic.shouldBypassDnd(notification, NotificationUrgency.Critical)
  }

  function snapshotOf(notification) {
    return NotificationLogic.snapshotOf(notification, Date.now())
  }

  // A notification nobody looks back at:
  //   - the freedesktop `transient` hint is set ("popup only, don't store")
  //   - app_name is "notify-send" (the CLI default — means the sender
  //     didn't bother declaring an identity, so it's almost certainly
  //     ephemeral test/feedback noise)
  //   - app_name is "omarchy-action" (Omarchy's own user-action toasts —
  //     the user just triggered them)
  // Their toasts still land in history like any other once they've been on
  // screen; the distinction only decides whether a DND-silenced one is worth
  // recording at all.
  function isEphemeral(notification) {
    var isTransient = false
    try {
      isTransient = !!(notification.hints && notification.hints["transient"])
    } catch (e) { isTransient = false }
    return isTransient || NotificationLogic.isEphemeralApp(String(notification.appName || ""))
  }

  function handleNotification(notification) {
    // Without `tracked = true` the Notification object is destroyed as soon
    // as this signal handler returns, which would null out the `ref` we just
    // captured for the popup card.
    notification.tracked = true
    var snapshot = snapshotOf(notification)
    liveRefs[snapshot.originalId] = notification
    // Guard the delete: a newer notification may have reused this originalId
    // (freedesktop replaces_id) and taken over the map slot.
    notification.closed.connect(function() {
      if (service.liveRefs[snapshot.originalId] === notification)
        delete service.liveRefs[snapshot.originalId]
    })

    // DND bypass rules: chat apps abuse urgency=critical to force
    // visibility, so critical alone isn't enough — we also require the
    // sender to be CLI-style. See shouldBypassDnd().
    if (service.doNotDisturb && !shouldBypassDnd(notification)) {
      // The toast never shows, so the only record a silenced notification
      // can leave is a history entry. Write it straight into history —
      // "what did I miss while silenced" is exactly what history is for.
      if (!isEphemeral(notification)) {
        writeSilenced(notification, snapshot)
        return
      }
      delete liveRefs[snapshot.originalId]
      notification.tracked = false
      return
    }

    persistPopupFile(snapshot)
    watchForUpdates(notification, snapshot)
    // Qt.callLater avoids "QV4::Object::insertMember" crashes when a
    // Repeater is mid-incubation while we mutate its model.
    Qt.callLater(function() {
      removePopupsByOriginalId(snapshot.originalId, NotificationLogic.popupFileName(snapshot))
      removePopupsByGroup(snapshot, NotificationLogic.popupFileName(snapshot))
      popupModel.insert(0, snapshot)
      while (popupModel.count > service.maxActivePopups) {
        service.dismissPopup(popupModel.count - 1)
      }
      // An update that arrived while the insert was deferred found no row to
      // write to, and a property that already changed will not change again.
      // Reading the object once the row exists catches up on it.
      service.refreshPopup(notification, snapshot.originalId, snapshot.timestamp)
    })
  }

  // Persist a silenced notification, held tracked until its content is
  // stable: untracking tells the sender its notification closed (Chromium
  // then deletes its avatar file), and a replaces_id update lands on this
  // object without a second onNotification — releasing on a stale snapshot
  // would drop it. Each catch-up write reuses the original file identity.
  function writeSilenced(notification, written) {
    writeHistoryFile(written, function() {
      var updated = null
      try {
        updated = NotificationLogic.replacementSnapshot(notification, written.originalId, written.timestamp)
      } catch (e) {
        // Torn down by the server while the write was queued.
      }
      if (updated && NotificationLogic.popupRowChanged(written, updated)) {
        service.writeSilenced(notification, updated)
        return
      }
      service.releaseSilenced(notification, written.originalId)
    })
  }

  // Let go of a DND-silenced notification once its history write has run.
  // The id may have been reused and the object torn down meanwhile.
  function releaseSilenced(notification, originalId) {
    if (liveRefs[originalId] === notification) delete liveRefs[originalId]
    try {
      notification.tracked = false
    } catch (e) {
      // Object already destroyed by the server — nothing left to release.
    }
  }

  // Everything the card draws. A change to any of these is a client updating
  // the notification in place, which is the only kind of update we ever hear
  // about after the popup exists.
  readonly property var updateSignals: [
    "summaryChanged", "bodyChanged", "appNameChanged", "appIconChanged",
    "imageChanged", "urgencyChanged", "expireTimeoutChanged", "hintsChanged"
  ]

  // A client that updates a notification through replaces_id does not produce
  // a second onNotification: the server writes the new content onto the object
  // we are already holding. The card draws a snapshot copied out of that
  // object — deliberately, since the object itself must stay out of the model
  // — so nothing reaches the screen until we copy it again.
  function watchForUpdates(notification, snapshot) {
    function refresh() {
      service.refreshPopup(notification, snapshot.originalId, snapshot.timestamp)
    }

    for (var i = 0; i < updateSignals.length; i++) {
      var signal = notification[updateSignals[i]]
      if (signal && typeof signal.connect === "function") signal.connect(refresh)
    }
  }

  function refreshPopup(notification, originalId, timestamp) {
    // A newer notification may have taken this id over, and the object may
    // outlive its popup — in both cases there is nothing here to refresh.
    if (service.liveRefs[originalId] !== notification) return

    var updated
    try {
      updated = NotificationLogic.replacementSnapshot(notification, originalId, timestamp)
    } catch (e) {
      // Object torn down by the server while the signal was in flight.
      return
    }

    var roles = NotificationLogic.popupRoles()
    for (var i = 0; i < popupModel.count; i++) {
      var row = popupModel.get(i)
      if (!row || row.originalId !== originalId || row.timestamp !== timestamp) continue
      if (!NotificationLogic.popupRowChanged(row, updated)) return
      for (var r = 0; r < roles.length; r++) popupModel.setProperty(i, roles[r], updated[roles[r]])
      // The file name is the timestamp and id this popup was persisted under,
      // so the rewrite lands on the same file: a restart restores the version
      // last shown, and so does the copy that ends up in history.
      persistPopupFile(updated)
      return
    }
  }

  // A restored row carries an id from the previous server generation, and
  // the new server hands out ids from 1 again — so a fresh notification
  // with the same originalId is a coincidence, not the same notification.
  // The timestamp (via the file name) disambiguates: it travels with the
  // row through every model and file round-trip.
  function isRestoredRow(row) {
    return !!row && !!restoredPopups[NotificationLogic.popupFileName(row)]
  }

  // A notification arriving under an originalId a popup on screen already
  // holds supersedes it, so that row leaves the screen. Its file is deleted
  // rather than archived: the row taking its place archives itself when it
  // goes, and history would otherwise hold two entries for what the sender
  // means as one notification.
  // keepFileName is the replacement's own file: a same-millisecond
  // replacement shares the replaced row's filename, and the new write is
  // already queued — deleting that path here would erase the replacement's
  // only file.
  function removePopupsByOriginalId(originalId, keepFileName) {
    for (var i = popupModel.count - 1; i >= 0; i--) {
      var row = popupModel.get(i)
      if (!row || row.originalId !== originalId) continue
      // Not a replaces_id match — see isRestoredRow. Removing it here
      // would silently kill a restored critical alert on an unrelated ping.
      if (isRestoredRow(row)) continue
      if (NotificationLogic.popupFileName(row) !== keepFileName) deletePopupFileFor(row)
      popupModel.remove(i)
    }
  }

  function removePopupsByApp(appName, keepFileName) {
    var name = String(appName || "").trim().toLowerCase()
    if (!name) return
    for (var i = popupModel.count - 1; i >= 0; i--) {
      var row = popupModel.get(i)
      if (!row) continue
      var rowApp = String(row.app || "").trim().toLowerCase()
      if (rowApp === name) {
        if (NotificationLogic.popupFileName(row) !== keepFileName) {
          dismissPopup(i)
        }
      }
    }
  }

  function removePopupsByGroup(snapshot, keepFileName) {
    if (persisted.groupingMode === "all") return

    var targetApp = String(snapshot.app || "").trim().toLowerCase()
    if (!targetApp) return

    if (persisted.groupingMode === "app") {
      removePopupsByApp(snapshot.app, keepFileName)
      return
    }

    if (persisted.groupingMode === "channel") {
      var targetChannel = String(snapshot.channel || "").trim().toLowerCase()
      var targetKey = targetChannel ? (targetApp + "::" + targetChannel) : (targetApp + "::" + String(snapshot.summary || "").trim().toLowerCase())

      for (var i = popupModel.count - 1; i >= 0; i--) {
        var row = popupModel.get(i)
        if (!row) continue
        var rowApp = String(row.app || "").trim().toLowerCase()
        if (rowApp !== targetApp) continue

        var rowChannel = String(row.channel || "").trim().toLowerCase()
        var rowKey = rowChannel ? (rowApp + "::" + rowChannel) : (rowApp + "::" + String(row.summary || "").trim().toLowerCase())

        if (rowKey === targetKey && NotificationLogic.popupFileName(row) !== keepFileName) {
          dismissPopup(i)
        }
      }
    }
  }

  function dismissPopup(index) {
    removePopup(index, "dismiss")
  }

  function expirePopup(index) {
    removePopup(index, "expire")
  }

  function removePopup(index, reason) {
    if (index < 0 || index >= popupModel.count) return
    var entry = popupModel.get(index)
    var originalId = entry ? entry.originalId : -1
    // A restored row has no live server object, and its old-generation id
    // may meanwhile belong to a fresh notification — resolving liveRefs by
    // id would dismiss that unrelated notification at the server.
    var restored = isRestoredRow(entry)
    var ref = !restored && originalId >= 0 ? liveRefs[originalId] : null
    // The popup is leaving the screen — for any reason — so its file must not
    // survive to the next shell restart. It becomes the newest history entry
    // instead. Rows that never had a file (a history replay, the empty-history
    // placeholder) archive to nothing, which the move tolerates.
    if (entry) {
      archivePopupFileFor(entry)
      if (restored) delete restoredPopups[NotificationLogic.popupFileName(entry)]
    }
    popupModel.remove(index)
    if (ref) {
      try {
        if (ref.tracked) {
          if (reason === "expire" && typeof ref.expire === "function") ref.expire()
          else ref.dismiss()
        }
      } catch (e) {
        // Object already torn down by the server — nothing to dismiss.
      }
    }
  }

  function clearPopups() {
    while (popupModel.count > 0) dismissPopup(0)
  }

  // Run the popup's client-registered default action, then dismiss.
  // Arbitrary shell commands are explicitly forbidden and removed for security.
  function invokePopupDefault(index) {
    if (index < 0 || index >= popupModel.count) return
    var entry = popupModel.get(index)
    // Restored rows have no live actions, and looking up liveRefs by their
    // old-generation id could fire an unrelated fresh notification's action.
    var ref = entry && !isRestoredRow(entry) ? liveRefs[entry.originalId] : null
    var invoked = false
    try {
      if (ref && ref.actions) {
        for (var i = 0; i < ref.actions.length; i++) {
          var action = ref.actions[i]
          if (action && action.identifier === "default") {
            action.invoke()
            invoked = true
            break
          }
        }
      }
    } catch (e) {
      // Notification already torn down by the server — fall through to focus.
      console.warn("invoke default failed:", e)
    }
    // Chat apps (Slack, Discord, Vesktop, etc.) rarely register a "default"
    // libnotify action — they just expect clicking the notification to
    // focus their window. Fall back to focusing the sending app by class so
    // that click-to-jump actually works.
    if (!invoked) focusApp(entry)
    dismissPopup(index)
  }

  // Try to focus an existing Hyprland window matching the notification's
  // sender. The helper handles case-insensitive class matching.
  function focusApp(entry) {
    if (!entry || !entry.app) return
    var cleanApp = String(entry.app || "").replace(/[^a-zA-Z0-9_\-\. ]/g, "").trim()
    if (!cleanApp) return
    focusAppProc.command = [
      service.omarchyPath + "/bin/omarchy-hyprland-focus-app",
      cleanApp
    ]
    focusAppProc.running = true
  }

  Process { id: focusAppProc; running: false }

  Process {
    id: ensureDirsProc
    command: [service.storageScript, "ensure-dirs", service.stateDir]
    running: false
  }

  // ---------------------------------------------------- popup persistence
  //
  // Mirror every on-screen popup to its own file under popupStateDir so
  // toasts survive shell restarts (notably the restart `omarchy-update`
  // performs). Writes, moves and deletes go through one serialized queue: a
  // burst of replaces_id updates must not race a single reused Process, and
  // ordering guarantees a delete issued after a write wins.

  // Popups restored from a previous shell process, keyed by their file
  // name (timestamp-originalId) since ids alone repeat across server
  // generations. The replaces_id handling and liveRefs lookups must not
  // match these rows against fresh notifications.
  property var restoredPopups: ({})

  // Entries are { command, input, done }
  property var popupFileQueue: []
  property var runningPopupFileJobDone: null

  function enqueuePopupFileJob(command, input, done) {
    if (typeof input === "function") {
      done = input
      input = ""
    }
    popupFileQueue = popupFileQueue.concat([{
      command: command,
      input: typeof input === "string" ? input : "",
      done: done || null
    }])
    runNextPopupFileJob()
  }

  function enqueueHistoryRead() {
    popupFileQueue = popupFileQueue.concat([{ read: true }])
    runNextPopupFileJob()
  }

  function runNextPopupFileJob() {
    if (readHistoryProc.running || popupFileProc.running) return
    if (popupFileQueue.length === 0) return

    var job = popupFileQueue[0]
    popupFileQueue = popupFileQueue.slice(1)

    if (job.read) {
      startHistoryRead()
      return
    }

    popupFileProc.pendingInput = job.input || ""
    popupFileProc.command = job.command
    service.runningPopupFileJobDone = job.done || null
    popupFileProc.running = true
  }

  Process {
    id: popupFileProc
    property string pendingInput: ""
    stdinEnabled: true
    running: false
    onStarted: {
      if (pendingInput.length > 0) {
        write(pendingInput + "\n")
        pendingInput = ""
      }
    }
    onExited: {
      var done = service.runningPopupFileJobDone
      service.runningPopupFileJobDone = null
      if (done) {
        try {
          done()
        } catch (e) {
          console.warn("notifications: file job callback failed:", e)
        }
      }
      service.runNextPopupFileJob()
    }
  }

  function persistPopupFile(snapshot) {
    var persistable = NotificationLogic.persistablePopup(snapshot, imagesDir)
    for (var i = 0; i < persistable.copies.length; i++) {
      var cp = persistable.copies[i]
      var stem = NotificationLogic.imageStem(snapshot) + "-" + (cp.role || ("role" + i))
      enqueuePopupFileJob([service.storageScript, "copy-image", cp.from, imagesDir, stem])
    }
    var json = NotificationLogic.serializePopup(persistable.entry, NotificationUrgency.Normal)
    if (json.length > 32768) json = json.slice(0, 32768)
    var fileName = NotificationLogic.popupFileName(snapshot)
    enqueuePopupFileJob([service.storageScript, "write-json", popupStateDir, fileName], json)
  }

  function deletePopupFileFor(row) {
    if (!row) return
    var stem = NotificationLogic.imageStem(row)
    enqueuePopupFileJob([service.storageScript, "delete", popupStateDir, imagesDir, stem])
  }

  function archivePopupFileFor(row) {
    if (!row) return
    var fileName = NotificationLogic.popupFileName(row)
    enqueuePopupFileJob([service.storageScript, "archive", popupStateDir, historyDir, fileName, String(service.historyLimit), imagesDir])
  }

  function writeHistoryFile(entry, done) {
    if (!entry) {
      if (done) done()
      return
    }
    var persistable = NotificationLogic.persistablePopup(entry, imagesDir)
    for (var i = 0; i < persistable.copies.length; i++) {
      var cp = persistable.copies[i]
      var stem = NotificationLogic.imageStem(entry) + "-" + (cp.role || ("role" + i))
      enqueuePopupFileJob([service.storageScript, "copy-image", cp.from, imagesDir, stem])
    }
    var json = NotificationLogic.serializePopup(persistable.entry, NotificationUrgency.Normal)
    if (json.length > 32768) json = json.slice(0, 32768)
    var fileName = NotificationLogic.popupFileName(entry)
    enqueuePopupFileJob([service.storageScript, "write-json", historyDir, fileName], json, done)
  }

  function clearHistory() {
    enqueuePopupFileJob([service.storageScript, "clear-history", historyDir, imagesDir, popupStateDir])
  }

  function sweepOrphanImages() {
    enqueuePopupFileJob([service.storageScript, "sweep-images", imagesDir, popupStateDir, historyDir])
  }

  Process {
    id: readHistoryProc
    running: false
    // Let the file queue go again, whatever the read did — a failed or empty
    // read must not leave archives and clears parked behind it forever.
    onExited: service.runNextPopupFileJob()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.replayHistory(text)
    }
  }

  // Toasts that were on screen when the replay was asked for. The clear in
  // replayHistory archives them, but the directory read is already in flight
  // by then, so they're handed over in memory instead of being waited for.
  property var replayCarryOver: []

  // Set from the moment a read is queued until it starts, so a second
  // showHistory while one is still waiting its turn doesn't queue another.
  property bool historyReadQueued: false

  // Re-show what's in historyDir as toasts. The read goes through the file
  // queue and its own subprocess, so the replay lands in replayHistory once
  // the work queued ahead of it has finished.
  function showRecentHistory() {
    if (readHistoryProc.running || service.historyReadQueued) return "ok"
    service.replayCarryOver = liveRowsForReplay()
    service.historyReadQueued = true
    enqueueHistoryRead()
    return "ok"
  }

  function startHistoryRead() {
    service.historyReadQueued = false
    readHistoryProc.command = [service.storageScript, "read-history", historyDir, String(service.historyLimit)]
    readHistoryProc.running = true
  }

  // Copy the on-screen rows out of the model. The placeholder from an earlier
  // empty replay carries originalId -1 and is not a notification, so it is
  // left behind rather than replayed as one. The replay dismisses these
  // notifications, and senders delete their images on close — so the carried
  // rows point at the persisted copies, like the archived files they join.
  function liveRowsForReplay() {
    var rows = []
    for (var i = 0; i < popupModel.count; i++) {
      var row = popupModel.get(i)
      if (!row || row.originalId < 0) continue
      rows.push(NotificationLogic.persistablePopup({
        id: row.id,
        originalId: row.originalId,
        app: row.app,
        appIcon: row.appIcon,
        summary: row.summary,
        body: row.body,
        image: row.image,
        glyph: row.glyph || "",
        channel: row.channel || "",
        urgency: row.urgency,
        timestamp: row.timestamp
      }, imagesDir).entry)
    }
    return rows
  }

  function replayHistory(raw) {
    var rows = NotificationLogic.historyRows(
      raw, service.replayCarryOver, NotificationUrgency.Normal, service.historyLimit)
    service.replayCarryOver = []

    // Replaying nothing at all looks like a dead keybinding, so say so.
    if (rows.length === 0) {
      popupModel.insert(0, {
        id: -1,
        originalId: -1,
        app: "omarchy-action",
        appIcon: "",
        summary: "No recent notifications",
        body: "",
        image: "",
        glyph: "󰂚",
        channel: "",
        urgency: NotificationUrgency.Low,
        expireTimeout: 0,
        timestamp: Date.now()
      })
      return
    }

    clearPopups()
    // Rows arrive newest-first, and index 0 is the top of the toast stack.
    for (var i = 0; i < rows.length; i++) {
      // Replayed rows are restored rows: their notification died with the
      // sender long ago, so they must never resolve to a live server object
      // that has since been handed their old id.
      service.restoredPopups[NotificationLogic.popupFileName(rows[i])] = true
      popupModel.append(rows[i])
    }
  }

  Process {
    id: restorePopupsProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.restorePopups(text)
    }
  }

  function restorePopups(raw) {
    var entries = NotificationLogic.parsePopupFiles(raw, NotificationUrgency.Normal)
    var now = Date.now()
    var live = []
    var seenApps = {}
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      var appKey = String(entry.app || "").trim().toLowerCase()
      if (appKey && seenApps[appKey]) {
        archivePopupFileFor(entry)
        continue
      }
      if (appKey) seenApps[appKey] = true
      var duration = durationFor(entry.urgency, entry.expireTimeout, entry.app, entry.appIcon)
      if (NotificationLogic.popupExpired(entry, duration, now)) {
        // It would have expired on screen had the shell kept running, so it
        // gets archived exactly like an expiry that happened while it did.
        archivePopupFileFor(entry)
        continue
      }
      // Survivors restart with a full lifetime on purpose: shell restarts
      // are rare, and a full look after the restart flicker beats resuming
      // a toast with a second left on its clock. The reset is persisted as
      // an absolute deadline so a second restart while the toast is still
      // on screen judges it by the reset clock, not the original timestamp.
      if (duration > 0) {
        entry.deadline = now + duration
        persistPopupFile(entry)
        // deadline is persistence metadata, not a model role — fresh rows
        // never carry it, and ListModel roles must stay consistent.
        delete entry.deadline
      }
      live.push(entry)
    }
    if (live.length === 0) return

    Qt.callLater(function() {
      for (var j = 0; j < live.length; j++) {
        var restored = live[j]
        // A notification received while the restore was reading the dir can
        // already occupy this originalId with the same timestamp — then it
        // IS this entry, live with its own file, and must be left alone. A
        // different timestamp is indistinguishable between a genuine
        // cross-restart replaces_id and a new-generation id coincidence, so
        // show both: a briefly duplicated toast beats silently dropping a
        // restored critical alert.
        var duplicate = false
        for (var k = 0; k < popupModel.count; k++) {
          var row = popupModel.get(k)
          if (row && row.originalId === restored.originalId && row.timestamp === restored.timestamp) {
            duplicate = true
            break
          }
        }
        if (duplicate) continue
        // Append (entries are newest-first) so restored toasts stack in
        // their original order below anything that just arrived. Restored
        // popups have no liveRefs entry — the server object died with the
        // old shell — so dismissal and action fallbacks degrade gracefully.
        service.restoredPopups[NotificationLogic.popupFileName(restored)] = true
        popupModel.append(restored)
      }
    })
  }

  // ---------------------------------------------------- settings persistence

  FileView {
    id: settingsFile
    path: service.settingsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: service.loadSettings(text())
    // First-run: the file doesn't exist yet. Without this branch,
    // `settingsLoaded` stays false forever and `scheduleSettingsSave` becomes
    // a no-op — so the file is never created and the DND preference vanishes
    // on shell restart.
    onLoadFailed: service.loadSettings("")
  }

  Timer {
    id: settingsSaveTimer
    interval: 200
    repeat: false
    onTriggered: service.flushSettings()
  }

  function scheduleSettingsSave() {
    if (!service.settingsLoaded) return
    settingsSaveTimer.restart()
  }

  property bool settingsLoaded: false

  function loadSettings(raw) {
    // FileView can fire onLoaded more than once during startup — the implicit
    // preload when `path` resolves, plus the explicit `settingsFile.reload()`
    // in Component.onCompleted can both end up calling here.
    if (service.settingsLoaded) return

    var parsed = NotificationLogic.parseSettings(raw)
    if (parsed.error) console.warn("notifications: settings parse failed:", parsed.errorMessage || "")

    service._hydrating = true
    if (parsed.dnd !== null) persisted.doNotDisturb = parsed.dnd
    if (parsed.position) persisted.position = parsed.position
    if (parsed.timeoutSeconds) persisted.timeoutSeconds = parsed.timeoutSeconds
    if (parsed.groupingMode) persisted.groupingMode = parsed.groupingMode
    if (typeof parsed.infiniteChat === "boolean") persisted.infiniteChat = parsed.infiniteChat
    if (typeof parsed.otpCopy === "boolean") persisted.otpCopy = parsed.otpCopy
    service._hydrating = false

    service.settingsLoaded = true
    // Versions before the history moved into its own directory kept every
    // notification in here. Rewrite once so that dead payload doesn't sit in
    // the file until the next DND toggle happens to clear it.
    if (parsed.legacy) service.scheduleSettingsSave()
  }

  function flushSettings() {
    var json = JSON.stringify({
      version: 5,
      dnd: persisted.doNotDisturb,
      position: persisted.position,
      timeoutSeconds: persisted.timeoutSeconds,
      groupingMode: persisted.groupingMode,
      infiniteChat: persisted.infiniteChat,
      otpCopy: persisted.otpCopy
    }, null, 2) + "\n"
    enqueuePopupFileJob([service.storageScript, "write-json", stateDir, "notifications.json"], json)
  }

  Component.onCompleted: {
    ensureDirsProc.running = true
    // Once mkdir has had a tick, load the existing settings file. FileView
    // surfaces an empty string when the file doesn't exist; loadSettings
    // handles that path.
    Qt.callLater(function() {
      settingsFile.reload()
      // Re-show popups that were on screen when the previous shell died.
      restorePopupsProc.command = [service.storageScript, "read-active", service.popupStateDir]
      restorePopupsProc.running = true
      // Safe beside the restore read: it only re-persists entries whose
      // JSON exists, exactly the images the sweep keeps.
      service.sweepOrphanImages()
    })
  }

  function sendPreview() {
    Util.execArgv([
      "notify-send",
      "-a", "Slack",
      "-h", "string:x-kde-tag:channel_dev",
      "Alice in #dev",
      "G-492019 is your staging deploy verification code."
    ])
  }

  // ---------------------------------------------------- IPC

  IpcHandler {
    target: "notifications"

    function preview(): string {
      service.sendPreview()
      return "ok"
    }

    function dndState(): string {
      return service.doNotDisturb ? "on" : "off"
    }

    function toggleDnd(): string {
      service.setDoNotDisturb(!service.doNotDisturb)
      return dndState()
    }

    function setDnd(value: string): string {
      var v = String(value || "").toLowerCase()
      var on = v === "true" || v === "1" || v === "on" || v === "yes"
      service.setDoNotDisturb(on)
      return dndState()
    }

    function isDnd(): string {
      return dndState()
    }

    // Replay the notifications that have been moved into the history dir.
    function showHistory(): string {
      return service.showRecentHistory()
    }

    // `clear` forgets the recorded history; the toasts on screen stay put.
    function clear(): string {
      service.clearHistory()
      return "ok"
    }

    function dismissAll(): string {
      service.clearPopups()
      return "ok"
    }

    // Dismiss the most recent popup.
    function dismissOne(): string {
      if (popupModel.count === 0) return "none"
      service.dismissPopup(0)
      return "ok"
    }

    // Fire the default action on the most recent popup, then dismiss it.
    function invokeLast(): string {
      if (popupModel.count === 0) return "none"
      service.invokePopupDefault(0)
      return "ok"
    }

    // Take a toast off the screen by summary substring, used by the
    // first-run notifications once their action has been clicked.
    function dismiss(summary: string): string {
      var needle = String(summary || "")
      if (!needle) return "none"
      var hit = false
      for (var i = popupModel.count - 1; i >= 0; i--) {
        var row = popupModel.get(i)
        if (row && String(row.summary || "").indexOf(needle) !== -1) {
          service.dismissPopup(i)
          hit = true
        }
      }
      return hit ? "ok" : "none"
    }

    function ping(): string { return "ok" }
  }

  // ---------------------------------------------------- server

  NotificationServer {
    id: server
    keepOnReload: false
    imageSupported: true
    actionsSupported: true
    bodyMarkupSupported: true
    bodyHyperlinksSupported: true
    persistenceSupported: true

    onNotification: function(notification) {
      service.handleNotification(notification)
    }
  }

  // -------------------------------------------------------------- popup UI
  //
  // One PanelWindow per output (Variants on Quickshell.screens) holding the
  // stacked toast cards. Layer is Overlay, exclusionMode Ignore, no
  // keyboard focus — popups are passive surfaces and must never steal input
  // from the focused application.

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: popupWindow
      required property var modelData
      screen: modelData
      visible: popupModel.count > 0

      WlrLayershell.namespace: "omarchy-notifications"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      color: "transparent"

      readonly property var popupPlacement: NotificationLogic.popupPlacement(
        service.barPosition, service.barClearance, Style.gapsOut, service.position)

      // Full-screen, fixed-size surface (like the OSD overlay). Adding or
      // removing a toast changes only the content inside; the Wayland surface
      // never resizes, so the compositor can't briefly scale a stale buffer --
      // which is what stretched/squished the cards during count changes.
      anchors { top: true; bottom: true; left: true; right: true }

      // Keep the surface click-through except over the toast column, so the
      // rest of the (invisible) full-screen overlay never eats input.
      mask: Region { item: popupColumn }

      ColumnLayout {
        id: popupColumn
        anchors.horizontalCenter: popupWindow.popupPlacement.isCenter ? parent.horizontalCenter : undefined
        anchors.left: popupWindow.popupPlacement.isLeft ? parent.left : undefined
        anchors.right: popupWindow.popupPlacement.isRight ? parent.right : undefined
        anchors.top: popupWindow.popupPlacement.isTop ? parent.top : undefined
        anchors.bottom: popupWindow.popupPlacement.isBottom ? parent.bottom : undefined

        anchors.topMargin: popupWindow.popupPlacement.margins.top
        anchors.bottomMargin: popupWindow.popupPlacement.margins.bottom
        anchors.leftMargin: popupWindow.popupPlacement.margins.left
        anchors.rightMargin: popupWindow.popupPlacement.margins.right
        spacing: Style.space(8)

        Repeater {
          model: popupModel

          // The delegate is a slot Item that owns lifetime timer state. The
          // actual visuals live in NotificationCard, which the history panel
          // also reuses.
          delegate: Item {
            id: cardSlot
            required property int index
            required property string app
            required property string appIcon
            required property string summary
            required property string body
            required property string image
            required property string glyph
            required property string channel
            required property int urgency
            required property double expireTimeout
            required property double timestamp

            // Each card sizes itself based on mode (text vs media); the slot
            // tracks the card so the column auto-fits to whichever is widest.
            width: card.implicitWidth
            height: card.implicitHeight
            implicitWidth: card.implicitWidth
            implicitHeight: card.implicitHeight
            Layout.preferredWidth: card.implicitWidth
            Layout.preferredHeight: card.implicitHeight
            Layout.alignment: popupWindow.popupPlacement.isLeft ? Qt.AlignLeft : (popupWindow.popupPlacement.isRight ? Qt.AlignRight : Qt.AlignHCenter)

            readonly property real lifetime: service.durationFor(cardSlot.urgency, cardSlot.expireTimeout, cardSlot.app, cardSlot.appIcon)
            property real remainingLifetime: 1.0
            readonly property bool ticking: cardSlot.lifetime > 0 && !card.hovered

            // A client updating this notification in place rewrites the row
            // under the card (see refreshPopup). New text deserves a full look,
            // so the countdown starts over instead of running out the clock the
            // superseded text was already most of the way through. Delegates
            // keep their own row as the model changes around them, so only a
            // real content change lands here.
            onSummaryChanged: cardSlot.remainingLifetime = 1.0
            onBodyChanged: cardSlot.remainingLifetime = 1.0
            onImageChanged: cardSlot.remainingLifetime = 1.0

            Timer {
              interval: 50
              repeat: true
              running: cardSlot.ticking
              onTriggered: {
                if (cardSlot.lifetime <= 0) return
                cardSlot.remainingLifetime -= 50.0 / cardSlot.lifetime
                if (cardSlot.remainingLifetime <= 0) {
                  cardSlot.remainingLifetime = 0
                  service.expirePopup(cardSlot.index)
                }
              }
            }

            NotificationCard {
              id: card
              anchors.fill: parent
              app: cardSlot.app
              appIcon: cardSlot.appIcon
              summary: cardSlot.summary
              body: cardSlot.body
              image: cardSlot.image
              urgency: cardSlot.urgency
              timestamp: cardSlot.timestamp
              cornerRadius: service.cornerRadius
              fontFamily: service.shell && service.shell.bar ? service.shell.bar.fontFamily : ""
              glyph: cardSlot.glyph
              channel: cardSlot.channel
              otpEnabled: service.otpCopy

              onCloseRequested: service.dismissPopup(cardSlot.index)
              onCardClicked: service.invokePopupDefault(cardSlot.index)
            }
          }
        }
      }
    }
  }
}
