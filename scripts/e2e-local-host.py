#!/usr/bin/env python3
"""The relay side of the local end-to-end rig (scripts/e2e-local.ps1): a local CA, the Worker and a TLS front.

  e2e-local-host.py start --out DIR [--relay-port N] [--tls-port N] [--lifetime SECONDS]
  e2e-local-host.py stop  --out DIR

`start` stays in the foreground until DIR/stop appears or the lifetime runs out (--lifetime 0: never). The CA, the server
certificate (both valid for ten years), the Worker's Durable Object state (DIR/wrangler-state) and the two ports (DIR/ports.json)
are kept between starts: a phone paired once keeps working against the next start. Delete DIR to start over. Everything lives under DIR; nothing
here reads or writes the user's real state, and no private key leaves DIR (never commit DIR). It starts:

- a development CA and a server certificate for localhost, 127.0.0.1 and 10.0.2.2 (openssl on PATH, or the one from Git for Windows). DIR/tls/ca.pem is the public CA (the phone and any dev client trust it); the keys stay in DIR/tls;
- the relay Worker (relay/worker) under `wrangler dev --local` (workerd, no Cloudflare login) on plain
  http://127.0.0.1:RELAY_PORT. The desktop (exohost, workspace service) reaches it there: the desktop's HTTPS client is
  WinHTTP with the Windows trust store, which has no development CA hook, and it already permits loopback http when
  EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP=1;
- scripts/e2e-tls-proxy.mjs, which serves the same Worker over https/wss on 127.0.0.1:TLS_PORT with the development
  certificate. The phone dials this one (through `adb reverse`), so its native TLS and platform HTTPS are exercised.

Both ports reach one Worker and one Durable Object store, so a machine, pairing or device made through one is seen by
the other. DIR/ready.json lists the ports, origins and pids. Build the Worker's tooling first: `npm ci` in relay/worker.
"""
import argparse
import json
import os
import platform
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
WRANGLER = ROOT / "relay" / "worker" / "node_modules" / "wrangler" / "bin" / "wrangler.js"
def workerd_package() -> str:
    if os.name == "nt":
        return "workerd-windows-64"
    if sys.platform == "darwin":
        return "workerd-darwin-arm64" if platform.machine() == "arm64" else "workerd-darwin-64"
    return "workerd-linux-arm64" if platform.machine() in ("aarch64", "arm64") else "workerd-linux-64"


WORKERD = ROOT / "relay" / "worker" / "node_modules" / "@cloudflare" / workerd_package()
LIFETIME_SECONDS = 40 * 60
CERTIFICATE_DAYS = "3650"
NO_WINDOW = (subprocess.CREATE_NO_WINDOW | subprocess.CREATE_NEW_PROCESS_GROUP) if os.name == "nt" else 0
# The browser origins the Worker allows for pairing pages (comma separated; --pairing-origin adds more for the local rig only);
# native clients (the phone, the desktop) send none.
PAIRING_ORIGIN = "http://localhost:5173"
SERVER_NAMES = "DNS:localhost,IP:127.0.0.1,IP:10.0.2.2"


class Log:
    def __init__(self, path: Path) -> None:
        self.file = path.open("a", encoding="utf-8")

    def __call__(self, event: str, **fields) -> None:
        line = json.dumps({"t": round(time.time(), 3), "event": event, **fields})
        print(line, flush=True)
        self.file.write(line + "\n")
        self.file.flush()


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def pid_alive(pid: int) -> bool:
    if os.name == "nt":
        output = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/NH"], capture_output=True, text=True, timeout=30,
                                creationflags=NO_WINDOW).stdout
        return f" {pid} " in output
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def names_rig(pid: int, directory: Path) -> bool:
    """POSIX: whether `pid` is still one of this rig's processes (a recorded pid may have been recycled since): its command line names
    the run folder (every process the rig starts carries it in its arguments)."""
    result = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True, timeout=30)
    command = result.stdout.strip()
    return bool(command) and str(directory) in command


def kill_tree(pid: int) -> None:
    if os.name == "nt":
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(pid)], capture_output=True, timeout=30, creationflags=NO_WINDOW)
    else:
        try:
            os.killpg(pid, 9)
        except OSError:
            pass


def kill_under(directory: Path) -> list[int]:
    """Belt and braces: the pids this rig recorded in DIR/pids.json (each its own process group on POSIX) that are still alive, except this one.
    Off Windows nothing is matched by command line; only processes this script started are touched."""
    if os.name != "nt":
        recorded = read_json(directory / "pids.json") or {}
        killed = []
        for pid in recorded.values():
            if isinstance(pid, int) and pid != os.getpid() and pid_alive(pid) and names_rig(pid, directory):
                kill_tree(pid)
                killed.append(pid)
        return killed
    marker = str(directory).replace("'", "''")
    # Never this process, its ancestors (a python launcher shim and the guard have the folder in their command line too), or another
    # e2e-local-host.py run (a `stop` names the folder as well).
    script = ("$all = Get-CimInstance Win32_Process; $skip = @{}; $id = " + str(os.getpid()) + "; "
              "while ($id -and -not $skip.ContainsKey($id)) { $skip[$id] = 1; $id = ($all | Where-Object ProcessId -eq $id).ParentProcessId }; "
              "$all | Where-Object { @('hl.exe','node.exe','workerd.exe','python.exe','python3.exe') -contains $_.Name -and $_.CommandLine -and "
              "$_.CommandLine.Contains('" + marker + "') -and -not $_.CommandLine.Contains('e2e-local-host') -and -not $skip.ContainsKey([int]$_.ProcessId) } | ForEach-Object { $_.ProcessId }")
    result = subprocess.run(["pwsh", "-NoProfile", "-NonInteractive", "-Command", script], capture_output=True, text=True, timeout=60,
                            creationflags=NO_WINDOW)
    killed = []
    for text in result.stdout.split():
        if text.isdigit() and int(text) != os.getpid():
            kill_tree(int(text))
            killed.append(int(text))
    return killed


def write_json(path: Path, value) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2), encoding="utf-8")
    os.replace(temporary, path)


def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def tail(path: Path, lines: int = 40) -> str:
    try:
        return "\n".join(path.read_text(errors="replace").splitlines()[-lines:])
    except OSError:
        return ""


def wait_until(condition, timeout: float, message: str, interval: float = 0.2):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = condition()
        if value:
            return value
        time.sleep(interval)
    raise RuntimeError(message)




def find_openssl() -> str:
    candidates = [shutil.which("openssl"), r"C:\Program Files\Git\usr\bin\openssl.exe", r"C:\Program Files\Git\mingw64\bin\openssl.exe"]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    raise RuntimeError("openssl was not found (Git for Windows ships one)")


def make_certificates(directory: Path, log) -> dict:
    """A CA and a server certificate it signs. Keys are written here and nowhere else."""
    directory.mkdir(parents=True, exist_ok=True)
    if all((directory / name).is_file() for name in ("ca.pem", "ca.key", "server.pem", "server.key")):
        log("certificates-kept", ca=str(directory / "ca.pem"))
        return {"ca": str(directory / "ca.pem"), "cert": str(directory / "server.pem"), "key": str(directory / "server.key")}
    openssl = find_openssl()

    def run(*arguments: str) -> None:
        result = subprocess.run([openssl, *arguments], cwd=str(directory), capture_output=True, text=True, timeout=60, creationflags=NO_WINDOW,
                                env=dict(os.environ, MSYS_NO_PATHCONV="1"))
        if result.returncode != 0:
            raise RuntimeError(f"openssl {' '.join(arguments[:2])} failed: {result.stderr}{result.stdout}")

    run("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "ca.key")
    run("req", "-x509", "-new", "-key", "ca.key", "-sha256", "-days", CERTIFICATE_DAYS, "-subj", "/CN=Exosuit local e2e development CA", "-out", "ca.pem",
        "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0", "-addext", "keyUsage=critical,keyCertSign,cRLSign")
    run("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "server.key")
    run("req", "-new", "-key", "server.key", "-subj", "/CN=localhost", "-out", "server.csr")
    (directory / "server.ext").write_text(
        f"basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName={SERVER_NAMES}\n", encoding="ascii")
    run("x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-days", CERTIFICATE_DAYS, "-sha256",
        "-extfile", "server.ext", "-out", "server.pem")
    # The chain the server presents: its certificate, then the CA (the CA is not secret).
    log("certificates", ca=str(directory / "ca.pem"), names=SERVER_NAMES)
    return {"ca": str(directory / "ca.pem"), "cert": str(directory / "server.pem"), "key": str(directory / "server.key")}


def start(arguments) -> int:
    out = Path(arguments.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    for stale in ("stop", "ready.json"):
        (out / stale).unlink(missing_ok=True)
    log = Log(out / "host.log")
    assert WRANGLER.is_file(), f"run `npm ci` in relay/worker first ({WRANGLER} is missing)"
    assert any(WORKERD.glob("bin/workerd*")), f"workerd's binary is missing under {WORKERD}"
    # The phone stores the relay's address when it pairs, so the ports are chosen once and kept.
    ports = read_json(out / "ports.json") or {}
    relay_port = arguments.relay_port or ports.get("relayPort") or free_port()
    tls_port = arguments.tls_port or ports.get("tlsPort") or free_port()
    write_json(out / "ports.json", {"relayPort": relay_port, "tlsPort": tls_port})
    (out / "wrangler-state").mkdir(exist_ok=True)

    pids: dict[str, int] = {"host": os.getpid()}
    processes: list[subprocess.Popen] = []
    handles = []
    exit_code = 0

    def spawn(name: str, command: list[str], cwd: Path) -> subprocess.Popen:
        handle = (out / f"{name}.log").open("w", encoding="utf-8", errors="replace")
        handles.append(handle)
        process = subprocess.Popen(command, cwd=str(cwd), stdout=handle, stderr=subprocess.STDOUT, creationflags=NO_WINDOW,
                                   start_new_session=(os.name != "nt"))
        processes.append(process)
        pids[name] = process.pid
        write_json(out / "pids.json", pids)
        log("spawned", name=name, pid=process.pid)
        return process

    def listening(process: subprocess.Popen, port: int, name: str):
        if process.poll() is not None:
            raise RuntimeError(f"{name} exited:\n" + tail(out / f"{name}.log"))
        import socket
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            return False

    try:
        tls_files = make_certificates(out / "tls", log)
        relay = spawn("relay", ["node", str(WRANGLER), "dev", "--local", "--ip", "127.0.0.1", "--port", str(relay_port),
                                "--persist-to", str(out / "wrangler-state"), "--var", "ALLOWED_ORIGINS:" + ",".join([PAIRING_ORIGIN, *arguments.pairing_origin])],
                      ROOT / "relay" / "worker")
        wait_until(lambda: listening(relay, relay_port, "relay"), 120, "the local relay did not start")
        log("relay-ready", relayPort=relay_port)
        proxy = spawn("tls-proxy", ["node", str(ROOT / "scripts" / "e2e-tls-proxy.mjs"), "--listen", str(tls_port), "--target", str(relay_port),
                                    "--cert", tls_files["cert"], "--key", tls_files["key"]], ROOT)
        wait_until(lambda: listening(proxy, tls_port, "tls-proxy"), 30, "the TLS front did not start")
        write_json(out / "ready.json", {
            "relayPort": relay_port, "relayOrigin": f"http://127.0.0.1:{relay_port}", "tlsPort": tls_port,
            "tlsOrigin": f"https://localhost:{tls_port}", "ca": tls_files["ca"], "out": str(out), "pids": pids})
        log("ready", ready=str(out / "ready.json"))
        started = time.monotonic()
        while not (out / "stop").exists():
            if arguments.lifetime and time.monotonic() - started > arguments.lifetime:
                log("lifetime-exceeded", seconds=arguments.lifetime)
                break
            for name, process in (("relay", relay), ("tls-proxy", proxy)):
                if process.poll() is not None:
                    raise RuntimeError(f"{name} exited with {process.returncode}:\n" + tail(out / f"{name}.log"))
            time.sleep(0.5)
        log("stopping")
    except KeyboardInterrupt:
        log("stopping", reason="interrupt")
    except Exception as error:  # noqa: BLE001
        log("failed", error=str(error))
        exit_code = 1
    finally:
        (out / "stop").write_text("stop\n")
        for process in reversed(processes):
            if process.poll() is None:
                kill_tree(process.pid)
        leftovers = kill_under(out)
        (out / "pids.json").unlink(missing_ok=True)
        log("stopped", leftoversKilled=leftovers)
        for handle in handles:
            handle.close()
    return exit_code


def stop(arguments) -> int:
    out = Path(arguments.out).resolve()
    (out / "stop").write_text("stop\n")
    recorded = read_json(out / "pids.json") or {}
    host = recorded.get("host")
    if host and host != os.getpid():
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and pid_alive(host):
            time.sleep(0.3)
        if pid_alive(host):
            for pid in recorded.values():
                if pid and pid != os.getpid() and pid_alive(pid) and (os.name == "nt" or names_rig(pid, out)):
                    kill_tree(pid)
    killed = kill_under(out)
    print(json.dumps({"stopped": True, "killedByCommandLine": killed}))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    start_parser = commands.add_parser("start")
    start_parser.add_argument("--out", required=True)
    start_parser.add_argument("--relay-port", type=int, default=0)
    start_parser.add_argument("--tls-port", type=int, default=0)
    start_parser.add_argument("--pairing-origin", action="append", default=[],
                              help="an extra browser origin the local Worker allows, e.g. http://127.0.0.1:18080 (repeatable)")
    start_parser.add_argument("--lifetime", type=int, default=LIFETIME_SECONDS)
    stop_parser = commands.add_parser("stop")
    stop_parser.add_argument("--out", required=True)
    arguments = parser.parse_args()
    return start(arguments) if arguments.command == "start" else stop(arguments)


if __name__ == "__main__":
    raise SystemExit(main())
