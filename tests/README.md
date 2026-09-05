# Tests

Two independent suites, no dependencies to install (just Node and Python 3,
both of which the plugin itself already requires at runtime).

```sh
node --test tests/                          # Model.js -- pure JS, no QML/Quickshell involved
python3 -m unittest discover -s tests -v     # the Python embedded in Service.qml
```

Or both at once:

```sh
tests/run.sh
```

## Why not test Panel.qml?

Panel.qml is pure presentation and depends on the real Quickshell/`qs.Ui`
component library, which only exists inside a running Omarchy shell -- there
is no headless Qt Quick Test harness available for it here. The logic worth
protecting (parsing, merging, formatting, and every `action_*` request the
plugin makes) already lives in `Model.js` and the scripts embedded in
`Service.qml`, both of which are covered.

## How the Python side is tested

The scripts in `Service.qml` (`_pySecureIo`, `_pyHttp`, `_remoteScript`,
`_localScript`, `_loginScript`, `_importAccountScript`, ...) only ever run as
`python3 -c <script> <args...>` inside a Quickshell `Process` -- there's no
module to `import` normally. `extract_py.js` pulls each one out of
`Service.qml` into `tests/_extracted/*.py` fresh before every run (never
committed -- see `.gitignore`), so the tests always exercise the current
source, never a stale copy.

From there, `test_scripts.py` uses two strategies:

- **Dispatch-table scripts** (`_remoteScript`, `_localScript`) are loaded
  with `load_defs()`, which `exec()`s everything up to the `action =
  sys.argv[1]` dispatch line so individual `action_*`/helper functions can be
  called directly with plain Python arguments -- fast, and lets a test
  target one function's behavior precisely.
- **Flat top-to-bottom scripts** (`_loginScript`, `_importAccountScript`) are
  run as real subprocesses via `run_script()`, exactly the way Service.qml
  invokes them, since they don't have anything to split cleanly.

Network calls are exercised against a real (local, background) HTTP server
per test rather than mocked at the `urllib` layer, so the tests cover the
actual request/response wire format -- headers, redirects, status codes --
not just whatever the test author assumed `urllib` would do with them.
