package suit.control;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import suit.LinkedEditor;
import suit.SuitRecord.SuitRecords;
import suit.remote.MachineRemote.DeferredReply;
import workspace.ContextKey;
import workspace.PathKey;
import workspace.transport.NativeRpcTransport;

private typedef Subscriber = {
	var transport:NativeRpcTransport;
	/** The event names it wants; empty for every event. */
	var names:Array<String>;
	var instance:Null<String>;
}

/**
	suit's control plane (docs/design/suitctl/TDD-exosuit-ctl.md §4–§6, §8): the `control` op on suit's main pipe and
	the methods of Pragtical control protocol v1 plus Exosuit's (`exosuit.*`). suit answers a few methods itself
	(`control.hello`, `control.ping`, `instance.status`, `exosuit.instances`, `exosuit.workspaces.list`) and forwards the
	rest, unchanged, to the editor window the request is routed to over that window's link (EditorDirectory). Events are
	opt-in: a connection that sends `exosuit.events.subscribe` becomes a stream of the events it named.

	Routing (§6): `target.instance_id` names a window; else a `target.path` (or the `path` param of `editor.open` and
	`project.*`) goes to the window whose workspaces hold it, the deepest folder first, then a window that shows that
	workspace, then the most recently used; a path no window holds, and a call without one, go to the most recently used
	window, unless `require_match` is set.
**/
class ControlRouter {
	/** Methods that drive a window like a user does (T4–T6): logged with the caller, and shown as "being driven" in the tray. */
	static final DRIVING = ~/^exosuit\.(ui\.(activate|focus|type|key|hover|scroll|drag)|terminal\.(create|send|restart|stop|close)|agent\.(create|send)|command\.run|dialog\.answer)$/;
	static inline final DRIVEN_SECONDS = 10.0;
	static inline final LOG_LINES = 500;

	final directory:EditorDirectory;
	final machine:Void->Dynamic;
	final folders:String->Array<String>;
	final subscribers:Array<Subscriber> = [];
	/** Event names the windows were last told to send (`exosuit.events.want`). */
	var wanted:String = "";
	var sequence = 0;
	/** When each window was last driven, by window id. */
	final driven:Map<String, Float> = [];
	/** This run's last lines of `control.log`: it is appended to, and rewritten with the last LOG_LINES once it holds twice as many. */
	final logged:Array<String> = [];
	/** The program of each calling process, looked up once (cleared when it holds 64). */
	final programs:Map<Int, String> = [];
	/** Events of every window, as Pragtical's per-window pipes want them (PragticalPipes). */
	public var onEvent:(LinkedEditor, String, Dynamic) -> Void = function(_, _, _) {};

	/**
		`machine` is suit's `machine` json; `folders` the folders of a workspace by id (none for an unknown id), so a
		window's roots are those of the workspaces it uses.
	**/
	public function new(directory:EditorDirectory, machine:Void->Dynamic, folders:String->Array<String>) {
		this.directory = directory;
		this.machine = machine;
		this.folders = folders;
	}

	/** Whether a main-pipe request is an events subscription, which takes the connection over (`subscribe`). */
	public static function isSubscription(request:Dynamic):Bool
		return SuitRecords.stringField(request, "op") == "control" && SuitRecords.stringField(request, "method") == "exosuit.events.subscribe";

	/**
		Takes over a connection whose first request was `exosuit.events.subscribe {names?, instance?}`: it is answered,
		then gets one event envelope per frame (`{version, kind:"event", sequence, event, data, instance_id}`).
	**/
	public function subscribe(transport:NativeRpcTransport, request:Dynamic):Void {
		var params:Dynamic = Reflect.field(request, "params");
		var names:Array<String> = [];
		var listed:Dynamic = params == null ? null : Reflect.field(params, "names");
		if (Std.isOfType(listed, Array))
			for (name in (listed : Array<Dynamic>))
				if (Std.isOfType(name, String))
					names.push(name);
		var instance = params == null ? null : SuitRecords.stringField(params, "instance");
		subscribers.push({transport: transport, names: names, instance: instance});
		transport.send(Bytes.ofString(Json.stringify({ok: true, result: {subscribed: names}})));
		tellWindows();
	}

	/** Handles one `control` request; the reply is a DeferredReply while the window works on it. */
	public function handle(request:Dynamic, peer:Int):Dynamic {
		var method = SuitRecords.stringField(request, "method");
		var version:Dynamic = Reflect.field(request, "version");
		if (version != null && version != 1)
			return failure(new ControlError("unsupported_version", "this suit speaks control protocol version 1"));
		if (method == null)
			return failure(new ControlError("invalid_request", "a control request needs a method"));
		var params:Dynamic = Reflect.field(request, "params");
		// Pragtical's encoder sends an empty map as an empty list.
		if (params == null || Std.isOfType(params, Array))
			params = {};
		var target:Dynamic = Reflect.field(request, "target");
		switch method {
			case "control.hello":
				return {ok: true, result: {protocol_version: 1, instance_id: "suit", capabilities: capabilities()}};
			case "control.ping":
				return {ok: true, result: {ok: true}};
			case "exosuit.instances":
				return {ok: true, result: {instances: [for (editor in directory.editors()) describe(editor)]}};
			case "exosuit.workspaces.list":
				return {ok: true, result: machine()};
			default:
		}
		var routed = route(method, params, target);
		if (routed.error != null)
			return failure(routed.error);
		var editor:LinkedEditor = routed.editor;
		if (method == "instance.status")
			return {ok: true, instance_id: editor.window, result: describe(editor)};
		return forward(editor, method, params, peer);
	}

	/** Sends `method` to `editor`; the reply waits for the window's answer. */
	public function forward(editor:LinkedEditor, method:String, params:Dynamic, peer:Int):DeferredReply {
		var reply = new DeferredReply();
		if (DRIVING.match(method)) {
			driven.set(editor.window, Sys.time());
			log(peer, editor, method);
		} else if (method != "exosuit.ui.snapshot" && method != "exosuit.state.get")
			log(peer, editor, method);
		if (!directory.request(editor.window, method, params, function(result, error) {
			reply.resolve(error == null ? {ok: true, instance_id: editor.window, result: result == null ? {} : result} : failure(error));
		}))
			reply.resolve(failure(new ControlError("not_found", "window " + editor.window + " is not linked")));
		return reply;
	}

	/** The window a request goes to, or why there is none. */
	public function route(method:String, params:Dynamic, target:Dynamic):{editor:Null<LinkedEditor>, error:Null<ControlError>} {
		var editors = directory.editors();
		var instance = target == null ? null : SuitRecords.stringField(target, "instance_id");
		if (instance != null) {
			for (editor in editors)
				if (editor.window == instance)
					return {editor: editor, error: null};
			return {editor: null, error: new ControlError("not_found", "no Exosuit window " + instance)};
		}
		if (editors.length == 0)
			return {editor: null, error: new ControlError("not_found", "no Exosuit window is open")};
		var path = target == null ? null : SuitRecords.stringField(target, "path");
		if (path == null && (method == "editor.open" || StringTools.startsWith(method, "project.")))
			path = SuitRecords.stringField(params, "path");
		if (path != null) {
			var holding = holder(editors, path);
			if (holding != null)
				return {editor: holding, error: null};
			if (target != null && Reflect.field(target, "require_match") == true)
				return {editor: null, error: new ControlError("not_found", "no Exosuit window holds " + path)};
		}
		return {editor: mostRecent(editors), error: null};
	}

	/**
		The window whose workspaces hold `path`: the deepest holding folder wins, then a window whose shown workspace
		holds it, then the most recently used. Null when none holds it.
	**/
	function holder(editors:Array<LinkedEditor>, path:String):Null<LinkedEditor> {
		var best:Null<LinkedEditor> = null, bestDepth = -1, bestActive = false;
		for (editor in editors) {
			var active = activeWorkspace(editor);
			for (item in roots(editor)) {
				if (!PathKey.within(item.root, path))
					continue;
				var depth = PathKey.of(item.root).split("/").length;
				var isActive = item.workspace != null && item.workspace == active;
				if (depth > bestDepth || depth == bestDepth && (isActive && !bestActive || isActive == bestActive && best != null && editor.focusedAt > best.focusedAt)) {
					best = editor;
					bestDepth = depth;
					bestActive = isActive;
				}
			}
		}
		return best;
	}

	/** Every folder of the workspaces a window uses, with the workspace, and the loose roots it reported. */
	function roots(editor:LinkedEditor):Array<{root:String, workspace:Null<String>}> {
		var result:Array<{root:String, workspace:Null<String>}> = [];
		var ids = editor.workspaces.copy();
		var active = activeWorkspace(editor);
		if (active != null && ids.indexOf(active) < 0)
			ids.push(active);
		for (id in ids)
			for (folder in folders(id))
				result.push({root: folder, workspace: id});
		for (root in editor.roots)
			result.push({root: root, workspace: null});
		return result;
	}

	static function activeWorkspace(editor:LinkedEditor):Null<String> {
		var parsed = editor.context == null ? null : ContextKey.parse(editor.context);
		return parsed == null || parsed.workspace.length == 0 ? null : parsed.workspace;
	}

	static function mostRecent(editors:Array<LinkedEditor>):LinkedEditor {
		var best = editors[0];
		for (editor in editors)
			if (editor.focusedAt > best.focusedAt)
				best = editor;
		return best;
	}

	/**
		A window as `instance.status` and `exosuit.instances` describe it: Pragtical's descriptor fields (`instance_id`,
		`pid`, `endpoint`, `started_at` in whole seconds, `project_roots`, `protocol_version`) and Exosuit's (`context`,
		`workspaces`, `focusedAt` in milliseconds, `driven`).
	**/
	public function describe(editor:LinkedEditor):Dynamic {
		var lastDriven = driven.get(editor.window);
		return {
			instance_id: editor.window, pid: editor.pid, endpoint: PragticalPipes.endpoint(editor.window), started_at: Std.int(editor.started),
			project_roots: projectRoots(editor), protocol_version: 1, context: editor.context, workspaces: editor.workspaces.copy(),
			focusedAt: editor.focusedAt, driven: lastDriven != null && Sys.time() - lastDriven < DRIVEN_SECONDS
		};
	}

	/** The folders of every workspace a window uses: its Pragtical `project_roots`. */
	public function projectRoots(editor:LinkedEditor):Array<String> {
		var result:Array<String> = [];
		for (item in roots(editor))
			if (result.indexOf(item.root) < 0)
				result.push(item.root);
		return result;
	}

	/** Windows driven in the last few seconds, for the tray's tooltip; empty when none. */
	public function drivenSummary():String {
		var now = Sys.time();
		var names = [for (editor in directory.editors()) if (driven.exists(editor.window) && now - driven.get(editor.window) < DRIVEN_SECONDS) editor.window];
		return names.length == 0 ? "" : "being driven: " + names.join(", ");
	}

	/** An event of a window: to the subscribers that want it, and to its Pragtical pipe. */
	public function event(editor:LinkedEditor, name:String, data:Dynamic):Void {
		publish(name, data, editor.window);
		onEvent(editor, name, data);
	}

	/** A window linked or unlinked: `exosuit.instance.attached` or `.detached`, and the windows learn what to send. */
	public function linked(editor:LinkedEditor, attached:Bool):Void {
		publish(attached ? "exosuit.instance.attached" : "exosuit.instance.detached", describe(editor), editor.window);
		if (attached) {
			wanted = "";
			tellWindows();
		}
	}

	/** Sends an event to its subscribers; `instance` is the window it is about (null for suit's own). */
	public function publish(name:String, data:Dynamic, instance:Null<String>):Void {
		if (subscribers.length == 0)
			return;
		sequence++;
		var text:Null<String> = null;
		for (subscriber in subscribers)
			if ((subscriber.names.length == 0 || subscriber.names.indexOf(name) >= 0)
				&& (subscriber.instance == null || instance == null || subscriber.instance == instance)) {
				if (text == null)
					text = Json.stringify({version: 1, kind: "event", sequence: sequence, event: name, data: data, instance_id: instance});
				try subscriber.transport.send(Bytes.ofString(text)) catch (_:Dynamic) subscriber.transport.close();
			}
	}

	/** Drops subscribers whose connection closed. */
	public function poll():Void {
		var index = subscribers.length, dropped = false;
		while (index-- > 0)
			if (!subscribers[index].transport.isOpen()) {
				subscribers.splice(index, 1);
				dropped = true;
			} else
				// A subscriber only listens: anything it sends is read and dropped.
				try while (subscribers[index].transport.receive() != null) {} catch (_:Dynamic) subscribers[index].transport.close();
		if (dropped)
			tellWindows();
	}

	public function subscriberCount():Int
		return subscribers.length;

	/**
		Tells every window which of the events only a subscriber wants (`exosuit.ui.changed`, `exosuit.terminal.output`)
		to send, so a window sends none while nobody listens (Q18: events are opt-in).
	**/
	function tellWindows():Void {
		var names:Array<String> = [];
		for (subscriber in subscribers)
			for (name in subscriber.names.length == 0 ? ["exosuit.ui.changed", "exosuit.terminal.output"] : subscriber.names)
				if (names.indexOf(name) < 0)
					names.push(name);
		names.sort(Reflect.compare);
		var key = names.join(",");
		if (key == wanted)
			return;
		wanted = key;
		for (editor in directory.editors())
			directory.request(editor.window, "exosuit.events.want", {names: names}, function(_, _) {});
	}

	function capabilities():Array<String>
		return ["control", "editor.open", "editor.documents", "editor.save", "project.add", "project.change", "window.focus", "exosuit"];

	static function failure(error:ControlError):Dynamic
		return {ok: false, error: error.json()};

	/** One line per call that changes or drives a window, with the calling process (docs/design/suitctl §10). */
	function log(peer:Int, editor:LinkedEditor, method:String):Void {
		var line = Std.int(Sys.time()) + " pid " + peer + " " + processName(peer) + " -> " + editor.window + " " + method;
		logged.push(line);
		var path = Path.join([SuitPaths.home(), "control.log"]);
		try {
			if (logged.length == 1 || logged.length >= 2 * LOG_LINES) {
				if (logged.length > LOG_LINES)
					logged.splice(0, logged.length - LOG_LINES);
				sys.io.File.saveContent(path, logged.join("\n") + "\n");
			} else
				sys.io.File.appendContent(path, line + "\n");
		} catch (_:Dynamic) {}
	}

	function processName(pid:Int):String {
		if (pid <= 0)
			return "?";
		var known = programs.get(pid);
		if (known != null)
			return known;
		var name = "?";
		try {
			var path = processkit.Processes.executablePath(pid);
			if (path != null)
				name = Path.withoutDirectory(path);
		} catch (_:Dynamic) {}
		if (Lambda.count(programs) >= 64)
			programs.clear();
		programs.set(pid, name);
		return name;
	}
}
