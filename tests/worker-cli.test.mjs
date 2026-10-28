// No npm packages, containers, network access, credentials, or model calls.
import assert from 'node:assert/strict';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import test from 'node:test';
import { validateWorkerArgs } from '../docker/worker-cli.mjs';

const required = ['--print', '--mode', 'json', '--no-session', '--no-extensions', '--no-skills',
  '--no-prompt-templates', '--no-themes', '--no-context-files', '--offline',
  '--provider', 'task-proxy', '--model', 'fixed-model'];
const valid = [...required, '--tools', 'read,write', '@/work/task.md'];

test('version is a separate probe and cannot carry execution arguments', () => {
  assert.doesNotThrow(() => validateWorkerArgs(['--version']));
  assert.throws(() => validateWorkerArgs(['--version', '@/work/task.md']));
  assert.throws(() => validateWorkerArgs([...valid, '--version']));
});

test('single-task mode accepts only explicit task configuration', () => {
  assert.doesNotThrow(() => validateWorkerArgs(valid));
  assert.doesNotThrow(() => validateWorkerArgs([...required, '--extension', '/fixed/academic.mjs',
    '--skill', '/fixed/one/SKILL.md', '--skill', '/fixed/two/SKILL.md', 'one plain prompt']));
});

for (const flag of ['--print', '--no-session', '--no-extensions', '--no-skills', '--no-prompt-templates',
  '--no-themes', '--no-context-files', '--offline']) {
  test('rejects omitted isolation option ' + flag, () => {
    assert.throws(() => validateWorkerArgs(valid.filter(value => value !== flag)));
  });
}

for (const arguments_ of [[], ['@/work/task.md'], [...required], [...valid, 'second prompt'],
  [...required, '--mode', 'rpc', 'prompt'], [...required, '--session', '/private/session', 'prompt'],
  [...required, '--continue', 'prompt'], [...required, '--resume', 'prompt'],
  [...required, '--print', 'prompt'], [...required, '--tools', '--session', 'prompt'],
  [...required, '--extension', '', 'prompt'], [...required, '--', 'prompt'],
  [...required, 'prompt', '--tools', 'bash'], [...required, '--unknown-secret-token', 'prompt'],
  [...required.map(value => value === 'json' ? 'text' : value), 'prompt']]) {
  test('rejects malformed or stateful request ' + JSON.stringify(arguments_), () => {
    assert.throws(() => validateWorkerArgs(arguments_));
  });
}

function fixture(context, { version = '0.99.2', packageName = '@earendil-works/pi-coding-agent' } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'pi-cage-worker-test-'));
  context.after(() => rmSync(root, { recursive: true, force: true }));
  const entry = join(root, 'lib', 'pi-cage', 'worker-cli.mjs');
  const pkg = join(root, 'lib', 'node_modules', '@earendil-works', 'pi-coding-agent');
  mkdirSync(dirname(entry), { recursive: true });
  mkdirSync(join(pkg, 'dist'), { recursive: true });
  cpSync(new URL('../docker/worker-cli.mjs', import.meta.url), entry);
  writeFileSync(join(pkg, 'package.json'), JSON.stringify({ name: packageName, version, type: 'module' }));
  const cli = join(pkg, 'dist', 'cli.js');
  writeFileSync(cli, `
    import { writeFileSync } from 'node:fs';
    writeFileSync(${JSON.stringify(join(root, 'cli-invoked'))}, 'yes');
    if (process.argv.length === 3 && process.argv[2] === '--version') console.log('0.99.2');
    else console.log(JSON.stringify({type:'fixture_invocation', argv:process.argv.slice(2),
      entry:process.argv[1], offline:process.env.PI_OFFLINE, skipVersion:process.env.PI_SKIP_VERSION_CHECK}));
  `);
  const spawn = (args, nodeArgs = []) => spawnSync(process.execPath, [...nodeArgs, entry, ...args], {
    encoding: 'utf8', timeout: 10000,
    env: { ...process.env, NODE_OPTIONS: '', NODE_PATH: '',
      PI_CAGE_CLI: join(root, 'wrong-entry.mjs'), PI_PACKAGE: 'wrong-package' },
  });
  return { root, entry, cli, spawn };
}

test('fixed relative CLI receives the exact task without spawning an intermediary', context => {
  const f = fixture(context);
  const result = f.spawn(valid);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, '');
  assert.deepEqual(JSON.parse(result.stdout), { type: 'fixture_invocation', argv: valid,
    entry: f.cli, offline: '1', skipVersion: '1' });
});

test('version really starts the fixed installed CLI', context => {
  const f = fixture(context);
  const result = f.spawn(['--version']);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, '0.99.2\n');
  assert.equal(readFileSync(join(f.root, 'cli-invoked'), 'utf8'), 'yes');
});

test('controller explicit --import stays in the same CLI process', context => {
  const f = fixture(context);
  const preload = join(f.root, 'trusted-preload.mjs');
  writeFileSync(preload, `const write = process.stdout.write.bind(process.stdout);
    process.stdout.write = chunk => write(JSON.stringify({preloaded:true, event:JSON.parse(chunk)}) + '\\n');`);
  const result = f.spawn(valid, ['--import', pathToFileURL(preload).href]);
  assert.equal(result.status, 0, result.stderr);
  const wrapped = JSON.parse(result.stdout);
  assert.equal(wrapped.preloaded, true);
  assert.deepEqual(wrapped.event.argv, valid);
});

test('invalid request fails before loading the CLI and redacts its arguments', context => {
  const f = fixture(context);
  const result = f.spawn([...required, '--session', 'private-token-value', 'prompt']);
  assert.equal(result.status, 64);
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, 'pi-cage: worker_start_failed\n');
  assert.throws(() => readFileSync(join(f.root, 'cli-invoked')));
});

for (const values of [{ version: '0.73.1' }, { packageName: '@mariozechner/pi-coding-agent' }]) {
  test('installed package drift fails before the CLI: ' + JSON.stringify(values), context => {
    const f = fixture(context, values);
    const result = f.spawn(valid);
    assert.equal(result.status, 64);
    assert.equal(result.stdout, '');
    assert.equal(result.stderr, 'pi-cage: worker_start_failed\n');
    assert.throws(() => readFileSync(join(f.root, 'cli-invoked')));
  });
}

test('build metadata identifies the repository, exact package, and installed entry', async context => {
  const f = fixture(context);
  const module = await import(pathToFileURL(f.entry).href);
  const revision = 'abc12345'.repeat(5);
  assert.deepEqual(module.runtimeMetadata(revision), { schema_version: 1,
    repository: 'https://github.com/zmhhaha/pi-cage', revision,
    package: '@earendil-works/pi-coding-agent', version: '0.99.2',
    entrypoint: '/usr/local/lib/pi-cage/worker-cli.mjs' });
  assert.equal(module.runtimeMetadata(null).revision, null);
  for (const revision of ['', 'main', 'edee89d', 'A'.repeat(40), 'a'.repeat(41), 123]) {
    assert.throws(() => module.runtimeMetadata(revision));
  }
  assert.throws(() => readFileSync(join(f.root, 'cli-invoked')));
});
