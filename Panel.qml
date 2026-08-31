import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Seafile sync status, library list, and daemon control for the Omarchy
// bar, backed entirely by seaf-cli -- including everything the desktop
// Seafile client (seafile-applet) offers: account login, browsing remote
// libraries, downloading / linking-an-existing-folder / creating libraries,
// and desyncing. Modeled on the built-in Dropbox panel for the bar icon and
// hero layout; the account/remote-library flows are new.
Panel {
  id: root
  moduleName: "io.github.kerrongordon.seafile"
  ipcTarget: "io.github.kerrongordon.seafile"
  manageIpc: false

  // "libraries" (default) | "login" | "browse" | "create" | "activity" | "errors" | "settings"
  property string viewMode: "libraries"
  property string focusSection: "header"
  property int libraryIndex: 0
  property bool cursorActive: false

  // The remote library currently being downloaded / linked, while the
  // inline folder-target form is open. Cleared when that form closes.
  property var pendingLibrary: null
  property string pendingMode: "download"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string tone: Model.overallTone(seafile.libraries, seafile.installed, seafile.daemonRunning)
  readonly property string summary: Model.summaryText(seafile.libraries, seafile.installed, seafile.daemonRunning)
  readonly property color toneColor: tone === "error" ? urgent : (tone === "busy" ? Color.accent : foreground)
  readonly property bool toneDim: tone === "dim"
  readonly property string toggleHint: seafile.active ? "Stop Seafile" : "Start Seafile"

  readonly property color barForeground: bar ? bar.barForeground : Color.foreground
  readonly property color barToneColor: tone === "error" ? (bar ? bar.urgent : Color.urgent) : (tone === "busy" ? Color.accent : barForeground)

  readonly property bool headerHasCursor: cursorActive && focusSection === "header"

  function ensureCursor() {
    if (root.viewMode !== "libraries" || seafile.libraries.length === 0) {
      focusSection = "header"
      libraryIndex = 0
      return
    }
    if (focusSection !== "libraries" && focusSection !== "header") focusSection = "libraries"
    if (libraryIndex >= seafile.libraries.length) libraryIndex = Math.max(0, seafile.libraries.length - 1)
    if (libraryIndex < 0) libraryIndex = 0
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0 || root.viewMode !== "libraries") return
    if (focusSection === "header") {
      if (dy > 0 && seafile.libraries.length > 0) {
        focusSection = "libraries"
        libraryIndex = 0
        scrollCursorIntoView()
      }
      return
    }
    if (focusSection === "libraries") {
      if (dy < 0 && libraryIndex === 0) {
        setHeaderCursor()
        return
      }
      libraryIndex = Math.max(0, Math.min(seafile.libraries.length - 1, libraryIndex + dy))
      scrollCursorIntoView()
    }
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
    if (panelFlick) panelFlick.contentY = 0
  }

  function setLibraryCursor(index) {
    cursorActive = true
    focusSection = "libraries"
    libraryIndex = index
    scrollCursorIntoView()
  }

  function activateCursor() {
    if (root.viewMode !== "libraries") return
    ensureCursor()
    if (focusSection === "header") toggleDaemon()
    else if (focusSection === "libraries") seafile.openLibrary(selectedLibrary())
  }

  function selectedLibrary() {
    if (seafile.libraries.length === 0) return null
    return seafile.libraries[Math.max(0, Math.min(libraryIndex, seafile.libraries.length - 1))]
  }

  function toggleDaemon() {
    if (seafile.installed && !seafile.busy) seafile.toggleDaemon()
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (focusSection === "libraries" && libraryColumn && libraryIndex >= 0 && libraryIndex < libraryColumn.children.length) {
      scrollItemIntoView(libraryColumn.children[libraryIndex])
    }
  }

  function openAddLibrary() {
    pendingLibrary = null
    if (!seafile.accountLinked) {
      openLogin()
    } else {
      viewMode = "browse"
      seafile.refreshRemote()
      Qt.callLater(function() { panelFlick.contentY = 0 })
    }
  }

  function openLogin() {
    seafile.loginError = ""
    seafile.loginNeedsTfa = false
    loginPasswordField.text = ""
    loginTfaField.text = ""
    viewMode = "login"
    Qt.callLater(function() { panelFlick.contentY = 0 })
  }

  function goToLibraries() {
    pendingLibrary = null
    viewMode = "libraries"
    cursorActive = false
    loginPasswordField.text = ""
    loginTfaField.text = ""
    Qt.callLater(function() { panelFlick.contentY = 0 })
  }

  function openActivity() {
    viewMode = "activity"
    seafile.refreshActivity()
    Qt.callLater(function() { panelFlick.contentY = 0 })
  }

  // Seahub's web file browser for a library -- the things this widget
  // deliberately doesn't do itself (history, sharing, permissions).
  // `/library/<id>/<name>/` is the real route (a plain Django path, no
  // hash) -- confirmed against a live server: an unauthenticated request
  // to it 302s to login with the path preserved in `next=`, while the
  // older Angular-era `#common/lib/<id>/` hash route this used to build
  // 404s outright on a current Seahub. The name only needs to be *a*
  // valid path segment (Seahub resolves the library from the id and just
  // displays the name back), so it's URL-encoded, not validated.
  function seahubUrl(repoId, repoName) {
    var base = String(seafile.accountServer || "").replace(/\/+$/, "")
    if (!base || !repoId) return ""
    return base + "/library/" + repoId + "/" + encodeURIComponent(repoName || "") + "/"
  }

  function openInSeahub(repoId, repoName) {
    var url = seahubUrl(repoId, repoName)
    if (url) Qt.openUrlExternally(url)
  }

  function openSyncErrors() {
    viewMode = "errors"
    seafile.refreshSyncErrors()
    Qt.callLater(function() { panelFlick.contentY = 0 })
  }

  function openSettings() {
    viewMode = "settings"
    seafile.refreshSettings()
    Qt.callLater(function() { panelFlick.contentY = 0 })
  }

  function startLibraryAction(remoteLib, mode) {
    pendingLibrary = remoteLib
    pendingMode = mode
    Qt.callLater(function() {
      folderField.text = mode === "download" ? (Quickshell.env("HOME") + "/Seafile/" + remoteLib.name) : ""
      libPasswordField.text = ""
      folderField.forceActiveFocus()
    })
  }

  function confirmLibraryAction() {
    if (!pendingLibrary) return
    var folder = folderField.text.trim()
    if (folder === "") return
    var passwd = libPasswordField.text
    if (pendingMode === "download") seafile.downloadLibrary(pendingLibrary, folder, passwd)
    else seafile.syncFolder(pendingLibrary, folder, passwd)
    pendingLibrary = null
  }

  // Shell-style Tab completion for the folder field: extends the current
  // text to the single match, or to the longest common prefix among
  // several -- same idea as bash's own path completion.
  function completeFolderPath() {
    seafile.completePath(folderField.text, function(matches) {
      if (matches.length === 0) return
      var completed = matches.length === 1 ? matches[0] : root.commonPrefix(matches)
      if (completed && completed !== folderField.text) {
        folderField.text = completed
        folderField.cursorPosition = folderField.text.length
      }
    })
  }

  function commonPrefix(strings) {
    var prefix = strings[0]
    for (var i = 1; i < strings.length; i++) {
      var s = strings[i]
      var j = 0
      while (j < prefix.length && j < s.length && prefix[j] === s[j]) j++
      prefix = prefix.substring(0, j)
    }
    return prefix
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    viewMode = "libraries"
    pendingLibrary = null
    if (panelFlick) panelFlick.contentY = 0
    seafile.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onLibraryIndexChanged: scrollCursorIntoView()

  Service {
    id: seafile
    settings: root.settings
  }

  Connections {
    target: seafile
    function onLibrariesChanged() { root.ensureCursor() }
    function onAccountLinkedChanged() {
      if (seafile.accountLinked && root.viewMode === "login") {
        root.viewMode = "browse"
        seafile.refreshRemote()
      }
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { seafile.refresh(); return "ok" }
    function status(): string { return root.summary }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // A plain color tint is easy to miss; an actively spinning icon (the
    // same visual language a refresh spinner uses everywhere else in the
    // shell) is the unambiguous "something is syncing right now" signal,
    // distinct from the tint that stays on for the whole session while
    // just the account or daemon state is off.
    text: root.tone === "busy" ? "\uf021" : (root.tone === "error" ? "\uf071" : "\uf0c2")
    tooltipText: "Seafile \u2014 " + root.summary
    dimmed: root.toneDim
    active: root.tone === "error" || root.tone === "busy"
    activeColor: root.barToneColor
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) seafile.refresh()
      else if (buttonCode === Qt.MiddleButton) root.toggleDaemon()
      else root.toggle()
    }

    RotationAnimation on textRotation {
      running: root.tone === "busy"
      from: 0
      to: 360
      duration: 1100
      loops: Animation.Infinite
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: {
        if (root.pendingLibrary) root.pendingLibrary = null
        else if (root.viewMode !== "libraries") root.goToLibraries()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.viewMode !== "libraries") return
        if (t === "r" || t === "R") seafile.refresh()
        else if (t === "p" || t === "P") root.toggleDaemon()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() { root.setHeaderCursor() }

            PanelHero {
              id: hero
              width: parent.width
              title: "Seafile"
              meta: root.viewMode === "libraries" ? root.summary
                : root.viewMode === "login" ? "Log in to Seafile"
                : root.viewMode === "browse" ? ("Libraries on " + seafile.accountServer)
                : root.viewMode === "activity" ? "Recent activity"
                : root.viewMode === "errors" ? "Sync errors"
                : root.viewMode === "settings" ? "Settings"
                : "Create a new library"
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: seafile.active ? 1.0 : 0.5

              iconComponent: Component {
                Text {
                  text: ""
                  color: root.toneColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              trailingControl: Component {
                Row {
                  spacing: Style.space(8)

                  ToggleSwitch {
                    id: powerSwitch
                    visible: seafile.installed && root.viewMode === "libraries"
                    anchors.verticalCenter: parent.verticalCenter
                    checked: seafile.active
                    busy: seafile.busy
                    hasCursor: header.ringVisible
                    foreground: hero.foreground
                    onHovered: function(on) { if (on) header.focusHero() }
                    onToggled: root.toggleDaemon()

                    PanelToolTip {
                      visible: powerSwitch.containsMouse
                      text: root.toggleHint
                      fontFamily: hero.fontFamily
                    }
                  }
                }
              }
            }
          }

          Row {
            visible: root.viewMode === "libraries" && seafile.installed && !seafile.accountLinked
            width: parent.width
            spacing: Style.space(8)

            Button {
              text: "Log in"
              iconText: "\uf090"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.openAddLibrary()
            }

            Button {
              text: ""
              iconText: "\uf021"
              iconSpinning: seafile.refreshing
              tooltipText: "Refresh"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: seafile.refresh()
            }
          }

          Flow {
            visible: root.viewMode === "libraries" && seafile.installed && seafile.accountLinked
            width: parent.width
            spacing: Style.space(8)

            Button {
              text: ""
              iconText: "\uf067"
              tooltipText: "Add library"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.openAddLibrary()
            }

            Button {
              text: ""
              iconText: "\uf1da"
              tooltipText: "Activity"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.openActivity()
            }

            Button {
              text: ""
              iconText: ""
              tooltipText: seafile.syncErrors.length > 0 ? "Errors (" + seafile.syncErrors.length + ")" : "Errors"
              foreground: seafile.syncErrors.length > 0 ? root.urgent : root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.openSyncErrors()
            }

            Button {
              text: ""
              iconText: ""
              tooltipText: "Settings"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.openSettings()
            }

            Button {
              text: ""
              iconText: "\uf021"
              iconSpinning: seafile.refreshing
              tooltipText: "Refresh"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: seafile.refresh()
            }
          }

          // A full email can run well past the panel width, so it's a
          // Layout.fillWidth Text that elides -- not part of a Button's own
          // label, which has no elide and would just push the row wider
          // than the panel until the far end of the text (and the button
          // border around it) ran off the edge.
          RowLayout {
            visible: root.viewMode === "libraries" && seafile.installed && seafile.accountLinked
            width: parent.width
            spacing: Style.space(8)

            Text {
              Layout.fillWidth: true
              text: "Signed in as " + seafile.accountUser
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            PanelActionButton {
              iconText: "\uf2f5"
              tooltipText: "Log out"
              foreground: root.dim
              fontFamily: root.fontFamily
              onClicked: {
                seafile.logout()
                root.openLogin()
              }
            }
          }

          Row {
            visible: root.viewMode !== "libraries"
            width: parent.width
            spacing: Style.space(8)

            Button {
              text: "‹ Back"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.goToLibraries()
            }
          }

          Text {
            visible: !seafile.installed
            width: parent.width
            text: "seaf-cli was not found on PATH. Install the Seafile CLI client to use this widget."
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: seafile.installed && root.viewMode === "libraries" && seafile.actionStatus !== ""
            width: parent.width
            text: seafile.actionStatus
            color: seafile.lastError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            visible: seafile.installed
            foreground: root.foreground
          }

          // ---- Libraries view ---------------------------------------------
          Column {
            visible: seafile.installed && root.viewMode === "libraries"
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "LIBRARIES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: seafile.daemonRunning && seafile.libraries.length === 0
              width: parent.width
              text: "No synced libraries found."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              visible: !seafile.daemonRunning
              width: parent.width
              text: "Start Seafile to see library status."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: libraryColumn
              visible: seafile.daemonRunning && seafile.libraries.length > 0
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: seafile.libraries
                LibraryRow {
                  required property var modelData
                  required property int index
                  width: libraryColumn.width
                  library: modelData
                  rowIndex: index
                }
              }
            }
          }

          // ---- Login view ------------------------------------------------
          Column {
            visible: root.viewMode === "login"
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              text: "Server URL"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            TextField {
              id: loginServerField
              width: parent.width
              placeholderText: "https://seafile.example.com"
              text: seafile.accountServer
              foreground: root.foreground
              Keys.onReturnPressed: loginUsernameField.forceActiveFocus()
            }

            Text {
              width: parent.width
              text: "Username / email"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            TextField {
              id: loginUsernameField
              width: parent.width
              placeholderText: "you@example.com"
              text: seafile.accountUser
              foreground: root.foreground
              Keys.onReturnPressed: loginPasswordField.forceActiveFocus()
            }

            Text {
              width: parent.width
              text: "Password"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            TextField {
              id: loginPasswordField
              width: parent.width
              password: true
              foreground: root.foreground
              Keys.onReturnPressed: {
                if (seafile.loginNeedsTfa) loginTfaField.forceActiveFocus()
                else loginSubmit.clicked()
              }
            }

            Text {
              visible: seafile.loginNeedsTfa
              width: parent.width
              text: "Two-factor code"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            TextField {
              id: loginTfaField
              visible: seafile.loginNeedsTfa
              width: parent.width
              placeholderText: "6-digit code"
              foreground: root.foreground
              Keys.onReturnPressed: loginSubmit.clicked()
            }

            Text {
              visible: seafile.loginError !== ""
              width: parent.width
              text: seafile.loginError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Row {
              spacing: Style.space(8)

              Button {
                id: loginSubmit
                text: seafile.loginBusy ? "Logging in…" : "Log in"
                iconText: ""
                iconSpinning: seafile.loginBusy
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                onClicked: {
                  if (seafile.loginBusy) return
                  var server = loginServerField.text.trim()
                  var username = loginUsernameField.text.trim()
                  var password = loginPasswordField.text
                  if (server === "" || username === "" || password === "") {
                    seafile.loginError = "Server, username, and password are all required"
                    return
                  }
                  seafile.login(server, username, password, loginTfaField.text.trim())
                  loginPasswordField.text = ""
                }
              }

              Button {
                text: "Cancel"
                foreground: root.dim
                fontFamily: root.fontFamily
                onClicked: root.goToLibraries()
              }
            }
          }

          // ---- Remote browse view -------------------------------------------
          Column {
            visible: root.viewMode === "browse"
            width: parent.width
            spacing: Style.space(10)

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: seafile.remoteRefreshing ? "Refreshing…" : "Refresh"
                iconText: ""
                iconSpinning: seafile.remoteRefreshing
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: seafile.refreshRemote()
              }

              Button {
                text: "New library"
                iconText: ""
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.viewMode = "create"
              }
            }

            Text {
              visible: seafile.remoteError !== ""
              width: parent.width
              text: seafile.remoteError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              visible: !seafile.remoteRefreshing && seafile.remoteError === "" && seafile.remoteLibraries.length === 0
              width: parent.width
              text: "No libraries found on this server."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            // Inline target picker for whichever remote row was clicked.
            Column {
              visible: root.pendingLibrary !== null
              width: parent.width
              spacing: Style.space(8)

              PanelSeparator { foreground: root.foreground }

              Text {
                width: parent.width
                text: (root.pendingMode === "download" ? "Download " : "Link ") + (root.pendingLibrary ? root.pendingLibrary.name : "")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              // No file-picker button: opening one (zenity) is a separate
              // window, and stealing focus to it closes this anchored popup
              // instantly, wiping the whole in-progress form. Tab-completes
              // like a shell instead, so everything stays in this one field.
              TextField {
                id: folderField
                width: parent.width
                placeholderText: root.pendingMode === "download" ? "Folder to create" : "Path to existing folder"
                foreground: root.foreground
                Keys.onTabPressed: function(event) {
                  root.completeFolderPath()
                  event.accepted = true
                }
              }

              Text {
                visible: seafile.pathCompletions.length > 1
                width: parent.width
                text: seafile.pathCompletions.slice(0, 6).map(function(p) { return p.split("/").pop() }).join(", ") + (seafile.pathCompletions.length > 6 ? ", …" : "")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                text: "Tab to autocomplete"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              TextField {
                id: libPasswordField
                width: parent.width
                password: true
                placeholderText: "Library password (only if encrypted)"
                foreground: root.foreground
              }

              Row {
                spacing: Style.space(8)

                Button {
                  text: root.pendingMode === "download" ? "Download" : "Link folder"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  onClicked: root.confirmLibraryAction()
                }

                Button {
                  text: "Cancel"
                  foreground: root.dim
                  fontFamily: root.fontFamily
                  onClicked: root.pendingLibrary = null
                }
              }
            }

            Column {
              visible: root.pendingLibrary === null
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: seafile.remoteLibraries
                RemoteLibraryRow {
                  required property var modelData
                  width: parent.width
                  remoteLib: modelData
                  linked: Model.isLinked(seafile.libraries, modelData.id)
                }
              }
            }
          }

          // ---- Create library view ------------------------------------------
          Column {
            visible: root.viewMode === "create"
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              text: "Library name"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            TextField {
              id: createNameField
              width: parent.width
              placeholderText: "My new library"
              foreground: root.foreground
            }

            Text {
              width: parent.width
              text: "Description"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            TextField {
              id: createDescField
              width: parent.width
              placeholderText: "Optional"
              foreground: root.foreground
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              ToggleSwitch {
                id: createEncryptToggle
                anchors.verticalCenter: parent.verticalCenter
                foreground: root.foreground
                onToggled: checked = !checked
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Encrypt this library"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            TextField {
              id: createPasswordField
              visible: createEncryptToggle.checked
              width: parent.width
              password: true
              placeholderText: "Library password"
              foreground: root.foreground
            }

            Text {
              visible: seafile.lastError !== "" && root.viewMode === "create"
              width: parent.width
              text: seafile.lastError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              text: "Create"
              iconText: ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: {
                var name = createNameField.text.trim()
                if (name === "") return
                seafile.createLibrary(name, createDescField.text.trim(), createEncryptToggle.checked ? createPasswordField.text : "")
                createNameField.text = ""
                createDescField.text = ""
                createPasswordField.text = ""
                createEncryptToggle.checked = false
                root.viewMode = "browse"
              }
            }
          }

          // ---- Activity view -------------------------------------------------
          Column {
            visible: root.viewMode === "activity"
            width: parent.width
            spacing: Style.space(10)

            Button {
              text: seafile.activityRefreshing ? "Refreshing…" : "Refresh"
              iconText: ""
              iconSpinning: seafile.activityRefreshing
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: seafile.refreshActivity()
            }

            Text {
              visible: seafile.activityError !== ""
              width: parent.width
              text: seafile.activityError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              visible: !seafile.activityRefreshing && seafile.activityError === "" && seafile.activityEntries.length === 0
              width: parent.width
              text: "No recent activity found."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              width: parent.width
              spacing: Style.space(10)

              Repeater {
                model: seafile.activityEntries
                ActivityRow {
                  required property var modelData
                  width: parent.width
                  entry: modelData
                }
              }
            }
          }

          // ---- Sync errors view ----------------------------------------------
          Column {
            visible: root.viewMode === "errors"
            width: parent.width
            spacing: Style.space(10)

            Button {
              text: seafile.syncErrorsRefreshing ? "Refreshing…" : "Refresh"
              iconText: ""
              iconSpinning: seafile.syncErrorsRefreshing
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: seafile.refreshSyncErrors()
            }

            Text {
              visible: seafile.syncErrorsError !== ""
              width: parent.width
              text: seafile.syncErrorsError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              visible: !seafile.syncErrorsRefreshing && seafile.syncErrorsError === "" && seafile.syncErrors.length === 0
              width: parent.width
              text: "No sync errors."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              width: parent.width
              spacing: Style.space(10)

              Repeater {
                model: seafile.syncErrors
                SyncErrorRow {
                  required property var modelData
                  width: parent.width
                  entry: modelData
                }
              }
            }
          }

          // ---- Settings view ---------------------------------------------
          Column {
            visible: root.viewMode === "settings"
            width: parent.width
            spacing: Style.space(14)

            Text {
              visible: !seafile.settingsLoaded
              width: parent.width
              text: seafile.settingsBusy ? "Loading settings…" : "Could not load settings."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              visible: seafile.settingsLoaded
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "DEVICE"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                width: parent.width
                text: "Name shown in this server's linked-devices list"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              TextField {
                id: clientNameField
                width: parent.width
                text: seafile.clientName
                foreground: root.foreground
              }
            }

            Column {
              visible: seafile.settingsLoaded
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "BANDWIDTH"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                width: parent.width
                text: "Upload limit, KB/s (0 = unlimited)"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              TextField {
                id: uploadLimitField
                width: parent.width
                text: String(seafile.uploadLimitKBps)
                foreground: root.foreground
              }

              Text {
                width: parent.width
                text: "Download limit, KB/s (0 = unlimited)"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              TextField {
                id: downloadLimitField
                width: parent.width
                text: String(seafile.downloadLimitKBps)
                foreground: root.foreground
              }
            }

            Column {
              visible: seafile.settingsLoaded
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "SYNC BEHAVIOR"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                ToggleSwitch {
                  id: ignoreSymlinksToggle
                  anchors.verticalCenter: parent.verticalCenter
                  checked: seafile.ignoreSymlinks
                  foreground: root.foreground
                  onToggled: checked = !checked
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Ignore symlinks"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }

              Text {
                width: parent.width
                text: "Confirm before deleting more than this many files in one sync"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              TextField {
                id: deleteConfirmField
                width: parent.width
                text: String(seafile.deleteConfirmThreshold)
                foreground: root.foreground
              }
            }

            Column {
              visible: seafile.settingsLoaded
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "PROXY"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                ToggleSwitch {
                  id: useProxyToggle
                  anchors.verticalCenter: parent.verticalCenter
                  checked: seafile.useProxy
                  foreground: root.foreground
                  onToggled: checked = !checked
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Use proxy"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }

              Row {
                visible: useProxyToggle.checked
                spacing: Style.space(8)

                Button {
                  text: "None"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: proxyTypeState.value !== "http" && proxyTypeState.value !== "socks"
                  onClicked: proxyTypeState.value = "none"
                }

                Button {
                  text: "HTTP"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: proxyTypeState.value === "http"
                  onClicked: proxyTypeState.value = "http"
                }

                Button {
                  text: "SOCKS"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: proxyTypeState.value === "socks"
                  onClicked: proxyTypeState.value = "socks"
                }
              }

              Item {
                id: proxyTypeState
                property string value: seafile.proxyType
                visible: false
              }

              TextField {
                id: proxyAddrField
                visible: useProxyToggle.checked
                width: parent.width
                placeholderText: "Proxy address"
                text: seafile.proxyAddr
                foreground: root.foreground
              }

              TextField {
                id: proxyPortField
                visible: useProxyToggle.checked
                width: parent.width
                placeholderText: "Proxy port"
                text: seafile.proxyPort
                foreground: root.foreground
              }

              TextField {
                id: proxyUsernameField
                visible: useProxyToggle.checked
                width: parent.width
                placeholderText: "Proxy username (optional)"
                text: seafile.proxyUsername
                foreground: root.foreground
              }

              TextField {
                id: proxyPasswordField
                visible: useProxyToggle.checked
                width: parent.width
                password: true
                placeholderText: "Proxy password (optional)"
                text: seafile.proxyPassword
                foreground: root.foreground
              }
            }

            Text {
              visible: seafile.settingsError !== ""
              width: parent.width
              text: seafile.settingsError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              visible: seafile.settingsLoaded
              text: seafile.settingsBusy ? "Saving…" : "Save"
              iconText: ""
              iconSpinning: seafile.settingsBusy
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: {
                seafile.uploadLimitKBps = parseInt(uploadLimitField.text, 10) || 0
                seafile.downloadLimitKBps = parseInt(downloadLimitField.text, 10) || 0
                seafile.ignoreSymlinks = ignoreSymlinksToggle.checked
                seafile.deleteConfirmThreshold = parseInt(deleteConfirmField.text, 10) || 500
                seafile.useProxy = useProxyToggle.checked
                seafile.proxyType = proxyTypeState.value
                seafile.proxyAddr = proxyAddrField.text
                seafile.proxyPort = proxyPortField.text
                seafile.proxyUsername = proxyUsernameField.text
                seafile.proxyPassword = proxyPasswordField.text
                seafile.clientName = clientNameField.text
                seafile.saveSettings()
              }
            }
          }
        }
      }
    }
  }

  component LibraryRow: CursorSurface {
    id: libraryRow
    property var library: null
    property int rowIndex: 0
    readonly property string libraryName: library ? String(library.name || "Untitled") : "Untitled"
    readonly property var meta: Model.stateMeta(library ? library.state : "")

    hasCursor: root.cursorActive && root.focusSection === "libraries" && root.libraryIndex === rowIndex
    foreground: root.foreground

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setLibraryCursor(libraryRow.rowIndex)
      onClicked: seafile.openLibrary(libraryRow.library)
    }

    RowLayout {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: libraryRow.meta.glyph
        color: libraryRow.meta.tone === "error" ? root.urgent : (libraryRow.meta.tone === "busy" ? Color.accent : root.foreground)
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: libraryRow.libraryName
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: libraryRow.meta.label
            + (libraryRow.library && libraryRow.library.path ? " \u00b7 " + libraryRow.library.path : "")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }

      Text {
        readonly property var sizeGB: libraryRow.library ? seafile.librarySizes[libraryRow.library.id] : undefined
        visible: sizeGB !== undefined
        text: sizeGB + " GB"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }

      PanelActionButton {
        visible: libraryRow.library && seafile.librarySizes[libraryRow.library.id] === undefined
        enabled: !(libraryRow.library && seafile.librarySizeBusy[libraryRow.library.id] === true)
        iconText: "\uf021"
        tooltipText: "Calculate size"
        foreground: root.dim
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: seafile.refreshLibrarySize(libraryRow.library.id, libraryRow.library.path)
      }

      PanelActionButton {
        visible: libraryRow.library && seafile.accountLinked
        iconText: "\uf14c"
        tooltipText: "Open in Seahub"
        foreground: root.dim
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.openInSeahub(libraryRow.library.id, libraryRow.library.name)
      }

      PanelActionButton {
        iconText: "\uf127"
        tooltipText: "Desync (keeps local files)"
        foreground: root.dim
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: seafile.desyncLibrary(libraryRow.library)
      }
    }
  }

  component RemoteLibraryRow: Item {
    id: remoteRow
    property var remoteLib: null
    property bool linked: false
    readonly property string remoteName: remoteLib ? String(remoteLib.name || "Untitled") : "Untitled"
    readonly property bool encrypted: remoteLib ? remoteLib.encrypted === true : false

    implicitHeight: remoteRowContent.implicitHeight + Style.space(8)

    RowLayout {
      id: remoteRowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        visible: remoteRow.encrypted
        text: ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: remoteRow.remoteName
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: remoteLib ? Model.formatBytes(remoteLib.size) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        visible: remoteRow.linked
        text: "Synced"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      PanelActionButton {
        iconText: "\uf14c"
        tooltipText: "Open in Seahub"
        foreground: root.dim
        fontFamily: root.fontFamily
        onClicked: root.openInSeahub(remoteRow.remoteLib.id, remoteRow.remoteLib.name)
      }

      PanelActionButton {
        visible: !remoteRow.linked
        iconText: ""
        tooltipText: "Download to a new folder"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.startLibraryAction(remoteRow.remoteLib, "download")
      }

      PanelActionButton {
        visible: !remoteRow.linked
        iconText: ""
        tooltipText: "Link an existing local folder"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.startLibraryAction(remoteRow.remoteLib, "sync")
      }
    }
  }

  component ActivityRow: RowLayout {
    id: activityRow
    property var entry: null
    readonly property string libraryLabel: entry ? Model.libraryName(seafile.libraries, entry.repo_id) : ""

    spacing: Style.space(8)

    Text {
      text: ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
      Layout.alignment: Qt.AlignTop
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(1)

      Text {
        Layout.fillWidth: true
        text: activityRow.entry ? activityRow.entry.desc : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
      }

      Text {
        Layout.fillWidth: true
        text: activityRow.libraryLabel + " · " + (activityRow.entry ? Model.relativeTime(activityRow.entry.ctime) : "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  component SyncErrorRow: RowLayout {
    id: syncErrorRow
    property var entry: null

    spacing: Style.space(8)

    Text {
      text: ""
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
      Layout.alignment: Qt.AlignTop
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(1)

      Text {
        Layout.fillWidth: true
        text: syncErrorRow.entry ? syncErrorRow.entry.path : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideMiddle
      }

      Text {
        Layout.fillWidth: true
        text: syncErrorRow.entry ? (syncErrorRow.entry.message + " · " + syncErrorRow.entry.repo_name + " · " + Model.relativeTime(syncErrorRow.entry.timestamp)) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    PanelActionButton {
      iconText: ""
      tooltipText: "Dismiss"
      foreground: root.dim
      fontFamily: root.fontFamily
      Layout.alignment: Qt.AlignVCenter
      onClicked: seafile.clearSyncError(syncErrorRow.entry.id)
    }
  }
}
