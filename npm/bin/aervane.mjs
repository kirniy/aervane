#!/usr/bin/env node
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { bundleID, downloadArchive, exists, loadRelease, replaceBundle } from '../lib/install.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const pkg = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'));
const help = `Aervane ${pkg.version} — native Mac temperature and fan control

  aervane install [--app-dir /Applications]   Install this version
  aervane open [--app-dir /Applications]      Open the installed app
  aervane doctor [--app-dir /Applications]    Check installation and signing
  aervane --version

The app runs entirely in Swift. Node is used only for this installer.
Fan control is enabled separately inside the app through macOS approval.
`;

function command(executable, args) {
  try { return execFileSync(executable, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }); }
  catch (error) { throw new Error(`${executable.split('/').at(-1)}: ${(error.stderr?.toString() || error.message).trim()}`); }
}
function plist(app, key) { return command('/usr/libexec/PlistBuddy', ['-c', `Print:${key}`, join(app, 'Contents/Info.plist')]).trim(); }
function identity(app) {
  const result = spawnSync('/usr/bin/codesign', ['--display', '--verbose=4', app], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error('Cannot read the app signing identity.');
  return result.stderr;
}
function verify(app, release) {
  if (plist(app, 'CFBundleIdentifier') !== bundleID || plist(app, 'CFBundleShortVersionString') !== release.version) throw new Error('Unexpected app identity or version.');
  command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
  const signature = identity(app);
  if (!signature.includes(`TeamIdentifier=${release.teamID}\n`) || !signature.includes('Authority=Developer ID Application:')) throw new Error('Unexpected app signing certificate.');
  command('/usr/sbin/spctl', ['--assess', '--type', 'execute', '--verbose=2', app]);
}

async function main() {
  const args = process.argv.slice(2);
  const action = args.shift() ?? '--help';
  if (['--help', '-h', 'help'].includes(action)) { console.log(help); return; }
  if (['--version', '-v'].includes(action)) { console.log(pkg.version); return; }
  if (!['install', 'open', 'doctor'].includes(action)) throw new Error(`Unknown command: ${action}. Run aervane --help.`);
  let appDir = '/Applications';
  if (args.length) {
    if (args.length !== 2 || args[0] !== '--app-dir' || args[1].startsWith('-')) throw new Error('Use --app-dir followed by a directory path.');
    appDir = resolve(args[1]);
  }
  if (process.platform !== 'darwin') throw new Error('Aervane is a macOS app.');
  const app = join(appDir, 'Aervane.app');
  if (action === 'doctor') {
    if (!await exists(app)) throw new Error(`No app at ${app}. Run aervane install.`);
    if (plist(app, 'CFBundleIdentifier') !== bundleID) throw new Error('The installed app has an unexpected bundle identifier.');
    console.log(`Aervane ${plist(app, 'CFBundleShortVersionString')}\n${app}`);
    command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
    console.log('Code signature: valid');
    const signature = identity(app);
    console.log(`Signing: ${signature.includes('Authority=Developer ID Application:') ? 'Developer ID Application' : signature.includes('Signature=adhoc') ? 'ad hoc' : 'development or another Apple identity'}`);
    const assessment = spawnSync('/usr/sbin/spctl', ['--assess', '--type', 'execute', '--verbose=2', app], { encoding: 'utf8' });
    console.log(`Gatekeeper on this Mac: ${assessment.status === 0 ? 'accepted' : 'not accepted'}`);
    if (assessment.status !== 0) process.exitCode = 1;
    return;
  }
  if (action === 'open') {
    if (!await exists(app) || plist(app, 'CFBundleIdentifier') !== bundleID) throw new Error(`Aervane is not installed at ${app}.`);
    command('/usr/bin/open', ['-a', app]);
    return;
  }
  const release = await loadRelease(root);
  const appleSilicon = command('/usr/sbin/sysctl', ['-n', 'hw.optional.arm64']).trim() === '1';
  if (!appleSilicon) throw new Error('This release supports Apple Silicon Macs. Intel builds are not yet distributed.');
  const majorOS = Number(command('/usr/bin/sw_vers', ['-productVersion']).trim().split('.')[0]);
  if (majorOS < release.minimumMacOS) throw new Error(`macOS ${release.minimumMacOS} or later is required.`);
  if (spawnSync('/usr/bin/pgrep', ['-x', 'Aervane'], { stdio: 'ignore' }).status === 0) throw new Error('Quit Aervane from its settings before installing. Quitting restores automatic fan control.');
  if (await exists(app)) {
    if (plist(app, 'CFBundleIdentifier') !== bundleID) throw new Error('Another app occupies the destination; it will not be replaced.');
  }
  const staging = await mkdtemp(join(tmpdir(), 'aervane-'));
  try {
    console.log(`Downloading Aervane ${release.version}…`);
    const archive = join(staging, 'Aervane.zip');
    await downloadArchive(release, archive);
    const unpacked = join(staging, 'unpacked');
    command('/usr/bin/ditto', ['-x', '-k', archive, unpacked]);
    const result = await replaceBundle(join(unpacked, 'Aervane.app'), app,
      candidate => verify(candidate, release),
      previous => {
        command('/usr/bin/codesign', ['--verify', '--deep', '--strict', previous]);
        if (!identity(previous).includes(`TeamIdentifier=${release.teamID}\n`)) throw new Error('The existing app belongs to a different signing team; it will not be replaced.');
        command(join(previous, 'Contents/MacOS/Aervane'), ['--unregister-helper']);
      });
    console.log(`Installed ${app}\nRun aervane open.`);
    if (result.backup) console.log(`Previous app retained at ${result.backup}`);
  } finally { await rm(staging, { recursive: true, force: true }); }
}

main().catch(error => { console.error(`Aervane: ${error.message}`); process.exitCode = 1; });
