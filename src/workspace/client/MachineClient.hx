package workspace.client;

import haxe.Json;
import exohost.MachineCatalog;
import exohost.MachineCatalog.MachineService;
import exohost.MachineCatalog.MachineState;
import exohost.MachineCatalog.MachineWorkspace;
import exohost.ExohostClient;
import exohost.ExohostLink;
import exohost.WindowFocus;
import exohost.WindowFocus.WindowFocuses;
import workspace.PathKey;
import workspace.sessions.SessionIndex;

/**
	This machine and its workspaces, from exohost (docs/architecture/0005-machines-and-workspaces.md), over the window's
	exohost link. exohost pushes the machine whenever it changes: its workspaces, the service each one runs and where every
	window is focused. Changes are requests on the same link; nothing here polls and nothing blocks the caller.
**/
class MachineClient {
	final link:ExohostLink;

	public var machine(default, null):Null<MachineState>;
	/** Where each editor window is focused, as exohost last pushed it (M19 Phase 8). */
	public var windows(default, null):Array<WindowFocus> = [];
	/** Why the last push or request failed; null after one succeeds. */
	public var error(default, null):Null<String>;
	/** Changes whenever `machine`, `windows` or `error` does. */
	public var revision(default, null):Int = 0;
	/** Scratch folders exohost made on request, until a push reports them. */
	final scratches:Map<String, String> = [];
	/** The running service of each workspace, as exohost last pushed them. */
	final services:Map<String, MachineService> = [];
	/** Changes to the workspaces sent and not answered yet. */
	var changing = 0;

	public function new(link:ExohostLink) {
		this.link = link;
		seedFromCatalog();
		link.onEvent = function(name, data) { if (name == "exosuit.machine.changed") pushed(data); };
	}

	/**
		Starts from exohost's saved catalog (the file exohost keeps it in), so the window can open its last workspace and show the
		tree before exohost's first push (0.45 s or more, seconds when exohost must start first). The push replaces it, and with
		it adds the services, which the file does not hold. A missing or unreadable file leaves the machine unknown.
	**/
	function seedFromCatalog():Void {
		try {
			var path = MachineCatalog.file();
			if (!sys.FileSystem.exists(path))
				return;
			machine = MachineCatalog.decode(sys.io.File.getContent(path));
			revision++;
			ConnectTimeline.mark("machine-seeded", null, machine.workspaces.length + " workspaces");
		} catch (_:Dynamic) {
			machine = null;
		}
	}

	/** Why exohost cannot be reached while the workspaces are still unknown after `UNREACHABLE_AFTER` seconds; else null. */
	public var unreachable(default, null):Null<String>;
	/** How long the window waits for exohost's first answer before it says why there is none. */
	public static inline final UNREACHABLE_AFTER = 4.0;
	var begun = Sys.time();
	var checkedAt = 0.0;

	/** Moves the link along; call every frame. */
	public function poll():Void {
		link.poll();
		var now = Sys.time();
		if (machine != null || link.isAttached()) {
			noteUnreachable(null);
			return;
		}
		if (now - begun < UNREACHABLE_AFTER || now - checkedAt < 1.0)
			return;
		checkedAt = now;
		noteUnreachable(ExohostClient.unreachableReason());
	}

	function noteUnreachable(reason:Null<String>):Void {
		if (reason == unreachable)
			return;
		unreachable = reason;
		revision++;
	}

	/** Try to reach exohost again, starting it if need be: the Workbench's Retry. */
	public function retry():Void {
		link.retryNow();
		begun = Sys.time();
		noteUnreachable(null);
	}

	/** Creates a workspace with these folders, which may be none if it has a name; `done` gets it, or the error. */
	public function create(name:Null<String>, folders:Array<String>, ?done:(Null<MachineWorkspace>, Null<String>) -> Void):Void
		change("workspace-create", {name: name, folders: folders.copy()}, workspaceReply(done, false));

	/** The workspace's scratch folder, which exohost creates on first request; `done` gets its path, or the error. */
	public function scratch(id:String, done:(Null<String>, Null<String>) -> Void):Void
		change("workspace-scratch", {workspace: id}, function(reply, failure) {
			var path:Null<String> = null;
			if (reply != null) {
				var value:Dynamic = Reflect.field(reply, "scratch");
				if (Std.isOfType(value, String) && (value : String).length > 0)
					path = value;
				else if (failure == null)
					failure = "exohost sent no scratch folder";
			}
			if (path != null) scratches.set(id, path);
			done(path, failure);
		});

	/**
		The running service of workspace `id`, which exohost starts first when the workspace is idle (`workspace.open`):
		`done` gets its pipe and identity, or why there is none. A ServiceOpener for the window's workspace clients.
	**/
	public function open(id:String, done:(Null<OpenedService>, Null<String>) -> Void):Void {
		var begun = Sys.time();
		ConnectTimeline.mark("exohost-queued", id, "workspace.open");
		link.call("workspace.open", {workspace: id}, function(reply, failure) {
			ConnectTimeline.mark("exohost-reply", id, "workspace.open" + (failure == null ? " ok " : " none ") + Std.int((Sys.time() - begun) * 1000) + " ms");
			var endpoint:Dynamic = reply == null ? null : Reflect.field(reply, "endpoint");
			var generation:Dynamic = reply == null ? null : Reflect.field(reply, "generation");
			var root:Dynamic = reply == null ? null : Reflect.field(reply, "root");
			if (failure == null && (!Std.isOfType(endpoint, String) || !Std.isOfType(generation, String) || !Std.isOfType(root, String)))
				failure = "exohost named no workspace service";
			done(failure == null ? {endpoint: endpoint, generation: generation, root: root} : null, failure);
		}, OPEN_TIMEOUT);
	}

	/** How long `open` waits for exohost: longer than exohost's own limit for a start, so exohost's answer says why one failed. */
	static inline final OPEN_TIMEOUT = 40.0;

	public function rename(id:String, name:String, ?done:(Null<MachineWorkspace>, Null<String>) -> Void):Void
		change("workspace-rename", {workspace: id, name: name}, workspaceReply(done, false));

	public function delete(id:String, ?done:(Null<MachineWorkspace>, Null<String>) -> Void):Void
		change("workspace-delete", {workspace: id}, workspaceReply(done, true));

	public function addFolder(id:String, folder:String, ?done:(Null<MachineWorkspace>, Null<String>) -> Void):Void
		change("workspace-add-folder", {workspace: id, folder: folder}, workspaceReply(done, false));

	public function removeFolder(id:String, folder:String, ?done:(Null<MachineWorkspace>, Null<String>) -> Void):Void
		change("workspace-remove-folder", {workspace: id, folder: folder}, workspaceReply(done, false));

	// ---- Remote access (ADR 0005 section 4): the machine's relay identity, paired devices and their workspaces.
	// Each reply is exohost's JSON as sent (docs/RPC-VECTORS.md, "exohost's machine reply"); `done` gets it or the error.

	/** Whether remote access is set up, its relay and whether the machine socket is connected. */
	public function remoteStatus(done:(Null<Dynamic>, Null<String>) -> Void):Void
		remote("remote-status", {}, done);

	/** Sets up remote access with this relay (an https origin; a loopback http one only for a development Worker). */
	public function remoteEnable(origin:String, done:(Null<Dynamic>, Null<String>) -> Void):Void
		remote("remote-enable", {origin: origin}, done);

	/** Stops using the relay and forgets its address, so `remoteEnable` can name another. */
	public function remoteDisable(done:(Null<Dynamic>, Null<String>) -> Void):Void
		remote("remote-disable", {}, done);

	/** A one-time pairing invitation: `invitation` has the pairing URL. */
	public function remoteInvite(ttlSeconds:Int, done:(Null<Dynamic>, Null<String>) -> Void):Void
		remote("remote-invite", {ttl: ttlSeconds}, done);

	/** Pending pairings, paired devices with the workspaces each is granted, and the machine's workspaces. */
	public function remoteDevices(done:(Null<Dynamic>, Null<String>) -> Void):Void
		remote("remote-devices", {}, done);

	/** Approves a pending device with these workspaces: each `{workspace, preset}` or `{workspace, grants}`; none grants nothing yet. */
	public function remoteApprove(deviceId:String, workspaces:Array<Dynamic>, done:(Null<Dynamic>, Null<String>) -> Void):Void
		remote("remote-approve", {deviceId: deviceId, workspaces: workspaces}, done);

	/** Replaces the workspaces a paired device is granted. */
	public function remoteGrant(deviceId:String, workspaces:Array<Dynamic>, done:(Null<Dynamic>, Null<String>) -> Void):Void
		remote("remote-grant", {deviceId: deviceId, workspaces: workspaces}, done);

	public function remoteReject(deviceId:String, done:(Null<Dynamic>, Null<String>) -> Void):Void
		remote("remote-reject", {deviceId: deviceId}, done);

	public function remoteRevoke(deviceId:String, done:(Null<Dynamic>, Null<String>) -> Void):Void
		remote("remote-revoke", {deviceId: deviceId}, done);

	// ---- Sessions (docs/phone-ui/CONTRACTS.md, D)

	/** Every session and terminal of this machine's running workspaces, as the last `sessions` call read them. */
	public final sessionIndex:SessionIndex = new SessionIndex();
	/** The workspaces the last `sessions` call could not read in time (their services did not answer). */
	public var unavailableWorkspaces(default, null):Array<String> = [];

	/**
		Asks exohost for the sessions and terminals of every running workspace service and replaces `sessionIndex` with them
		(its `revision` changes); `done` gets null, or why the call failed (the index is then unchanged). exohost waits up to
		2 s for each service, so a reply takes that long at most.
	**/
	public function sessions(?done:Null<String> -> Void):Void
		link.call("sessions", {}, function(reply, failure) {
			if (failure == null) {
				sessionIndex.replace(SessionIndex.fromJson(reply));
				var missing:Dynamic = reply == null ? null : Reflect.field(reply, "unavailable");
				unavailableWorkspaces = Std.isOfType(missing, Array) ? [for (id in (missing : Array<Dynamic>)) if (Std.isOfType(id, String)) (id : String)] : [];
				revision++;
			}
			if (done != null)
				done(failure);
		}, SESSIONS_TIMEOUT);

	/** Longer than exohost's 2 s per service. */
	static inline final SESSIONS_TIMEOUT = 8.0;

	/** The workspace with this id, if the machine has one. */
	public function workspaceById(id:String):Null<MachineWorkspace> {
		var state = machine;
		if (state == null)
			return null;
		for (workspace in state.workspaces)
			if (workspace.id == id)
				return workspace;
		return null;
	}

	/** The workspace that has `folder` among its folders, or as its scratch folder. */
	public function workspaceHolding(folder:String, ?preferred:String):Null<MachineWorkspace> {
		var state = machine;
		if (state == null)
			return null;
		return holdingIn(state.workspaces, folder, scratchOf, preferred);
	}

	/**
		The workspace a folder belongs to: `preferred` (the workspace a terminal was made in) when it is known, else the
		first that holds the folder. Two workspaces may share a first folder; only the id tells them apart.
	**/
	public static function holdingIn(workspaces:Array<MachineWorkspace>, folder:String, scratchOf:MachineWorkspace->Null<String>, ?preferred:String):Null<MachineWorkspace> {
		if (preferred != null)
			for (workspace in workspaces)
				if (workspace.id == preferred)
					return workspace;
		for (workspace in workspaces) {
			var scratch = scratchOf(workspace);
			if (scratch != null && PathKey.same(scratch, folder))
				return workspace;
			for (attached in workspace.folders)
				if (PathKey.same(attached, folder))
					return workspace;
		}
		return null;
	}

	/** The workspace's scratch folder if exohost already made one, as a push or a scratch request reported it. */
	public function scratchOf(workspace:MachineWorkspace):Null<String>
		return workspace.scratch != null ? workspace.scratch : scratches.get(workspace.id);

	/** The service a folder's workspace has: null until the machine's workspaces are known, and for a folder none holds. */
	public function serviceTargetFor(folder:String, ?preferred:String):Null<WorkspaceServiceTarget> {
		var workspace = workspaceHolding(folder, preferred);
		return workspace == null ? null : serviceTarget(workspace);
	}

	public function serviceTarget(workspace:MachineWorkspace):WorkspaceServiceTarget
		return WorkspaceServiceTarget.forWorkspace(workspace.id, workspace.folders, scratchOf(workspace));

	/** A change to the workspaces is on its way. */
	public function busy():Bool
		return changing > 0;

	/** The service exohost last reported for workspace `id`: null when it reported none. */
	public function serviceOf(id:String):Null<MachineService>
		return services.get(id);

	/** `removed`: the request deletes the workspace, otherwise the reply's workspace replaces what is known of it. */
	function workspaceReply(done:Null<(Null<MachineWorkspace>, Null<String>) -> Void>, removed:Bool):(Null<Dynamic>, Null<String>) -> Void
		return function(reply, failure) {
			var workspace:Null<MachineWorkspace> = null;
			var entry:Dynamic = reply == null ? null : Reflect.field(reply, "workspace");
			if (entry != null)
				try workspace = MachineCatalog.decodeWorkspace(entry) catch (error:Dynamic) failure = "exohost sent an invalid workspace: " + Std.string(error);
			if (workspace != null && failure == null)
				know(workspace, removed);
			if (done != null)
				done(workspace, failure);
		};

	/** Keeps the listing current until exohost's push arrives: the service a workspace's folders belong to follows its folders. */
	function know(workspace:MachineWorkspace, removed:Bool):Void {
		var state = machine;
		if (state == null)
			return;
		var found = -1;
		for (index in 0...state.workspaces.length)
			if (state.workspaces[index].id == workspace.id)
				found = index;
		if (removed) {
			if (found >= 0)
				state.workspaces.splice(found, 1);
		} else if (found >= 0)
			state.workspaces[found] = workspace;
		else
			state.workspaces.push(workspace);
		revision++;
	}

	function change(op:String, params:Dynamic, done:(Null<Dynamic>, Null<String>) -> Void):Void {
		changing++;
		ConnectTimeline.mark("exohost-queued", null, op);
		var begun = Sys.time();
		link.call(op, params, function(reply, failure) {
			changing--;
			ConnectTimeline.mark("exohost-reply", null, op + (failure == null ? " ok " : " none ") + Std.int((Sys.time() - begun) * 1000) + " ms");
			if (failure == null && reply != null && Reflect.hasField(reply, "machine"))
				failure = readMachine(Reflect.field(reply, "machine"));
			if (failure == null && error != null) {
				error = null;
				revision++;
			}
			done(failure == null ? reply : null, failure);
		});
	}

	function remote(op:String, params:Dynamic, done:(Null<Dynamic>, Null<String>) -> Void):Void
		link.call(op, params, done, ExohostLink.REMOTE_TIMEOUT);

	/** exohost pushed the machine: its workspaces with their services, and the windows' focus. */
	function pushed(data:Dynamic):Void {
		var failure = readMachine(data == null ? null : Reflect.field(data, "machine"));
		if (failure == null)
			windows = WindowFocuses.decode(data);
		error = failure;
		revision++;
	}

	/** Reads a machine listing as exohost sends it; returns why it is unusable, or null. */
	function readMachine(listing:Dynamic):Null<String> {
		if (listing == null)
			return "exohost sent no machine";
		try machine = MachineCatalog.decode(Json.stringify({version: MachineCatalog.VERSION, id: listing.id,
			name: listing.name, workspaces: listing.workspaces})) catch (error:Dynamic) return Std.string(error);
		readServices(listing.workspaces);
		revision++;
		return null;
	}

	/** The services exohost reports in a listing; one that is malformed counts as none. */
	function readServices(entries:Dynamic):Void {
		services.clear();
		if (!Std.isOfType(entries, Array))
			return;
		for (entry in (entries : Array<Dynamic>)) {
			var id:Dynamic = Reflect.field(entry, "id");
			if (!Std.isOfType(id, String))
				continue;
			var service:Null<MachineService> = null;
			try service = MachineCatalog.decodeService(entry) catch (_:Dynamic) {}
			// The window connects to what exohost reports, so only an endpoint of the agent's own shape counts.
			if (service != null && service.running && WorkspaceLink.validEndpoint(service.endpoint, Sys.systemName() == "Windows"))
				services.set(id, service);
		}
	}
}
