#!/usr/bin/env node
import {spawnSync} from 'node:child_process';
import {dirname, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
function run(command, args, options = {}) {
  const result = spawnSync(command, args, {cwd: root, stdio: 'inherit', ...options});
  if (result.error || result.status !== 0) throw new Error(`${command} failed (${result.status ?? result.error?.message}).`);
  return result;
}
run('xcodegen', ['generate', '--spec', 'apps/RayNeoCompanion/project-source.yml']);
const listing = run('xcrun', ['simctl', 'list', 'devices', 'available', '-j'], {stdio: 'pipe', encoding: 'utf8'});
const device = Object.entries(JSON.parse(listing.stdout).devices)
  .filter(([runtime]) => runtime.includes('.iOS-26-'))
  .flatMap(([, devices]) => devices)
  .find(value => value.isAvailable && value.name.startsWith('iPhone'));
if (!device) throw new Error('An available iOS 26 iPhone simulator is required.');
try {
run('xcodebuild', [
  '-project', 'apps/RayNeoCompanion/RayNeoCompanion.xcodeproj', '-scheme', 'RayNeoCompanion',
  '-destination', `id=${device.udid}`,
  '-only-testing:RayNeoCompanionTests/SubtitleRealtimeTests',
  '-only-testing:RayNeoCompanionTests/SubtitleSettingsTests',
  '-only-testing:RayNeoCompanionTests/ManuscriptLibraryTests',
  '-only-testing:RayNeoCompanionTests/SpeechPrompterRuntimeTests',
  '-only-testing:RayNeoCompanionTests/LocalBoundaryTests',
  '-only-testing:RayNeoCompanionUITests/PrompterUITests',
  '-parallel-testing-enabled', 'NO',
  '-derivedDataPath', 'apps/RayNeoCompanion/build-subtitle-rolling',
  '-resultBundlePath', 'apps/RayNeoCompanion/build-subtitle-rolling/Tests.xcresult',
  'CODE_SIGNING_ALLOWED=NO', 'test'
]);
} finally {
  const exported = spawnSync('xcrun', ['xcresulttool', 'export', 'attachments',
    '--path', 'apps/RayNeoCompanion/build-subtitle-rolling/Tests.xcresult',
    '--output-path', 'apps/RayNeoCompanion/build-subtitle-rolling/attachments'],
  {cwd: root, stdio: 'inherit'});
  if (exported.error || exported.status !== 0) process.stderr.write('Test attachments were not exported.\n');
}
