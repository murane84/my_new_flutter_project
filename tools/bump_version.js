// Raises the app version in pubspec.yaml before a release build.
//   node tools/bump_version.js          1.0.2+3 -> 1.0.3+4   (patch, default)
//   node tools/bump_version.js minor    1.0.2+3 -> 1.1.0+4
//   node tools/bump_version.js major    1.0.2+3 -> 2.0.0+4
//   node tools/bump_version.js build    1.0.2+3 -> 1.0.2+4   (same name)
// The +N (build number) ALWAYS goes up: Android only installs a higher one
// as an update, and the in-app updater compares it. Prints the new
// version (e.g. "1.0.3+4") and nothing else.
const fs = require('fs');
const path = require('path');

const file = path.join(__dirname, '..', 'pubspec.yaml');
const kind = (process.argv[2] || 'patch').toLowerCase();
const text = fs.readFileSync(file, 'utf8');
const re = /^version:[ \t]*(\d+)\.(\d+)\.(\d+)\+(\d+)[ \t]*(?=\r?$)/m;
const m = text.match(re);
if (!m) {
  console.error('pubspec.yaml has no "version: X.Y.Z+N" line');
  process.exit(1);
}
let [maj, min, pat, build] = m.slice(1).map(Number);
if (kind === 'major') { maj++; min = 0; pat = 0; }
else if (kind === 'minor') { min++; pat = 0; }
else if (kind === 'patch') { pat++; }
else if (kind !== 'build') {
  console.error('Use: patch | minor | major | build');
  process.exit(1);
}
build++;
const v = `${maj}.${min}.${pat}+${build}`;
fs.writeFileSync(file, text.replace(re, `version: ${v}`));
console.log(v);
