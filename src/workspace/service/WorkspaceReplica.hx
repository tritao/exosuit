package workspace.service;

import haxeon.rpc.RpcConnection;
import workspace.service.WorkspaceProtocol;

/** Client-owned view. Restore is explicit on each freshly handshaken connection.
 * Generation guards fence asynchronous responses; cursors survive disconnection. */
class WorkspaceReplica {
	public var ready(get, never):Bool;

	var synchronized:Bool = false;

	function get_ready():Bool
		return synchronized && guard();

	public var error(default, null):Null<String>;
	public var epoch(default, null):String = "";
	public var cursor(default, null):Int = 0;

	final workspace:String;
	final groups:Map<String, WorkspaceGroup> = [];
	final buffered:Array<WorkspaceEvent> = [];
	final timeoutMs:Int;
	final bufferLimit:Int;
	var connection:Null<RpcConnection>;
	var guard:Void->Bool = function() return false;
	var token:Int = 0;
	var generation:Int = 0;

	public function new(workspace:String, timeoutMs:Int = 1000, bufferLimit:Int = 64) {
		if (workspace == null || workspace.length == 0 || timeoutMs < 1 || bufferLimit < 1)
			throw "Invalid workspace replica limits";
		this.workspace = workspace;
		this.timeoutMs = timeoutMs;
		this.bufferLimit = bufferLimit;
	}

	public function view():Array<WorkspaceGroup> {
		var result = [for (group in groups) WorkspaceProtocol.copyGroup(group)];
		result.sort(function(a, b) return Reflect.compare(a.id, b.id));
		return result;
	}

	public function restore(next:RpcConnection, isCurrent:Void->Bool):Void {
		token++;
		generation++;
		var installed = generation;
		connection = next;
		guard = isCurrent;
		synchronized = false;
		error = null;
		buffered.resize(0);
		next.onNotification(WorkspaceProtocol.CHANGED, WorkspaceProtocol.decodeEvent, function(event) {
			if (installed != generation || !guard())
				return;
			if (!ready) {
				if (buffered.length >= bufferLimit) {
					error = "replay_gap";
					next.close("workspace_event_overflow");
					return;
				}
				buffered.push(event);
			} else if (!apply(event)) {
				synchronized = false;
				error = "replay_gap";
			}
		});
		resume(false);
	}

	/** A detected live sequence gap requires an explicit fresh snapshot. */
	public function recover():Void {
		if (connection == null || !guard())
			return;
		resume(true);
	}

	function failed(code:String, expected:Int):Void {
		if (expected != token || !guard())
			return;
		synchronized = false;
		error = code;
	}

	function resume(fresh:Bool):Void {
		var active = connection;
		if (active == null || !guard())
			return;
		token++;
		var expected = token;
		// The notification handler fences by connection, not this recovery attempt.
		synchronized = false;
		error = null;
		buffered.resize(0);
		active.call(WorkspaceProtocol.WATCH, {workspace: workspace, epoch: fresh ? "" : epoch, cursor: fresh ? 0 : cursor}, timeoutMs, function(replay) {
			if (expected != token || !guard())
				return;
			if (replay.epoch == null || replay.epoch.length == 0 || replay.cursor < 0 || replay.events == null || replay.events.length > bufferLimit) {
				failed("invalid_response", expected);
				return;
			}
			if (replay.reset) {
				active.call(WorkspaceProtocol.QUERY, {workspace: workspace}, timeoutMs, function(snapshot) {
					if (expected != token || !guard())
						return;
					if (snapshot.epoch != replay.epoch || snapshot.cursor < replay.cursor || snapshot.groups == null || snapshot.groups.length > 32) {
						failed("invalid_response", expected);
						return;
					}
					var replacement:Map<String, WorkspaceGroup> = [];
					for (group in snapshot.groups) {
						if (!valid(group) || replacement.exists(group.id)) {
							failed("invalid_response", expected);
							return;
						}
						replacement.set(group.id, WorkspaceProtocol.copyGroup(group));
					}
					groups.clear();
					for (group in replacement)
						groups.set(group.id, group);
					epoch = snapshot.epoch;
					cursor = snapshot.cursor;
					finish(expected);
				}, function(error) {
					failed(error.code, expected);
				});
			} else {
				if (replay.epoch != epoch || replay.cursor < cursor) {
					failed("invalid_response", expected);
					return;
				}
				for (event in replay.events)
					if (!apply(event)) {
						failed("replay_gap", expected);
						return;
					}
				if (cursor != replay.cursor) {
					failed("replay_gap", expected);
					return;
				}
				finish(expected);
			}
		}, function(error) {
			failed(error.code, expected);
		});
	}

	static function valid(group:WorkspaceGroup):Bool
		return group != null
			&& group.id != null
			&& group.id.length > 0
			&& group.id.length <= 128
			&& group.name != null
			&& StringTools.trim(group.name).length > 0
			&& group.name.length <= 128
			&& group.revision > 0
			&& (group.cwd == null || group.cwd.length <= 1024);

	function apply(event:WorkspaceEvent):Bool {
		if (event == null || event.epoch != epoch || event.sequence < 1 || !valid(event.group))
			return false;
		if (event.sequence <= cursor)
			return true;
		if (cursor == 0x7fffffff || event.sequence != cursor + 1)
			return false;
		var previous = groups.get(event.group.id);
		if (previous == null
			|| previous.revision == 0x7fffffff
			|| event.group.revision != previous.revision + 1
			|| event.group.cwd != previous.cwd)
			return false;
		groups.set(event.group.id, WorkspaceProtocol.copyGroup(event.group));
		cursor = event.sequence;
		return true;
	}

	function finish(expected:Int):Void {
		if (expected != token || !guard())
			return;
		for (event in buffered)
			if (!apply(event)) {
				buffered.resize(0);
				failed("replay_gap", expected);
				return;
			}
		buffered.resize(0);
		synchronized = true;
		error = null;
	}
}
