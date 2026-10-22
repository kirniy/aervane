#!/usr/bin/env node
import { fileURLToPath } from 'node:url';
import { loadRelease } from '../lib/install.mjs';
try {
  const release = await loadRelease(fileURLToPath(new URL('../', import.meta.url)));
  console.log(`Prepared notarized Aervane ${release.version}`);
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
