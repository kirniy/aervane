import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, readFile, readdir, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { bundleID, downloadArchive, maxArchiveBytes, replaceBundle, validateRelease } from '../lib/install.mjs';

const release = {
  version: '0.2.0', bundleID, notarized: true, teamID: 'ABCDE12345', arch: 'arm64', minimumMacOS: 14,
  url: 'https://github.com/kirniy/aervane/releases/download/v0.2.0/Aervane-0.2.0-macos-arm64.zip',
  sha256: 'a'.repeat(64),
};
async function temporary(t) {
  const dir = await mkdtemp(join(tmpdir(), 'aervane-test-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return dir;
}

test('publishing rejects missing notarization, changed identity, version and external URLs', () => {
  assert.equal(validateRelease(release, '0.2.0'), release);
  for (const mutation of [
    { notarized: false }, { bundleID: 'other' }, { teamID: 'unknown' }, { sha256: 'bad' },
    { version: '0.3.0' }, { arch: 'x64' }, { minimumMacOS: 13 },
    { url: 'https://other.example/app.zip' }, { url: release.url.replace('https:', 'http:') },
  ]) assert.throws(() => validateRelease({ ...release, ...mutation }, '0.2.0'));
});

test('checksum failure writes no downloaded artifact', async t => {
  const dir = await temporary(t);
  await assert.rejects(downloadArchive(release, join(dir, 'download.zip'), async () => new Response('tampered')), /checksum/);
  assert.deepEqual(await readdir(dir), []);
});

test('download accepts only the pinned bytes and never replaces an existing file', async t => {
  const dir = await temporary(t), destination = join(dir, 'download.zip');
  const bytes = Buffer.from('expected archive');
  const pinned = { ...release, sha256: createHash('sha256').update(bytes).digest('hex') };
  await downloadArchive(pinned, destination, async () => new Response(bytes));
  assert.deepEqual(await readFile(destination), bytes);
  await assert.rejects(downloadArchive(pinned, destination, async () => new Response(bytes)), /EEXIST/);
  assert.deepEqual(await readFile(destination), bytes);
});

test('HTTP errors and oversized downloads stop before writing', async t => {
  const dir = await temporary(t), destination = join(dir, 'download.zip');
  await assert.rejects(downloadArchive(release, destination, async () => new Response('', { status: 404 })), /404/);
  await assert.rejects(downloadArchive(release, destination, async () => new Response('x', { headers: { 'content-length': maxArchiveBytes + 1 } })), /size limit/);
  const body = new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(maxArchiveBytes)); controller.enqueue(new Uint8Array(1)); controller.close(); } });
  await assert.rejects(downloadArchive(release, destination, async () => new Response(body)), /size limit/);
  assert.deepEqual(await readdir(dir), []);
});

test('signature failure on copied app preserves the previous app', async t => {
  const dir = await temporary(t), source = join(dir, 'source.app'), destination = join(dir, 'Aervane.app');
  await mkdir(source); await mkdir(destination);
  await writeFile(join(source, 'content'), 'new'); await writeFile(join(destination, 'content'), 'previous');
  let checks = 0;
  await assert.rejects(replaceBundle(source, destination, async () => { if (++checks === 2) throw new Error('signature rejected'); }), /signature rejected/);
  assert.equal(await readFile(join(destination, 'content'), 'utf8'), 'previous');
  assert.deepEqual((await readdir(dir)).sort(), ['Aervane.app', 'source.app']);
});

test('verified replacement swaps the complete app and cleans temporary directories', async t => {
  const dir = await temporary(t), source = join(dir, 'source.app'), destination = join(dir, 'Applications/Aervane.app');
  await mkdir(source); await mkdir(destination, { recursive: true });
  await writeFile(join(source, 'content'), 'new'); await writeFile(join(destination, 'obsolete'), 'old');
  let checks = 0;
  await replaceBundle(source, destination, async path => { assert.equal(await readFile(join(path, 'content'), 'utf8'), 'new'); checks++; });
  assert.equal(checks, 2);
  assert.deepEqual(await readdir(destination), ['content']);
  assert.deepEqual(await readdir(join(dir, 'Applications')), ['Aervane.app']);
});

test('installer refuses a symlink destination without touching its target', async t => {
  const dir = await temporary(t), source = join(dir, 'source.app'), actual = join(dir, 'other.app'), destination = join(dir, 'Aervane.app');
  await mkdir(source); await mkdir(actual); await writeFile(join(actual, 'data'), 'keep'); await symlink(actual, destination);
  await assert.rejects(replaceBundle(source, destination, async () => {}), /regular app directory/);
  assert.equal(await readFile(join(actual, 'data'), 'utf8'), 'keep');
});

test('failed update preparation keeps the old bundle and cleans the verified copy', async t => {
  const dir = await temporary(t), source = join(dir, 'source.app'), destination = join(dir, 'Aervane.app');
  await mkdir(source); await mkdir(destination); await writeFile(join(destination, 'data'), 'previous');
  let verified = 0;
  await assert.rejects(replaceBundle(source, destination, async () => { verified++; }, async old => {
    assert.equal(verified, 2);
    assert.equal(old, destination);
    throw new Error('helper still controls the fan');
  }), /helper still controls the fan/);
  assert.equal(await readFile(join(destination, 'data'), 'utf8'), 'previous');
  assert.deepEqual((await readdir(dir)).sort(), ['Aervane.app', 'source.app']);
});
