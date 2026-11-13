#!/usr/bin/env python3
"""A terminal in a terminal host survives its workspace service: same shell, same screen, after the service is stopped and started again and after it is killed and started again. Then, with its own suit: the host is listed, kept by the polite quit (`suit quit --keep-terminals`) and part of `kill --all`, `suit terminals end` ends it, and a service start cleans up what no terminal needs. Last, with several terminals in two workspaces: each comes back to its own view with its scrollback, a full-screen program keeps its modes, a broken connection to a host is opened again, and a program that ends while no service runs keeps its last screen and exit code."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import ctypes

ROOT=Path(__file__).resolve().parent.parent
from agent_test_runtime import launcher_path, manager_command, manager_environment
from haxeon_cli import run_cli

MANAGER=launcher_path(ROOT)
MANAGER_COMMAND=manager_command(ROOT)
MODE=['--self-hosted'] if os.environ.get('HAXEON_SELF_HOSTED')=='1' else []
PROJECT=ROOT/'tests/workspace-terminals/haxeon.json'
HAXEON_ROOT=Path(os.environ.get('HAXEON_ROOT',str(ROOT/'haxeon'))).resolve()
OUTPUT=PROJECT.parent/'build/host'
RUNNER=[str(HAXEON_ROOT/'.tools/hashlink'/('hl.exe' if os.name=='nt' else 'hl')),str(OUTPUT/'main.hl')]
if os.name!='nt':
    print('SKIP: terminal hosts have only been run on Windows'); sys.exit(0)
if run_cli(ROOT,['build','--project',str(PROJECT),*MODE])!=0: sys.exit('build failed')

kernel=ctypes.WinDLL('kernel32'); kernel.OpenProcess.restype=ctypes.c_void_p
def kill_tree(process):
    if process.poll() is not None: return
    subprocess.run(['taskkill','/F','/T','/PID',str(process.pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try: process.wait(timeout=10)
    except subprocess.TimeoutExpired: pass
def hosts_of(fixture):
    """Pids of the terminal hosts started for this fixture: they are detached, so no process tree holds them."""
    script="Get-CimInstance Win32_Process -Filter \"Name='hl.exe'\" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains('--terminal-host') -and $_.CommandLine.Contains('%s') } | ForEach-Object { $_.ProcessId }" % fixture.name
    found=subprocess.run(['powershell','-NoProfile','-Command',script],capture_output=True,text=True,timeout=60).stdout.split()
    return [int(pid) for pid in found if pid.isdigit()]
def run_tree(command,environment,timeout=60):
    process=subprocess.Popen(command,env=environment)
    try: status=process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        kill_tree(process); raise
    if status: raise subprocess.CalledProcessError(status,command)

with tempfile.TemporaryDirectory(prefix='exhost-',ignore_cleanup_errors=True) as temporary:
    fixture=Path(temporary); root=fixture/'project'; root.mkdir(); state=fixture/'state'
    environment=dict(manager_environment(ROOT, MANAGER),XDG_STATE_HOME=str(state),EXOSUIT_AGENT_STATE_HOME=str(state/'exosuit'),
        EXOSUIT_TERMINAL_HOST='1')
    environment.pop('EXOSUIT_AGENT_ALWAYS_AVAILABLE',None)
    libraries=[HAXEON_ROOT/'out',HAXEON_ROOT/'.tools/hashlink',*sorted(path for path in (OUTPUT/'native').iterdir() if path.is_dir())]
    environment['PATH']=os.pathsep.join(str(path) for path in libraries)+os.pathsep+environment.get('PATH','')
    def endpoints(): return list(state.glob('exosuit/workspaces/*/endpoint.json'))
    def generation():
        try: return json.loads(endpoints()[0].read_text())['generation']
        except (IndexError,OSError,ValueError,KeyError): return None
    def start(log,previous=None,hosts_on=True):
        """Starts a manager and waits for its endpoint; `previous` is the generation a killed one left in its endpoint file."""
        manager=subprocess.Popen([*MANAGER_COMMAND,str(root),'--idle-seconds','8'],env=dict(environment,EXOSUIT_TERMINAL_HOST='1' if hosts_on else '0'),
            stdout=log,stderr=subprocess.STDOUT)
        deadline=time.monotonic()+90
        while generation() in (None,previous):
            assert manager.poll() is None,'the manager exited before it was ready'
            assert time.monotonic()<deadline,'the manager did not become ready'
            time.sleep(.05)
        return manager
    def host_runs():
        code=ctypes.c_ulong(); kernel.GetExitCodeProcess(ctypes.c_void_p(handle),ctypes.byref(code))
        return code.value==259
    def logs():
        text=(fixture/'manager.log').read_text(errors='replace')[-6000:]
        for path in state.glob('exosuit/workspaces/*/manager.log'): text+='\n== '+str(path)+'\n'+path.read_text(errors='replace')[-6000:]
        for path in state.glob('exosuit/workspaces/*/terminal-hosts/*/host.log'): text+='\n== '+str(path)+'\n'+path.read_text(errors='replace')[-4000:]
        return text
    with (fixture/'manager.log').open('w') as log:
        manager=start(log)
        try:
            first=json.loads(endpoints()[0].read_text())
            run_tree([*RUNNER,'create',str(root),str(MANAGER)],environment)
            hosts=hosts_of(fixture)
            assert len(hosts)==1,'expected one terminal host, found %r'%hosts
            handle=kernel.OpenProcess(0x1000,False,hosts[0])
            assert handle,'the terminal host could not be opened'
            assert list(state.glob('exosuit/terminal-host/*/complete')),'the host does not run from a private runtime copy'
            # Stop the service the way suit does; the terminal's shell must outlive it.
            (endpoints()[0].parent/'stop-request.json').write_text(json.dumps({'version':1,'generation':first['generation']})+chr(10))
            assert manager.wait(timeout=20)==0,'the manager did not stop on request'
            assert not endpoints(),'the stopped manager kept its endpoint'
            shell=int((root/'shell-pid').read_text().strip())
            time.sleep(2)
            assert host_runs(),'the terminal host ended with its service'
            assert hosts_of(fixture)==hosts,'the terminal host is not listed any more'
            manager=start(log)
            second=json.loads(endpoints()[0].read_text())
            assert second['generation']!=first['generation']
            # A service that is killed (no stop, nothing cleaned up) leaves the terminal running as well. Killing the manager
            # closes the job its daemon runs in.
            subprocess.run(['taskkill','/F','/PID',str(second['managerPid'])],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            manager.wait(timeout=20)
            time.sleep(2)
            assert host_runs() and hosts_of(fixture)==hosts,'the terminal host ended when its service was killed'
            # A service without hosts cannot reach the terminal and records it as lost; the host and its program go on, and
            # the next service with hosts takes the terminal back.
            manager=start(log,second['generation'],hosts_on=False)
            without=json.loads(endpoints()[0].read_text())
            time.sleep(1)
            (endpoints()[0].parent/'stop-request.json').write_text(json.dumps({'version':1,'generation':without['generation']})+chr(10))
            assert manager.wait(timeout=20)==0,'the manager without hosts did not stop on request'
            assert host_runs(),'the terminal host ended under a service that ran without hosts'
            manager=start(log)
            assert generation() not in (first['generation'],second['generation'],without['generation'])
            # The existing attach check: the screen shows what the shell printed (also while no service ran), the shell has the
            # same pid and state, takes input and a resize, and its exit code arrives.
            run_tree([*RUNNER,'attach',str(root),str(MANAGER)],environment)
            deadline=time.monotonic()+15
            while hosts_of(fixture):
                assert time.monotonic()<deadline,'the terminal host did not end after its shell exited'
                time.sleep(.5)
            print('PASS: a hosted terminal (shell pid %d) kept its process and screen across a stopped service, a killed one and one without hosts'%shell,flush=True)
        except Exception:
            print(logs(),file=sys.stderr)
            raise
        finally:
            kill_tree(manager)
            for pid in hosts_of(fixture): subprocess.run(['taskkill','/F','/T','/PID',str(pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

# ---- suit and the kill switches (docs/design/terminal-host-status.md): a host is listed by suit under its workspace, is
# kept by Quit and by bulk stops, and ends on `suit terminals end`; a service start asks hosts without a terminal record
# to end, removes dead hosts' folders and unused runtime copies, and a service without hosts says which hosts go on.
from suit import library_path, library_variable
SUIT=ROOT/'suit/build/host/main.hl'
assert SUIT.is_file(),'build suit first: %s'%SUIT
def pid_runs(pid):
    opened=kernel.OpenProcess(0x1000,False,pid)
    if not opened: return False
    code=ctypes.c_ulong(); kernel.GetExitCodeProcess(ctypes.c_void_p(opened),ctypes.byref(code)); kernel.CloseHandle(ctypes.c_void_p(opened))
    return code.value==259
with tempfile.TemporaryDirectory(prefix='exhost-',ignore_cleanup_errors=True) as temporary:
    fixture=Path(temporary); root=fixture/'project'; root.mkdir(); state=fixture/'state'
    # Its own suit: hosts register in this home only, and suit reads no other process (EXOSUIT_SUIT_SCAN=0).
    environment=dict(manager_environment(ROOT, MANAGER),XDG_STATE_HOME=str(state),EXOSUIT_AGENT_STATE_HOME=str(state/'exosuit'),
        EXOSUIT_TERMINAL_HOST='1',EXOSUIT_SUIT='isolated',EXOSUIT_SUIT_HOME=str(fixture/'suit-home'),EXOSUIT_SUIT_AUTOSTART='0',
        EXOSUIT_SUIT_TRAY='0',EXOSUIT_SUIT_SCAN='0',EXOSUIT_TERMINAL_HOST_CHECK_SECONDS='1')
    environment.pop('EXOSUIT_AGENT_ALWAYS_AVAILABLE',None)
    libraries=[HAXEON_ROOT/'out',HAXEON_ROOT/'.tools/hashlink',*sorted(path for path in (OUTPUT/'native').iterdir() if path.is_dir())]
    environment['PATH']=os.pathsep.join(str(path) for path in libraries)+os.pathsep+environment.get('PATH','')
    suit_environment=dict(environment,EXOSUIT_SUIT_LAUNCHER=str(SUIT))
    suit_environment[library_variable()]=library_path(SUIT,Path(RUNNER[0]),HAXEON_ROOT,environment['PATH'])
    def suit(*arguments):
        result=subprocess.run([RUNNER[0],str(SUIT),*arguments],env=suit_environment,capture_output=True,text=True,timeout=60)
        assert result.returncode==0,'suit %s failed (%d): %s%s'%(' '.join(arguments),result.returncode,result.stderr,result.stdout)
        return result.stdout
    def planned(*arguments): return {int(line.split()[0]) for line in suit(*arguments,'--dry-run').splitlines() if line.endswith('would stop')}
    def endpoints(): return list(state.glob('exosuit/workspaces/*/endpoint.json'))
    def start(log,hosts_on=True):
        manager=subprocess.Popen([*MANAGER_COMMAND,str(root),'--idle-seconds','8'],env=dict(environment,EXOSUIT_TERMINAL_HOST='1' if hosts_on else '0'),
            stdout=log,stderr=subprocess.STDOUT)
        deadline=time.monotonic()+90
        while not endpoints():
            assert manager.poll() is None,'the manager exited before it was ready'
            assert time.monotonic()<deadline,'the manager did not become ready'
            time.sleep(.05)
        time.sleep(1)
        return manager
    def stop(manager):
        endpoint=json.loads(endpoints()[0].read_text())
        (endpoints()[0].parent/'stop-request.json').write_text(json.dumps({'version':1,'generation':endpoint['generation']})+chr(10))
        assert manager.wait(timeout=20)==0,'the manager did not stop on request'
    def logs():
        text=(fixture/'manager.log').read_text(errors='replace')[-6000:]
        for path in state.glob('exosuit/workspaces/*/manager.log'): text+='\n== '+str(path)+'\n'+path.read_text(errors='replace')[-6000:]
        for path in state.glob('exosuit/workspaces/*/terminal-hosts/*/host.log'): text+='\n== '+str(path)+'\n'+path.read_text(errors='replace')[-4000:]
        return text
    suit('status')
    with (fixture/'manager.log').open('w') as log:
        manager=start(log)
        try:
            run_tree([*RUNNER,'create',str(root),str(MANAGER)],environment)
            hosts=hosts_of(fixture)
            assert len(hosts)==1,'expected one terminal host, found %r'%hosts
            host=hosts[0]; shell=int((root/'shell-pid').read_text().strip())
            workspace=endpoints()[0].parent; folders=workspace/'terminal-hosts'; copies=state/'exosuit/terminal-host'
            folder=next(path for path in folders.iterdir() if (path/'host.json').is_file())
            assert json.loads((folder/'terminal.json').read_text())['terminal']=='test-terminal','the service did not say which terminal the host keeps'
            assert list(copies.glob('*/host-%d.lease'%host)),'the host holds no lease in its runtime copy'
            stop(manager)
            # 1. suit knows the host, with no service running: its own kind, under its workspace, not orphaned, in `kill --all`.
            listing=json.loads(suit('list','--json'))
            entry=next((process for process in listing['processes'] if process['pid']==host),None)
            assert entry is not None,'suit does not list the terminal host: %r'%listing
            assert entry['kind']=='terminal-host' and entry['source']=='registered' and not entry['orphaned'],entry
            assert entry['terminal']['terminal']=='test-terminal' and entry['workspace']==root.name,entry
            assert listing['terminals']==1 and '1 terminal' in listing['summary'],listing
            assert host in planned('kill','--all') and host not in planned('kill','--orphans'),'`kill --all` must include the host and the orphan sweep must not'
            assert planned('terminals','end','--all')=={host} and planned('terminals','end',str(root))=={host},'`suit terminals end` does not select the host'
            menu=suit('menu')
            assert str(host) in suit('terminals') and 'End all terminals (1)' in menu and 'Quit Exosuit and end everything (1 terminal)' in menu and 'Quit, keep terminals running (1)' in menu,menu
            # 2. The polite quit keeps the terminal and says so (the full quit is covered by scripts/test-suit.py).
            said=suit('quit','--keep-terminals')
            assert '1 terminal keeps running' in said and 'suit terminals end --all' in said,said
            assert pid_runs(host) and pid_runs(shell),'the polite quit ended the terminal'
            # 3. Planted: a host folder with no terminal record that holds a last screen, an old one with no host and nothing
            # to collect, an old runtime copy nothing runs from and a young one.
            unrecorded=folders/('0'*24); unrecorded.mkdir(); (unrecorded/'host.log').write_text('left behind\n'); (unrecorded/'final.bin').write_bytes(b'last')
            dead=folders/('1'*24); dead.mkdir(); (dead/'host.log').write_text('dead\n'); (dead/'end-request.json').write_text('{"version":1,"reason":"test"}\n')
            os.utime(dead,(time.time()-300,time.time()-300))
            for name,age in (('0'*16,7200),('1'*16,30)):
                (copies/name).mkdir(); (copies/name/'hl.exe').write_bytes(b'not a program'); (copies/name/'complete').write_text('x\n')
                os.utime(copies/name/'complete',(time.time()-age,time.time()-age))
            # A service without hosts: the host goes on, the service says so, and the sweep still runs.
            manager=start(log,hosts_on=False)
            assert unrecorded.is_dir() and not (unrecorded/'end-request.json').exists(),'a host folder without a terminal record was asked to end or removed'
            assert not dead.exists(),'the folder of a host that is gone was not removed'
            assert (folder/'host.json').is_file() and not (folder/'end-request.json').exists(),'the recorded terminal\'s host was disturbed'
            assert 'keep running although this service runs without hosts' in logs(),'a service without hosts did not say that hosts keep running'
            assert pid_runs(host) and json.loads(suit('list','--json'))['terminals']==1,'the host is not visible under a service without hosts'
            stop(manager)
            # A service with hosts removes the runtime copy no host runs from, and keeps the young one and its own.
            manager=start(log)
            assert not (copies/('0'*16)).exists(),'an unused runtime copy was not removed'
            assert (copies/('1'*16)).exists(),'a runtime copy made a moment ago was removed'
            assert list(copies.glob('*/host-%d.lease'%host)) and pid_runs(host),'the running host lost its runtime copy'
            stop(manager)
            # A service whose terminal catalog is empty (the database was replaced or recreated) ends no host and removes no
            # host folder: the running host has no record there, and is only logged.
            aside=fixture/'catalog-aside'; aside.mkdir()
            moved=list(workspace.glob('catalog.sqlite*'))
            for path in moved: path.rename(aside/path.name)
            manager=start(log)
            assert (folder/'host.json').is_file() and not (folder/'end-request.json').exists() and unrecorded.is_dir(),'a service with an empty terminal catalog disturbed the host folders'
            assert 'has no terminal record in this workspace: left running' in logs(),'the service did not log the host it has no record of'
            stop(manager)
            time.sleep(1.5)
            assert pid_runs(host) and pid_runs(shell),'a service with an empty terminal catalog ended the terminal'
            for path in workspace.glob('catalog.sqlite*'): path.unlink()
            for path in moved: (aside/path.name).rename(workspace/path.name)
            # The host with no service attached (it checks every second here): suit's list of workspaces is emptied, then lists
            # only another workspace. Neither is a removal of the host's workspace: the program keeps running.
            identity=folder/'terminal.json'; written=identity.read_text()
            identity.write_text(json.dumps(dict(json.loads(written),workspace='workspace-lifecycle-test'))+'\n')
            catalog=fixture/'suit-home'/'machine.json'; kept=catalog.read_text() if catalog.exists() else None
            catalog.write_text(json.dumps({'version':2,'id':'machine-test','name':'test','workspaces':[]})+'\n')
            time.sleep(4)
            assert pid_runs(host) and pid_runs(shell),'an empty machine.json ended an unattached host'
            catalog.write_text(json.dumps({'version':2,'id':'machine-test','name':'test','workspaces':[
                {'id':'workspace-other','name':'other','folders':[],'scratch':None,'revision':1}]})+'\n')
            time.sleep(4)
            assert pid_runs(host) and pid_runs(shell),'a machine.json that lacks the workspace ended an unattached host at once'
            if kept is None: catalog.unlink()
            else: catalog.write_text(kept)
            identity.write_text(written)
            # Restart Terminal of a terminal whose host runs but does not answer (suspended here): the old host is asked to
            # end and then killed; the new host owns the folder and is not ended by a later request addressed to the old one.
            old_instance=json.loads((folder/'host.json').read_text())['instance']
            suspended=kernel.OpenProcess(0x0800,False,host)
            assert suspended and ctypes.WinDLL('ntdll').NtSuspendProcess(ctypes.c_void_p(suspended))==0,'the host could not be suspended'
            manager=start(log)
            deadline=time.monotonic()+60
            while 'test-terminal is lost' not in logs():
                assert time.monotonic()<deadline,'the service did not give up the host that does not answer'
                time.sleep(.5)
            run_tree([*RUNNER,'host-restart',str(root),str(MANAGER),'test-terminal',"'RESTARTED_'+'SHELL'",'RESTARTED_SHELL'],environment,timeout=150)
            deadline=time.monotonic()+20
            while pid_runs(host) or pid_runs(shell):
                assert time.monotonic()<deadline,'the old host of the restarted terminal (or its shell) is still running'
                time.sleep(.2)
            kernel.CloseHandle(ctypes.c_void_p(suspended))
            renewed=hosts_of(fixture)
            assert len(renewed)==1 and renewed[0]!=host,'expected one new terminal host, found %r'%renewed
            assert 'did not end when asked; it was killed' in logs(),'the service did not kill the old host that did not answer'
            stop(manager)
            (folder/'end-request.json').write_text(json.dumps({'version':2,'reason':'test: for the old host','pid':host,'instance':old_instance})+'\n')
            time.sleep(3)
            assert pid_runs(renewed[0]),'an end request addressed to the old host ended the new one'
            assert not (folder/'end-request.json').exists(),'the new host did not remove a request for a host that is gone'
            assert json.loads((folder/'host.json').read_text())['pid']==renewed[0] and not (folder/'final.bin').exists()
            host=renewed[0]
            # 4. The kill switch: `suit terminals end --all` ends the host and its program through the host's folder.
            assert planned('terminals','end','--all')=={host}
            ended=suit('terminals','end','--all')
            assert str(host) in ended,ended
            deadline=time.monotonic()+15
            while pid_runs(host) or pid_runs(shell):
                assert time.monotonic()<deadline,'`suit terminals end --all` left the host or its shell running: %s'%ended
                time.sleep(.2)
            assert 'asked to end by a request' in (folder/'host.log').read_text(errors='replace'),'the host was killed, not asked to end'
            assert json.loads(suit('list','--json'))['terminals']==0 and 'No terminal is kept running' in suit('terminals')
            assert not list(copies.glob('*/host-%d.lease'%host)),'the ended host left its lease'
            # 5. A host that fails to start (its runtime copy's bytecode is broken here) leaves no spec.bin: it holds the
            # program's environment and the pipe's token.
            manager=start(log)
            for program in copies.glob('*/terminal-host.hl'): program.write_bytes(b'not bytecode')
            # The client's own result does not matter here: what the start leaves in the host's folder does.
            subprocess.run([*RUNNER,'host-type',str(root),str(MANAGER),'term-broken','create',"'NEVER'"],env=environment,
                stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=120)
            broken_folder=folders/hashlib.sha256(b'term-broken').hexdigest()[:24]
            deadline=time.monotonic()+30
            while 'term-broken is failed' not in logs():
                assert time.monotonic()<deadline,'the terminal whose host cannot start did not fail'
                time.sleep(.5)
            assert broken_folder.is_dir() and not (broken_folder/'spec.bin').exists(),'spec.bin was left behind by a host that failed to start'
            assert 'exited before it was ready' in logs(),'the host did not fail the way this check expects'
            stop(manager)
            print('PASS: suit lists a terminal host, the polite quit keeps it, kill --all includes it, `suit terminals end` ends it; a service start ends no host (an empty terminal catalog included), keeps a folder with a last screen and removes dead folders and unused runtime copies; an empty or partial machine.json ends no unattached host; Restart Terminal of a host that does not answer kills it and the new host ignores requests for the old one; a host that fails to start leaves no spec.bin',flush=True)
        except Exception:
            print(logs(),file=sys.stderr)
            raise
        finally:
            kill_tree(manager)
            for pid in hosts_of(fixture): subprocess.run(['taskkill','/F','/T','/PID',str(pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

# Several terminals, two workspaces: each comes back to its own view with its scrollback (also what was printed while no
# service ran) and its full-screen program's modes; a service whose connection to a host breaks connects again in place;
# a program that ends while no service runs leaves its last screen and exit code for the next service.
with tempfile.TemporaryDirectory(prefix='exhosts-',ignore_cleanup_errors=True) as temporary:
    fixture=Path(temporary); state=fixture/'state'
    roots={'a':fixture/'project-a','b':fixture/'project-b'}
    for path in roots.values(): path.mkdir()
    environment=dict(manager_environment(ROOT, MANAGER),XDG_STATE_HOME=str(state),EXOSUIT_AGENT_STATE_HOME=str(state/'exosuit'),
        EXOSUIT_TERMINAL_HOST='1',EXOSUIT_SUIT='off')
    environment.pop('EXOSUIT_AGENT_ALWAYS_AVAILABLE',None)
    libraries=[HAXEON_ROOT/'out',HAXEON_ROOT/'.tools/hashlink',*sorted(path for path in (OUTPUT/'native').iterdir() if path.is_dir())]
    environment['PATH']=os.pathsep.join(str(path) for path in libraries)+os.pathsep+environment.get('PATH','')
    managers={}
    def endpoint(key):
        """The endpoint file and content of the service for workspace `key`, or (None, None) while it has none."""
        for path in state.glob('exosuit/workspaces/*/endpoint.json'):
            try: content=json.loads(path.read_text())
            except (OSError,ValueError): continue
            if os.path.normcase(os.path.realpath(content.get('root','')))==os.path.normcase(os.path.realpath(roots[key])): return path,content
        return None,None
    def start(key,log):
        managers[key]=subprocess.Popen([*MANAGER_COMMAND,str(roots[key]),'--idle-seconds','8'],env=environment,stdout=log,stderr=subprocess.STDOUT)
        deadline=time.monotonic()+90
        while endpoint(key)[0] is None:
            assert managers[key].poll() is None,'the manager of workspace %s exited before it was ready'%key
            assert time.monotonic()<deadline,'the manager of workspace %s did not become ready'%key
            time.sleep(.05)
        return endpoint(key)[1]['generation']
    def stop(key):
        path,content=endpoint(key)
        (path.parent/'stop-request.json').write_text(json.dumps({'version':1,'generation':content['generation']})+chr(10))
        assert managers[key].wait(timeout=20)==0,'the manager of workspace %s did not stop on request'%key
        return path.parent
    def client(mode,key,*arguments,timeout=90):
        run_tree([*RUNNER,mode,str(roots[key]),str(MANAGER),*[str(value) for value in arguments]],environment,timeout)
    def view(key,terminal,expected=None):
        target=fixture/('view-%s.json'%terminal)
        client('host-dump',key,terminal,target,*([expected] if expected else []))
        return json.loads(target.read_text(encoding='utf-8'))
    def text(dump): return '\n'.join(dump['lines'])
    def host_folder(workspace,terminal):
        return workspace/'terminal-hosts'/hashlib.sha256(terminal.encode()).hexdigest()[:24]
    def logs():
        text=(fixture/'manager.log').read_text(errors='replace')[-8000:]
        for path in state.glob('exosuit/workspaces/*/manager.log'): text+='\n== '+str(path)+'\n'+path.read_text(errors='replace')[-8000:]
        for path in state.glob('exosuit/workspaces/*/terminal-hosts/*/host.log'): text+='\n== '+str(path)+'\n'+path.read_text(errors='replace')[-3000:]
        return text
    def numbered(prefix,count,gate):
        """A command that prints `count` numbered lines, and 40 more once the file `gate` exists."""
        return ("1..%d | %% { '%s_LINE_{0:0000}' -f $_ }; '%s_'+'READY'; while (!(Test-Path '%s')) { Start-Sleep -Milliseconds 200 }; "
            "1..40 | %% { '%s_LATE_{0:00}' -f $_ }; '%s_'+'DONE'")%(count,prefix,prefix,gate,prefix,prefix)
    with (fixture/'manager.log').open('w') as log:
        try:
            generations={key:start(key,log) for key in roots}
            gate=fixture/'gate'; last=fixture/'last'
            client('host-type','a','term-a1','create',numbered('A1',11000,gate),'A1_READY')
            client('host-type','a','term-a2','create',numbered('A2',30,gate),'A2_READY')
            client('host-type','a','term-tui','create',"& '%s' '%s'"%(sys.executable,ROOT/'tests/workspace-terminals/fullscreen-tui.py'),'TUI_FRAME_')
            client('host-type','b','term-b1','create',numbered('B1',30,gate),'B1_READY')
            hosts=hosts_of(fixture)
            assert len(hosts)==4,'expected four terminal hosts, found %r'%hosts
            before=view('a','term-tui','TUI_FRAME_')
            # The Windows pseudoconsole keeps mouse reporting and cursor-key mode to itself; the alternate screen and bracketed
            # paste reach the terminal. Whatever arrived must be the same after the restart.
            assert before['alternate'] and 'paste=1' in before['modes'],'the full-screen program did not set its modes before the restart: %r'%{k:v for k,v in before.items() if k!='lines'}
            frame=max(int(line.split('TUI_FRAME_')[1][:6]) for line in before['lines'] if 'TUI_FRAME_' in line)
            workspaces={key:stop(key) for key in roots}
            # Output while no service runs.
            gate.write_text('go')
            time.sleep(3)
            assert sorted(hosts_of(fixture))==sorted(hosts),'terminal hosts ended with their services'
            restarted={key:start(key,log) for key in roots}
            assert all(restarted[key]!=generations[key] for key in roots)
            a1=view('a','term-a1','A1_DONE'); body=text(a1)
            kept={line.strip() for line in a1['lines'] if 'A1_LINE_' in line}
            assert a1['found'] and a1['state']=='running',{k:v for k,v in a1.items() if k!='lines'}
            assert a1['scrollback']>=9900,'the view holds %d lines above the screen, expected the 10000 the host keeps'%a1['scrollback']
            assert len(kept)>=9000 and 'A1_LINE_11000' in body and 'A1_LINE_2000' in body,'the scrollback holds %d of the numbered lines'%len(kept)
            assert all('A1_LATE_%02d'%number in body for number in range(1,41)),'lines printed while no service ran are missing'
            assert 'A2_' not in body and 'B1_' not in body,'another terminal\'s output is in this view'
            a2=view('a','term-a2','A2_DONE'); b1=view('b','term-b1','B1_DONE')
            assert a2['found'] and a2['state']=='running' and 'A2_LINE_0001' in text(a2) and 'A1_' not in text(a2) and 'B1_' not in text(a2),'terminal a2 came back wrong'
            assert b1['found'] and b1['state']=='running' and 'B1_LINE_0001' in text(b1) and 'A1_' not in text(b1) and 'A2_' not in text(b1),'terminal b1 came back wrong'
            # The full-screen program: same process (its counter went on), its screen and its modes.
            tui=view('a','term-tui','TUI_FRAME_')
            later=max([int(line.split('TUI_FRAME_')[1][:6]) for line in tui['lines'] if 'TUI_FRAME_' in line] or [0])
            assert tui['alternate'] and tui['mouse']==before['mouse'] and tui['modes']==before['modes'],'the full-screen program\'s modes changed: before %r %r, after %r %r'%(before['mouse'],before['modes'],tui['mouse'],tui['modes'])
            assert 'TUI_HEADER' in text(tui) and later>frame,'the full-screen program\'s screen did not come back (frame %d, then %d)'%(frame,later)
            assert sorted(hosts_of(fixture))==sorted(hosts),'the hosts are not the ones that were started'
            # The connection between the service and a host breaks while both run: another connection takes the host over.
            client('host-steal','a',host_folder(workspaces['a'],'term-a2'))
            client('host-type','a','term-a2','attach',"'A2_AFTER_'+'BREAK'",'A2_AFTER_BREAK')
            again=view('a','term-a2','A2_AFTER_BREAK')
            assert again['found'] and again['state']=='running' and 'A2_LINE_0001' in text(again),'the terminal did not go on after its connection broke'
            # The host sends its whole history again on the new connection, into the service's emulator that already holds
            # it: the history replaces what was there instead of following it (each line once, not twice).
            for marker in ('A2_LINE_0001','A2_LATE_01','A2_DONE'):
                seen=sum(1 for line in again['lines'] if marker in line)
                assert seen==1,'after the reconnect the view shows %s %d times:\n%s'%(marker,seen,text(again))
            assert endpoint('a')[1]['generation']==restarted['a'],'the service was replaced instead of connecting again'
            assert 'connected again' in (workspaces['a']/'manager.log').read_text(errors='replace'),'the service did not log the reconnect'
            # A program that ends while no service is attached.
            client('host-type','b','term-b1','attach',"while (!(Test-Path '%s')) { Start-Sleep -Milliseconds 200 }; 'B1_LAST_'+'SCREEN'; exit 9"%last)
            stop('b')
            last.write_text('go')
            final=host_folder(workspaces['b'],'term-b1')/'final.bin'
            deadline=time.monotonic()+20
            while not final.exists() or len(hosts_of(fixture))!=3:
                assert time.monotonic()<deadline,'the host of the ended program did not leave final.bin and end'
                time.sleep(.25)
            start('b',log)
            ended=view('b','term-b1','B1_LAST_SCREEN')
            assert ended['found'] and ended['state']=='exited' and ended['exitCode']==9,'the ended program came back as %r, exit code %r'%(ended['state'],ended['exitCode'])
            assert 'B1_LINE_0001' in text(ended),'the ended program lost its scrollback'
            assert not final.exists(),'final.bin was not removed after the service took it'
            print('PASS: four hosted terminals in two workspaces came back to their own views with %d lines of scrollback, a full-screen program kept its modes, a broken host connection was opened again, and an exit with no service kept its screen and code'%a1['scrollback'],flush=True)
        except Exception:
            print(logs(),file=sys.stderr)
            raise
        finally:
            for manager in managers.values(): kill_tree(manager)
            for pid in hosts_of(fixture): subprocess.run(['taskkill','/F','/T','/PID',str(pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

# A flood of coloured output: a host sends faster than the service takes it in. The service's connection holds at most
# 1 MiB it has not read and closes when more arrives, so the host may send only what the service said it has taken
# (TerminalHostProtocol.CREDIT). Before that, the service lost the host within seconds and its terminal turned failed.
with tempfile.TemporaryDirectory(prefix='exhostflood-',ignore_cleanup_errors=True) as temporary:
    fixture=Path(temporary); state=fixture/'state'; root=fixture/'project'; root.mkdir()
    environment=dict(manager_environment(ROOT, MANAGER),XDG_STATE_HOME=str(state),EXOSUIT_AGENT_STATE_HOME=str(state/'exosuit'),
        EXOSUIT_TERMINAL_HOST='1',EXOSUIT_SUIT='off',EXOSUIT_TEST_TERMINAL_COLUMNS='200')
    environment.pop('EXOSUIT_AGENT_ALWAYS_AVAILABLE',None)
    libraries=[HAXEON_ROOT/'out',HAXEON_ROOT/'.tools/hashlink',*sorted(path for path in (OUTPUT/'native').iterdir() if path.is_dir())]
    environment['PATH']=os.pathsep.join(str(path) for path in libraries)+os.pathsep+environment.get('PATH','')
    def flood_client(mode,*arguments,timeout=120):
        run_tree([*RUNNER,mode,str(root),str(MANAGER),*[str(value) for value in arguments]],environment,timeout)
    def service_log():
        return ''.join(path.read_text(errors='replace') for path in state.glob('exosuit/workspaces/*/manager.log'))
    with (fixture/'manager.log').open('w') as log:
        manager=subprocess.Popen([*MANAGER_COMMAND,str(root),'--idle-seconds','8'],env=environment,stdout=log,stderr=subprocess.STDOUT)
        try:
            deadline=time.monotonic()+90
            while not any(state.glob('exosuit/workspaces/*/endpoint.json')):
                assert manager.poll() is None and time.monotonic()<deadline,'the manager did not become ready'
                time.sleep(.05)
            done=fixture/'flood-done'
            flood=("$e=[char]27; $l=-join (0..194 | %% { $e+'[38;5;'+($_ %% 200 + 16)+'m'+[char](65+$_ %% 26) }); "
                "1..6000 | %% { ('{0:00000}' -f $_)+$l }; $e+'[0m'; 'FLOOD_'+'DONE'; 'x' > '%s'")%done
            flood_client('host-type','flood','create',flood)
            deadline=time.monotonic()+300
            while not done.exists():
                assert time.monotonic()<deadline,'the terminal did not finish printing'
                assert 'connection to the host closed' not in service_log(),'the service lost the host while it printed'
                time.sleep(.5)
            target=fixture/'view-flood.json'
            flood_client('host-dump','flood',target,'FLOOD_DONE')
            dump=json.loads(target.read_text(encoding='utf-8'))
            text='\n'.join(service_log().splitlines()[-40:])
            assert 'connection closed' not in text and 'connection to the host closed' not in text,'the service lost its connection to the host:\n'+text
            assert dump['found'] and dump['state']=='running','the flooded terminal is %r, not running:\n%s'%(dump['state'],text)
            # The rendered history a view takes is bounded to 16 MiB (terminalkit_history_copy): about 4300 of these lines.
            assert dump['scrollback']>=3000 and '06000' in '\n'.join(dump['lines']),'the flooded terminal holds %d lines above the screen'%dump['scrollback']
            # The window holds from the service's ATTACH, before its first CREDIT arrives; this service sends CREDIT, so no
            # host may take it for an older one that sends none and lift the window.
            lifted=[path for path in state.glob('exosuit/workspaces/*/terminal-hosts/*/host.log') if 'sends no CREDIT' in path.read_text(errors='replace')]
            assert not lifted,'a host took this service for one that sends no CREDIT: %s'%lifted
            print('PASS: a host printing 6000 lines of 200 coloured columns kept its connection to the service (%d lines above the screen)'%dump['scrollback'],flush=True)
        except Exception:
            print((fixture/'manager.log').read_text(errors='replace')[-4000:]+'\n'+service_log()[-6000:],file=sys.stderr)
            for path in state.glob('exosuit/workspaces/*/terminal-hosts/*/host.log'): print('== '+str(path)+'\n'+path.read_text(errors='replace')[-3000:],file=sys.stderr)
            raise
        finally:
            kill_tree(manager)
            for pid in hosts_of(fixture): subprocess.run(['taskkill','/F','/T','/PID',str(pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

# ---- Memory (docs/design/terminal-host-status.md, "Memory"): four terminals filled with 10000 lines of 200-column
# coloured output, two of which then exit. Prints the private memory of the service and of each host while all four
# run, right after two ended, and once the service let the ended ones go; a view of an ended terminal still gets its
# whole scrollback (from disk), and a full live one attaches with all of it.
def private_memory(fixture):
    """{pid: (kind, private bytes)} of this fixture's hl.exe processes: the hosts and the workspace service."""
    script=("Get-CimInstance Win32_Process -Filter \"Name='hl.exe'\" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains('%s') } | "
        "ForEach-Object { $p=Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue; if ($p) { '{0} {1} {2}' -f $_.ProcessId,$p.PrivateMemorySize64,"
        "$(if ($_.CommandLine.Contains('--terminal-host')) {'host'} else {'service'}) } }")%fixture.name
    found={}
    for line in subprocess.run(['powershell','-NoProfile','-Command',script],capture_output=True,text=True,timeout=60).stdout.splitlines():
        parts=line.split()
        if len(parts)==3 and parts[0].isdigit(): found[int(parts[0])]=(parts[2],int(parts[1]))
    return found
def report(label,found):
    mib=lambda value: value/1048576
    hosts=sorted(size for kind,size in found.values() if kind=='host')
    services=[size for kind,size in found.values() if kind=='service']
    print('MEMORY %s: service %s MiB; %d hosts %s MiB'%(label,' + '.join('%.1f'%mib(size) for size in services),len(hosts),
        ', '.join('%.1f'%mib(size) for size in hosts)),flush=True)
    return sum(services)
if os.environ.get('EXOSUIT_TERMINAL_MEMORY')!='1':
    print('SKIP: the memory measurement runs with EXOSUIT_TERMINAL_MEMORY=1 (it takes minutes)')
else:
    with tempfile.TemporaryDirectory(prefix='exhostmem-',ignore_cleanup_errors=True) as temporary:
        fixture=Path(temporary); state=fixture/'state'; root=fixture/'project'; root.mkdir()
        environment=dict(manager_environment(ROOT, MANAGER),XDG_STATE_HOME=str(state),EXOSUIT_AGENT_STATE_HOME=str(state/'exosuit'),
            EXOSUIT_TERMINAL_HOST='1',EXOSUIT_SUIT='off',EXOSUIT_TEST_TERMINAL_COLUMNS='200')
        environment.pop('EXOSUIT_AGENT_ALWAYS_AVAILABLE',None)
        libraries=[HAXEON_ROOT/'out',HAXEON_ROOT/'.tools/hashlink',*sorted(path for path in (OUTPUT/'native').iterdir() if path.is_dir())]
        environment['PATH']=os.pathsep.join(str(path) for path in libraries)+os.pathsep+environment.get('PATH','')
        def endpoint_file(): return next(iter(state.glob('exosuit/workspaces/*/endpoint.json')),None)
        def client(mode,*arguments,timeout=120):
            run_tree([*RUNNER,mode,str(root),str(MANAGER),*[str(value) for value in arguments]],environment,timeout)
        def view(terminal,expected=None):
            target=fixture/('view-%s.json'%terminal)
            client('host-dump',terminal,target,*([expected] if expected else []))
            return json.loads(target.read_text(encoding='utf-8'))
        with (fixture/'manager.log').open('w') as log:
            manager=subprocess.Popen([*MANAGER_COMMAND,str(root),'--idle-seconds','8'],env=environment,stdout=log,stderr=subprocess.STDOUT)
            try:
                deadline=time.monotonic()+90
                while endpoint_file() is None:
                    assert manager.poll() is None and time.monotonic()<deadline,'the manager did not become ready'
                    time.sleep(.05)
                base=report('empty service',private_memory(fixture))
                terminals=['mem-%d'%number for number in range(1,5)]
                for terminal in terminals:
                    done=fixture/('done-'+terminal)
                    fill=("$e=[char]27; $l=-join (0..194 | %% { $e+'[38;5;'+($_ %% 200 + 16)+'m'+[char](65+$_ %% 26) }); "
                        "1..10000 | %% { ('{0:00000}' -f $_)+$l }; $e+'[0m'; 'FILL_'+'DONE'; 'x' > '%s'")%done
                    client('host-type',terminal,'create',fill)
                deadline=time.monotonic()+600
                # The highest the service reached while the terminals filled: the periodic history saves made it gigabytes.
                peak=0
                while not all((fixture/('done-'+terminal)).exists() for terminal in terminals):
                    assert time.monotonic()<deadline,'the terminals did not finish printing'
                    peak=max(peak,sum(size for kind,size in private_memory(fixture).values() if kind=='service'))
                    time.sleep(2)
                time.sleep(5)
                report('4 full terminals, just filled',private_memory(fixture))
                # The service takes the hosts' output in after the programs printed it; then it is quiet.
                time.sleep(30)
                live=report('4 full terminals, quiet',private_memory(fixture))
                print('MEMORY highest while filling: service %.1f MiB'%(peak/1048576),flush=True)
                for terminal in terminals[2:]: client('host-type',terminal,'attach','exit')
                deadline=time.monotonic()+30
                while sum(1 for kind,_ in private_memory(fixture).values() if kind=='host')>2:
                    assert time.monotonic()<deadline,'the hosts of the exited programs did not end'
                    time.sleep(.5)
                time.sleep(3)
                ended=report('2 full + 2 just ended',private_memory(fixture))
                time.sleep(40)
                unloaded=report('2 full + 2 ended and let go',private_memory(fixture))
                for terminal in terminals[2:]:
                    dump=view(terminal,'FILL_DONE')
                    body='\n'.join(dump['lines'])
                    # A view takes at most 16 MiB of rendered history (terminalkit_history_copy): about 4300 of these lines.
                    assert dump['state']=='exited' and dump['scrollback']>=3000 and '10000' in body,'ended terminal %s came back with %d lines above the screen'%(terminal,dump['scrollback'])
                dump=view(terminals[0],'FILL_DONE')
                assert dump['state']=='running' and dump['scrollback']>=3000,'live terminal has %d lines above the screen'%dump['scrollback']
                print('PASS: memory measured (service %.1f MiB with 4 full terminals, %.1f MiB once 2 ended and were let go); ended terminals came back with their whole scrollback'
                    %(live/1048576,unloaded/1048576),flush=True)
            except Exception:
                text=(fixture/'manager.log').read_text(errors='replace')[-6000:]
                for path in state.glob('exosuit/workspaces/*/manager.log'): text+='\n== '+str(path)+'\n'+path.read_text(errors='replace')[-6000:]
                print(text,file=sys.stderr)
                raise
            finally:
                kill_tree(manager)
                for pid in hosts_of(fixture): subprocess.run(['taskkill','/F','/T','/PID',str(pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
