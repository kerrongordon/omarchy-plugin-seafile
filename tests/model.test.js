// Unit tests for Model.js's pure functions -- everything here is plain JS
// with no Quickshell/QML dependency, so it runs under Node's built-in test
// runner with zero extra packages.
//
// Run with: node --test tests/

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const Model = require(path.join(__dirname, '..', 'Model.js'));

test('parseJsonArray', async (t) => {
  await t.test('parses a valid JSON array', () => {
    assert.deepEqual(Model.parseJsonArray('[{"id":"1"}]'), [{ id: '1' }]);
  });

  await t.test('returns [] for empty/blank input', () => {
    assert.deepEqual(Model.parseJsonArray(''), []);
    assert.deepEqual(Model.parseJsonArray('   '), []);
    assert.deepEqual(Model.parseJsonArray(undefined), []);
  });

  await t.test('returns [] for malformed JSON instead of throwing', () => {
    assert.deepEqual(Model.parseJsonArray('{not json'), []);
  });

  await t.test('returns [] when the JSON parses but is not an array', () => {
    assert.deepEqual(Model.parseJsonArray('{"id":"1"}'), []);
  });

  await t.test('caps at MAX_LIST_ITEMS so a huge dump stays cheap to render', () => {
    const many = JSON.stringify(Array.from({ length: Model.MAX_LIST_ITEMS + 500 }, (_, i) => ({ id: String(i) })));
    const result = Model.parseJsonArray(many);
    assert.equal(result.length, Model.MAX_LIST_ITEMS);
  });
});

test('capString', () => {
  assert.equal(Model.capString('short', 10), 'short');
  assert.equal(Model.capString('x'.repeat(20), 10), 'x'.repeat(10) + '…');
  assert.equal(Model.capString(null, 10), '');
  assert.equal(Model.capString(undefined, 10), '');
});

test('parseRefresh', async (t) => {
  await t.test('splits the list/status JSON blobs on the marker', () => {
    const raw = '[{"id":"1","name":"A"}]\n@@STATUS@@\n[{"id":"1","state":"synchronized"}]';
    const { list, status } = Model.parseRefresh(raw);
    assert.deepEqual(list, [{ id: '1', name: 'A' }]);
    assert.deepEqual(status, [{ id: '1', state: 'synchronized' }]);
  });

  await t.test('treats the whole input as `list` when the marker is missing', () => {
    const { list, status } = Model.parseRefresh('[{"id":"1"}]');
    assert.deepEqual(list, [{ id: '1' }]);
    assert.deepEqual(status, []);
  });
});

test('mergeLibraries', async (t) => {
  await t.test('joins list and status entries by id', () => {
    const list = [{ id: '1', name: 'Docs', path: '/home/x/Docs' }];
    const status = [{ id: '1', state: 'synchronized' }];
    const merged = Model.mergeLibraries(list, status);
    assert.deepEqual(merged, [{ id: '1', name: 'Docs', path: '/home/x/Docs', state: 'synchronized' }]);
  });

  await t.test('keeps a status-only entry (known to the daemon, not yet in `list`)', () => {
    const merged = Model.mergeLibraries([], [{ id: '2', name: 'Photos', state: 'error' }]);
    assert.deepEqual(merged, [{ id: '2', name: 'Photos', path: '', state: 'error' }]);
  });

  await t.test('skips entries with no id', () => {
    const merged = Model.mergeLibraries([{ name: 'no id' }], []);
    assert.deepEqual(merged, []);
  });

  await t.test('sorts the result by name', () => {
    const list = [
      { id: '1', name: 'Zebra' },
      { id: '2', name: 'Apple' },
    ];
    const merged = Model.mergeLibraries(list, []);
    assert.deepEqual(merged.map((l) => l.name), ['Apple', 'Zebra']);
  });

  await t.test('caps name/path/state length (defense against a hostile or corrupt server)', () => {
    const merged = Model.mergeLibraries([{ id: '1', name: 'x'.repeat(500), path: 'y'.repeat(2000) }], [{ id: '1', state: 'z'.repeat(200) }]);
    assert.equal(merged[0].name.length, 301); // 300 + ellipsis
    assert.equal(merged[0].path.length, 1001);
    assert.equal(merged[0].state.length, 101);
  });
});

test('stateMeta', async (t) => {
  await t.test('resolves a known state case-insensitively', () => {
    assert.equal(Model.stateMeta('Synchronized').tone, 'ok');
    assert.equal(Model.stateMeta('UPLOADING').tone, 'busy');
    assert.equal(Model.stateMeta('error').tone, 'error');
  });

  await t.test('falls back to a dim "Unknown" for an unrecognized state', () => {
    const meta = Model.stateMeta('some future daemon state');
    assert.equal(meta.tone, 'dim');
    assert.equal(meta.label, 'some future daemon state');
  });

  await t.test('reports "Unknown" (not blank) for an empty state', () => {
    assert.equal(Model.stateMeta('').label, 'Unknown');
  });
});

test('overallTone', async (t) => {
  await t.test('is "error" when seaf-cli is not installed, regardless of libraries', () => {
    assert.equal(Model.overallTone([{ state: 'synchronized' }], false, true), 'error');
  });

  await t.test('is "dim" when the daemon is stopped', () => {
    assert.equal(Model.overallTone([], true, false), 'dim');
  });

  await t.test('is "error" if any library errors, even alongside busy ones', () => {
    const libs = [{ state: 'uploading' }, { state: 'error' }];
    assert.equal(Model.overallTone(libs, true, true), 'error');
  });

  await t.test('is "busy" when nothing errors but something is syncing', () => {
    assert.equal(Model.overallTone([{ state: 'downloading' }], true, true), 'busy');
  });

  await t.test('is "ok" when everything is settled', () => {
    assert.equal(Model.overallTone([{ state: 'synchronized' }], true, true), 'ok');
  });
});

test('summaryText', async (t) => {
  await t.test('reports libraries with errors first', () => {
    const libs = [{ state: 'error' }, { state: 'uploading' }];
    assert.equal(Model.summaryText(libs, true, true), '1 library with errors');
  });

  await t.test('reports sync progress when nothing errors', () => {
    const libs = [{ state: 'uploading' }, { state: 'synchronized' }];
    assert.equal(Model.summaryText(libs, true, true), 'Syncing 1 of 2');
  });

  await t.test('reports a fully-synced count', () => {
    const libs = [{ state: 'synchronized' }, { state: 'synchronized' }];
    assert.equal(Model.summaryText(libs, true, true), '2 libraries synced');
  });

  await t.test('reports "No libraries" for an empty, running daemon', () => {
    assert.equal(Model.summaryText([], true, true), 'No libraries');
  });
});

test('formatBytes', () => {
  assert.equal(Model.formatBytes(0), '0 B');
  assert.equal(Model.formatBytes(500), '500 B');
  // Note: only a fully-zero fraction gets trimmed (e.g. "1.00" -> "1"), so
  // an exact-and-a-half value like this keeps both trailing digits.
  assert.equal(Model.formatBytes(1500), '1.50 KB');
  assert.equal(Model.formatBytes(1_500_000), '1.50 MB');
  assert.equal(Model.formatBytes(53_687_091_200), '53.7 GB');
  assert.equal(Model.formatBytes(-5), '0 B');
});

test('relativeTime', async (t) => {
  const now = Date.parse('2024-06-01T12:00:00Z');

  await t.test('handles a missing/zero timestamp', () => {
    assert.equal(Model.relativeTime(0, now), 'Unknown time');
  });

  await t.test('reports seconds-old as "Just now"', () => {
    assert.equal(Model.relativeTime(now / 1000 - 10, now), 'Just now');
  });

  await t.test('reports minutes ago', () => {
    assert.equal(Model.relativeTime(now / 1000 - 5 * 60, now), '5m ago');
  });

  await t.test('reports hours ago', () => {
    assert.equal(Model.relativeTime(now / 1000 - 3 * 3600, now), '3h ago');
  });

  await t.test('reports days ago', () => {
    assert.equal(Model.relativeTime(now / 1000 - 2 * 86400, now), '2d ago');
  });
});

test('libraryName', async (t) => {
  await t.test('finds a known library', () => {
    assert.equal(Model.libraryName([{ id: '1', name: 'Docs' }], '1'), 'Docs');
  });

  await t.test('falls back for an unknown id (e.g. a not-locally-synced repo)', () => {
    assert.equal(Model.libraryName([], 'missing'), 'Unknown library');
  });
});

test('isLinked', () => {
  assert.equal(Model.isLinked([{ id: '1' }], '1'), true);
  assert.equal(Model.isLinked([{ id: '1' }], '2'), false);
});
