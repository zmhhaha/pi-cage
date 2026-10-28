// pi-cage's fixed single-task entry for an external job controller.
// This module is also safe to import for build-time metadata and offline tests.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const REPOSITORY = 'https://github.com/zmhhaha/pi-cage';
export const PACKAGE = '@earendil-works/pi-coding-agent';
export const VERSION = '0.99.2';
export const ENTRYPOINT = '/usr/local/lib/pi-cage/worker-cli.mjs';
const packageJson = new URL('../node_modules/@earendil-works/pi-coding-agent/package.json', import.meta.url);
const cli = new URL('../node_modules/@earendil-works/pi-coding-agent/dist/cli.js', import.meta.url);
const requiredFlags = new Set([
  '--print', '--no-session', '--no-extensions', '--no-skills',
  '--no-prompt-templates', '--no-themes', '--no-context-files', '--offline',
]);
const singleValues = new Set(['--mode', '--provider', '--model', '--tools']);
const repeatedValues = new Set(['--extension', '--skill']);

export function validateWorkerArgs(args) {
  if (args.length === 1 && args[0] === '--version') return;
  const seen = new Set();
  const values = new Map();
  let prompt = null;
  for (let index = 0; index < args.length; index++) {
    const argument = args[index];
    if (typeof argument !== 'string' || !argument || argument.includes('\0')) throw new Error('worker_arguments_invalid');
    if (requiredFlags.has(argument)) {
      if (seen.has(argument)) throw new Error('worker_arguments_invalid');
      seen.add(argument);
    } else if (singleValues.has(argument) || repeatedValues.has(argument)) {
      if (singleValues.has(argument) && seen.has(argument)) throw new Error('worker_arguments_invalid');
      const value = args[++index];
      if (typeof value !== 'string' || !value || value.startsWith('-') || value.includes('\0')) {
        throw new Error('worker_arguments_invalid');
      }
      seen.add(argument);
      values.set(argument, value);
    } else if (argument.startsWith('-') || prompt !== null || index !== args.length - 1) {
      throw new Error('worker_arguments_invalid');
    } else {
      prompt = argument;
    }
  }
  if ([...requiredFlags].some(flag => !seen.has(flag)) || values.get('--mode') !== 'json'
      || !values.get('--provider') || !values.get('--model') || prompt === null) {
    throw new Error('worker_arguments_invalid');
  }
}

function installedPackage() {
  const installed = JSON.parse(readFileSync(packageJson, 'utf8'));
  if (installed.name !== PACKAGE || installed.version !== VERSION) throw new Error('worker_runtime_mismatch');
  return installed;
}

export function runtimeMetadata(revision) {
  if (revision !== null && (typeof revision !== 'string' || !/^[0-9a-f]{40}$/.test(revision))) {
    throw new Error('worker_revision_invalid');
  }
  installedPackage();
  return { schema_version: 1, repository: REPOSITORY, revision,
    package: PACKAGE, version: VERSION, entrypoint: ENTRYPOINT };
}

async function main() {
  try {
    validateWorkerArgs(process.argv.slice(2));
    installedPackage();
    // The image-owned CLI is fixed relative to this entry, never selected by
    // PATH, a request field, or a model/provider environment variable. Import it
    // in this process so a controller's explicit node --import preload remains
    // active and the process/UID supervision boundary does not gain a daemon.
    process.argv[1] = fileURLToPath(cli);
    process.env.PI_SKIP_VERSION_CHECK = '1';
    process.env.PI_OFFLINE = '1';
    await import(cli.href);
  } catch {
    // Invalid arguments and loader failures can include prompt paths or secrets.
    process.stderr.write('pi-cage: worker_start_failed\n');
    process.exitCode = 64;
  }
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  await main();
}
