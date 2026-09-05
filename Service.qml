import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Wraps seaf-cli for everything the Seafile desktop client (seafile-applet)
// offers: local library status + daemon control, browsing remote libraries,
// and downloading / syncing-an-existing-folder / creating libraries. Library
// history, sharing, and permissions are Seahub web-UI features, not
// desktop-client ones -- out of scope here same as upstream.
//
// Account: works standalone -- log in from this widget's own panel and it
// never needs seafile-applet (the GUI client) installed at all. The one-time
// login writes server/user/token into a private 0600 ini file, the format
// seaf-cli itself reads via `-C <file>` (see get_value_from_user_config in
// seaf-cli) for every remote call, so no password or token is ever passed on
// a later command line. As a convenience during a transition off the GUI
// client, each refresh also opportunistically imports whatever account
// seafile-applet is currently logged into from its own `accounts.db` sqlite
// file -- but only ever to *add* an account, never to clear the one this
// widget logged in with itself.
Item {
  id: root

  property var settings: ({})
  // Deliberately NOT under ~/.config/omarchy/plugins/ -- the shell hot-reloads
  // a plugin on any change under its own directory, and this file gets
  // rewritten on every refresh. Keeping it there caused an infinite
  // reload loop (write -> hot-reload -> Component.onCompleted -> write...).
  readonly property string accountFile: Quickshell.env("HOME") + "/.local/state/omarchy-seafile/account.ini"
  readonly property string ccnetConfig: Quickshell.env("HOME") + "/.ccnet/seafile.ini"

  property bool installed: true
  property bool daemonRunning: false
  property var libraries: []
  property bool refreshing: false
  property string actionStatus: ""
  property string lastError: ""

  property bool accountLinked: false
  property string accountServer: ""
  property string accountUser: ""
  property bool loginBusy: false
  property string loginError: ""
  property bool loginNeedsTfa: false

  property var remoteLibraries: []
  property bool remoteRefreshing: false
  property string remoteError: ""

  property var activityEntries: []
  property bool activityRefreshing: false
  property string activityError: ""

  // -1 means "not loaded yet"; accountQuotaBytes <= 0 (once loaded) means
  // the server has no quota configured, i.e. unlimited.
  property real accountUsageBytes: -1
  property real accountQuotaBytes: -1

  property var pathCompletions: []

  readonly property bool muteNotifications: setting("muteNotifications", false) === true

  // ---- Local daemon settings (bandwidth, proxy, sync behavior) --------
  // All backed directly by the same `seafile` RPC client used for local
  // sync registration elsewhere in this file -- no seaf-cli subcommand
  // covers any of this, but the RPC methods it's itself built on
  // (seafile_set_upload_rate_limit, seafile_get_config, ...) are right
  // there in the same python module.
  property bool settingsLoaded: false
  property bool settingsBusy: false
  property string settingsError: ""
  property int uploadLimitKBps: 0
  property int downloadLimitKBps: 0
  property bool ignoreSymlinks: false
  property int deleteConfirmThreshold: 1000000
  property bool useProxy: false
  property string proxyType: "http"
  property string proxyAddr: ""
  property string proxyPort: ""
  property string proxyUsername: ""
  // The daemon's stored proxy password is never read back into this process
  // -- only whether one is set. proxyPasswordInput is a transient, write-only
  // field: it starts empty on every settings load and is only sent on save
  // if the user actually typed something into it.
  property bool proxyPasswordConfigured: false
  property string proxyPasswordInput: ""
  property string clientName: ""

  property var syncErrors: []
  property bool syncErrorsRefreshing: false
  property string syncErrorsError: ""

  property var trashItems: []
  property bool trashRefreshing: false
  property string trashError: ""
  property string trashBusyPath: ""

  // Server-side search across all libraries (Seahub's /api2/search/). Only
  // works when the server is running Seafile Professional with a search
  // backend configured -- a Community Edition server always 403s this
  // endpoint, surfaced here as a normal searchError rather than a crash.
  property var searchResults: []
  property bool searchBusy: false
  property string searchError: ""

  property var librarySizes: ({})
  property var librarySizeBusy: ({})

  // repo id -> {rate: KB/s, percent: 0-100}, either field may be absent
  // (e.g. percent has nothing to divide by until block_total is known).
  // Polled only while at least one library is actively busy (see
  // transferRateTimer below) -- empty again the moment nothing is
  // transferring, so a stale value never lingers next to a settled library.
  property var transferRates: ({})

  // Optimistic desired daemon state, so the toggle switch throws the instant
  // you click it instead of waiting for seaf-daemon to actually settle.
  // -1 means "just follow the real state"; 0/1 means a stop/start is still
  // catching up.
  property int _desired: -1
  readonly property bool active: _desired === -1 ? daemonRunning : (_desired === 1)
  readonly property bool busy: refreshProcess.running || controlProcess.running

  // Auto-start seaf-daemon once per plugin load (i.e. once per session,
  // since the bar loads this plugin at Hyprland startup) so syncing resumes
  // on login the same way the real seafile-applet auto-connects, without
  // requiring a manual toggle click every time. Only fires once installed +
  // account state are both known and an account is actually linked -- an
  // unconfigured widget has nothing to sync and should stay quiet.
  property bool _autoStartAttempted: false
  function maybeAutoStart() {
    if (_autoStartAttempted) return
    if (!installed || daemonRunning || !accountLinked) return
    if (controlProcess.running) return
    _autoStartAttempted = true
    start()
  }

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 10, 3600)

  property string _refreshOutput: ""
  property string _controlOutput: ""
  property string _controlError: ""
  property string _accountOutput: ""
  property string _loginOutput: ""
  property string _remoteOutput: ""
  property string _remoteError: ""
  property string _localOutput: ""
  property string _libraryActionOutput: ""
  property string _libraryActionError: ""

  // Shared by every script below that writes the account file. Writing it
  // safely means never trusting the path to resolve where we expect: each
  // path component is opened with O_NOFOLLOW relative to the last (so a
  // symlink swapped in anywhere along ~/.local/state/omarchy-seafile/ is
  // refused rather than followed), an existing target that isn't a plain
  // file is rejected outright, and the new content lands via a 0600
  // O_EXCL temp file in that same held directory, fsync'd and then renamed
  // into place with renameat against the held directory fd -- so a reader
  // never observes a partially-written file and a concurrent attacker can't
  // race the rename with a symlink of their own.
  readonly property string _pySecureIo: [
    "import os, stat",
    "",
    "def _write_account_atomic(account_path, fields):",
    "  from configparser import ConfigParser",
    "  parts = [p for p in os.path.dirname(account_path).split('/') if p]",
    "  dir_fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)",
    "  try:",
    "    for part in parts:",
    "      try:",
    "        next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd)",
    "      except FileNotFoundError:",
    "        os.mkdir(part, 0o700, dir_fd=dir_fd)",
    "        next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd)",
    "      os.close(dir_fd)",
    "      dir_fd = next_fd",
    "    name = os.path.basename(account_path)",
    "    try:",
    "      st = os.lstat(name, dir_fd=dir_fd)",
    "      if not stat.S_ISREG(st.st_mode):",
    "        raise OSError('refusing to write over a non-regular path: %s' % account_path)",
    "    except FileNotFoundError:",
    "      pass",
    "    tmp_name = '.%s.tmp-%d' % (name, os.getpid())",
    "    try:",
    "      os.unlink(tmp_name, dir_fd=dir_fd)",
    "    except FileNotFoundError:",
    "      pass",
    "    tmp_fd = os.open(tmp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dir_fd)",
    "    try:",
    "      with os.fdopen(tmp_fd, 'w') as f:",
    "        cfg = ConfigParser()",
    "        cfg['account'] = fields",
    "        cfg.write(f)",
    "        f.flush()",
    "        os.fsync(f.fileno())",
    "      os.rename(tmp_name, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)",
    "    except Exception:",
    "      try:",
    "        os.unlink(tmp_name, dir_fd=dir_fd)",
    "      except OSError:",
    "        pass",
    "      raise",
    "  finally:",
    "    os.close(dir_fd)"
  ].join("\n")

  // Shared by every script below that talks to the user's Seafile server.
  // Enforces https (an http exception only for localhost, for local test
  // servers), rejects credentials embedded in the URL, and replaces
  // urllib's automatic redirect-following with a same-origin check on every
  // hop up to a small cap -- so a compromised or misconfigured server can't
  // silently redirect an authenticated request off to an attacker-controlled
  // host. _read_capped bounds how much of a response is ever pulled into
  // memory before it's parsed as JSON.
  readonly property string _pyHttp: [
    "import time, urllib.request, urllib.parse, urllib.error",
    "from urllib.parse import urlparse, urljoin",
    "",
    "def _validate_server_url(url):",
    "  p = urlparse(url)",
    "  if p.username or p.password:",
    "    raise ValueError('Server URL must not contain embedded credentials')",
    "  host = (p.hostname or '').lower()",
    "  if not host:",
    "    raise ValueError('Server URL is missing a host')",
    "  loopback = host in ('localhost', '127.0.0.1', '::1')",
    "  if p.scheme != 'https' and not (p.scheme == 'http' and loopback):",
    "    raise ValueError('Server must use https:// (http:// is only allowed to localhost)')",
    "  return p",
    "",
    "class _NoRedirect(urllib.request.HTTPRedirectHandler):",
    "  def redirect_request(self, req, fp, code, msg, headers, newurl):",
    "    return None",
    "",
    "_opener = urllib.request.build_opener(_NoRedirect)",
    "",
    "def _read_capped(resp, max_bytes):",
    "  data = resp.read(max_bytes + 1)",
    "  if len(data) > max_bytes:",
    "    raise ValueError('Response exceeded the %d byte limit' % max_bytes)",
    "  return data",
    "",
    "def _safe_open(req, timeout=10, max_redirects=2):",
    "  deadline = time.monotonic() + timeout * (max_redirects + 1)",
    "  url = req.full_url",
    "  origin = _validate_server_url(url)",
    "  for _ in range(max_redirects + 1):",
    "    if time.monotonic() > deadline:",
    "      raise TimeoutError('Request exceeded its overall deadline')",
    "    try:",
    "      return _opener.open(req, timeout=timeout)",
    "    except urllib.error.HTTPError as e:",
    "      if e.code not in (301, 302, 303, 307, 308):",
    "        raise",
    "      location = e.headers.get('Location')",
    "      if not location:",
    "        raise ValueError('Redirect with no Location header')",
    "      newurl = urljoin(url, location)",
    "      newp = _validate_server_url(newurl)",
    "      if (newp.scheme, newp.hostname, newp.port) != (origin.scheme, origin.hostname, origin.port):",
    "        raise ValueError('Refusing a cross-origin redirect to %s' % newurl)",
    "      method = 'GET' if e.code == 303 else req.get_method()",
    "      data = None if e.code == 303 else req.data",
    "      url = newurl",
    "      req = urllib.request.Request(url, data=data, headers=dict(req.header_items()), method=method)",
    "  raise ValueError('Too many redirects')",
    "",
    "def _cap_str(value, limit=500):",
    "  s = str(value or '')",
    "  return s if len(s) <= limit else s[:limit] + '\\u2026'"
  ].join("\n")

  // Step 1 of syncAccount(): if seafile-applet (the GUI client) is currently
  // logged in, opportunistically copy its account from its own sqlite db
  // into our ini -- but only ever to *add* one, never to clear an account
  // this widget logged into on its own. Never reports the token back to QML.
  readonly property string _importAccountScript: _pySecureIo + "\n" + [
    "import sys, os, sqlite3, configparser",
    "ccnet_config, account_path = sys.argv[1], sys.argv[2]",
    "existing = configparser.ConfigParser()",
    "if existing.read(account_path) and existing.has_section('account') and existing.get('account', 'token', fallback=''):",
    "  sys.exit(0)",
    "datadir = ''",
    "try:",
    "  with open(ccnet_config, 'r') as f:",
    "    datadir = f.readline().strip()",
    "except OSError:",
    "  pass",
    "db_path = os.path.join(datadir, 'accounts.db') if datadir else ''",
    "if db_path and os.path.exists(db_path):",
    "  try:",
    "    conn = sqlite3.connect(db_path)",
    "    row = conn.execute('SELECT url, username, token FROM Accounts ORDER BY lastVisited DESC LIMIT 1').fetchone()",
    "    conn.close()",
    "  except sqlite3.Error:",
    "    row = None",
    "  if row and row[2]:",
    "    url, username, token = row",
    "    _write_account_atomic(account_path, {'server': url, 'user': username, 'token': token})"
  ].join("\n")

  // Step 2 of syncAccount(): report whatever ended up in our own account
  // file -- freshly imported above, from this widget's own login, or
  // neither. This is the single source of truth accountLinked reflects.
  readonly property string _readAccountScript: [
    "import sys, json",
    "from configparser import ConfigParser",
    "path = sys.argv[1]",
    "cfg = ConfigParser()",
    "try:",
    "  if cfg.read(path) and cfg.has_section('account') and cfg.get('account', 'token', fallback=''):",
    "    print(json.dumps({'found': True, 'server': cfg.get('account', 'server', fallback=''), 'user': cfg.get('account', 'user', fallback='')}))",
    "  else:",
    "    print(json.dumps({'found': False, 'server': '', 'user': ''}))",
    "except Exception:",
    "  print(json.dumps({'found': False, 'server': '', 'user': ''}))"
  ].join("\n")

  // This widget's own login, independent of seafile-applet: POSTs to the
  // server's auth-token API itself (mirroring seaf-cli's get_token(), 2FA
  // included) and writes the result straight into our account ini. The
  // password travels over this process's stdin, never argv.
  readonly property string _loginScript: _pyHttp + "\n" + _pySecureIo + "\n" + [
    "import sys, json, secrets",
    "server = sys.argv[1].rstrip('/')",
    "username = sys.argv[2]",
    "tfa = sys.argv[3] if len(sys.argv) > 3 else ''",
    "account_path = sys.argv[4]",
    "password = sys.stdin.readline().rstrip(chr(10))",
    "try:",
    "  _validate_server_url(server)",
    "except ValueError as e:",
    "  print(json.dumps({'ok': False, 'error': str(e), 'needsTfa': False}))",
    "  sys.exit(0)",
    "data = {",
    "  'username': username, 'password': password, 'platform': 'linux',",
    "  'device_id': secrets.token_hex(20), 'device_name': 'omarchy-seafile-plugin',",
    "  'client_version': '1.0.0', 'platform_version': '',",
    "}",
    "headers = {'User-Agent': 'Seafile Desktop Client (Omarchy plugin)'}",
    "if tfa: headers['X-SEAFILE-OTP'] = tfa",
    "req = urllib.request.Request(server + '/api2/auth-token/', data=urllib.parse.urlencode(data).encode('utf-8'), headers=headers)",
    "try:",
    "  with _safe_open(req, timeout=10) as resp:",
    "    body = _read_capped(resp, 65536).decode('utf-8', 'replace')",
    "  token = json.loads(body).get('token', '')",
    "  if not token:",
    "    print(json.dumps({'ok': False, 'error': 'Server did not return a token', 'needsTfa': False}))",
    "  else:",
    "    _write_account_atomic(account_path, {'server': server, 'user': username, 'token': token})",
    "    print(json.dumps({'ok': True}))",
    "except urllib.error.HTTPError as e:",
    "  body = _read_capped(e, 65536).decode('utf-8', 'replace')",
    "  lowered = body.lower()",
    "  needs_tfa = (not tfa) and any(s in lowered for s in ('two-factor', 'two factor', 'otp', 'verification code'))",
    "  message = body",
    "  try:",
    "    parsed = json.loads(body)",
    "    parts = []",
    "    for value in parsed.values():",
    "      parts.extend(str(v) for v in value) if isinstance(value, list) else parts.append(str(value))",
    "    if parts: message = ' '.join(parts)",
    "  except Exception: pass",
    "  print(json.dumps({'ok': False, 'error': (message.strip() or ('HTTP %d' % e.code))[:500], 'needsTfa': needs_tfa}))",
    "except Exception as e:",
    "  print(json.dumps({'ok': False, 'error': str(e)[:500], 'needsTfa': False}))"
  ].join("\n")

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  // ---- Local library status + daemon control ------------------------------

  function refresh() {
    if (refreshProcess.running) return
    _refreshOutput = ""
    refreshing = true
    refreshProcess.running = true
    syncAccount()
  }

  function applyRefresh(raw, exitCode) {
    refreshing = false
    if (exitCode === 3) {
      installed = false
      daemonRunning = false
      libraries = []
      return
    }
    installed = true
    var parsed = Model.parseRefresh(raw)
    // `seaf-cli status` only answers once seaf-daemon is reachable over its
    // local socket, so a clean exit with parseable output is our proof the
    // daemon is actually up -- there is no separate "is it running" call.
    daemonRunning = exitCode === 0
    if (_desired !== -1 && daemonRunning === (_desired === 1)) _desired = -1
    var merged = Model.mergeLibraries(parsed.list, parsed.status)
    notifyLibraryTransitions(merged)
    libraries = merged
    maybeAutoStart()
    if (daemonRunning) refreshSyncErrors()

    var hasBusy = false
    for (var i = 0; i < merged.length; i++) {
      if (Model.stateMeta(merged[i].state).tone === "busy") { hasBusy = true; break }
    }
    if (hasBusy) {
      transferRateTimer.restart()
    } else {
      transferRateTimer.stop()
      if (Object.keys(transferRates).length > 0) transferRates = {}
    }
  }

  // Desktop notification via notify-send -- picked up by the shell's own
  // NotificationServer (Quickshell.Services.Notifications), the same path
  // any freedesktop-notification-spec call goes through, so it renders
  // exactly like every other app's notification rather than needing its
  // own bespoke toast UI in this plugin.
  readonly property string logoPath: String(Qt.resolvedUrl("icons/seafile.png")).replace("file://", "")

  function notify(summary, body, urgency) {
    if (muteNotifications) return
    var args = ["notify-send", "-a", "Seafile", "-u", urgency || "normal", "-i", logoPath]
    args.push(summary)
    if (body) args.push(body)
    Quickshell.execDetached(args)
  }

  // Fires a notification the moment a library finishes syncing (busy -> ok)
  // or starts erroring (-> error), same as the desktop client's own
  // per-library toasts. Keyed off the previous refresh's tones rather than
  // one-shot state so it only fires on the transition, not every poll while
  // already settled -- and nothing fires on the very first refresh after the
  // plugin loads, since there is no prior tone yet to compare against.
  //
  // Error notifications additionally require the error tone to survive two
  // consecutive polls before firing. Waking the machine from sleep is the
  // common case this guards against: seaf-daemon hasn't reconnected yet on
  // the very first poll after resume, so a library can read "error" for
  // exactly one cycle before recovering on its own a refresh later -- that
  // one-cycle blip should never have reached the user as a critical toast.
  property var _lastLibraryTones: ({})
  property var _errorStreak: ({})
  function notifyLibraryTransitions(newLibraries) {
    var nextTones = {}
    var nextStreak = {}
    for (var i = 0; i < newLibraries.length; i++) {
      var lib = newLibraries[i]
      var meta = Model.stateMeta(lib.state)
      nextTones[lib.id] = meta.tone
      var prevTone = _lastLibraryTones[lib.id]

      if (meta.tone === "error") {
        var streak = (_errorStreak[lib.id] || 0) + 1
        nextStreak[lib.id] = streak
        if (streak === 2) notify(lib.name + " sync error", meta.label, "critical")
        continue
      }
      if (prevTone === "busy" && meta.tone === "ok") {
        notify(lib.name + " is synchronized", "", "normal")
      }
    }
    _lastLibraryTones = nextTones
    _errorStreak = nextStreak
  }

  function start() { runControl(["seaf-cli", "start"], 1) }
  function stop() { runControl(["seaf-cli", "stop"], 0) }
  function toggleDaemon() { if (active) stop(); else start() }

  function runControl(command, desired) {
    if (!installed || controlProcess.running) return
    _desired = desired
    _controlOutput = ""
    _controlError = ""
    controlProcess.command = command
    controlProcess.running = true
  }

  function openLibrary(library) {
    if (!library || !library.path) return
    Quickshell.execDetached(["uwsm-app", "--", "nautilus", library.path])
  }

  // Unlinks a local library from syncing. seaf-cli desync never deletes the
  // local files -- it only removes the sync registration -- so this needs no
  // confirmation dialog the way a destructive delete would.
  function desyncLibrary(library) {
    if (!library || !library.path || libraryActionProcess.running) return
    actionStatus = "Desyncing " + library.name + "…"
    _libraryActionOutput = ""
    _libraryActionError = ""
    libraryActionProcess.command = ["seaf-cli", "desync", "--folder", library.path]
    libraryActionProcess._pendingName = library.name
    libraryActionProcess.running = true
  }

  // ---- Account -------------------------------------------------------------

  // Opportunistically import from seafile-applet, then report whatever our
  // own account file ends up holding. Cheap (one sqlite SELECT plus a config
  // read) to run on every regular refresh, so logging in/out of either this
  // widget or the real Seafile app is picked up without a manual step.
  function syncAccount() {
    if (importAccountProcess.running) return
    importAccountProcess.running = true
  }

  function readAccount() {
    if (accountProcess.running) return
    _accountOutput = ""
    accountProcess.command = ["python3", "-c", _readAccountScript, accountFile]
    accountProcess.running = true
  }

  function applyAccount(raw) {
    var parsed = { found: false, server: "", user: "" }
    try {
      var value = JSON.parse(String(raw || "").trim())
      if (value && typeof value === "object") parsed = value
    } catch (e) { /* keep defaults */ }
    accountServer = String(parsed.server || "")
    accountUser = String(parsed.user || "")
    var wasLinked = accountLinked
    accountLinked = parsed.found === true
    if (wasLinked && !accountLinked) {
      accountUsageBytes = -1
      accountQuotaBytes = -1
    }
    maybeAutoStart()
  }

  function login(server, username, password, tfa) {
    if (loginProcess.running) return
    loginError = ""
    loginBusy = true
    _loginOutput = ""
    loginProcess.command = ["python3", "-c", _loginScript, server, username, tfa || "", accountFile]
    loginProcess._pendingPassword = password
    loginProcess.running = true
  }

  function applyLoginResult(raw) {
    loginBusy = false
    var parsed = null
    try { parsed = JSON.parse(String(raw || "").trim()) } catch (e) { /* fall through */ }
    if (!parsed) {
      loginError = "Unexpected response from the login helper"
      return
    }
    if (parsed.ok) {
      loginNeedsTfa = false
      loginError = ""
      readAccount()
      return
    }
    loginNeedsTfa = parsed.needsTfa === true
    loginError = String(parsed.error || "Login failed")
  }

  function logout() {
    if (logoutProcess.running) return
    logoutProcess.running = true
  }

  function openSeafileApp() {
    Quickshell.execDetached(["uwsm-app", "--", "seafile-applet"])
  }

  // ---- Remote libraries ------------------------------------------------
  //
  // seaf-cli's own list-remote/download/sync/create all call Python's
  // urllib with no User-Agent override -- and this server's front end (like
  // many, hardened against bots) 403s the resulting default "Python-urllib"
  // UA outright, confirmed directly against this account's token: curl and
  // a UA-spoofed urllib request both succeed with the exact same token where
  // plain urllib.request.urlopen() gets HTTP 403. So these four operations
  // are reimplemented here rather than shelled out to seaf-cli: the HTTP part
  // (talking to Seahub's API) is done with a spoofed User-Agent, and the
  // actual sync registration is done via the same local `seafile` RPC socket
  // module seaf-cli itself imports (already installed as a seaf-cli
  // dependency) -- no seaf-daemon-side behavior differs from what seaf-cli
  // would have done, only the HTTP client. desync/list/status/start/stop
  // stay on plain seaf-cli since those never touch the network.
  readonly property string _remoteScript: _pyHttp + "\n" + [
    "import sys, os, json, configparser",
    "from datetime import datetime",
    "UA = 'Seafile Desktop Client (Omarchy plugin)'",
    "MAX_BYTES = 4 * 1024 * 1024",
    "",
    "def read_account(path):",
    "  cfg = configparser.ConfigParser()",
    "  cfg.read(path)",
    "  return (cfg.get('account', 'server', fallback=''), cfg.get('account', 'token', fallback=''))",
    "",
    "def api_get(url, token):",
    "  _validate_server_url(url)",
    "  req = urllib.request.Request(url, headers={'Authorization': 'Token %s' % token, 'User-Agent': UA})",
    "  with _safe_open(req, timeout=10) as resp:",
    "    return json.loads(_read_capped(resp, MAX_BYTES).decode('utf-8'))",
    "",
    "def api_post(url, token, data):",
    "  _validate_server_url(url)",
    "  body = urllib.parse.urlencode(data).encode('utf-8')",
    "  req = urllib.request.Request(url, data=body, headers={'Authorization': 'Token %s' % token, 'User-Agent': UA})",
    "  with _safe_open(req, timeout=10) as resp:",
    "    return json.loads(_read_capped(resp, MAX_BYTES).decode('utf-8'))",
    "",
    "def base_url(url):",
    "  from urllib.parse import urlparse",
    "  p = urlparse(url)",
    "  return '%s://%s' % (p.scheme, p.netloc) if p.scheme and p.netloc else None",
    "",
    "def rpc_client():",
    "  import seafile",
    "  datadir = ''",
    "  try:",
    "    with open(os.path.join(os.environ.get('HOME', ''), '.ccnet', 'seafile.ini')) as f:",
    "      datadir = f.readline().strip()",
    "  except OSError:",
    "    pass",
    "  return seafile.RpcClient(os.path.join(datadir, 'seafile.sock'))",
    "",
    "def action_list(server, token):",
    "  repos = api_get(server + '/api2/repos/', token)",
    "  seen, out = {}, []",
    "  for r in repos[:1000]:",
    "    if r['id'] in seen: continue",
    "    seen[r['id']] = True",
    "    out.append({'id': r['id'], 'name': _cap_str(r.get('name', '')), 'owner': _cap_str(r.get('owner', '')), 'size': r.get('size', 0), 'encrypted': bool(r.get('encrypted')), 'permission': _cap_str(r.get('permission', ''), 20)})",
    "  print(json.dumps({'ok': True, 'repos': out}))",
    "",
    "def action_clone(mode, server, token, repo_id, target, libpasswd):",
    "  info = api_get('%s/api2/repos/%s/download-info/' % (server, repo_id), token)",
    "  encrypted = bool(info.get('encrypted'))",
    "  if encrypted and not libpasswd:",
    "    print(json.dumps({'ok': False, 'error': 'This library is encrypted -- a library password is required.'}))",
    "    return",
    "  more = {}",
    "  burl = base_url(server)",
    "  if burl: more['server_url'] = burl",
    "  if info.get('salt'): more['repo_salt'] = info.get('salt')",
    "  more['is_readonly'] = 1 if info.get('permission') == 'r' else 0",
    "  rpc = rpc_client()",
    "  fn = rpc.download if mode == 'download' else rpc.clone",
    "  fn(repo_id, info.get('repo_version', 0), info['repo_name'], target, info['token'], (libpasswd if encrypted else None), info.get('magic'), info['email'], info.get('random_key'), info.get('enc_version'), json.dumps(more))",
    "  print(json.dumps({'ok': True}))",
    "",
    "def action_create(server, token, name, desc, libpasswd):",
    "  data = {'name': name, 'desc': desc}",
    "  if libpasswd: data['passwd'] = libpasswd",
    "  result = api_post(server + '/api2/repos/', token, data)",
    "  print(json.dumps({'ok': True, 'id': result.get('repo_id', '')}))",
    "",
    "def action_share_link(server, token, repo_id, path):",
    "  result = api_post(server + '/api/v2.1/share-links/', token, {'repo_id': repo_id, 'path': path})",
    "  link = result.get('link', '')",
    "  if not link:",
    "    print(json.dumps({'ok': False, 'error': 'Server did not return a share link'}))",
    "  else:",
    "    print(json.dumps({'ok': True, 'link': _cap_str(link, 2000)}))",
    "",
    "def _iso_to_epoch(s):",
    "  try:",
    "    return int(datetime.fromisoformat(s.replace('Z', '+00:00')).timestamp())",
    "  except Exception:",
    "    return 0",
    "",
    "def action_trash_list(server, token, repo_id):",
    "  result = api_get('%s/api2/repos/%s/trash/' % (server, repo_id), token)",
    "  items = []",
    "  for item in result.get('data', [])[:200]:",
    "    parent = (item.get('parent_dir') or '/').rstrip('/')",
    "    items.append({",
    "      'path': parent + '/' + item.get('obj_name', ''),",
    "      'name': _cap_str(item.get('obj_name', ''), 300),",
    "      'is_dir': bool(item.get('is_dir')),",
    "      'size': item.get('size') or 0,",
    "      'deleted_time': _iso_to_epoch(item.get('deleted_time', '')),",
    "      'commit_id': _cap_str(item.get('commit_id', ''), 100),",
    "    })",
    "  print(json.dumps({'ok': True, 'items': items}))",
    "",
    "def action_trash_restore(server, token, repo_id, commit_id, path):",
    "  result = api_post('%s/api2/repos/%s/trash/dirents/revert/' % (server, repo_id), token, {'path': path, 'commit_id': commit_id})",
    "  failed = result.get('failed') or []",
    "  if failed:",
    "    print(json.dumps({'ok': False, 'error': _cap_str(failed[0].get('error_msg', 'Restore failed'), 500)}))",
    "  else:",
    "    print(json.dumps({'ok': True}))",
    "",
    "def action_search(server, token, query):",
    "  url = '%s/api2/search/?q=%s&search_repo=all&per_page=30' % (server, urllib.parse.quote(query))",
    "  result = api_get(url, token)",
    "  items = []",
    "  for r in (result.get('results') or [])[:30]:",
    "    items.append({",
    "      'repo_id': _cap_str(r.get('repo_id', ''), 100),",
    "      'name': _cap_str(r.get('name', ''), 300),",
    "      'path': _cap_str(r.get('fullpath', ''), 1000),",
    "      'is_dir': bool(r.get('is_dir')),",
    "      'size': r.get('size') or 0,",
    "    })",
    "  print(json.dumps({'ok': True, 'items': items}))",
    "",
    "def action_activity(server, token, repo_ids):",
    "  merged = []",
    "  for repo_id in repo_ids[:200]:",
    "    if not repo_id: continue",
    "    try:",
    "      data = api_get('%s/api2/repos/%s/history/?per_page=10' % (server, repo_id), token)",
    "    except Exception:",
    "      continue",
    "    # Seahub's RepoHistory view (seahub/api2/endpoints/repo_history.py)",
    "    # returns {'data': [...], 'more': bool} with commit_id/description/",
    "    # time(ISO)/name fields -- not the commits/id/desc/ctime/creator_name",
    "    # shape this used to assume, which silently produced zero entries",
    "    # against a real server.",
    "    for c in (data.get('data') or [])[:50]:",
    "      merged.append({'id': _cap_str(c.get('commit_id', ''), 100), 'repo_id': repo_id, 'desc': _cap_str((c.get('description') or '').strip(), 2000), 'ctime': _iso_to_epoch(c.get('time', '')), 'creator_name': _cap_str(c.get('name', ''), 200), 'device_name': _cap_str(c.get('device_name', ''), 200)})",
    "  merged.sort(key=lambda e: e['ctime'], reverse=True)",
    "  print(json.dumps({'ok': True, 'entries': merged[:30]}))",
    "",
    "def action_account_info(server, token):",
    "  info = api_get(server + '/api2/account/info/', token)",
    "  usage = info.get('usage', 0) or 0",
    "  total = info.get('total', 0) or 0",
    "  print(json.dumps({'ok': True, 'usage': usage, 'total': total}))",
    "",
    "action = sys.argv[1]",
    "server, token = read_account(sys.argv[2])",
    "libpasswd = sys.stdin.readline().rstrip(chr(10)) if action in ('download', 'sync', 'create') else ''",
    "try:",
    "  if not token:",
    "    print(json.dumps({'ok': False, 'error': 'Not logged in'}))",
    "  elif action == 'list':",
    "    action_list(server, token)",
    "  elif action in ('download', 'sync'):",
    "    action_clone(action, server, token, sys.argv[3], sys.argv[4], libpasswd)",
    "  elif action == 'create':",
    "    action_create(server, token, sys.argv[3], sys.argv[4], libpasswd)",
    "  elif action == 'share_link':",
    "    action_share_link(server, token, sys.argv[3], sys.argv[4])",
    "  elif action == 'trash_list':",
    "    action_trash_list(server, token, sys.argv[3])",
    "  elif action == 'trash_restore':",
    "    action_trash_restore(server, token, sys.argv[3], sys.argv[4], sys.argv[5])",
    "  elif action == 'search':",
    "    action_search(server, token, sys.argv[3])",
    "  elif action == 'activity':",
    "    action_activity(server, token, sys.argv[3].split(',') if len(sys.argv) > 3 and sys.argv[3] else [])",
    "  elif action == 'account_info':",
    "    action_account_info(server, token)",
    "except urllib.error.HTTPError as e:",
    "  body = _read_capped(e, 65536).decode('utf-8', 'replace')",
    "  print(json.dumps({'ok': False, 'error': (body.strip() or ('HTTP %d' % e.code))[:500]}))",
    "except Exception as e:",
    "  print(json.dumps({'ok': False, 'error': str(e)[:500]}))"
  ].join("\n")

  // Local-only daemon settings, bandwidth limits, and sync-error detail --
  // none of this has a seaf-cli subcommand, but it's all plain RPC on the
  // same local `seafile` python module `_remoteScript`'s rpc_client() also
  // uses, so it needs no account/token/HTTP at all.
  readonly property string _localScript: [
    "import sys, os, json, time",
    "",
    "def _cap_str(value, limit=500):",
    "  s = str(value or '')",
    "  return s if len(s) <= limit else s[:limit] + '\\u2026'",
    "",
    "def rpc_client():",
    "  import seafile",
    "  datadir = ''",
    "  try:",
    "    with open(os.path.join(os.environ.get('HOME', ''), '.ccnet', 'seafile.ini')) as f:",
    "      datadir = f.readline().strip()",
    "  except OSError:",
    "    pass",
    "  return seafile.RpcClient(os.path.join(datadir, 'seafile.sock'))",
    "",
    "def cfg_str(rpc, key, default):",
    "  try:",
    "    val = rpc.get_config(key)",
    "    return val if val else default",
    "  except Exception:",
    "    return default",
    "",
    "def cfg_int(rpc, key, default):",
    "  try:",
    "    val = rpc.get_config_int(key)",
    "    return val if val is not None else default",
    "  except Exception:",
    "    return default",
    "",
    "def action_get_settings(rpc):",
    "  out = {",
    "    'uploadLimitBytes': cfg_int(rpc, 'upload_limit', 0),",
    "    'downloadLimitBytes': cfg_int(rpc, 'download_limit', 0),",
    "    'ignoreSymlinks': cfg_str(rpc, 'ignore_symlinks', 'false') == 'true',",
    "    'deleteConfirmThreshold': cfg_int(rpc, 'delete_confirm_threshold', 500),",
    "    'useProxy': cfg_str(rpc, 'use_proxy', 'false') == 'true',",
    "    'proxyType': _cap_str(cfg_str(rpc, 'proxy_type', 'http'), 20),",
    "    'proxyAddr': _cap_str(cfg_str(rpc, 'proxy_addr', ''), 500),",
    "    'proxyPort': _cap_str(cfg_str(rpc, 'proxy_port', ''), 10),",
    "    'proxyUsername': _cap_str(cfg_str(rpc, 'proxy_username', ''), 200),",
    "    'proxyPasswordConfigured': bool(cfg_str(rpc, 'proxy_password', '')),",
    "    'clientName': _cap_str(cfg_str(rpc, 'client_name', ''), 200)",
    "  }",
    "  print(json.dumps({'ok': True, 'settings': out}))",
    "",
    "def action_set_settings(rpc, payload):",
    "  rpc.set_upload_rate_limit(int(payload.get('uploadLimitBytes', 0)))",
    "  rpc.set_download_rate_limit(int(payload.get('downloadLimitBytes', 0)))",
    "  rpc.set_config(str('ignore_symlinks'), 'true' if payload.get('ignoreSymlinks') else 'false')",
    "  rpc.set_config_int('delete_confirm_threshold', int(payload.get('deleteConfirmThreshold', 500)))",
    "  rpc.set_config('use_proxy', 'true' if payload.get('useProxy') else 'false')",
    "  rpc.set_config('proxy_type', (payload.get('proxyType') or 'http')[:20])",
    "  rpc.set_config('proxy_addr', (payload.get('proxyAddr') or '')[:500])",
    "  rpc.set_config('proxy_port', str(payload.get('proxyPort') or '')[:10])",
    "  rpc.set_config('proxy_username', (payload.get('proxyUsername') or '')[:200])",
    "  if payload.get('proxyPassword'):",
    "    rpc.set_config('proxy_password', payload.get('proxyPassword')[:500])",
    "  client_name = payload.get('clientName')",
    "  if client_name:",
    "    rpc.set_config('client_name', client_name[:200])",
    "  print(json.dumps({'ok': True}))",
    "",
    "def action_sync_errors(rpc, offset, limit):",
    "  limit = max(1, min(limit, 200))",
    "  errors = rpc.get_file_sync_errors(offset, limit)",
    "  out = []",
    "  for e in errors:",
    "    try:",
    "      message = rpc.sync_error_id_to_str(e.err_id)",
    "    except Exception:",
    "      message = 'Sync error'",
    "    # 27 = SYNC_ERROR_ID_CONFLICT, 37 = SYNC_ERROR_ID_CASE_CONFLICT in",
    "    # seafile's include/seafile-error.h -- both mean a second copy of",
    "    # the file already exists to go look at, not a broken sync.",
    "    is_conflict = e.err_id in (27, 37)",
    "    out.append({'id': e.id, 'repo_id': e.repo_id, 'repo_name': _cap_str(e.repo_name, 300), 'path': _cap_str(e.path, 1000), 'message': _cap_str(message, 500), 'timestamp': e.timestamp, 'isConflict': is_conflict})",
    "  out.sort(key=lambda x: x['timestamp'], reverse=True)",
    "  print(json.dumps({'ok': True, 'errors': out}))",
    "",
    "def action_clear_sync_error(rpc, error_id):",
    "  rpc.del_file_sync_error_by_id(error_id)",
    "  print(json.dumps({'ok': True}))",
    "",
    "def action_transfer_rates(rpc, repo_ids):",
    "  out = {}",
    "  for repo_id in repo_ids[:100]:",
    "    if not repo_id: continue",
    "    try:",
    "      task = rpc.find_transfer_task(repo_id)",
    "    except Exception:",
    "      task = None",
    "    if task is None: continue",
    "    entry = {}",
    "    if getattr(task, 'rate', None) is not None:",
    "      entry['rate'] = round(task.rate / 1024.0, 1)",
    "    block_total = getattr(task, 'block_total', 0) or 0",
    "    block_done = getattr(task, 'block_done', 0) or 0",
    "    if block_total > 0:",
    "      entry['percent'] = round(block_done * 100.0 / block_total)",
    "    if entry:",
    "      out[repo_id] = entry",
    "  print(json.dumps({'ok': True, 'rates': out}))",
    "",
    "def action_dir_size(path):",
    "  deadline = time.monotonic() + 20",
    "  max_entries = 200000",
    "  total = 0",
    "  count = 0",
    "  truncated = False",
    "  for dirpath, dirnames, filenames in os.walk(path, onerror=lambda e: None):",
    "    if time.monotonic() > deadline:",
    "      truncated = True",
    "      break",
    "    for name in filenames:",
    "      count += 1",
    "      if count > max_entries:",
    "        truncated = True",
    "        break",
    "      try:",
    "        total += os.lstat(os.path.join(dirpath, name)).st_size",
    "      except OSError:",
    "        pass",
    "    if truncated:",
    "      break",
    "  print(json.dumps({'ok': True, 'gb': round(total / (1024 * 1024 * 1024), 2), 'truncated': truncated}))",
    "",
    "action = sys.argv[1]",
    "try:",
    "  if action == 'dir_size':",
    "    action_dir_size(sys.argv[2])",
    "  else:",
    "    rpc = rpc_client()",
    "    if action == 'get_settings':",
    "      action_get_settings(rpc)",
    "    elif action == 'set_settings':",
    "      action_set_settings(rpc, json.loads(sys.stdin.read(1048576) or '{}'))",
    "    elif action == 'sync_errors':",
    "      action_sync_errors(rpc, int(sys.argv[2]), int(sys.argv[3]))",
    "    elif action == 'clear_sync_error':",
    "      action_clear_sync_error(rpc, int(sys.argv[2]))",
    "    elif action == 'transfer_rates':",
    "      action_transfer_rates(rpc, sys.argv[2].split(',') if len(sys.argv) > 2 and sys.argv[2] else [])",
    "except Exception as e:",
    "  print(json.dumps({'ok': False, 'error': str(e)[:500]}))"
  ].join("\n")

  function refreshSettings() {
    if (localActionProcess.running) return
    settingsBusy = true
    settingsError = ""
    localActionProcess.command = ["python3", "-c", _localScript, "get_settings"]
    localActionProcess._pendingStdin = ""
    localActionProcess._onDone = function(result) {
      settingsBusy = false
      if (result && result.ok) {
        var s = result.settings
        uploadLimitKBps = Math.round((s.uploadLimitBytes || 0) / 1024)
        downloadLimitKBps = Math.round((s.downloadLimitBytes || 0) / 1024)
        ignoreSymlinks = s.ignoreSymlinks === true
        deleteConfirmThreshold = s.deleteConfirmThreshold || 500
        useProxy = s.useProxy === true
        proxyType = s.proxyType || "http"
        proxyAddr = s.proxyAddr || ""
        proxyPort = s.proxyPort || ""
        proxyUsername = s.proxyUsername || ""
        proxyPasswordConfigured = s.proxyPasswordConfigured === true
        proxyPasswordInput = ""
        clientName = s.clientName || ""
        settingsLoaded = true
        settingsError = ""
      } else {
        settingsError = (result && result.error) || "Could not read settings"
      }
    }
    localActionProcess.running = true
  }

  function saveSettings() {
    if (localActionProcess.running) return
    settingsBusy = true
    settingsError = ""
    var payload = {
      uploadLimitBytes: Math.max(0, uploadLimitKBps) * 1024,
      downloadLimitBytes: Math.max(0, downloadLimitKBps) * 1024,
      ignoreSymlinks: ignoreSymlinks,
      deleteConfirmThreshold: Math.max(1, deleteConfirmThreshold),
      useProxy: useProxy,
      proxyType: proxyType,
      proxyAddr: proxyAddr,
      proxyPort: proxyPort,
      proxyUsername: proxyUsername,
      clientName: clientName.trim()
    }
    // Only sent when the user actually typed a new one -- an empty field
    // means "leave the stored password alone", never "clear it".
    if (proxyPasswordInput !== "") payload.proxyPassword = proxyPasswordInput
    localActionProcess.command = ["python3", "-c", _localScript, "set_settings"]
    localActionProcess._pendingStdin = JSON.stringify(payload)
    localActionProcess._onDone = function(result) {
      settingsBusy = false
      if (result && result.ok) {
        settingsError = ""
        if (proxyPasswordInput !== "") proxyPasswordConfigured = true
        proxyPasswordInput = ""
        notify("Seafile", "Settings saved", "normal")
      } else {
        settingsError = (result && result.error) || "Could not save settings"
      }
    }
    localActionProcess.running = true
  }

  function refreshSyncErrors() {
    if (localActionProcess.running) return
    syncErrorsRefreshing = true
    syncErrorsError = ""
    localActionProcess.command = ["python3", "-c", _localScript, "sync_errors", "0", "50"]
    localActionProcess._pendingStdin = ""
    localActionProcess._onDone = function(result) {
      syncErrorsRefreshing = false
      if (result && result.ok) {
        syncErrorsError = ""
        syncErrors = result.errors || []
      } else {
        syncErrors = []
        syncErrorsError = (result && result.error) || "Could not read sync errors"
      }
    }
    localActionProcess.running = true
  }

  function clearSyncError(id) {
    if (localActionProcess.running) return
    localActionProcess.command = ["python3", "-c", _localScript, "clear_sync_error", String(id)]
    localActionProcess._pendingStdin = ""
    localActionProcess._onDone = function(result) {
      refreshSyncErrors()
    }
    localActionProcess.running = true
  }

  // calc_dir_size walks the whole local tree synchronously, so this is
  // on-demand per library (a button click), never automatic on refresh.
  function refreshLibrarySize(repoId, path) {
    if (!path || localActionProcess.running) return
    var busy = {}
    for (var k in librarySizeBusy) busy[k] = librarySizeBusy[k]
    busy[repoId] = true
    librarySizeBusy = busy
    localActionProcess.command = ["python3", "-c", _localScript, "dir_size", path]
    localActionProcess._pendingStdin = ""
    localActionProcess._onDone = function(result) {
      var stillBusy = {}
      for (var k2 in librarySizeBusy) if (k2 !== repoId) stillBusy[k2] = librarySizeBusy[k2]
      librarySizeBusy = stillBusy
      if (result && result.ok) {
        var sizes = {}
        for (var k3 in librarySizes) sizes[k3] = librarySizes[k3]
        // A huge tree stops the walk early (see _localScript's action_dir_size
        // deadline/entry cap) rather than hanging -- "+" flags that the total
        // is a lower bound, not the exact size.
        sizes[repoId] = result.truncated ? (result.gb + "+") : result.gb
        librarySizes = sizes
      }
    }
    localActionProcess.running = true
  }

  // Polled by transferRateTimer only while at least one library is busy
  // (see applyRefresh) -- shares localActionProcess with everything else in
  // this file, so a poll due while a settings save or size calc is already
  // running just gets skipped; the next tick a few seconds later catches up.
  function refreshTransferRates() {
    if (localActionProcess.running) return
    var busyIds = []
    for (var i = 0; i < libraries.length; i++) {
      if (Model.stateMeta(libraries[i].state).tone === "busy") busyIds.push(libraries[i].id)
    }
    if (busyIds.length === 0) return
    localActionProcess.command = ["python3", "-c", _localScript, "transfer_rates", busyIds.join(",")]
    localActionProcess._pendingStdin = ""
    localActionProcess._onDone = function(result) {
      if (result && result.ok) transferRates = result.rates || {}
    }
    localActionProcess.running = true
  }

  function refreshRemote() {
    if (!accountLinked || remoteActionProcess.running) return
    remoteRefreshing = true
    remoteError = ""
    remoteActionProcess.command = ["python3", "-c", _remoteScript, "list", accountFile]
    remoteActionProcess._pendingStdin = ""
    remoteActionProcess._onDone = function(result) {
      remoteRefreshing = false
      if (result && result.ok) {
        remoteError = ""
        remoteLibraries = result.repos || []
      } else {
        remoteLibraries = []
        remoteError = (result && result.error) || "Could not reach the server."
      }
    }
    remoteActionProcess.running = true
  }

  // Pulls recent commit history per locally-synced library and merges it
  // into one feed, matching the desktop client's Activities tab (just
  // sourced from Seahub's per-repo history API since there is no single
  // account-wide activity endpoint reachable the same way).
  function refreshActivity() {
    if (!accountLinked || remoteActionProcess.running) return
    var ids = []
    for (var i = 0; i < libraries.length; i++) ids.push(libraries[i].id)
    if (ids.length === 0) {
      activityEntries = []
      activityError = ""
      refreshAccountInfo()
      return
    }
    activityRefreshing = true
    activityError = ""
    remoteActionProcess.command = ["python3", "-c", _remoteScript, "activity", accountFile, ids.join(",")]
    remoteActionProcess._pendingStdin = ""
    remoteActionProcess._onDone = function(result) {
      activityRefreshing = false
      if (result && result.ok) {
        activityError = ""
        var entries = result.entries || []
        notifyNewActivity(entries)
        activityEntries = entries
      } else {
        activityEntries = []
        activityError = (result && result.error) || "Could not load activity."
      }
      // Shares remoteActionProcess with the activity fetch above rather than
      // running concurrently -- quota changes rarely, so piggybacking on the
      // same periodic cycle is plenty and keeps this to one process at a time.
      refreshAccountInfo()
    }
    remoteActionProcess.running = true
  }

  function refreshAccountInfo() {
    if (!accountLinked || remoteActionProcess.running) return
    remoteActionProcess.command = ["python3", "-c", _remoteScript, "account_info", accountFile]
    remoteActionProcess._pendingStdin = ""
    remoteActionProcess._onDone = function(result) {
      if (result && result.ok) {
        accountUsageBytes = result.usage || 0
        accountQuotaBytes = result.total || 0
      }
    }
    remoteActionProcess.running = true
  }

  // Desktop notification per new file added/modified, sourced from the same
  // per-library commit history the Activity view shows. Keyed off commit id
  // so it only fires once per commit, and nothing fires on the very first
  // check after the plugin loads (there is no "since when" baseline yet --
  // that would mean a notification for the entire existing history).
  property var _seenActivityIds: ({})
  property bool _activitySeeded: false
  function notifyNewActivity(entries) {
    var nextSeen = {}
    var fresh = []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      var key = entry.id || (entry.repo_id + ":" + entry.ctime + ":" + entry.desc)
      nextSeen[key] = true
      if (_activitySeeded && !_seenActivityIds[key]) fresh.push(entry)
    }
    _seenActivityIds = nextSeen
    _activitySeeded = true
    if (fresh.length === 0) return

    var maxNotify = 4
    for (var j = 0; j < Math.min(fresh.length, maxNotify); j++) {
      var f = fresh[j]
      notify(f.desc || "File changed", Model.libraryName(libraries, f.repo_id), "normal")
    }
    if (fresh.length > maxNotify) {
      notify((fresh.length - maxNotify) + " more file changes", "", "normal")
    }
  }

  // Downloads a remote library into a brand-new local folder.
  function downloadLibrary(remoteLib, targetDir, libPasswd) {
    runRemoteAction(["download", accountFile, remoteLib.id, targetDir], libPasswd, "Downloading " + remoteLib.name + "…", remoteLib.name + " downloaded")
  }

  // Attaches an existing local folder to a remote library instead of
  // downloading a fresh copy.
  function syncFolder(remoteLib, folder, libPasswd) {
    runRemoteAction(["sync", accountFile, remoteLib.id, folder], libPasswd, "Linking " + remoteLib.name + "…", remoteLib.name + " linked")
  }

  function createLibrary(name, desc, libPasswd) {
    runRemoteAction(["create", accountFile, name, desc || ""], libPasswd, "Creating " + name + "…", "Created library \"" + name + "\"")
  }

  // Links a whole library ("/" as the path -- there's no in-widget file
  // browser to reach a specific file/folder inside one) via Seahub's
  // share-links API, and copies the result straight to the clipboard rather
  // than showing it in a dialog, so this is a single click from a library
  // row to something pasteable.
  function copyShareLink(repoId, name) {
    if (remoteActionProcess.running) return
    actionStatus = "Getting share link…"
    lastError = ""
    remoteActionProcess.command = ["python3", "-c", _remoteScript, "share_link", accountFile, repoId, "/"]
    remoteActionProcess._pendingStdin = ""
    remoteActionProcess._onDone = function(result) {
      if (result && result.ok && result.link) {
        lastError = ""
        actionStatus = ""
        Quickshell.execDetached(["wl-copy", result.link])
        notify("Seafile", "Share link for " + (name || "library") + " copied to clipboard", "normal")
      } else {
        lastError = (result && result.error) || "Could not create a share link"
        actionStatus = lastError
        notify("Seafile", lastError, "critical")
      }
      actionStatusTimer.restart()
    }
    remoteActionProcess.running = true
  }

  // ---- Trash (per-library, server-side) ------------------------------

  function refreshTrash(repoId) {
    if (!accountLinked || remoteActionProcess.running) return
    trashRefreshing = true
    trashError = ""
    remoteActionProcess.command = ["python3", "-c", _remoteScript, "trash_list", accountFile, repoId]
    remoteActionProcess._pendingStdin = ""
    remoteActionProcess._onDone = function(result) {
      trashRefreshing = false
      if (result && result.ok) {
        trashError = ""
        trashItems = result.items || []
      } else {
        trashItems = []
        trashError = (result && result.error) || "Could not read trash"
      }
    }
    remoteActionProcess.running = true
  }

  function restoreTrashItem(repoId, commitId, path, name) {
    if (remoteActionProcess.running) return
    trashBusyPath = path
    remoteActionProcess.command = ["python3", "-c", _remoteScript, "trash_restore", accountFile, repoId, commitId, path]
    remoteActionProcess._pendingStdin = ""
    remoteActionProcess._onDone = function(result) {
      trashBusyPath = ""
      if (result && result.ok) {
        notify("Seafile", (name || path) + " restored", "normal")
        refreshTrash(repoId)
        delayedRefresh.restart()
      } else {
        var message = (result && result.error) || "Could not restore " + (name || path)
        trashError = message
        notify("Seafile", message, "critical")
      }
    }
    remoteActionProcess.running = true
  }

  // ---- Search (account-wide, server-side) -----------------------------

  function searchFiles(query) {
    if (!accountLinked || remoteActionProcess.running) return
    var q = String(query || "").trim()
    if (q === "") {
      searchResults = []
      searchError = ""
      return
    }
    searchBusy = true
    searchError = ""
    remoteActionProcess.command = ["python3", "-c", _remoteScript, "search", accountFile, q]
    remoteActionProcess._pendingStdin = ""
    remoteActionProcess._onDone = function(result) {
      searchBusy = false
      if (result && result.ok) {
        searchError = ""
        searchResults = result.items || []
      } else {
        searchResults = []
        searchError = (result && result.error) || "Search failed"
      }
    }
    remoteActionProcess.running = true
  }

  function runRemoteAction(args, libPasswd, statusMessage, successMessage) {
    if (remoteActionProcess.running) return
    actionStatus = statusMessage
    lastError = ""
    remoteActionProcess.command = ["python3", "-c", _remoteScript].concat(args)
    remoteActionProcess._pendingStdin = (libPasswd || "") + "\n"
    remoteActionProcess._onDone = function(result) {
      if (result && result.ok) {
        lastError = ""
        actionStatus = ""
        notify("Seafile", successMessage, "normal")
        refreshRemote()
        delayedRefresh.restart()
      } else {
        lastError = (result && result.error) || "Seafile command failed"
        actionStatus = lastError
        notify("Seafile", lastError, "critical")
      }
      actionStatusTimer.restart()
    }
    remoteActionProcess.running = true
  }

  // ---- Folder path completion (shell-style, no external file-picker
  //      window -- opening one steals focus from the anchored bar popup and
  //      closes it instantly, wiping the in-progress form) --------------

  function completePath(partial, callback) {
    if (pathCompletionProcess.running) return
    var expanded = String(partial || "")
    if (expanded === "~" || expanded.indexOf("~/") === 0) {
      expanded = Quickshell.env("HOME") + expanded.substring(1)
    }
    pathCompletionProcess._callback = callback
    pathCompletionProcess.command = ["bash", "-c", "compgen -d -- \"$1\"", "--", expanded]
    pathCompletionProcess.running = true
  }

  Component.onCompleted: {
    syncAccount()
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: delayedRefresh
    interval: 1000
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    // seaf-daemon takes a moment to settle after start/stop, so re-poll a
    // handful of times to reflect the new state without waiting for the
    // next periodic refresh.
    id: settleTimer
    property int ticks: 0
    interval: 1200
    repeat: true
    running: false
    onTriggered: {
      settleTimer.ticks += 1
      root.refresh()
      if (settleTimer.ticks >= 4) {
        settleTimer.ticks = 0
        settleTimer.running = false
        root._desired = -1
      }
    }
  }

  Timer {
    id: actionStatusTimer
    interval: 2600
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  // Started/stopped from applyRefresh() based on whether any library is
  // currently busy -- runs at a much tighter interval than the main
  // refreshTimer so the displayed rate actually looks live, and stops
  // itself the moment nothing is transferring rather than polling forever.
  Timer {
    id: transferRateTimer
    interval: 3000
    repeat: true
    running: false
    triggeredOnStart: true
    onTriggered: root.refreshTransferRates()
  }

  // Every Process below pairs with a watchdog Timer: if the child hasn't
  // exited on its own within a generous bound, `running = false` sends it
  // SIGTERM rather than leaving it (and whatever's awaiting its onExited --
  // a spinner, a busy flag) hanging indefinitely on a wedged seaf-daemon
  // socket or a stalled network call.
  Process {
    id: refreshProcess
    running: false
    command: ["bash", "-c", "if ! command -v seaf-cli >/dev/null 2>&1; then exit 3; fi; seaf-cli list --json 2>/dev/null; printf '\\n@@STATUS@@\\n'; seaf-cli status --json 2>/dev/null"]
    onRunningChanged: if (running) refreshWatchdog.restart(); else refreshWatchdog.stop()
    stdout: StdioCollector { id: refreshStdout; waitForEnd: true; onStreamFinished: root._refreshOutput = text }
    onExited: function(exitCode) {
      root.applyRefresh(String(refreshStdout.text || root._refreshOutput || ""), exitCode)
    }
  }

  Timer {
    id: refreshWatchdog
    interval: 20000
    repeat: false
    onTriggered: if (refreshProcess.running) refreshProcess.running = false
  }

  Process {
    id: controlProcess
    running: false
    command: []
    onRunningChanged: if (running) controlWatchdog.restart(); else controlWatchdog.stop()
    stdout: StdioCollector { id: controlStdout; waitForEnd: true; onStreamFinished: root._controlOutput = text }
    stderr: StdioCollector { id: controlStderr; waitForEnd: true; onStreamFinished: root._controlError = text }
    onExited: function(exitCode) {
      var stdout = String(controlStdout.text || root._controlOutput || "")
      var stderr = String(controlStderr.text || root._controlError || "")
      // `seaf-cli start` exits non-zero if seaf-daemon is already running
      // (it can't reacquire the data-dir lock) -- a benign race (two start
      // attempts overlapping, e.g. maybeAutoStart firing on a fresh plugin
      // reload while a prior instance's daemon is still alive), not a real
      // failure. The daemon is fine; just let the next refresh confirm it
      // rather than alarming the user with a critical notification.
      var message = (stderr || stdout || "Seafile command failed").trim()
      var alreadyRunning = message.indexOf("already used by another Seafile client instance") !== -1
      if (exitCode !== 0 && !alreadyRunning) {
        root._desired = -1
        root.lastError = message
        root.actionStatus = root.lastError
        root.notify("Seafile", root.lastError, "critical")
        actionStatusTimer.restart()
      } else {
        root.lastError = ""
        root.actionStatus = ""
      }
      settleTimer.ticks = 0
      settleTimer.restart()
      delayedRefresh.restart()
    }
  }

  Timer {
    id: controlWatchdog
    interval: 20000
    repeat: false
    onTriggered: if (controlProcess.running) controlProcess.running = false
  }

  Process {
    // Step 1 of syncAccount(): best-effort import from seafile-applet, if
    // it's logged in. Ignores its own exit code -- readAccount() right after
    // is what actually determines accountLinked, from whatever is on disk
    // whether this step found anything or not.
    id: importAccountProcess
    running: false
    command: ["python3", "-c", root._importAccountScript, root.ccnetConfig, root.accountFile]
    onRunningChanged: if (running) importAccountWatchdog.restart(); else importAccountWatchdog.stop()
    onExited: function() { root.readAccount() }
  }

  Timer {
    id: importAccountWatchdog
    interval: 15000
    repeat: false
    onTriggered: if (importAccountProcess.running) importAccountProcess.running = false
  }

  Process {
    id: accountProcess
    running: false
    command: []
    onRunningChanged: if (running) accountWatchdog.restart(); else accountWatchdog.stop()
    stdout: StdioCollector { id: accountStdout; waitForEnd: true; onStreamFinished: root._accountOutput = text }
    onExited: function() {
      root.applyAccount(String(accountStdout.text || root._accountOutput || ""))
      // The remote browse list itself is refreshed on demand (opening "Add
      // library", or right after a download/sync/create) rather than on
      // every cycle here -- it and the activity check below share one
      // process, and activity notifications are the one that actually
      // needs to run continuously in the background to be useful.
      if (root.accountLinked) root.refreshActivity()
      else root.remoteLibraries = []
    }
  }

  Timer {
    id: accountWatchdog
    interval: 10000
    repeat: false
    onTriggered: if (accountProcess.running) accountProcess.running = false
  }

  Process {
    id: loginProcess
    running: false
    command: []
    property string _pendingPassword: ""
    stdinEnabled: true
    onRunningChanged: if (running) loginWatchdog.restart(); else loginWatchdog.stop()
    stdout: StdioCollector { id: loginStdout; waitForEnd: true; onStreamFinished: root._loginOutput = text }
    onStarted: {
      write(_pendingPassword + "\n")
      _pendingPassword = ""
    }
    onExited: function() {
      root.applyLoginResult(String(loginStdout.text || root._loginOutput || ""))
    }
  }

  Timer {
    id: loginWatchdog
    interval: 35000
    repeat: false
    onTriggered: if (loginProcess.running) loginProcess.running = false
  }

  Process {
    id: logoutProcess
    running: false
    command: ["rm", "-f", root.accountFile]
    onExited: function() { root.readAccount() }
  }

  Process {
    // Runs _remoteScript for list/download/sync/create. `_onDone(result)` is
    // set by the caller right before `running = true` and handles whatever
    // that specific action needs to do with the parsed {ok, ...} response.
    id: remoteActionProcess
    running: false
    command: []
    property string _pendingStdin: ""
    property var _onDone: null
    stdinEnabled: true
    onRunningChanged: if (running) remoteActionWatchdog.restart(); else remoteActionWatchdog.stop()
    stdout: StdioCollector { id: remoteActionStdout; waitForEnd: true; onStreamFinished: root._remoteOutput = text }
    onStarted: {
      write(_pendingStdin)
      _pendingStdin = ""
    }
    onExited: function() {
      var raw = String(remoteActionStdout.text || root._remoteOutput || "")
      var result = null
      try { result = JSON.parse(raw.trim()) } catch (e) { /* leave null */ }
      var done = _onDone
      _onDone = null
      if (done) done(result)
    }
  }

  Timer {
    id: remoteActionWatchdog
    interval: 40000
    repeat: false
    onTriggered: if (remoteActionProcess.running) remoteActionProcess.running = false
  }

  Process {
    // Runs _localScript for settings/bandwidth/sync-errors/dir-size, same
    // _onDone(result) convention as remoteActionProcess above.
    id: localActionProcess
    running: false
    command: []
    property string _pendingStdin: ""
    property var _onDone: null
    stdinEnabled: true
    onRunningChanged: if (running) localActionWatchdog.restart(); else localActionWatchdog.stop()
    stdout: StdioCollector { id: localActionStdout; waitForEnd: true; onStreamFinished: root._localOutput = text }
    onStarted: {
      write(_pendingStdin)
      _pendingStdin = ""
    }
    onExited: function() {
      var raw = String(localActionStdout.text || root._localOutput || "")
      var result = null
      try { result = JSON.parse(raw.trim()) } catch (e) { /* leave null */ }
      var done = _onDone
      _onDone = null
      if (done) done(result)
    }
  }

  Timer {
    id: localActionWatchdog
    interval: 30000
    repeat: false
    onTriggered: if (localActionProcess.running) localActionProcess.running = false
  }

  Process {
    id: libraryActionProcess
    running: false
    command: []
    property string _pendingName: ""
    onRunningChanged: if (running) libraryActionWatchdog.restart(); else libraryActionWatchdog.stop()
    stdout: StdioCollector { id: libraryActionStdout; waitForEnd: true; onStreamFinished: root._libraryActionOutput = text }
    stderr: StdioCollector { id: libraryActionStderr; waitForEnd: true; onStreamFinished: root._libraryActionError = text }
    onExited: function(exitCode) {
      var stdout = String(libraryActionStdout.text || root._libraryActionOutput || "")
      var stderr = String(libraryActionStderr.text || root._libraryActionError || "")
      var name = _pendingName
      _pendingName = ""
      if (exitCode !== 0) {
        root.lastError = (stderr || stdout || "Seafile command failed").trim()
        root.actionStatus = root.lastError
        root.notify("Seafile", root.lastError, "critical")
      } else {
        root.lastError = ""
        root.actionStatus = ""
        root.notify(name + " desynced", "Local files were kept", "normal")
      }
      actionStatusTimer.restart()
      delayedRefresh.restart()
    }
  }

  Timer {
    id: libraryActionWatchdog
    interval: 20000
    repeat: false
    onTriggered: if (libraryActionProcess.running) libraryActionProcess.running = false
  }

  Process {
    id: pathCompletionProcess
    running: false
    command: []
    property var _callback: null
    property string _output: ""
    onRunningChanged: if (running) pathCompletionWatchdog.restart(); else pathCompletionWatchdog.stop()
    stdout: StdioCollector { id: pathCompletionStdout; waitForEnd: true; onStreamFinished: pathCompletionProcess._output = text }
    onExited: function(exitCode) {
      var raw = String(pathCompletionStdout.text || _output || "")
      var matches = raw.split("\n").map(function(s) { return s.trim() }).filter(function(s) { return s !== "" }).slice(0, 200)
      root.pathCompletions = matches
      var cb = _callback
      _callback = null
      _output = ""
      if (cb && exitCode === 0) cb(matches)
    }
  }

  Timer {
    id: pathCompletionWatchdog
    interval: 8000
    repeat: false
    onTriggered: if (pathCompletionProcess.running) pathCompletionProcess.running = false
  }
}
