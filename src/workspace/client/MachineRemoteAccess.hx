package workspace.client;

/** What the Remote Access panel shows of this machine's relay identity (exohost's `remote-status`). */
typedef MachineRemoteStatus = {
	var enabled:Bool;
	var connected:Bool;
	var origin:Null<String>;
	var error:Null<String>;
}

/** A device's access to one workspace; `preset` is `read`, `edit`, `all` or `custom`. */
typedef MachineDeviceWorkspace = {
	var workspace:String;
	var grants:Array<String>;
	var preset:String;
}

typedef MachinePendingDevice = {
	var deviceId:String;
	var authenticationCode:String;
	var expiresInSeconds:Int;
}

typedef MachinePairedDevice = {
	var deviceId:String;
	var connected:Bool;
	var revoked:Bool;
	var workspaces:Array<MachineDeviceWorkspace>;
}

typedef MachineRemoteDevices = {
	var pending:Array<MachinePendingDevice>;
	var devices:Array<MachinePairedDevice>;
	/** The machine's workspaces, to pick from. */
	var workspaces:Array<{id:String, name:String}>;
}

/** A workspace and the preset (`read`, `edit`, `all`) a device gets in it. */
typedef MachineWorkspacePick = {
	var workspace:String;
	var preset:String;
}

/** One-time pairing invitation: the address to give the device. */
typedef MachineInvitation = {
	var pairingSocketUrl:String;
	/** What the owner gives the device: the socket URL with the machine key's fingerprint (`#mk=`), or the socket URL alone from an older exohost. */
	var invitationUrl:String;
	var deviceId:String;
	var expiresInSeconds:Int;
}

/**
	Remote access for the whole machine (ADR 0005 section 4): paired devices and the workspaces each may use. The panel
	reads this; MachineRemoteAccess implements it over exohost's control ops, tests fake it.
**/
interface MachineRemoteView {
	function status():Null<MachineRemoteStatus>;
	function devices():Null<MachineRemoteDevices>;
	function busy():Bool;
	function error():Null<String>;
	/** Asks exohost for the current status and devices, at most every few seconds unless `force`. */
	function refresh(force:Bool):Void;
	function enable(origin:String, done:Null<String>->Void):Void;
	/** Stops using the relay so another can be enabled. Paired devices stay listed but cannot connect. */
	function disable(done:Null<String>->Void):Void;
	function invite(ttlSeconds:Int, done:(Null<MachineInvitation>, Null<String>) -> Void):Void;
	/** Approves a pending device and gives it these workspaces (none is allowed: the device then sees nothing). */
	function approve(deviceId:String, picks:Array<MachineWorkspacePick>, done:Null<String>->Void):Void;
	/** Replaces the device's workspaces. */
	function grant(deviceId:String, picks:Array<MachineWorkspacePick>, done:Null<String>->Void):Void;
	function reject(deviceId:String, done:Null<String>->Void):Void;
	function revoke(deviceId:String, done:Null<String>->Void):Void;
}

/** MachineRemoteView over MachineClient: the answers are cached and refreshed on request. */
class MachineRemoteAccess implements MachineRemoteView {
	static inline final REFRESH_SECONDS = 2.0;

	final machine:MachineClient;
	final changed:Void->Void;
	var cachedStatus:Null<MachineRemoteStatus>;
	var cachedDevices:Null<MachineRemoteDevices>;
	var failure:Null<String>;
	var pending = 0;
	var refreshing = false;
	var nextRefresh = 0.0;

	public function new(machine:MachineClient, changed:Void->Void) {
		this.machine = machine;
		this.changed = changed;
	}

	public function status():Null<MachineRemoteStatus>
		return cachedStatus;

	public function devices():Null<MachineRemoteDevices>
		return cachedDevices;

	public function busy():Bool
		return pending > 0;

	public function error():Null<String>
		return failure;

	public function refresh(force:Bool):Void {
		if (refreshing || !force && Sys.time() < nextRefresh)
			return;
		refreshing = true;
		nextRefresh = Sys.time() + REFRESH_SECONDS;
		machine.remoteStatus(function(reply, problem) {
			if (reply != null)
				cachedStatus = {enabled: reply.enabled == true, connected: reply.connected == true, origin: text(reply.origin), error: text(reply.error)};
			else
				cachedStatus = null;
			if (cachedStatus == null || !cachedStatus.enabled) {
				refreshing = false;
				cachedDevices = null;
				changed();
				return;
			}
			machine.remoteDevices(function(list, problem) {
				refreshing = false;
				if (list != null)
					cachedDevices = readDevices(list);
				changed();
			});
		});
	}

	static function text(value:Dynamic):Null<String>
		return Std.isOfType(value, String) ? value : null;

	static function strings(value:Dynamic):Array<String> {
		var result:Array<String> = [];
		if (Std.isOfType(value, Array))
			for (item in (value : Array<Dynamic>))
				result.push(Std.string(item));
		return result;
	}

	static function readDevices(reply:Dynamic):MachineRemoteDevices {
		var result:MachineRemoteDevices = {pending: [], devices: [], workspaces: []};
		if (Std.isOfType(reply.pending, Array))
			for (item in (reply.pending : Array<Dynamic>))
				result.pending.push({deviceId: Std.string(item.deviceId), authenticationCode: Std.string(item.authenticationCode),
					expiresInSeconds: Std.int(item.expiresInSeconds)});
		if (Std.isOfType(reply.workspaces, Array))
			for (item in (reply.workspaces : Array<Dynamic>))
				result.workspaces.push({id: Std.string(item.id), name: Std.string(item.name)});
		if (Std.isOfType(reply.devices, Array))
			for (item in (reply.devices : Array<Dynamic>)) {
				var granted:Array<MachineDeviceWorkspace> = [];
				if (Std.isOfType(item.workspaces, Array))
					for (entry in (item.workspaces : Array<Dynamic>))
						granted.push({workspace: Std.string(entry.workspace), grants: strings(entry.grants), preset: Std.string(entry.preset)});
				result.devices.push({deviceId: Std.string(item.deviceId), connected: item.connected == true, revoked: item.revoked == true, workspaces: granted});
			}
		return result;
	}

	/** Runs an op; `done` gets the reply's error (null when it worked) and the panel is redrawn. */
	function run(start:((Null<Dynamic>, Null<String>) -> Void) -> Void, done:(Null<Dynamic>, Null<String>) -> Void):Void {
		pending++;
		failure = null;
		start(function(reply, problem) {
			pending--;
			failure = problem;
			done(reply, problem);
			refresh(true);
			changed();
		});
		changed();
	}

	static function wire(picks:Array<MachineWorkspacePick>):Array<Dynamic>
		return [for (pick in picks) {workspace: pick.workspace, preset: pick.preset}];

	public function enable(origin:String, done:Null<String>->Void):Void
		run(function(finish) machine.remoteEnable(origin, finish), function(_, problem) done(problem));

	public function disable(done:Null<String>->Void):Void
		run(function(finish) machine.remoteDisable(finish), function(_, problem) done(problem));

	public function invite(ttlSeconds:Int, done:(Null<MachineInvitation>, Null<String>) -> Void):Void
		run(function(finish) machine.remoteInvite(ttlSeconds, finish), function(reply, problem) {
			var value:Dynamic = reply == null ? null : reply.invitation;
			if (value == null) {
				done(null, problem == null ? "exohost sent no invitation" : problem);
				return;
			}
			var socketUrl = Std.string(value.pairingSocketUrl);
			done({pairingSocketUrl: socketUrl, invitationUrl: value.invitationUrl == null ? socketUrl : Std.string(value.invitationUrl), deviceId: Std.string(value.deviceId),
				expiresInSeconds: Std.int(value.expiresInSeconds)}, null);
		});

	public function approve(deviceId:String, picks:Array<MachineWorkspacePick>, done:Null<String>->Void):Void
		run(function(finish) machine.remoteApprove(deviceId, wire(picks), finish), function(_, problem) done(problem));

	public function grant(deviceId:String, picks:Array<MachineWorkspacePick>, done:Null<String>->Void):Void
		run(function(finish) machine.remoteGrant(deviceId, wire(picks), finish), function(_, problem) done(problem));

	public function reject(deviceId:String, done:Null<String>->Void):Void
		run(function(finish) machine.remoteReject(deviceId, finish), function(_, problem) done(problem));

	public function revoke(deviceId:String, done:Null<String>->Void):Void
		run(function(finish) machine.remoteRevoke(deviceId, finish), function(_, problem) done(problem));
}
