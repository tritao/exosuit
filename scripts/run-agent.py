#!/usr/bin/env python3
"""POSIX catalog daemon manager: private discovery, lifetime lock and durable storage."""
import argparse
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import selectors
import signal
import socket
import stat
import subprocess
import sys
import time
import urllib.parse

os.environ.setdefault("EXOSUIT_CODEX_PROXY_LAUNCHER", str(Path(__file__).resolve().with_name("run-codex-proxy.py")))

REPO = Path(__file__).resolve().parent.parent


def agent_build_id():
    """Content identity, including dirty sources; unrelated UI edits do not force service updates."""
    digest = hashlib.sha256()
    manager_path = Path(__file__).resolve()
    paths = [REPO / 'agent/haxeon.json', REPO / 'haxeon.json', REPO / 'release.lock', manager_path,
             manager_path.with_name('run-codex-proxy.py')]
    for base in [REPO / 'agent/src', REPO / 'src', REPO / 'native-packages',
                 REPO / 'haxeon/vendor/nativekit/src', REPO / 'haxeon/vendor/nativekit/include',
                 REPO / 'haxeon/stdlib/haxeon/rpc']:
        for directory, names, files in os.walk(base):
            names[:] = sorted(name for name in names if name not in ('build', 'out', 'vendor', '.git', '__pycache__'))
            paths.extend(Path(directory) / name for name in sorted(files)
                         if Path(name).suffix in ('.hx', '.c', '.h', '.cpp', '.json') or name == 'CMakeLists.txt')
    bundled = Path(__file__).resolve().with_name('exosuit-agent.hl')
    if bundled.is_file():
        paths.append(bundled)
        paths.extend([manager_path.with_name('exosuit-agent'), manager_path.with_name('hl')])
        paths.extend(path for path in (REPO / 'lib').glob('*') if path.is_file() and not path.is_symlink())
    for path in sorted(set(paths)):
        if path.is_file():
            digest.update(str(path.relative_to(REPO)).encode())
            digest.update(b'\0')
            digest.update(path.read_bytes())
    return digest.hexdigest()


def prepare_update(directory, root):
    """A failed build must leave the existing daemon and its sessions alive."""
    if not Path(__file__).resolve().with_name('exosuit-agent').is_file():
        toolchain = Path(os.environ.get('HAXEON_ROOT', str(REPO / 'haxeon')))
        compiler = os.environ.get('HAXEON_BIN', str(toolchain / 'scripts/haxeon'))
        mode = ['--self-hosted'] if os.environ.get('HAXEON_SELF_HOSTED') == '1' else []
        log_path = directory / 'update-build.log'
        fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        private_file(log_path)
        with os.fdopen(fd, 'wb') as output:
            result = subprocess.run([compiler, 'build', '--project', str(REPO / 'agent/haxeon.json'), *mode],
                                    cwd=root, stdout=output, stderr=subprocess.STDOUT, timeout=90)
        if result.returncode != 0:
            raise RuntimeError('Workspace update build failed; existing sessions are unchanged. Inspect update-build.log')


def stop_legacy_manager(directory, root, expected_generation):
    descriptor = read_discovery(directory, root)
    if descriptor['generation'] != expected_generation:
        raise RuntimeError('Workspace service changed; refresh before restarting')
    pid = descriptor['managerPid']
    pidfd = os.pidfd_open(pid)
    try:
        arguments = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
        if (not any(Path(os.fsdecode(argument)).name == 'run-agent.py' for argument in arguments if argument)
                or os.fsencode(root) not in arguments):
            raise RuntimeError('Workspace manager process identity could not be verified')
        current = read_discovery(directory, root)
        if current['generation'] != expected_generation or current['managerPid'] != pid:
            raise RuntimeError('Workspace service changed before restart')
        signal.pidfd_send_signal(pidfd, signal.SIGTERM)
        deadline = time.monotonic() + 15
        while (directory / 'endpoint.json').exists():
            if time.monotonic() >= deadline:
                raise RuntimeError('Workspace service did not finish stopping')
            time.sleep(0.05)
    finally:
        os.close(pidfd)


def private_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_nlink != 1:
        raise RuntimeError(f"Expected a private owned regular file: {path}")
    return info


def atomic_json(path, value):
    temporary = path.with_name(path.name + '.' + secrets.token_hex(8))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'w') as output:
            json.dump(value, output)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def make_relay_bootstrap(directory):
    origin = os.environ.get('EXOSUIT_RELAY_ORIGIN')
    saved = directory / 'relay-settings.json'
    if not origin and saved.exists():
        private_file(saved)
        if saved.stat().st_size > 4096:
            raise RuntimeError('Relay settings exceed limit')
        origin = json.loads(saved.read_text()).get('origin')
    if not origin:
        return None
    origin = validate_relay_origin(origin)
    identity_path = directory / 'relay-machine.json'
    if identity_path.exists() or identity_path.is_symlink():
        private_file(identity_path)
        value = json.loads(identity_path.read_text())
        if not isinstance(value, dict):
            raise RuntimeError('Invalid workspace relay identity')
        machine_id = value.get('machineId')
        if value.get('version') != 1 or not isinstance(machine_id, str) or len(machine_id) != 32 or any(c not in '0123456789abcdef' for c in machine_id):
            raise RuntimeError('Invalid workspace relay identity')
    else:
        machine_id = secrets.token_hex(16)
        atomic_json(identity_path, {'version': 1, 'machineId': machine_id})
    bootstrap = directory / 'relay-bootstrap.json'
    if bootstrap.exists() or bootstrap.is_symlink():
        private_file(bootstrap)
        bootstrap.unlink()
    atomic_json(bootstrap, {
        'version': 1,
        'origin': origin,
        'machineId': machine_id,
        'bootstrapToken': secrets.token_hex(32),
    })
    return bootstrap


def validate_relay_origin(origin):
    if not isinstance(origin, str) or len(origin) > 2048:
        raise RuntimeError('Enter an HTTPS relay address')
    value = origin.strip().rstrip('/')
    parsed = urllib.parse.urlsplit(value)
    try:
        port = parsed.port
    except ValueError:
        raise RuntimeError('Invalid relay port')
    loopback = parsed.hostname in ('localhost', '127.0.0.1')
    if (not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment
            or parsed.path or (port is not None and not 1 <= port <= 65535)
            or (parsed.scheme != 'https' and not (parsed.scheme == 'http' and loopback
                and os.environ.get('EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP') == '1'))):
        raise RuntimeError('Enter an HTTPS relay origin without a path, credentials or query')
    return value


# Permanent ids for the native client's typed helper output; endpoint.json remains human-readable.
DISCOVERY_FIELDS = ['version', 'protocol', 'codec', 'workspace', 'root', 'managerPid', 'generation', 'socket', 'websocket', 'credentialFile', 'expectedBuild']


def emit_discovery(value, wire):
    value = dict(value, expectedBuild=agent_build_id())
    if wire:
        value = {'version': 1, 'value': [[f'{index}:{name}', value[name]] for index, name in enumerate(DISCOVERY_FIELDS, 1)]}
    print(json.dumps(value), flush=True)


def read_discovery(directory, root):
    endpoint = directory / 'endpoint.json'
    info = private_file(endpoint)
    if info.st_size > 16384:
        raise RuntimeError('Workspace descriptor exceeds limit')
    value = json.loads(endpoint.read_text())
    if not isinstance(value, dict) or any(type(value.get(key)) is not int or value[key] != 1 for key in ['version', 'protocol', 'codec']):
        raise RuntimeError('Unsupported workspace descriptor')
    if value.get('root') != str(root) or value.get('workspace') != 'workspace':
        raise RuntimeError('Workspace descriptor identity mismatch')
    generation = value.get('generation')
    if not isinstance(generation, str) or len(generation) != 32 or any(c not in '0123456789abcdef' for c in generation):
        raise RuntimeError('Invalid workspace descriptor generation')
    if type(value.get('managerPid')) is not int or value['managerPid'] <= 0:
        raise RuntimeError('Invalid workspace descriptor PID')
    if value.get('socket') != str(directory / 'agent.sock') or value.get('credentialFile') != str(directory / 'credential'):
        raise RuntimeError('Workspace descriptor path mismatch')
    private_file(directory / 'credential')
    identity = directory / 'workspace.json'
    if private_file(identity).st_size > 16384 or json.loads(identity.read_text()) != {'version': 1, 'root': str(root)}:
        raise RuntimeError('Workspace state directory identity mismatch')
    address = urllib.parse.urlparse(value.get('websocket', ''))
    if address.scheme != 'ws' or address.hostname != '127.0.0.1' or address.port is None or not 1 <= address.port <= 65535 or address.path != '/workspace' or address.username is not None or address.query or address.fragment:
        raise RuntimeError('Invalid workspace loopback endpoint')
    return value


def adopt_children():
    # Linux reparenting lets the manager reap launcher descendants before returning.
    # Waiting for an independently acquired database lock alone is insufficient:
    # the kernel may close that fd before the inherited lifetime-lock fd.
    if sys.platform.startswith('linux'):
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
            raise OSError(ctypes.get_errno(), 'Could not enable daemon child reaping')


def stop(process):
    # The build-tool launcher and its HashLink child belong to the same group.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    finally:
        # The launcher can exit before its child. Retire the whole owned group,
        # including children still holding inherited locks, then reap the launcher.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)
        if sys.platform.startswith('linux'):
            # SIGKILL has retired the owned group; reap any adopted descendants.
            while True:
                try:
                    os.waitpid(-process.pid, 0)
                except ChildProcessError:
                    break


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workspace', type=Path)
    parser.add_argument('--state-dir', type=Path)
    parser.add_argument('--wire', action='store_true', help='Emit typed JsonWire discovery output for native clients')
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--idle-seconds', type=int, default=60, help='Stop after this many seconds without authenticated clients (default: 60)')
    parser.add_argument('--always-available', action='store_true', default=os.environ.get('EXOSUIT_AGENT_ALWAYS_AVAILABLE') == '1', help='Keep the service running without clients for remote availability')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--discover', action='store_true', help='Read private discovery hints without launching or trusting daemon identity')
    modes.add_argument('--detach', action='store_true', help='Wait for discovery readiness, then leave the manager running')
    modes.add_argument('--configure-relay', metavar='ORIGIN', help='Enable remote access on the running workspace without restarting sessions')
    modes.add_argument('--prepare-update', action='store_true', help='Build an update while the current service keeps running')
    modes.add_argument('--restart', action='store_true', help='Explicitly restart a legacy daemon; terminates its active sessions')
    parser.add_argument('--expected-generation', help='Guard an explicit restart against a changed service instance')
    args = parser.parse_args()
    root = args.workspace.resolve(strict=True)
    if not root.is_dir() or not 0 <= args.port <= 65535 or not 1 <= args.idle_seconds <= 86400:
        raise RuntimeError('Expected a workspace directory, a valid port and idle seconds in 1..86400')
    os.umask(0o077)
    key = hashlib.sha256(os.fsencode(root)).hexdigest()[:20]
    base = Path(os.environ.get('XDG_STATE_HOME', Path.home() / '.local/state'))
    directory = args.state_dir.absolute() if args.state_dir else base / 'exosuit/workspaces' / key
    if args.discover and not directory.exists():
        return 4
    if not args.discover:
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError('Workspace state directory must be private and owned by this user')
    endpoint = directory / 'endpoint.json'
    if args.prepare_update or args.restart:
        descriptor = read_discovery(directory, root)
        prepare_update(directory, root)
        if args.prepare_update:
            emit_discovery(descriptor, args.wire)
            return 0
        if not args.expected_generation:
            raise RuntimeError('Restart requires the expected service generation')
        stop_legacy_manager(directory, root, args.expected_generation)
        args.restart = False
        args.detach = True
    if args.configure_relay is not None:
        origin = validate_relay_origin(args.configure_relay)
        descriptor = read_discovery(directory, root)
        saved = directory / 'relay-settings.json'
        if saved.exists():
            private_file(saved)
            if json.loads(saved.read_text()).get('origin') != origin:
                raise RuntimeError('This workspace already has a relay configured')
        atomic_json(saved, {'version': 1, 'origin': origin})
        os.environ['EXOSUIT_RELAY_ORIGIN'] = origin
        make_relay_bootstrap(directory)
        emit_discovery(descriptor, args.wire)
        return 0
    if args.discover:
        try:
            emit_discovery(read_discovery(directory, root), args.wire)
            return 0
        except FileNotFoundError:
            return 4
    if args.detach:
        command = [sys.executable, str(Path(__file__).resolve()), str(root), '--state-dir', str(directory), '--port', str(args.port)]
        command.extend(['--idle-seconds', str(args.idle_seconds)])
        if args.always_available:
            command.append('--always-available')
        # Discovery must belong to this manager, not a stale descriptor from an earlier launch.
        log_path = directory / 'manager.log'
        fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        private_file(log_path)
        with os.fdopen(fd, 'ab') as log:
            manager = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if manager.poll() is not None:
                return manager.returncode
            try:
                private_file(endpoint)
                descriptor = json.loads(endpoint.read_text())
                if descriptor['managerPid'] == manager.pid:
                    emit_discovery(descriptor, args.wire)
                    return 0
            except (FileNotFoundError, KeyError, ValueError):
                pass
            time.sleep(0.05)
        stop(manager)
        raise RuntimeError('Timed out starting workspace daemon; inspect manager.log')
    lock_path = directory / 'agent.lock'
    lock = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    private_file(lock_path)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(lock)
        print('workspace_in_use: another manager owns this workspace state', file=sys.stderr)
        return 3
    adopt_children()
    child = None
    relay_bootstrap = None
    generation = secrets.token_hex(16)
    stopping = False
    restarting = False

    def request_stop(*_):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    try:
        identity = directory / 'workspace.json'
        if identity.exists() or identity.is_symlink():
            private_file(identity)
            if json.loads(identity.read_text()) != {'version': 1, 'root': str(root)}:
                raise RuntimeError('Workspace state directory identity mismatch')
        else:
            atomic_json(identity, {'version': 1, 'root': str(root)})
        endpoint.unlink(missing_ok=True)
        credential = directory / 'credential'
        if credential.exists() or credential.is_symlink():
            private_file(credential)
            token = credential.read_text()
            if len(token) != 64 or any(c not in '0123456789abcdef' for c in token):
                raise RuntimeError('Invalid session credential')
        else:
            fd = os.open(credential, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'w') as output:
                output.write(secrets.token_hex(32))
                output.flush()
                os.fsync(output.fileno())
        relay_bootstrap = make_relay_bootstrap(directory)
        database = directory / 'catalog.sqlite'
        for path in [database, directory / 'catalog.sqlite-wal', directory / 'catalog.sqlite-shm', directory / 'catalog.sqlite.sqlitekit-lock']:
            if path.exists() or path.is_symlink():
                private_file(path)
        address = directory / 'agent.sock'
        if len(os.fsencode(address)) > 100:
            raise RuntimeError('State directory path is too long for a local socket; use --state-dir')
        port = args.port
        if port == 0:
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0))
                port = probe.getsockname()[1]
        haxeon_root = Path(os.environ.get('HAXEON_ROOT', str(REPO / 'haxeon'))).resolve()
        haxeon = os.environ.get('HAXEON_BIN', str(haxeon_root / 'scripts/haxeon'))
        compiler_mode = ['--self-hosted'] if os.environ.get('HAXEON_SELF_HOSTED') == '1' else []
        os.environ['EXOSUIT_AGENT_BUILD_ID'] = agent_build_id()
        os.environ['EXOSUIT_AGENT_MANAGED_UPDATES'] = '1'
        daemon_args = [str(address), str(port), str(credential), secrets.token_hex(16), str(database), str(root), generation, str(0 if args.always_available else args.idle_seconds * 1000)]
        if relay_bootstrap is not None:
            daemon_args.append(str(relay_bootstrap))
        bundled_runner = Path(__file__).resolve().with_name('exosuit-agent')
        if bundled_runner.is_file():
            command = [str(bundled_runner), *daemon_args]
        else:
            # Compiler workers may outlive the build and start their own session.
            # Never expose the workspace lifetime lock to the build process tree.
            child = subprocess.Popen([haxeon, 'build', '--project', str(REPO / 'agent/haxeon.json'), *compiler_mode], cwd=root, start_new_session=True)
            deadline = time.monotonic() + 90
            while child.poll() is None:
                if stopping:
                    return 0
                if time.monotonic() >= deadline:
                    raise RuntimeError('Workspace daemon build timed out')
                time.sleep(0.05)
            if child.returncode != 0:
                raise RuntimeError(f'Workspace daemon build failed with status {child.returncode}')
            child = None
            output = REPO / 'agent/build/host'
            libraries = [haxeon_root / 'out', haxeon_root / '.tools/hashlink']
            libraries.extend(sorted(path for path in (output / 'native').iterdir() if path.is_dir()))
            existing = os.environ.get('LD_LIBRARY_PATH')
            os.environ['LD_LIBRARY_PATH'] = ':'.join(str(path) for path in libraries) + (':' + existing if existing else '')
            command = [str(haxeon_root / '.tools/hashlink/hl'), str(output / 'main.hl'), *daemon_args]
        # The child inherits the lifetime lock: killing the manager alone cannot unlock a live daemon.
        child = subprocess.Popen(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True, pass_fds=(lock,))
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + 90
            pending = b''
            ready = False
            database_identity = None
            idle_shutdown = False
            update_shutdown = False
            while not stopping:
                for event, _ in selector.select(0.1):
                    chunk = os.read(event.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(event.fileobj)
                    pending += chunk
                    if len(pending) > 1048576:
                        raise RuntimeError('Workspace daemon output line exceeds limit')
                    while b'\n' in pending:
                        line, pending = pending.split(b'\n', 1)
                        print(line.decode(errors='replace'), flush=True)
                        if line == b'STOPPED: exosuit-agent idle':
                            idle_shutdown = True
                        if line == b'STOPPED: exosuit-agent update':
                            update_shutdown = True
                        if line.startswith(b'READY: exosuit-agent') and not ready:
                            info = private_file(database)
                            database_identity = (info.st_dev, info.st_ino)
                            descriptor = {'version': 1, 'protocol': 1, 'codec': 1, 'workspace': 'workspace', 'root': str(root), 'managerPid': os.getpid(), 'generation': generation, 'socket': str(address), 'websocket': f'ws://127.0.0.1:{port}/workspace', 'credentialFile': str(credential)}
                            atomic_json(endpoint, descriptor)
                            emit_discovery(descriptor, args.wire)
                            ready = True
                if child.poll() is not None:
                    if child.returncode == 0 and update_shutdown:
                        restarting = True
                        break
                    if child.returncode == 0 and idle_shutdown:
                        return 0
                    raise RuntimeError(f'Workspace daemon exited with status {child.returncode}')
                if not ready and time.monotonic() >= deadline:
                    raise RuntimeError('Workspace daemon did not become ready')
                if ready:
                    info = private_file(database)
                    if (info.st_dev, info.st_ino) != database_identity:
                        raise RuntimeError('Workspace database was replaced; stopping the daemon')
        if not restarting:
            return 0
    finally:
        try:
            if child is not None:
                stop(child)
                # The agent owns this independently acquired lock until process exit.
                # Waiting for it prevents reporting a completed stop while a child
                # still holds the inherited workspace lock.
                database_lock = directory / 'catalog.sqlite.sqlitekit-lock'
                if database_lock.exists():
                    fd = os.open(database_lock, os.O_RDWR | os.O_NOFOLLOW)
                    try:
                        deadline = time.monotonic() + 5
                        while True:
                            try:
                                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                                break
                            except BlockingIOError:
                                if time.monotonic() >= deadline:
                                    raise RuntimeError('Daemon database lock remained held after stop')
                                time.sleep(0.01)
                    finally:
                        os.close(fd)
        finally:
            if relay_bootstrap is not None:
                relay_bootstrap.unlink(missing_ok=True)
            try:
                if json.loads(endpoint.read_text()).get('generation') == generation:
                    endpoint.unlink()
            except (FileNotFoundError, ValueError):
                pass
            os.close(lock)
    # A fresh manager reopens the durable catalog with the replacement build.
    # The lifetime lock and old descriptor have been released before exec.
    os.execv(sys.executable, [sys.executable, *sys.argv])


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(f'Workspace startup failed: {error}', file=sys.stderr)
        sys.exit(1)
