#!/usr/bin/env python3
"""A terminal in a terminal host survives its workspace service: same shell, same screen, after the service is stopped and started again and after it is killed and started again. Then, with its own exohost: the host is listed, kept by the polite quit (`exohost quit --keep-terminals`) and part of `kill --all`, `exohost terminals end` ends it, and a service start cleans up what no terminal needs. Last, with several terminals in two workspaces: each comes back to its own view with its scrollback, a full-screen program keeps its modes, a broken connection to a host is opened again, and a program that ends while no service runs keeps its last screen and exit code."""
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
sys.path.insert(0,str(ROOT/'scripts'))
from test_driver import (HAXEON_ROOT, build_test, isolated_environment, launcher_path, process_runs as pid_runs, run_tree,
                         service_log as log_of, start_service, workspace_id)

# The agent bytecode: the services' program, and what a client program (testing.DirectService) starts one with.
SERVICE=launcher_path(ROOT)
if os.name!='nt':
    print('SKIP: terminal hosts have only been run on Windows'); sys.exit(0)
RUNNER=build_test('workspace-terminals')

kernel=ctypes.WinDLL('kernel32'); kernel.OpenProcess.restype=ctypes.c_void_p
def hosts_of(fixture):
    """Pids of the terminal hosts started for this fixture: they are detached, so no process tree holds them."""
    script="Get-CimInstance Win32_Process -Filter \"Name='hl.exe'\" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains('--terminal-host') -and $_.CommandLine.Contains('%s') } | ForEach-Object { $_.ProcessId }" % fixture.name
    found=subprocess.run(['powershell','-NoProfile','-Command',script],capture_output=True,text=True,timeout=60).stdout.split()
    return [int(pid) for pid in found if pid.isdigit()]
def environment_of(state,**extra):
    """A service's and a client's environment, all state under `state` (test_driver.isolated_environment). A service a
    client starts (testing.DirectService, when the one `begin` started idled out meanwhile) idles out as `begin`'s do."""
    return dict(isolated_environment(state,SERVICE,'workspace-terminals'),EXOSUIT_SERVICE_IDLE_SECONDS='8',**extra)
def begin(environment,state,root,idle=8):
    """Starts the service of `root`'s test workspace with idle limit `idle` and returns it once ready."""
    return start_service(environment,state,root,idle_seconds=idle)
def stop(service,idle=8):
    """Stops a service the clean way there is without exohost: its clients are gone, so it idles out."""
    assert service.wait(idle+20)==0,'the service did not idle out'
def kill(service):
    subprocess.run(['taskkill','/F','/PID',str(service.pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    service.wait(20)
def service_logs(state,limit=6000):
    return ''.join('\n== '+str(path)+'\n'+path.read_text(errors='replace')[-limit:] for path in state.glob('exosuit/workspaces/*/service.log'))

with tempfile.TemporaryDirectory(prefix='exhost-',ignore_cleanup_errors=True) as temporary:
    fixture=Path(temporary); root=fixture/'project'; root.mkdir(); state=fixture/'state'
    environment=environment_of(state)
    def host_runs():
        code=ctypes.c_ulong(); kernel.GetExitCodeProcess(ctypes.c_void_p(handle),ctypes.byref(code))
        return code.value==259
    def logs():
        text=service_logs(state)
        for path in state.glob('exosuit/workspaces/*/terminal-hosts/*/host.log'): text+='\n== '+str(path)+'\n'+path.read_text(errors='replace')[-4000:]
        return text
    if True:
        service=begin(environment,state,root)
        try:
            first=service
            run_tree([*RUNNER,'create',str(root),str(SERVICE)],environment)
            hosts=hosts_of(fixture)
            assert len(hosts)==1,'expected one terminal host, found %r'%hosts
            handle=kernel.OpenProcess(0x1000,False,hosts[0])
            assert handle,'the terminal host could not be opened'
            assert list(state.glob('exosuit/terminal-host/*/complete')),'the host does not run from a private runtime copy'
            # The service stops cleanly (it idles out, as when exohost stops it); the terminal's shell must outlive it.
            stop(service)
            shell=int((root/'shell-pid').read_text().strip())
            time.sleep(2)
            assert host_runs(),'the terminal host ended with its service'
            assert hosts_of(fixture)==hosts,'the terminal host is not listed any more'
            second=service=begin(environment,state,root)
            assert second.generation!=first.generation
            # A service that is killed (no stop, nothing cleaned up) leaves the terminal running as well.
            kill(service)
            time.sleep(2)
            assert host_runs() and hosts_of(fixture)==hosts,'the terminal host ended when its service was killed'
            service=begin(environment,state,root)
            assert service.generation not in (first.generation,second.generation)
            # The existing attach check: the screen shows what the shell printed (also while no service ran), the shell has the
            # same pid and state, takes input and a resize, and its exit code arrives.
            run_tree([*RUNNER,'attach',str(root),str(SERVICE)],environment)
            deadline=time.monotonic()+15
            while hosts_of(fixture):
                assert time.monotonic()<deadline,'the terminal host did not end after its shell exited'
                time.sleep(.5)
            print('PASS: a hosted terminal (shell pid %d) kept its process and screen across a stopped service and a killed one'%shell,flush=True)
        except Exception:
            print(logs(),file=sys.stderr)
            raise
        finally:
            kill(service)
            for pid in hosts_of(fixture): subprocess.run(['taskkill','/F','/T','/PID',str(pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

# ---- exohost and the kill switches (docs/design/terminal-host-status.md): a host is listed by exohost under its workspace, is
# kept by Quit and by bulk stops, and ends on `exohost terminals end`; a service start ends no host, removes dead hosts'
# folders and unused runtime copies.
from exohost import library_path, library_variable
EXOHOST=ROOT/'exohost/build/host/main.hl'
assert EXOHOST.is_file(),'build exohost first: %s'%EXOHOST
with tempfile.TemporaryDirectory(prefix='exhost-',ignore_cleanup_errors=True) as temporary:
    fixture=Path(temporary); root=fixture/'project'; root.mkdir(); state=fixture/'state'
    # Its own exohost: hosts register in this home only, and exohost reads no other process (EXOSUIT_EXOHOST_SCAN=0).
    environment=environment_of(state,EXOSUIT_EXOHOST_HOME=str(fixture/'exohost-home'),EXOSUIT_EXOHOST_AUTOSTART='0',
        EXOSUIT_EXOHOST_TRAY='0',EXOSUIT_EXOHOST_SCAN='0',EXOSUIT_TERMINAL_HOST_CHECK_SECONDS='1')
    exohost_environment=dict(environment,EXOSUIT_EXOHOST_LAUNCHER=str(EXOHOST))
    exohost_environment[library_variable()]=library_path(EXOHOST,Path(RUNNER[0]),HAXEON_ROOT,environment['PATH'])
    def exohost(*arguments):
        result=subprocess.run([RUNNER[0],str(EXOHOST),*arguments],env=exohost_environment,capture_output=True,text=True,timeout=60)
        assert result.returncode==0,'exohost %s failed (%d): %s%s'%(' '.join(arguments),result.returncode,result.stderr,result.stdout)
        return result.stdout
    def planned(*arguments): return {int(line.split()[0]) for line in exohost(*arguments,'--dry-run').splitlines() if line.endswith('would stop')}
    def start(idle=8):
        service=begin(environment,state,root,idle)
        time.sleep(1)
        return service
    def logs():
        text=service_logs(state)
        for path in state.glob('exosuit/workspaces/*/terminal-hosts/*/host.log'): text+='\n== '+str(path)+'\n'+path.read_text(errors='replace')[-4000:]
        return text
    exohost('status')
    if True:
        manager=start()
        try:
            run_tree([*RUNNER,'create',str(root),str(SERVICE)],environment)
            hosts=hosts_of(fixture)
            assert len(hosts)==1,'expected one terminal host, found %r'%hosts
            host=hosts[0]; shell=int((root/'shell-pid').read_text().strip())
            workspace=log_of(state,workspace_id(root)).parent; folders=workspace/'terminal-hosts'; copies=state/'exosuit/terminal-host'
            folder=next(path for path in folders.iterdir() if (path/'host.json').is_file())
            assert json.loads((folder/'terminal.json').read_text())['terminal']=='test-terminal','the service did not say which terminal the host keeps'
            assert list(copies.glob('*/host-%d.lease'%host)),'the host holds no lease in its runtime copy'
            stop(manager)
            # 1. exohost knows the host, with no service running: its own kind, under its workspace, not orphaned, in `kill --all`.
            listing=json.loads(exohost('list','--json'))
            entry=next((process for process in listing['processes'] if process['pid']==host),None)
            assert entry is not None,'exohost does not list the terminal host: %r'%listing
            assert entry['kind']=='terminal-host' and entry['source']=='registered' and not entry['orphaned'],entry
            assert entry['terminal']['terminal']=='test-terminal' and entry['workspace']==root.name,entry
            assert listing['terminals']==1 and '1 terminal' in listing['summary'],listing
            assert host in planned('kill','--all') and host not in planned('kill','--orphans'),'`kill --all` must include the host and the orphan sweep must not'
            assert planned('terminals','end','--all')=={host} and planned('terminals','end',str(root))=={host},'`exohost terminals end` does not select the host'
            menu=exohost('menu')
            assert str(host) in exohost('terminals') and 'End all terminals (1)' in menu and 'Quit Exosuit and end everything (1 terminal)' in menu and 'Quit, keep terminals running (1)' in menu,menu
            # 2. The polite quit keeps the terminal and says so (the full quit is covered by scripts/test-exohost.py).
            said=exohost('quit','--keep-terminals')
            assert '1 terminal keeps running' in said and 'exohost terminals end --all' in said,said
            assert pid_runs(host) and pid_runs(shell),'the polite quit ended the terminal'
            # 3. Planted: a host folder with no terminal record that holds a last screen, an old one with no host and nothing
            # to collect, an old runtime copy nothing runs from and a young one.
            unrecorded=folders/('0'*24); unrecorded.mkdir(); (unrecorded/'host.log').write_text('left behind\n'); (unrecorded/'screen.bin').write_bytes(b'last')
            dead=folders/('1'*24); dead.mkdir(); (dead/'host.log').write_text('dead\n')
            os.utime(dead,(time.time()-300,time.time()-300))
            for name,age in (('0'*16,7200),('1'*16,30)):
                (copies/name).mkdir(); (copies/name/'hl.exe').write_bytes(b'not a program'); (copies/name/'complete').write_text('x\n')
                os.utime(copies/name/'complete',(time.time()-age,time.time()-age))
            # A service start keeps the folder with a last screen, removes the folder of a host that is gone and the runtime
            # copy no host runs from, and keeps the young copy and its own.
            manager=start()
            assert unrecorded.is_dir(),'a host folder that holds a last screen was removed'
            assert not dead.exists(),'the folder of a host that is gone was not removed'
            assert (folder/'host.json').is_file(),'the recorded terminal\'s host was disturbed'
            assert not (copies/('0'*16)).exists(),'an unused runtime copy was not removed'
            assert (copies/('1'*16)).exists(),'a runtime copy made a moment ago was removed'
            assert list(copies.glob('*/host-%d.lease'%host)) and pid_runs(host),'the running host lost its runtime copy'
            stop(manager)
            # A service whose terminal catalog is empty (the database was replaced or recreated) ends no host and removes no
            # host folder: the running host has no record there, and is only logged.
            aside=fixture/'catalog-aside'; aside.mkdir()
            moved=list(workspace.glob('catalog.sqlite*'))
            for path in moved: path.rename(aside/path.name)
            manager=start()
            assert (folder/'host.json').is_file() and unrecorded.is_dir(),'a service with an empty terminal catalog disturbed the host folders'
            assert 'has no terminal record in this workspace: left running' in logs(),'the service did not log the host it has no record of'
            stop(manager)
            time.sleep(1.5)
            assert pid_runs(host) and pid_runs(shell),'a service with an empty terminal catalog ended the terminal'
            for path in workspace.glob('catalog.sqlite*'): path.unlink()
            for path in moved: (aside/path.name).rename(workspace/path.name)
            # The host with no service attached (it checks every second here): exohost's list of workspaces is emptied, then lists
            # only another workspace. Neither is a removal of the host's workspace: the program keeps running.
            identity=folder/'terminal.json'; written=identity.read_text()
            identity.write_text(json.dumps(dict(json.loads(written),workspace='workspace-lifecycle-test'))+'\n')
            catalog=fixture/'exohost-home'/'machine.json'; kept=catalog.read_text() if catalog.exists() else None
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
            # A host that runs but does not answer (suspended here) is lost for now, never ended: the service tries it again
            # and takes the same shell back once it answers.
            suspended=kernel.OpenProcess(0x0800,False,host)
            ntdll=ctypes.WinDLL('ntdll')
            assert suspended and ntdll.NtSuspendProcess(ctypes.c_void_p(suspended))==0,'the host could not be suspended'
            # No client comes while the host is suspended, and a running terminal does not keep a service: a longer idle limit.
            manager=start(idle=90)
            deadline=time.monotonic()+60
            while 'test-terminal is lost' not in logs():
                assert time.monotonic()<deadline,'the service did not give up waiting for the host that does not answer'
                time.sleep(.5)
            assert pid_runs(host) and pid_runs(shell),'the service ended a host that did not answer'
            assert ntdll.NtResumeProcess(ctypes.c_void_p(suspended))==0,'the host could not be resumed'
            kernel.CloseHandle(ctypes.c_void_p(suspended))
            run_tree([*RUNNER,'host-type',str(root),str(SERVICE),'test-terminal','attach',"'RESUMED_'+'SHELL'",'RESUMED_SHELL'],environment,timeout=150)
            assert hosts_of(fixture)==[host] and pid_runs(shell),'the terminal was not taken back from the same host'
            kill(manager)  # its idle limit is long
            # 4. The kill switch: `exohost terminals end --all` kills the host and its program.
            assert planned('terminals','end','--all')=={host}
            ended=exohost('terminals','end','--all')
            assert str(host) in ended,ended
            deadline=time.monotonic()+15
            while pid_runs(host) or pid_runs(shell):
                assert time.monotonic()<deadline,'`exohost terminals end --all` left the host or its shell running: %s'%ended
                time.sleep(.2)
            assert json.loads(exohost('list','--json'))['terminals']==0 and 'No terminal is kept running' in exohost('terminals')
            # 5. A host that fails to start (its runtime copy's bytecode is broken here) leaves no spec.bin: it holds the
            # program's environment and the pipe's token.
            manager=start()
            for program in copies.glob('*/terminal-host.hl'): program.write_bytes(b'not bytecode')
            # The client's own result does not matter here: what the start leaves in the host's folder does.
            subprocess.run([*RUNNER,'host-type',str(root),str(SERVICE),'term-broken','create',"'NEVER'"],env=environment,
                stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=120)
            broken_folder=folders/hashlib.sha256(b'term-broken').hexdigest()[:24]
            deadline=time.monotonic()+30
            while 'term-broken is failed' not in logs():
                assert time.monotonic()<deadline,'the terminal whose host cannot start did not fail'
                time.sleep(.5)
            assert broken_folder.is_dir() and not (broken_folder/'spec.bin').exists(),'spec.bin was left behind by a host that failed to start'
            assert 'exited before it was ready' in logs(),'the host did not fail the way this check expects'
            stop(manager)
            print('PASS: exohost lists a terminal host, the polite quit keeps it, kill --all includes it, `exohost terminals end` ends it; a service start ends no host (an empty terminal catalog included), keeps a folder with a last screen and removes dead folders and unused runtime copies; an empty or partial machine.json ends no unattached host; a host that does not answer is not ended and is taken back once it answers; a host that fails to start leaves no spec.bin',flush=True)
        except Exception:
            print(logs(),file=sys.stderr)
            raise
        finally:
            kill(manager)
            for pid in hosts_of(fixture): subprocess.run(['taskkill','/F','/T','/PID',str(pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

# Several terminals, two workspaces: each comes back to its own view with its scrollback (also what was printed while no
# service ran) and its full-screen program's modes; a service whose connection to a host breaks connects again in place;
# a program that ends while no service runs leaves its last screen and exit code for the next service.
with tempfile.TemporaryDirectory(prefix='exhosts-',ignore_cleanup_errors=True) as temporary:
    fixture=Path(temporary); state=fixture/'state'
    roots={'a':fixture/'project-a','b':fixture/'project-b'}
    for path in roots.values(): path.mkdir()
    environment=environment_of(state)
    managers={}
    def start(key):
        managers[key]=begin(environment,state,roots[key])
        return managers[key].generation
    def stop_key(key):
        """Stops workspace `key`'s service (it idles out) and returns its state folder."""
        stop(managers[key])
        return log_of(state,workspace_id(roots[key])).parent
    def client(mode,key,*arguments,timeout=90):
        run_tree([*RUNNER,mode,str(roots[key]),str(SERVICE),*[str(value) for value in arguments]],environment,timeout)
    def view(key,terminal,expected=None):
        target=fixture/('view-%s.json'%terminal)
        client('host-dump',key,terminal,target,*([expected] if expected else []))
        return json.loads(target.read_text(encoding='utf-8'))
    def text(dump): return '\n'.join(dump['lines'])
    def host_folder(workspace,terminal):
        return workspace/'terminal-hosts'/hashlib.sha256(terminal.encode()).hexdigest()[:24]
    def logs():
        text=service_logs(state,8000)
        for path in state.glob('exosuit/workspaces/*/terminal-hosts/*/host.log'): text+='\n== '+str(path)+'\n'+path.read_text(errors='replace')[-3000:]
        return text
    def numbered(prefix,count,gate):
        """A command that prints `count` numbered lines, and 40 more once the file `gate` exists."""
        return ("1..%d | %% { '%s_LINE_{0:0000}' -f $_ }; '%s_'+'READY'; while (!(Test-Path '%s')) { Start-Sleep -Milliseconds 200 }; "
            "1..40 | %% { '%s_LATE_{0:00}' -f $_ }; '%s_'+'DONE'")%(count,prefix,prefix,gate,prefix,prefix)
    if True:
        try:
            generations={key:start(key) for key in roots}
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
            workspaces={key:stop_key(key) for key in roots}
            # Output while no service runs.
            gate.write_text('go')
            time.sleep(3)
            assert sorted(hosts_of(fixture))==sorted(hosts),'terminal hosts ended with their services'
            restarted={key:start(key) for key in roots}
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
            # The host sends its whole history again on the new connection: a view gets each line once, not twice.
            for marker in ('A2_LINE_0001','A2_LATE_01','A2_DONE'):
                seen=sum(1 for line in again['lines'] if marker in line)
                assert seen==1,'after the reconnect the view shows %s %d times:\n%s'%(marker,seen,text(again))
            assert managers['a'].runs() and managers['a'].generation==restarted['a'],'the service was replaced instead of connecting again'
            assert 'connected again' in (workspaces['a']/'service.log').read_text(errors='replace'),'the service did not log the reconnect'
            # A program that ends while no service is attached.
            client('host-type','b','term-b1','attach',"while (!(Test-Path '%s')) { Start-Sleep -Milliseconds 200 }; 'B1_LAST_'+'SCREEN'; exit 9"%last)
            stop_key('b')
            last.write_text('go')
            final=host_folder(workspaces['b'],'term-b1')/'screen.bin'
            deadline=time.monotonic()+20
            while not final.exists() or len(hosts_of(fixture))!=3:
                assert time.monotonic()<deadline,'the host of the ended program did not leave screen.bin and end'
                time.sleep(.25)
            start('b')
            ended=view('b','term-b1','B1_LAST_SCREEN')
            assert ended['found'] and ended['state']=='exited' and ended['exitCode']==9,'the ended program came back as %r, exit code %r'%(ended['state'],ended['exitCode'])
            assert 'B1_LINE_0001' in text(ended),'the ended program lost its scrollback'
            assert final.exists(),'the last screen of the ended terminal was removed before the terminal was closed'
            print('PASS: four hosted terminals in two workspaces came back to their own views with %d lines of scrollback, a full-screen program kept its modes, a broken host connection was opened again, and an exit with no service kept its screen and code'%a1['scrollback'],flush=True)
        except Exception:
            print(logs(),file=sys.stderr)
            raise
        finally:
            for service in managers.values(): kill(service)
            for pid in hosts_of(fixture): subprocess.run(['taskkill','/F','/T','/PID',str(pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

# A flood of coloured output: a host sends faster than the service takes it in. The service's connection holds at most
# 1 MiB it has not read and closes when more arrives, so the host may send only what the service said it has taken
# (TerminalHostProtocol.CREDIT).
with tempfile.TemporaryDirectory(prefix='exhostflood-',ignore_cleanup_errors=True) as temporary:
    fixture=Path(temporary); state=fixture/'state'; root=fixture/'project'; root.mkdir()
    environment=environment_of(state,EXOSUIT_TEST_TERMINAL_COLUMNS='200')
    def flood_client(mode,*arguments,timeout=120):
        run_tree([*RUNNER,mode,str(root),str(SERVICE),*[str(value) for value in arguments]],environment,timeout)
    def service_log():
        return ''.join(path.read_text(errors='replace') for path in state.glob('exosuit/workspaces/*/service.log'))
    if True:
        manager=begin(environment,state,root)
        try:
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
            print('PASS: a host printing 6000 lines of 200 coloured columns kept its connection to the service (%d lines above the screen)'%dump['scrollback'],flush=True)
        except Exception:
            print(service_log()[-6000:],file=sys.stderr)
            for path in state.glob('exosuit/workspaces/*/terminal-hosts/*/host.log'): print('== '+str(path)+'\n'+path.read_text(errors='replace')[-3000:],file=sys.stderr)
            raise
        finally:
            kill(manager)
            for pid in hosts_of(fixture): subprocess.run(['taskkill','/F','/T','/PID',str(pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

# ---- Memory: four terminals filled with 10000 lines of 200-column
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
        environment=environment_of(state,EXOSUIT_TEST_TERMINAL_COLUMNS='200')
        def client(mode,*arguments,timeout=120):
            run_tree([*RUNNER,mode,str(root),str(SERVICE),*[str(value) for value in arguments]],environment,timeout)
        def view(terminal,expected=None):
            target=fixture/('view-%s.json'%terminal)
            client('host-dump',terminal,target,*([expected] if expected else []))
            return json.loads(target.read_text(encoding='utf-8'))
        if True:
            manager=begin(environment,state,root)
            try:
                base=report('empty service',private_memory(fixture))
                terminals=['mem-%d'%number for number in range(1,5)]
                for terminal in terminals:
                    done=fixture/('done-'+terminal)
                    fill=("$e=[char]27; $l=-join (0..194 | %% { $e+'[38;5;'+($_ %% 200 + 16)+'m'+[char](65+$_ %% 26) }); "
                        "1..10000 | %% { ('{0:00000}' -f $_)+$l }; $e+'[0m'; 'FILL_'+'DONE'; 'x' > '%s'")%done
                    client('host-type',terminal,'create',fill)
                deadline=time.monotonic()+600
                # The highest the service reached while the terminals filled.
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
                print(service_logs(state),file=sys.stderr)
                raise
            finally:
                kill(manager)
                for pid in hosts_of(fixture): subprocess.run(['taskkill','/F','/T','/PID',str(pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
