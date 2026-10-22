import { createHash, randomUUID } from 'node:crypto';
import { cp, lstat, mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';

export const bundleID = 'dev.kirniy.aervane';
export const maxArchiveBytes = 64 * 1024 * 1024;

export function validateRelease(value, version) {
  if (!value || value.version !== version || !/^\d+\.\d+\.\d+$/.test(version)) throw new Error('Release version does not match this package.');
  if (value.bundleID !== bundleID || value.notarized !== true) throw new Error('This package has no notarized Aervane release.');
  if (!/^[a-f0-9]{64}$/.test(value.sha256 ?? '') || !/^[A-Z0-9]{10}$/.test(value.teamID ?? '')) throw new Error('Invalid release identity or checksum.');
  const expected = `https://github.com/kirniy/aervane/releases/download/v${version}/Aervane-${version}-macos-arm64.zip`;
  if (value.url !== expected || value.arch !== 'arm64' || value.minimumMacOS !== 14) throw new Error('Unexpected release platform or URL.');
  return value;
}

export async function loadRelease(packageRoot) {
  const pkg = JSON.parse(await readFile(join(packageRoot, 'package.json'), 'utf8'));
  let release;
  try { release = JSON.parse(await readFile(join(packageRoot, 'release.json'), 'utf8')); }
  catch { throw new Error('No prepared release in this source checkout. Run tools/prepare-distribution.py after signing and notarization.'); }
  return validateRelease(release, pkg.version);
}

export async function downloadArchive(release, destination, fetcher = fetch) {
  const response = await fetcher(release.url, { signal: AbortSignal.timeout(90_000) });
  if (!response.ok) throw new Error(`Release download failed (HTTP ${response.status}).`);
  if (response.url && new URL(response.url).protocol !== 'https:') throw new Error('The download redirected away from HTTPS.');
  if (Number(response.headers.get('content-length')) > maxArchiveBytes) throw new Error('Release archive exceeds the size limit.');
  if (!response.body) throw new Error('The release download is empty.');
  const chunks = [];
  let size = 0;
  for await (const chunk of response.body) {
    size += chunk.length;
    if (size > maxArchiveBytes) throw new Error('Release archive exceeds the size limit.');
    chunks.push(chunk);
  }
  const bytes = Buffer.concat(chunks);
  if (createHash('sha256').update(bytes).digest('hex') !== release.sha256) throw new Error('Release checksum mismatch; nothing was installed.');
  await writeFile(destination, bytes, { flag: 'wx', mode: 0o600 });
}

export async function exists(path) {
  try { return await lstat(path); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

// Verify before and after copying, then swap directories on the same volume.
// Failure restores the previous app; neither a failed download nor a bad
// signature can replace it. The caller must reject a running app first.
export async function replaceBundle(source, destination, verify, beforeReplace = async () => {}) {
  const prior = await exists(destination);
  if (prior && (!prior.isDirectory() || prior.isSymbolicLink())) throw new Error('The destination is not a regular app directory.');
  await verify(source);
  await mkdir(dirname(destination), { recursive: true });
  const temporary = join(dirname(destination), `.Aervane-install-${randomUUID()}.app`);
  const backup = join(dirname(destination), `.Aervane-previous-${randomUUID()}.app`);
  let backedUp = false;
  let installed = false;
  try {
    await cp(source, temporary, { recursive: true, force: false, errorOnExist: true, verbatimSymlinks: true });
    await verify(temporary);
    if (prior) await beforeReplace(destination);
    if (prior) { await rename(destination, backup); backedUp = true; }
    await rename(temporary, destination);
    installed = true;
  } catch (error) {
    if (backedUp && !installed) {
      try { await rename(backup, destination); }
      catch { throw new Error(`Installation failed. Your previous app is preserved at ${backup}.`, { cause: error }); }
    }
    throw error;
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
  if (backedUp) {
    try { await rm(backup, { recursive: true }); }
    catch { return { backup }; }
  }
  return {};
}
