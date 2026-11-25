#!/usr/bin/env python3
"""Build the application once and run the four restored-provider review suites.

Uses the installed macOS SDK and Python standard library only. No downloads.
Run from any directory: python3 <repository>/desktop/native/test-provider-review.py
"""
from pathlib import Path
import datetime
import hashlib
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import tempfile
import time

NATIVE = Path(__file__).resolve().parent
REPOSITORY = NATIVE.parent.parent
TESTS = NATIVE / 'tests' / 'provider-review'
MODULE = 'NextCRMR2Integrated'
TARGET = 'arm64-apple-macos13.0'
C_NAMES = ['CampaignHTML', 'NativeMailTransport', 'NativePluginsHTTP', 'NativeRestoreHostBridge']
CASES = [
    ('smtp', ['SMTPReviewTests.swift'], r'Restored SMTP review: (\d+) checks passed', 52),
    ('google-review', ['PersonalGoogleRestoredReviewTests.swift'], r'Personal Google restored review: (\d+) checks passed', 45),
    ('google-hold', ['ExistingGooglePushSupport.swift', 'HoldTests.swift'], r'"checks"\s*:\s*(\d+)', 61),
    ('prior-resend-review', ['PersonalRunningReviewTests.swift'], r'Personal running review: (\d+) checks passed', 275),
]
SEED_MODELS = ['crm_Industry_Type', 'crm_Contact_Types', 'crm_Lead_Sources', 'crm_Lead_Statuses',
               'crm_Lead_Types', 'crm_Opportunities_Sales_Stages', 'crm_Opportunities_Type']


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def application_sources():
    names = json.loads((NATIVE / 'ApplicationSources.json').read_text())
    if not isinstance(names, list) or not names or len(names) != len(set(names)):
        raise ValueError('ApplicationSources.json must be a nonempty ordered list of unique Swift filenames')
    for name in names:
        if not isinstance(name, str) or Path(name).name != name or not name.endswith('.swift'):
            raise ValueError('ApplicationSources.json must contain filenames inside desktop/native')
        if not (NATIVE / name).is_file():
            raise FileNotFoundError(NATIVE / name)
    return [NATIVE / name for name in names]


def stop_owned_process(process):
    # Only this runner's new process group. Join it before removing its files.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def main():
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('This verified test target requires Apple Silicon macOS and an installed macOS developer SDK.')
    for tool in ['xcrun', 'swiftc', 'getconf']:
        if shutil.which(tool) is None:
            raise SystemExit('Required installed tool is unavailable: ' + tool)
    if not Path('/usr/bin/sandbox-exec').is_file():
        raise SystemExit('The test sandbox is unavailable; tests will not run without it.')

    sources = application_sources()  # Preserve the application's declared order.
    inputs = sources + [Path(__file__), NATIVE / 'ApplicationSources.json', NATIVE / 'schema.json', NATIVE / 'schema.sql']
    inputs += [NATIVE / (name + suffix) for name in C_NAMES for suffix in ['.c', '.h']]
    inputs += [NATIVE / 'NativeBridges.h', NATIVE / 'NativeMailParsing.h']
    inputs += sorted(TESTS.rglob('*.swift')) + sorted(TESTS.rglob('*.json'))
    inputs += [REPOSITORY / 'prisma' / 'initial-data' / (name + '.json') for name in SEED_MODELS]
    before = {str(path.relative_to(REPOSITORY)): digest(path) for path in inputs}

    parent = NATIVE / 'build' / 'provider-review-tests'
    parent.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ-'), dir=parent))
    cache = output / 'module-cache'
    core = output / 'core'
    core.mkdir()
    env = {key: value for key, value in os.environ.items() if not key.startswith('NEXTCRM_')}
    phases = []
    proof = {'complete': False, 'sourceCount': len(sources), 'checks': 0, 'expectedChecks': 433,
             'phases': phases, 'inputsSHA256': before, 'normalData': False, 'externalNetwork': False,
             'realKeychain': False, 'target': TARGET, 'optimization': 'Onone WMO; behavior test, not a performance measurement',
             'scope': 'Actual synthetic SQLite/Backup/Restore/owner binding/quarantine and AppKit controls; fake provider transports. Synthetic activation journals, not App/IPC launch or live provider verification.'}
    started = time.monotonic()
    owned_fixtures = []

    def run(label, command, log, *, timeout=600, run_env=None):
        tick = time.monotonic()
        with log.open('a') as stream:
            process = subprocess.Popen(command, env=env if run_env is None else run_env,
                                       stdout=stream, stderr=subprocess.STDOUT, start_new_session=True, umask=0o077)
            try:
                code = process.wait(timeout=timeout)
            except BaseException:
                stop_owned_process(process)
                raise
        phase = {'name': label, 'exit': code, 'seconds': round(time.monotonic() - tick, 2)}
        phases.append(phase)
        print(json.dumps(phase), flush=True)
        if code:
            print('\n'.join(log.read_text(errors='replace').splitlines()[-12:]), flush=True)
            raise RuntimeError(label + ' failed; see ' + str(log.relative_to(REPOSITORY)))

    try:
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True, env=env).strip()
        objects = []
        for name in C_NAMES:
            target = core / (name + '.o')
            run(name, ['xcrun', 'clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                       '-target', TARGET, '-isysroot', sdk, '-I', sdk + '/usr/include/libxml2',
                       '-c', str(NATIVE / (name + '.c')), '-o', str(target)], core / 'build.log')
            objects.append(target)
        library = core / ('lib' + MODULE + '.dylib')
        command = ['swiftc', '-swift-version', '5', '-parse-as-library', '-Onone', '-whole-module-optimization',
                   '-enable-testing', '-emit-library', '-emit-module', '-module-name', MODULE,
                   '-emit-module-path', str(core / (MODULE + '.swiftmodule')), '-target', TARGET,
                   '-module-cache-path', str(cache), '-D', 'PERSONAL_APP_HOST', '-D', 'RESTORE_APP_HOST',
                   '-D', 'PERSONAL_PROVIDER_REVIEW_TESTING', '-import-objc-header', str(NATIVE / 'NativeBridges.h'),
                   '-framework', 'Security', '-framework', 'AppKit', '-framework', 'CoreText',
                   '-framework', 'LocalAuthentication', '-lsqlite3', '-lxml2', '-lcurl']
        command += [str(path) for path in sources + objects] + ['-o', str(library)]
        write_json(core / 'command.json', command)
        run('application-test-core', command, core / 'build.log')
        library_hash = digest(library)
        proof['librarySHA256'] = library_hash
        proof['libraryBytes'] = library.stat().st_size
        if any(digest(REPOSITORY / path) != value for path, value in before.items()):
            raise RuntimeError('Inputs changed during compilation; rerun on a stable checkout.')

        temporary_root = Path(subprocess.check_output(['getconf', 'DARWIN_USER_TEMP_DIR'], text=True, env=env).strip()).resolve()
        q = lambda path: json.dumps(str(path))
        profile = output / 'sandbox.sb'
        profile.write_text('(version 1)\n(allow default)\n(deny file-write*)\n'
            '(allow file-write* (subpath ' + q(output) + ') (subpath ' + q(temporary_root) + ') (subpath "/dev/fd") (literal "/dev/null"))\n'
            '(deny file-read* (subpath ' + q(Path.home() / 'Library/Keychains') + ')'
            ' (subpath ' + q(Path.home() / 'Library/Application Support/NextCRMNative') + ')'
            ' (subpath ' + q(Path.home() / 'Library/Application Support/NextCRM') + '))\n'
            '(deny mach-lookup (global-name "com.apple.securityd"))\n(deny network*)\n')
        for name, filenames, pattern, expected in CASES:
            case_output = output / name
            case_output.mkdir()
            binary = case_output / 'Tests'
            command = ['swiftc', '-swift-version', '5', '-parse-as-library', '-Onone', '-target', TARGET,
                       '-module-cache-path', str(cache), '-I', str(core), '-L', str(core), '-l' + MODULE,
                       '-Xlinker', '-rpath', '-Xlinker', str(core), '-import-objc-header', str(NATIVE / 'NativeBridges.h'),
                       '-framework', 'AppKit', '-framework', 'Security', '-framework', 'CoreText',
                       '-framework', 'LocalAuthentication', '-lsqlite3', '-lxml2', '-lcurl']
            command += [str(TESTS / file) for file in filenames] + ['-o', str(binary)]
            log = case_output / 'test.log'
            write_json(case_output / 'command.json', command)
            run(name + '-compile', command, log, timeout=240)
            with tempfile.TemporaryDirectory(prefix='NextCRMProviderReview-', dir=temporary_root) as folder:
                fixture = Path(folder).resolve()
                owned_fixtures.append(fixture)
                os.chmod(fixture, 0o700)
                test_env = dict(env, TMPDIR=str(fixture) + os.sep)
                run(name + '-run', ['/usr/bin/sandbox-exec', '-f', str(profile), str(binary), str(NATIVE), str(fixture)],
                    log, timeout=240, run_env=test_env)
            matches = re.findall(pattern, log.read_text())
            if not matches or int(matches[-1]) != expected:
                raise RuntimeError(name + ' did not report its expected ' + str(expected) + ' checks')
            proof['checks'] += expected
            print(json.dumps({'case': name, 'checks': expected}), flush=True)
        run('standalone-database-typecheck', ['swiftc', '-swift-version', '5', '-parse-as-library', '-typecheck',
            '-target', TARGET, '-module-cache-path', str(cache), str(NATIVE / 'NativeDatabase.swift'),
            str(NATIVE / 'MailReview.swift')], output / 'database.log', timeout=240)
        proof['snapshotUnchanged'] = all(digest(REPOSITORY / path) == value for path, value in before.items())
        if not proof['snapshotUnchanged'] or digest(library) != library_hash or proof['checks'] != 433:
            raise RuntimeError('Inputs, library, or expected check total changed.')
        proof['complete'] = True
    except BaseException as error:
        proof['error'] = type(error).__name__ + ': ' + str(error)
    finally:
        if cache.exists():
            shutil.rmtree(cache)
        proof['moduleCacheRemoved'] = not cache.exists()
        proof['fixturesRemoved'] = all(not path.exists() for path in owned_fixtures)
        proof['seconds'] = round(time.monotonic() - started, 2)
        write_json(output / 'verification.json', proof)
        write_json(parent / 'latest.json', {'path': str((output / 'verification.json').relative_to(REPOSITORY))})
        print(json.dumps({key: proof[key] for key in ['complete', 'sourceCount', 'checks', 'seconds', 'moduleCacheRemoved', 'fixturesRemoved', 'error'] if key in proof}), flush=True)
        print('Logs and build artifacts: ' + str(output.relative_to(REPOSITORY)), flush=True)
    return 0 if proof['complete'] and proof['moduleCacheRemoved'] and proof['fixturesRemoved'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
