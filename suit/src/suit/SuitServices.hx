package suit;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.ChildProcess;
import suit.MachineCatalog.MachineService;
import suit.MachineCatalog.MachineWorkspace;
import suit.SuitRecord.SuitRecords;
import workspace.client.OpenedService;
import workspace.client.WorkspaceServiceTarget;
import workspace.transport.NativeRpcTransport;

private typedef ServiceEntry = {
	var transport:NativeRpcTransport;
	var workspace:String;
	var endpoint:String;
	var pid:Int;
	var generation:String;
	var root:String;
	var launcher:String;
	var build:String;
	/** The user stopped it: it is not handed out any more. */
	var stopping:Bool;
	/** When suit asked it to stop once no agent turn runs (it runs another build); 0 while it was not asked. */
	var replacedAt:Float;
}

private typedef Start = {
	var workspace:String;
	/** The process suit started, until it reports or exits; null while an older service is still stopping. */
	var child:Null<ChildProcess>;
	/** The process exited because another service holds the workspace's lock: that one's report answers the start. */
	var locked:Bool;
	var deadline:Float;
	var waiters:Array<(Null<OpenedService>, Null<String>) -> Void>;
	/** The link of the spare this start adopted: its `service-attach` comes over it. */
	var link:Null<NativeRpcTransport>;
	/** The length of the workspace's `service.log` when the start began: `failure` reads only what came after. */
	var logFrom:Int;
}

/** The warm spare: started, and linked once it says `service-spare`. */
private typedef Spare = {
	var child:ChildProcess;
	var launcher:String;
	var build:String;
	var link:Null<NativeRpcTransport>;
	var pid:Int;
	var deadline:Float;
}

/**
	The workspace services, one process per running workspace. suit starts them (`open`, which the editors' link and
	the machine remote ask), and a service reports itself once it listens: it connects to suit's pipe, says which
	workspace it serves on which pipe (`service-attach`, sent by SuitServiceLink) and keeps the connection open while it
	runs. suit learns that it is ready from the attach and that it stopped from the connection closing; nothing is
	scanned and nothing is read from disk.

	A service of another build (its program or build stamp is not the one suit would start now) is asked to stop once
	no agent turn runs, and the next one starts as soon as it is gone: its terminals carry on in their hosts. One that
	is still there after HANDOVER_SECONDS runs a turn: opens are answered with it until it stops, and the next open
	after that starts the new one.

	While an editor is linked (`keepSpare`) suit holds one warm spare: an agent process started with `--spare`, loaded
	and linked (`service-spare`) but serving nothing. An idle workspace that is opened adopts it (`adopt`, with the
	workspace's folders) instead of waiting for a process start, and a new spare is started behind it. A spare of another
	build is stopped and replaced; one that fails to start is tried again after SPARE_RETRY_SECONDS.
**/
class SuitServices {
	/** How long a service of another build may take to stop before opens are answered with it (it runs a turn). */
	static inline final HANDOVER_SECONDS = 2.0;
	/** How long a start may take before the open fails. */
	static inline final START_SECONDS = 30.0;
	/** The exit status of a service that found its workspace's state locked by another one (AgentMain). */
	static inline final IN_USE = 3;
	/** How long a spare may take to link before it is given up. */
	static inline final SPARE_SECONDS = 30.0;
	/** The wait after a spare failed before the next is started. */
	static inline final SPARE_RETRY_SECONDS = 30.0;

	final entries:Array<ServiceEntry> = [];
	final starts:Map<String, Start> = [];
	final workspace:String->Null<MachineWorkspace>;
	final scratch:String->Null<String>;
	/** Changes whenever a service comes or goes. */
	public var revision(default, null):Int = 0;
	var spare:Null<Spare>;
	var spareWanted = false;
	var spareRetryAt = 0.0;

	/** `workspace` finds a workspace in the machine catalog; `scratch` makes (or finds) the scratch folder of one with no folders. */
	public function new(workspace:String->Null<MachineWorkspace>, scratch:String->Null<String>) {
		this.workspace = workspace;
		this.scratch = scratch;
	}

	/** The agent bytecode beside suit's own (a source build's agent/build/host/main.hl, or a bundle's tools/exosuit-agent.hl). */
	public static function agentLauncher():Null<String> {
		var configured = Sys.getEnv("EXOSUIT_AGENT_LAUNCHER");
		if (configured != null && configured.length > 0)
			return FileSystem.exists(configured) ? FileSystem.fullPath(configured) : null;
		var own = SuitClient.findLauncher();
		if (own == null)
			return null;
		var directory = Path.directory(own);
		for (candidate in [Path.join([Path.directory(Path.directory(Path.directory(directory))), "agent", "build", "host", "main.hl"]),
			Path.join([directory, "exosuit-agent.hl"])])
			if (FileSystem.exists(candidate))
				return FileSystem.fullPath(candidate);
		return null;
	}

	/**
		Gives `done` the running service of workspace `id`, starting it first when none runs (or when the one that runs is
		of another build). Every open of a workspace whose start is under way waits for that start.
	**/
	public function open(id:String, done:(Null<OpenedService>, Null<String>) -> Void):Void {
		var entry = workspace(id);
		if (entry == null) {
			done(null, "unknown_workspace");
			return;
		}
		var running = find(id);
		if (running != null && !running.stopping) {
			var now = Sys.time();
			if (current(running) || running.replacedAt > 0 && now >= running.replacedAt + HANDOVER_SECONDS) {
				done(opened(running), null);
				return;
			}
			if (running.replacedAt == 0) {
				running.replacedAt = now;
				send(running, {op: "stop", when: "turn"});
			}
		}
		var start = starts.get(id);
		if (start == null) {
			start = {workspace: id, child: null, locked: false, deadline: Sys.time() + START_SECONDS, waiters: [], link: null,
				logFrom: logLength(id)};
			if (find(id) == null)
				try {
					if (!adopt(start, entry))
						start.child = spawn(entry);
				} catch (error:Dynamic) {
					done(null, Std.string(error));
					return;
				}
			starts.set(id, start);
		}
		start.waiters.push(done);
	}

	/** Whether `entry` runs the build suit would start now. */
	static function current(entry:ServiceEntry):Bool {
		var launcher = agentLauncher();
		return launcher == null || entry.launcher == launcher && entry.build == SuitServiceLink.buildOf(launcher);
	}

	function spawn(entry:MachineWorkspace):ChildProcess {
		var launcher = agentLauncher();
		if (launcher == null)
			throw "The workspace agent is not installed";
		var target = targetOf(entry);
		return sys.io.Process.spawn(Sys.executablePath(), [launcher].concat(target.serviceArguments()), target.root(),
			[SuitClient.libraryVariable()], [SuitClient.nativePath(launcher)], true);
	}

	/** The workspace as its service serves it; throws when it has no folder that exists. */
	function targetOf(entry:MachineWorkspace):WorkspaceServiceTarget {
		var folder = entry.scratch;
		if (entry.folders.length == 0 && folder == null)
			folder = scratch(entry.id);
		var target = WorkspaceServiceTarget.forWorkspace(entry.id, entry.folders, folder);
		if (target.root() == null)
			throw "This workspace has no folder that exists";
		return target;
	}

	/**
		Hands the linked spare to `start` (`adopt`): it serves the workspace from now on and reports it over its link.
		False when there is no spare ready, or it runs another build than suit would start now.
	**/
	function adopt(start:Start, entry:MachineWorkspace):Bool {
		var ready = spare, launcher = agentLauncher();
		if (ready == null || ready.link == null || launcher == null)
			return false;
		var link:NativeRpcTransport = ready.link;
		if (!link.isOpen() || ready.launcher != launcher || ready.build != SuitServiceLink.buildOf(launcher)) {
			dropSpare();
			return false;
		}
		var target = targetOf(entry);
		if (!link.send(Bytes.ofString(Json.stringify({op: "adopt", workspace: target.workspace, folders: target.folders, scratch: target.scratch})))) {
			dropSpare();
			return false;
		}
		spare = null;
		start.child = ready.child;
		start.link = link;
		return true;
	}

	/** Whether suit holds a warm spare: while an editor is linked. Without one wanted, the spare there is stopped. */
	public function keepSpare(wanted:Bool):Void {
		spareWanted = wanted;
		if (!wanted)
			dropSpare();
	}

	/** Takes over the connection of a spare that says `service-spare`; false when it is not the spare suit started. */
	public function linkSpare(transport:NativeRpcTransport, request:Dynamic):Bool {
		// The spare suit started is the one that links while it waits (a child's pid is not known to suit).
		var waiting = spare, pid = SuitRecords.intField(request, "pid");
		if (waiting == null || waiting.link != null || pid == null || pid <= 0) {
			transport.send(Bytes.ofString(Json.stringify({ok: false, error: "no spare was started"})));
			return false;
		}
		waiting.link = transport;
		waiting.pid = pid;
		waiting.launcher = text(request, "launcher");
		waiting.build = text(request, "build");
		transport.send(Bytes.ofString(Json.stringify({ok: true})));
		return true;
	}

	/** Starts a spare when one is wanted and none runs; ends one that exited, never linked, or lost its link. */
	function pollSpare(now:Float):Void {
		var held = spare;
		if (held != null) {
			var link = held.link;
			var status = held.child.pollExit();
			var gone = status != null && status >= 0 || link != null && !link.isOpen() || link == null && now >= held.deadline;
			if (link != null)
				try while (link.receive() != null) {} catch (_:Dynamic) link.close();
			if (gone) {
				if (link == null)
					spareRetryAt = now + SPARE_RETRY_SECONDS;
				dropSpare();
			}
		}
		if (spare != null || !spareWanted || now < spareRetryAt)
			return;
		var launcher = agentLauncher();
		if (launcher == null)
			return;
		try {
			var child = sys.io.Process.spawn(Sys.executablePath(), [launcher, "--spare"], Path.directory(launcher),
				[SuitClient.libraryVariable()], [SuitClient.nativePath(launcher)], true);
			spare = {child: child, launcher: launcher, build: "", link: null, pid: 0, deadline: now + SPARE_SECONDS};
		} catch (_:Dynamic) {
			spareRetryAt = now + SPARE_RETRY_SECONDS;
		}
	}

	/** Ends the spare: closing its link ends a linked one; one not linked yet is killed. */
	function dropSpare():Void {
		var held = spare;
		spare = null;
		if (held == null)
			return;
		var link = held.link;
		if (link != null)
			link.close();
		else
			try held.child.cancel() catch (_:Dynamic) {}
		try held.child.close() catch (_:Dynamic) {}
	}

	/** Takes over a connection whose first request was `service-attach`. False when the request is not valid. */
	public function attach(transport:NativeRpcTransport, request:Dynamic):Bool {
		var id = SuitRecords.stringField(request, "workspace"), endpoint = SuitRecords.stringField(request, "endpoint");
		var pid = SuitRecords.intField(request, "pid");
		if (id == null || endpoint == null || pid == null || pid <= 0) {
			transport.send(Bytes.ofString(Json.stringify({ok: false, error: "service-attach needs workspace, endpoint and pid"})));
			return false;
		}
		var entry:ServiceEntry = {transport: transport, workspace: id, endpoint: endpoint, pid: pid,
			generation: text(request, "generation"), root: text(request, "root"), launcher: text(request, "launcher"),
			build: text(request, "build"), stopping: false, replacedAt: 0};
		entries.push(entry);
		transport.send(Bytes.ofString(Json.stringify({ok: true})));
		revision++;
		// Whoever started it, a service of the workspace answers the opens waiting for one.
		var start = starts.get(id);
		if (start != null)
			finish(start, opened(entry), null);
		return true;
	}

	static function text(request:Dynamic, field:String):String {
		var value = SuitRecords.stringField(request, field);
		return value == null ? "" : value;
	}

	static function opened(entry:ServiceEntry):OpenedService
		return {endpoint: entry.endpoint, generation: entry.generation, root: entry.root};

	/** Drops services whose connection closed, starts what waited for them, and ends starts that failed or took too long. */
	public function poll():Void {
		var index = entries.length;
		while (index-- > 0) {
			var entry = entries[index];
			try while (entry.transport.receive() != null) {} catch (_:Dynamic) entry.transport.close();
			if (!entry.transport.isOpen()) {
				entries.splice(index, 1);
				revision++;
			}
		}
		var now = Sys.time();
		pollSpare(now);
		for (start in [for (start in starts) start]) {
			// An adopted spare reports over its own link.
			var link = start.link;
			if (link != null) {
				var request:Dynamic = null;
				try {
					var received = link.receive();
					if (received != null) request = Json.parse(received.toString());
				} catch (_:Dynamic) {}
				if (request != null && SuitRecords.stringField(request, "op") == "service-attach") {
					start.link = null;
					if (attach(link, request))
						continue;
				}
			}
			var child = start.child;
			if (child == null) {
				var running = find(start.workspace);
				if (running != null && !running.stopping && running.replacedAt > 0 && now >= running.replacedAt + HANDOVER_SECONDS)
					finish(start, opened(running), null);
				else if (now >= start.deadline)
					finish(start, null, "The workspace service did not start in time");
				else if (!start.locked && find(start.workspace) == null)
					restart(start);
				continue;
			}
			var status = child.pollExit();
			if (status == IN_USE) {
				// Another service holds the workspace's lock (one suit did not start, or one whose link has not come back
				// yet): it reports itself within seconds, and its attach answers this start.
				close(start);
				start.locked = true;
				continue;
			}
			if (status >= 0)
				finish(start, null, failure(start, status));
			else if (now >= start.deadline)
				finish(start, null, "The workspace service did not start in time");
		}
	}

	/** The older service this start waited for is gone: start the new one. */
	function restart(start:Start):Void {
		starts.remove(start.workspace);
		for (waiter in start.waiters)
			open(start.workspace, waiter);
	}

	static function logOf(workspace:String):String
		return Path.join([MachineCatalog.agentStateBase(), "workspaces", workspace, "service.log"]);

	static function logLength(workspace:String):Int {
		var metadata = FileSystem.metadata(logOf(workspace));
		return metadata == null ? 0 : metadata.size;
	}

	/** Why a service that suit started exited before it reported: the last failure its `service.log` names since `start` began. */
	static function failure(start:Start, status:Int):String {
		var reason = 'The workspace service exited with status $status before it was ready';
		try {
			var bytes = sys.io.File.getBytes(logOf(start.workspace));
			var from = start.logFrom <= bytes.length ? start.logFrom : 0;
			for (line in bytes.getString(from, bytes.length - from).split("\n")) {
				var at = line.indexOf("Workspace startup failed: ");
				if (at >= 0)
					reason = StringTools.trim(line.substr(at + "Workspace startup failed: ".length));
			}
		} catch (_:Dynamic) {}
		return reason;
	}

	function finish(start:Start, service:Null<OpenedService>, failure:Null<String>):Void {
		starts.remove(start.workspace);
		close(start);
		for (waiter in start.waiters)
			try waiter(service, failure) catch (_:Dynamic) {}
	}

	static function close(start:Start):Void {
		var child = start.child;
		start.child = null;
		if (child != null)
			try child.close() catch (_:Dynamic) {}
		var link = start.link;
		start.link = null;
		if (link != null)
			link.close();
	}

	/** Asks the service of process `pid` (or the spare) to stop now. False when no service of that process is linked. */
	public function stop(pid:Int):Bool {
		var held = spare;
		if (held != null && held.pid == pid) {
			dropSpare();
			spareRetryAt = Sys.time() + SPARE_RETRY_SECONDS;
			return true;
		}
		for (entry in entries)
			if (entry.pid == pid) {
				entry.stopping = true;
				send(entry, {op: "stop", when: "now"});
				return true;
			}
		return false;
	}

	static function send(entry:ServiceEntry, message:Dynamic):Void
		try entry.transport.send(Bytes.ofString(Json.stringify(message))) catch (_:Dynamic) {}

	function find(id:String):Null<ServiceEntry> {
		var index = entries.length;
		while (index-- > 0)
			if (entries[index].workspace == id)
				return entries[index];
		return null;
	}

	/** The running service of workspace `id`: the one that reported last. */
	public function serviceOf(id:String):Null<MachineService> {
		var entry = find(id);
		return entry == null ? null : {endpoint: entry.endpoint, pid: entry.pid, running: true};
	}

	public function count():Int
		return entries.length;

	/** Starts under way, or a spare not linked yet: they keep suit's loop turning quickly. */
	public function busy():Bool {
		var held = spare;
		return starts.keys().hasNext() || held != null && held.link == null;
	}

	public function dispose():Void {
		for (entry in entries)
			entry.transport.close();
		entries.resize(0);
		for (start in starts)
			close(start);
		starts.clear();
		dropSpare();
	}
}
