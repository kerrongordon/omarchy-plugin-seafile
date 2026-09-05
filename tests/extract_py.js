#!/usr/bin/env node
// Pulls the Python scripts embedded as QML string properties in Service.qml
// (_pySecureIo, _pyHttp, _importAccountScript, _loginScript, _remoteScript,
// _localScript, ...) out into real .py files, so they can be syntax-checked
// and unit tested with the standard Python toolchain instead of only ever
// running inside a live seaf-daemon.
//
// Each matched property's value is a JS expression -- either a bare
// `[...].join("\n")` array, or one of the shared helpers concatenated in
// front of it (e.g. `_pyHttp + "\n" + [...].join("\n")`). Properties are
// evaluated in file order so later ones can reference earlier ones by name,
// exactly as they do inside Service.qml itself.
//
// Usage: node extract_py.js <path-to-Service.qml> <output-dir>

const fs = require('fs');
const path = require('path');

const [, , qmlPath, outDir] = process.argv;
if (!qmlPath || !outDir) {
  console.error('Usage: node extract_py.js <Service.qml> <output-dir>');
  process.exit(1);
}

const src = fs.readFileSync(qmlPath, 'utf8');
const re = /readonly property string (_\w+):\s*([\s\S]*?\]\.join\("\\n"\))/g;

const env = {};
const names = [];
let m;
while ((m = re.exec(src))) {
  const name = m[1];
  const exprSrc = m[2];
  const argNames = names.slice();
  const argVals = argNames.map((n) => env[n]);
  const fn = new Function(...argNames, 'return (' + exprSrc + ');');
  env[name] = fn(...argVals);
  names.push(name);
}

if (names.length === 0) {
  console.error('No embedded python scripts found -- did the property naming/shape in Service.qml change?');
  process.exit(1);
}

fs.mkdirSync(outDir, { recursive: true });
for (const name of names) {
  fs.writeFileSync(path.join(outDir, name + '.py'), env[name]);
}
console.log('Extracted: ' + names.join(', '));
