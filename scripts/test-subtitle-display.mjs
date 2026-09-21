#!/usr/bin/env node
// Runs the real display runtime with injected transport, plus the independent tab UI.
import {spawnSync} from 'node:child_process';
import {dirname, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const generated = spawnSync('xcodegen', ['generate', '--spec', 'apps/RayNeoCompanion/project-source.yml'], {cwd: root, stdio: 'inherit'});
if (generated.error || generated.status !== 0) throw new Error('XcodeGen could not create the simulator project.');
const listing = spawnSync('xcrun', ['simctl', 'list', 'devices', 'available', '-j'], {cwd: root, encoding: 'utf8'});
if (listing.error || listing.status !== 0) throw new Error('An installed iOS Simulator is required.');
const device = Object.entries(JSON.parse(listing.stdout).devices)
  .filter(([runtime]) => runtime.includes('.iOS-'))
  .flatMap(([, devices]) => devices).find(value => value.isAvailable && value.name.startsWith('iPhone'));
if (!device) throw new Error('No available iPhone simulator.');
const result = spawnSync('xcodebuild', [
  '-project', 'apps/RayNeoCompanion/RayNeoCompanion.xcodeproj', '-scheme', 'RayNeoCompanion',
  '-destination', `id=${device.udid}`,
  '-only-testing:RayNeoCompanionTests/SubtitleDisplayRuntimeTests',
  '-only-testing:RayNeoCompanionTests/SubtitleRealtimeTests',
  '-only-testing:RayNeoCompanionTests/SubtitleLatencyDiagnosticsTests',
  '-only-testing:RayNeoCompanionTests/AliyunRealtimeProtocolTests',
  '-only-testing:RayNeoCompanionTests/SubtitleArchiveTests',
  '-only-testing:RayNeoCompanionTests/CaptionSocketTests',
  '-only-testing:RayNeoCompanionUITests/SubtitleDisplayUITests',
  '-only-testing:RayNeoCompanionUITests/RealtimeSubtitlesUITests',
  '-derivedDataPath', 'apps/RayNeoCompanion/build-subtitle-simulator',
  '-resultBundlePath', 'apps/RayNeoCompanion/build-subtitle-simulator/Tests.xcresult',
  'CODE_SIGNING_ALLOWED=NO', 'test'
], {cwd: root, stdio: 'inherit'});
process.exitCode = result.status ?? 1;
