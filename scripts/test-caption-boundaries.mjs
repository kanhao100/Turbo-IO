#!/usr/bin/env node
// macOS/Xcode only. No service key, audio upload, device signing or installation.
import {spawnSync} from 'node:child_process';
import {dirname, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const listing = spawnSync('xcrun', ['simctl', 'list', 'devices', 'available', '-j'], {cwd: root, encoding: 'utf8'});
if (listing.error || listing.status !== 0) throw new Error('Xcode with an installed iOS Simulator is required.');
const simulator = Object.entries(JSON.parse(listing.stdout).devices)
  .filter(([runtime]) => runtime.includes('.iOS-'))
  .flatMap(([, devices]) => devices)
  .find(device => device.isAvailable && device.name.startsWith('iPhone'));
if (!simulator) throw new Error('No available iPhone simulator. Install an iOS runtime in Xcode.');
const result = spawnSync('xcodebuild', [
  '-project', 'apps/RayNeoCompanion/RayNeoCompanion.xcodeproj',
  '-scheme', 'RayNeoCompanion', '-destination', `id=${simulator.udid}`,
  '-only-testing:RayNeoCompanionTests/CaptionBoundaryTests',
  '-only-testing:RayNeoCompanionTests/CaptionSocketTests',
  '-derivedDataPath', 'apps/RayNeoCompanion/build-captions-simulator',
  'CODE_SIGNING_ALLOWED=NO', 'test'
], {cwd: root, stdio: 'inherit'});
process.exitCode = result.status ?? 1;
