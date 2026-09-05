#!/usr/bin/env python3
"""Unit tests for the Python scripts embedded in Service.qml.

These scripts only ever run as `python3 -c <script> <args...>` inside a
Quickshell Process, so there's no way to import them normally. Instead:

- extract_py.js pulls each `readonly property string _xyz: [...]` out of
  Service.qml into tests/_extracted/_xyz.py (re-run fresh on every test run,
  so these tests always exercise the current source, never a stale copy).
- Scripts built around a dispatch table (`_remoteScript`, `_localScript`)
  are loaded with `load_defs()`, which execs everything up to the dispatch
  line so individual action_*/helper functions can be called directly.
- Scripts that are flat top-to-bottom programs (`_loginScript`,
  `_importAccountScript`) are run as real subprocesses via `run_script()`,
  exactly the way Service.qml invokes them.

Run with: python3 -m unittest discover -s tests -v
"""
import http.server
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, urlparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXTRACT_DIR = os.path.join(ROOT, "tests", "_extracted")


def setUpModule():
    subprocess.run(
        [
            "node",
            os.path.join(ROOT, "tests", "extract_py.js"),
            os.path.join(ROOT, "Service.qml"),
            EXTRACT_DIR,
        ],
        check=True,
        cwd=ROOT,
    )


def load_defs(name):
    with open(os.path.join(EXTRACT_DIR, name + ".py")) as f:
        code = f.read()
    defs_code = code.split("\naction = sys.argv[1]")[0]
    ns = {"__name__": name}
    exec(compile(defs_code, name, "exec"), ns)
    return ns


def run_script(name, args, stdin="", timeout=10):
    with open(os.path.join(EXTRACT_DIR, name + ".py")) as f:
        code = f.read()
    return subprocess.run(
        [sys.executable, "-c", code, *args],
        input=stdin,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def read_file(path):
    with open(path) as f:
        return f.read()


def capture_stdout(fn):
    buf = io.StringIO()
    old = sys.stdout
    sys.stdout = buf
    try:
        fn()
    finally:
        sys.stdout = old
    return buf.getvalue()


def json_response(payload, status=200):
    return (status, {"Content-Type": "application/json"}, json.dumps(payload).encode())


def redirect_response(location):
    return (302, {"Location": location}, b"")


class MockServer:
    """Background HTTP server. Set `.handler = fn` where
    fn(method, path, query, body_str) -> (status, headers_dict, body_bytes)."""

    def __init__(self):
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _handle(self):
                parsed = urlparse(self.path)
                query = parse_qs(parsed.query)
                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length).decode() if length else ""
                status, headers, payload = outer.handler(self.command, parsed.path, query, body)
                self.send_response(status)
                for k, v in headers.items():
                    self.send_header(k, v)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_GET(self):
                self._handle()

            def do_POST(self):
                self._handle()

        self._httpd = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        self.port = self._httpd.server_port
        self.handler = lambda method, path, query, body: json_response({})
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()

    @property
    def url(self):
        return "http://127.0.0.1:%d" % self.port

    def close(self):
        self._httpd.shutdown()
        self._httpd.server_close()


# ---------------------------------------------------------------------------
# _pySecureIo -- the symlink-safe, atomic account-file writer
# ---------------------------------------------------------------------------

class SecureIoTests(unittest.TestCase):
    def setUp(self):
        self.ns = load_defs("_pySecureIo")
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def account_path(self):
        return os.path.join(self.tmp, "state", "account.ini")

    def test_write_and_read_roundtrip(self):
        path = self.account_path()
        self.ns["_write_account_atomic"](path, {"server": "https://x", "user": "me", "token": "abc"})
        self.assertEqual(oct(os.stat(path).st_mode)[-3:], "600")
        self.assertEqual(oct(os.stat(os.path.dirname(path)).st_mode)[-3:], "700")
        self.assertIn("token = abc", read_file(path))

    def test_overwrite_replaces_content(self):
        path = self.account_path()
        self.ns["_write_account_atomic"](path, {"server": "a", "user": "a", "token": "first"})
        self.ns["_write_account_atomic"](path, {"server": "b", "user": "b", "token": "second"})
        content = read_file(path)
        self.assertIn("token = second", content)
        self.assertNotIn("first", content)

    def test_refuses_to_write_through_a_symlinked_target(self):
        path = self.account_path()
        os.makedirs(os.path.dirname(path))
        decoy = os.path.join(self.tmp, "decoy.txt")
        with open(decoy, "w") as f:
            f.write("do not touch")
        os.symlink(decoy, path)
        with self.assertRaises(OSError):
            self.ns["_write_account_atomic"](path, {"server": "x", "user": "y", "token": "z"})
        self.assertEqual(read_file(decoy), "do not touch")

    def test_refuses_a_symlinked_intermediate_directory(self):
        real_dir = os.path.join(self.tmp, "real")
        os.makedirs(real_dir)
        os.symlink(real_dir, os.path.join(self.tmp, "state"))
        with self.assertRaises(OSError):
            self.ns["_write_account_atomic"](self.account_path(), {"server": "x", "user": "y", "token": "z"})


# ---------------------------------------------------------------------------
# _pyHttp -- HTTPS/redirect/credential/byte-cap policy for remote requests
# ---------------------------------------------------------------------------

class HttpHardeningTests(unittest.TestCase):
    def setUp(self):
        self.ns = load_defs("_pyHttp")

    def test_accepts_https(self):
        self.ns["_validate_server_url"]("https://seafile.example.com")

    def test_rejects_plain_http(self):
        with self.assertRaises(ValueError):
            self.ns["_validate_server_url"]("http://seafile.example.com")

    def test_allows_http_to_localhost_only(self):
        self.ns["_validate_server_url"]("http://localhost:8000")
        self.ns["_validate_server_url"]("http://127.0.0.1:8000")

    def test_rejects_embedded_credentials(self):
        with self.assertRaises(ValueError):
            self.ns["_validate_server_url"]("https://user:pass@seafile.example.com")

    def test_rejects_missing_host(self):
        with self.assertRaises(ValueError):
            self.ns["_validate_server_url"]("https://")

    def test_read_capped_enforces_byte_limit(self):
        class FakeResp:
            def read(self, n):
                return b"x" * 100

        with self.assertRaises(ValueError):
            self.ns["_read_capped"](FakeResp(), 50)

    def test_read_capped_allows_content_under_the_limit(self):
        class FakeResp:
            def read(self, n):
                return b"ok"

        self.assertEqual(self.ns["_read_capped"](FakeResp(), 50), b"ok")

    def test_safe_open_follows_a_same_origin_redirect(self):
        import urllib.request

        server = MockServer()
        self.addCleanup(server.close)

        def handler(method, path, query, body):
            if path == "/start":
                return redirect_response("/final")
            return json_response({"ok": True})

        server.handler = handler
        req = urllib.request.Request(server.url + "/start")
        with self.ns["_safe_open"](req, timeout=5) as resp:
            self.assertEqual(json.loads(resp.read()), {"ok": True})

    def test_safe_open_refuses_a_cross_origin_redirect(self):
        import urllib.request

        server = MockServer()
        self.addCleanup(server.close)
        server.handler = lambda m, p, q, b: redirect_response("http://127.0.0.1:1/final")

        req = urllib.request.Request(server.url + "/start")
        with self.assertRaises(ValueError):
            self.ns["_safe_open"](req, timeout=5)

    def test_safe_open_gives_up_after_too_many_redirects(self):
        import urllib.request

        server = MockServer()
        self.addCleanup(server.close)
        server.handler = lambda m, p, q, b: redirect_response("/start")  # redirects to itself forever

        req = urllib.request.Request(server.url + "/start")
        with self.assertRaises(ValueError):
            self.ns["_safe_open"](req, timeout=2, max_redirects=2)


# ---------------------------------------------------------------------------
# _remoteScript -- everything that talks to Seahub's HTTP API
# ---------------------------------------------------------------------------

class RemoteScriptTests(unittest.TestCase):
    def setUp(self):
        self.ns = load_defs("_remoteScript")
        self.server = MockServer()
        self.addCleanup(self.server.close)

    def result_of(self, fn):
        return json.loads(capture_stdout(fn))

    def test_account_info(self):
        self.server.handler = lambda m, p, q, b: json_response({"usage": 100, "total": 1000})
        result = self.result_of(lambda: self.ns["action_account_info"](self.server.url, "tok"))
        self.assertEqual(result, {"ok": True, "usage": 100, "total": 1000})

    def test_share_link_success(self):
        self.server.handler = lambda m, p, q, b: json_response({"link": "https://x/f/abc/", "token": "abc"})
        result = self.result_of(lambda: self.ns["action_share_link"](self.server.url, "tok", "r1", "/"))
        self.assertEqual(result, {"ok": True, "link": "https://x/f/abc/"})

    def test_share_link_missing_link_is_reported_as_failure(self):
        self.server.handler = lambda m, p, q, b: json_response({})
        result = self.result_of(lambda: self.ns["action_share_link"](self.server.url, "tok", "r1", "/"))
        self.assertFalse(result["ok"])

    def test_trash_list_builds_full_paths_for_root_and_nested_items(self):
        self.server.handler = lambda m, p, q, b: json_response(
            {
                "data": [
                    {
                        "parent_dir": "/",
                        "obj_name": "report.docx",
                        "deleted_time": "2024-01-15T14:30:45+00:00",
                        "is_dir": False,
                        "size": 2048,
                        "commit_id": "c1",
                    },
                    {
                        "parent_dir": "/sub",
                        "obj_name": "oldfolder",
                        "deleted_time": "2024-01-16T09:00:00Z",
                        "is_dir": True,
                        "size": "",
                        "commit_id": "c2",
                    },
                ],
                "more": False,
            }
        )
        result = self.result_of(lambda: self.ns["action_trash_list"](self.server.url, "tok", "r1"))
        self.assertTrue(result["ok"])
        paths = {item["path"]: item for item in result["items"]}
        self.assertIn("/report.docx", paths)
        self.assertIn("/sub/oldfolder", paths)
        self.assertEqual(paths["/report.docx"]["deleted_time"], 1705329045)
        self.assertEqual(paths["/sub/oldfolder"]["size"], 0)
        self.assertTrue(paths["/sub/oldfolder"]["is_dir"])

    def test_trash_restore_success(self):
        def handler(method, path, query, body):
            params = parse_qs(body)
            self.assertEqual(params.get("path"), ["/report.docx"])
            self.assertEqual(params.get("commit_id"), ["c1"])
            return json_response({"success": [{"path": "/report.docx"}], "failed": []})

        self.server.handler = handler
        result = self.result_of(
            lambda: self.ns["action_trash_restore"](self.server.url, "tok", "r1", "c1", "/report.docx")
        )
        self.assertEqual(result, {"ok": True})

    def test_trash_restore_surfaces_the_server_side_failure_reason(self):
        self.server.handler = lambda m, p, q, b: json_response(
            {"success": [], "failed": [{"path": "/x", "error_msg": "Dirent /x not found."}]}
        )
        result = self.result_of(
            lambda: self.ns["action_trash_restore"](self.server.url, "tok", "r1", "c1", "/x")
        )
        self.assertFalse(result["ok"])
        self.assertIn("not found", result["error"])

    def test_search_maps_result_fields(self):
        def handler(method, path, query, body):
            self.assertEqual(path, "/api2/search/")
            self.assertEqual(query.get("q"), ["budget report"])
            return json_response(
                {
                    "total": 1,
                    "has_more": False,
                    "results": [
                        {
                            "repo_id": "r1",
                            "name": "budget report.xlsx",
                            "fullpath": "/Finance/budget report.xlsx",
                            "is_dir": False,
                            "size": 4096,
                        }
                    ],
                }
            )

        self.server.handler = handler
        result = self.result_of(lambda: self.ns["action_search"](self.server.url, "tok", "budget report"))
        self.assertEqual(
            result["items"],
            [{"repo_id": "r1", "name": "budget report.xlsx", "path": "/Finance/budget report.xlsx", "is_dir": False, "size": 4096}],
        )

    def test_list_dedupes_by_id_and_caps_at_1000(self):
        repos = [{"id": "r1", "name": "A"}] * 5 + [{"id": "r%d" % i, "name": "n"} for i in range(1500)]
        self.server.handler = lambda m, p, q, b: json_response(repos)
        result = self.result_of(lambda: self.ns["action_list"](self.server.url, "tok"))
        ids = [r["id"] for r in result["repos"]]
        self.assertEqual(len(ids), len(set(ids)))  # deduped
        self.assertLessEqual(len(ids), 1000)

    def test_activity_parses_the_shape_actual_deployed_servers_return(self):
        # Regression test for a real mistake: an earlier version of this
        # parser was rewritten to match seahub/api2/endpoints/repo_history.py
        # on GitHub's master branch (a `data` array with commit_id/
        # description/time(ISO)/name fields), on the assumption that was
        # what a real server returns. It wasn't -- verified directly against
        # a live production Seahub instance, which returns `commits` with
        # id/desc/ctime/creator_name, the shape this now parses first.
        self.server.handler = lambda m, p, q, b: json_response(
            {
                "commits": [
                    {
                        "id": "93f0145bbc439d9730b2ab88f6b5aba0ca2850ed",
                        "creator_name": "me@example.com",
                        "desc": 'Deleted ".modules.yaml" and 2 more files.\n',
                        "ctime": 1788547214,
                        "repo_id": "r1",
                        "device_name": "kgp-xps",
                        "client_version": "9.0.19",
                    }
                ]
            }
        )
        result = self.result_of(lambda: self.ns["action_activity"](self.server.url, "tok", ["r1"]))
        self.assertTrue(result["ok"])
        self.assertEqual(len(result["entries"]), 1)
        entry = result["entries"][0]
        self.assertEqual(entry["id"], "93f0145bbc439d9730b2ab88f6b5aba0ca2850ed")
        self.assertEqual(entry["desc"], 'Deleted ".modules.yaml" and 2 more files.')
        self.assertEqual(entry["creator_name"], "me@example.com")
        self.assertEqual(entry["device_name"], "kgp-xps")
        self.assertEqual(entry["ctime"], 1788547214)

    def test_activity_falls_back_to_the_newer_documented_shape(self):
        # Not confirmed against any real server, but handled in case a
        # future server version switches to it (see
        # seahub/api2/endpoints/repo_history.py on GitHub).
        self.server.handler = lambda m, p, q, b: json_response(
            {
                "data": [
                    {
                        "email": "me@example.com",
                        "name": "me",
                        "time": "2024-01-15T14:30:45+00:00",
                        "commit_id": "c1",
                        "description": "Added budget.xlsx",
                        "device_name": "laptop",
                    }
                ],
                "more": False,
            }
        )
        result = self.result_of(lambda: self.ns["action_activity"](self.server.url, "tok", ["r1"]))
        self.assertTrue(result["ok"])
        self.assertEqual(len(result["entries"]), 1)
        entry = result["entries"][0]
        self.assertEqual(entry["id"], "c1")
        self.assertEqual(entry["desc"], "Added budget.xlsx")
        self.assertEqual(entry["creator_name"], "me")
        self.assertEqual(entry["device_name"], "laptop")
        self.assertEqual(entry["ctime"], 1705329045)

    def test_activity_survives_a_repo_whose_history_call_fails(self):
        self.server.handler = lambda m, p, q, b: (500, {}, b"boom")
        result = self.result_of(lambda: self.ns["action_activity"](self.server.url, "tok", ["r1"]))
        self.assertEqual(result, {"ok": True, "entries": []})


# ---------------------------------------------------------------------------
# _localScript -- everything that talks to seaf-daemon's local RPC socket
# ---------------------------------------------------------------------------

class FakeTask:
    def __init__(self, rate=None, block_done=0, block_total=0):
        self.rate = rate
        self.block_done = block_done
        self.block_total = block_total


class FakeSyncError:
    def __init__(self, id, repo_id, repo_name, path, err_id, timestamp):
        self.id, self.repo_id, self.repo_name, self.path = id, repo_id, repo_name, path
        self.err_id, self.timestamp = err_id, timestamp


class FakeRpc:
    def __init__(self):
        self.config = {}
        self.upload_limit = None
        self.download_limit = None
        self.transfer_tasks = {}
        self.sync_errors = []

    def get_config(self, key):
        return self.config.get(key)

    def get_config_int(self, key):
        val = self.config.get(key)
        return int(val) if val is not None else None

    def set_config(self, key, value):
        self.config[key] = value

    def set_config_int(self, key, value):
        self.config[key] = value

    def set_upload_rate_limit(self, value):
        self.upload_limit = value

    def set_download_rate_limit(self, value):
        self.download_limit = value

    def find_transfer_task(self, repo_id):
        if repo_id not in self.transfer_tasks:
            raise Exception("no such task")
        return self.transfer_tasks[repo_id]

    def get_file_sync_errors(self, offset, limit):
        return self.sync_errors[offset : offset + limit]

    def sync_error_id_to_str(self, err_id):
        return {27: "Concurrent updates to file. File is saved as conflict file"}.get(err_id, "Sync error")

    def del_file_sync_error_by_id(self, error_id):
        self.sync_errors = [e for e in self.sync_errors if e.id != error_id]


class LocalScriptTests(unittest.TestCase):
    def setUp(self):
        self.ns = load_defs("_localScript")
        self.rpc = FakeRpc()

    def result_of(self, fn):
        return json.loads(capture_stdout(fn))

    def test_sync_errors_flags_conflict_and_case_conflict_ids(self):
        self.rpc.sync_errors = [
            FakeSyncError(1, "r1", "Pictures", "/Pictures/photo.jpg", 27, 200),  # conflict
            FakeSyncError(2, "r2", "Music", "/Music/song.mp3", 13, 100),  # real error
            FakeSyncError(3, "r3", "Docs", "/Docs/Report.docx", 37, 300),  # case conflict
        ]
        result = self.result_of(lambda: self.ns["action_sync_errors"](self.rpc, 0, 50))
        by_repo = {e["repo_name"]: e["isConflict"] for e in result["errors"]}
        self.assertTrue(by_repo["Pictures"])
        self.assertTrue(by_repo["Docs"])
        self.assertFalse(by_repo["Music"])
        # newest first
        self.assertEqual([e["repo_name"] for e in result["errors"]], ["Docs", "Pictures", "Music"])

    def test_transfer_rates_reports_rate_and_percent(self):
        self.rpc.transfer_tasks["r1"] = FakeTask(rate=51200, block_done=30, block_total=100)
        result = self.result_of(lambda: self.ns["action_transfer_rates"](self.rpc, ["r1", "r2"]))
        self.assertEqual(result["rates"]["r1"], {"rate": 50.0, "percent": 30})
        self.assertNotIn("r2", result["rates"])  # no task -> excluded, not zeroed

    def test_transfer_rates_omits_percent_before_block_total_is_known(self):
        self.rpc.transfer_tasks["r1"] = FakeTask(rate=1024, block_done=0, block_total=0)
        result = self.result_of(lambda: self.ns["action_transfer_rates"](self.rpc, ["r1"]))
        self.assertEqual(result["rates"]["r1"], {"rate": 1.0})

    def test_get_settings_never_returns_the_proxy_password(self):
        self.rpc.config["proxy_password"] = "supersecret"
        result = self.result_of(lambda: self.ns["action_get_settings"](self.rpc))
        settings = result["settings"]
        self.assertNotIn("proxyPassword", settings)
        self.assertTrue(settings["proxyPasswordConfigured"])
        self.assertNotIn("supersecret", json.dumps(settings))

    def test_get_settings_reports_unconfigured_password(self):
        result = self.result_of(lambda: self.ns["action_get_settings"](self.rpc))
        self.assertFalse(result["settings"]["proxyPasswordConfigured"])

    def test_set_settings_only_touches_proxy_password_when_provided(self):
        self.rpc.config["proxy_password"] = "existing"
        self.result_of(lambda: self.ns["action_set_settings"](self.rpc, {}))
        self.assertEqual(self.rpc.config["proxy_password"], "existing")

        self.result_of(lambda: self.ns["action_set_settings"](self.rpc, {"proxyPassword": "new-value"}))
        self.assertEqual(self.rpc.config["proxy_password"], "new-value")

    def test_dir_size_sums_file_sizes(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        # gb is rounded to 2 decimal places by the source, so the total
        # needs to be large enough for that rounding to still show it.
        total_bytes = 3 * 10_000_000
        for i in range(3):
            with open(os.path.join(tmp, "f%d.bin" % i), "wb") as f:
                f.write(b"x" * 10_000_000)
        result = self.result_of(lambda: self.ns["action_dir_size"](tmp))
        self.assertTrue(result["ok"])
        self.assertFalse(result["truncated"])
        self.assertEqual(result["gb"], round(total_bytes / (1024**3), 2))


# ---------------------------------------------------------------------------
# _loginScript and _importAccountScript -- flat top-to-bottom programs, run
# as real subprocesses exactly the way Service.qml invokes them.
# ---------------------------------------------------------------------------

class LoginScriptTests(unittest.TestCase):
    def setUp(self):
        self.server = MockServer()
        self.addCleanup(self.server.close)
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.account_path = os.path.join(self.tmp, "account.ini")

    def test_successful_login_writes_the_account_file(self):
        def handler(method, path, query, body):
            self.assertEqual(path, "/api2/auth-token/")
            return json_response({"token": "tok123"})

        self.server.handler = handler
        result = run_script(
            "_loginScript", [self.server.url, "me@example.com", "", self.account_path], stdin="hunter2\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout.strip())
        self.assertTrue(payload["ok"])
        self.assertIn("token = tok123", read_file(self.account_path))
        self.assertEqual(oct(os.stat(self.account_path).st_mode)[-3:], "600")

    def test_rejects_a_non_https_server_without_ever_making_a_request(self):
        result = run_script(
            "_loginScript", ["http://seafile.example.com", "me", "", self.account_path], stdin="pw\n"
        )
        payload = json.loads(result.stdout.strip())
        self.assertFalse(payload["ok"])
        self.assertIn("https", payload["error"].lower())
        self.assertFalse(os.path.exists(self.account_path))

    def test_reports_needs_tfa_when_the_server_asks_for_a_one_time_code(self):
        self.server.handler = lambda m, p, q, b: (
            400,
            {"Content-Type": "application/json"},
            json.dumps(
                {"non_field_errors": ["Please enter your two-factor authentication token."]}
            ).encode(),
        )
        result = run_script(
            "_loginScript", [self.server.url, "me", "", self.account_path], stdin="pw\n"
        )
        payload = json.loads(result.stdout.strip())
        self.assertFalse(payload["ok"])
        self.assertTrue(payload["needsTfa"])


class ImportAccountScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.ccnet_dir = os.path.join(self.tmp, "ccnet-data")
        os.makedirs(self.ccnet_dir)
        self.ccnet_config = os.path.join(self.tmp, "seafile.ini")
        with open(self.ccnet_config, "w") as f:
            f.write(self.ccnet_dir + "\n")
        self.account_path = os.path.join(self.tmp, "state", "account.ini")

    def seed_accounts_db(self, url, username, token):
        conn = sqlite3.connect(os.path.join(self.ccnet_dir, "accounts.db"))
        conn.execute("CREATE TABLE Accounts (url text, username text, token text, lastVisited integer)")
        conn.execute("INSERT INTO Accounts VALUES (?, ?, ?, ?)", (url, username, token, 100))
        conn.commit()
        conn.close()

    def test_imports_the_seafile_applet_account_when_none_exists_yet(self):
        self.seed_accounts_db("https://example.com", "me@example.com", "tok999")
        result = run_script("_importAccountScript", [self.ccnet_config, self.account_path])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("token = tok999", read_file(self.account_path))

    def test_never_overwrites_an_account_this_widget_logged_into_itself(self):
        os.makedirs(os.path.dirname(self.account_path))
        with open(self.account_path, "w") as f:
            f.write("[account]\nserver = https://own-login.example.com\nuser = self\ntoken = own-token\n")
        os.chmod(self.account_path, 0o600)
        self.seed_accounts_db("https://gui-client.example.com", "gui-user", "gui-token")

        result = run_script("_importAccountScript", [self.ccnet_config, self.account_path])
        self.assertEqual(result.returncode, 0, result.stderr)
        content = read_file(self.account_path)
        self.assertIn("token = own-token", content)
        self.assertNotIn("gui-token", content)

    def test_does_nothing_when_no_accounts_db_exists(self):
        result = run_script("_importAccountScript", [self.ccnet_config, self.account_path])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(os.path.exists(self.account_path))


if __name__ == "__main__":
    unittest.main()
