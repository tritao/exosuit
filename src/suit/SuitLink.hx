package suit;

import haxe.Json;
import haxe.io.Bytes;
import haxeon.platform.event.EventPump;
import haxeon.rpc.RpcConnectResult;
import suit.control.ControlError;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcTransport;

private typedef Outgoing = {
	var id:String;
	var method:String;
	var params:Dynamic;
	var until:Float;
	var answer:(Null<Dynamic>, Null<String>) -> Void;
}

/**
	An editor window's one persistent link to suit (docs/design/suitctl/TDD-exosuit-ctl.md §5.3, §7). suit is always
	on: the link starts suit when it does not answer and reconnects when suit restarts. It replaces the registry record
	an editor once wrote. Over it:

	- the editor attaches once (`editor-attach`, a request on suit's main pipe) with its window id and state, and sends
	  an `exosuit.state` event whenever its focused context or the workspaces it uses change;
	- suit pushes `exosuit.machine.changed`: the machine's workspaces with their running services, and where every
	  window is focused;
	- the editor sends requests (`workspace-create` and the other machine ops of suit's main pipe) and gets responses;
	- suit sends requests the editor answers (`onRequest`): the control methods (Pragtical's `editor.open` and the
	  others, Exosuit's `exosuit.*`, `exosuit.quit {mode}`) that suit routes to this window;
	- the editor sends events (`emit`) for suit to fan out to whoever subscribed: `document.opened`, `project.changed`,
	  and the events a subscriber asked for (`wants`; suit says which with `exosuit.events.want`).

	After the attach reply every frame is one JSON envelope of Pragtical control protocol v1 (`version`, `kind`
	request/response/event). Nothing blocks: `poll`, called every frame, moves everything along.

	There is one link per editor process. It lives in a static (`instance`) so a live patch of the code that uses it
	keeps the connection.
**/
class SuitLink {
	public static inline final VERSION = 1;
	/** The largest message on the link and on suit's pipe: a window's `exosuit.ui.snapshot` can be large. */
	public static inline final MAX_MESSAGE_BYTES = 8 * 1024 * 1024;
	/** How long a request waits for the link and suit's answer, and for a remote access step, which waits on the relay. */
	public static inline final TIMEOUT = 5.0;
	public static inline final REMOTE_TIMEOUT = 20.0;
	static inline final RETRY_FAST = 0.5;
	static inline final RETRY_SLOW = 5.0;
	static inline final FAST_SECONDS = 10.0;

	/** This editor process's link, once `start` made it. */
	public static var instance(default, null):Null<SuitLink>;

	/** This editor window's id, `w<pid>-<seconds>`: Pragtical's instance id pattern, unique per process. */
	public final windowId:String;
	/** Called with each event suit pushes: its name and data. */
	public var onEvent:(String, Dynamic) -> Void = function(_, _) {};
	/**
		Called with each request suit sends this window: its method, params and the function that sends the answer (a
		result, or an error). It may answer later; until it does, suit's caller waits.
	**/
	public var onRequest:(String, Dynamic, (Null<Dynamic>, Null<ControlError>) -> Void) -> Void = function(method, _, answer)
		answer(null, new ControlError("unsupported", method + " is not supported by this window"));
	/** Changes whenever the link attaches or drops. */
	public var revision(default, null):Int = 0;

	final hub:NativeRpcHub;
	var transport:Null<NativeRpcTransport>;
	var connecting = false;
	var attached = false;
	var attachSent = false;
	var retryAt = 0.0;
	var failingSince = -1.0;
	var nextId = 1;
	var sequence = 0;
	final queue:Array<Outgoing> = [];
	final sent:Map<String, Outgoing> = [];
	var context:Null<String>;
	var focusedAt = 0.0;
	/** The events only a subscriber wants (`exosuit.ui.changed`, ...) that suit asked this window to send. */
	var wanted:Array<String> = [];
	final workspaces:Array<String> = [];
	final roots:Array<String> = [];
	var stateChanged = false;

	public static function start(events:EventPump):SuitLink {
		var current = instance;
		if (current != null)
			return current;
		var created = new SuitLink(events);
		instance = created;
		return created;
	}

	function new(events:EventPump) {
		hub = new NativeRpcHub(events, 32, 4, MAX_MESSAGE_BYTES);
		windowId = "w" + Sys.getPid() + "-" + Std.int(Sys.time());
	}

	/** True while the link is attached to suit. */
	public function isAttached():Bool
		return attached;

	/** The context (`machine/workspace/group`) this window shows; suit tells the other windows. */
	public function setContext(key:String):Void {
		if (key == context)
			return;
		context = key;
		stateChanged = true;
	}

	/** The window got the OS focus: it is now the most recently used window, where suit routes calls without a target. */
	public function focused():Void {
		focusedAt = Sys.time() * 1000;
		stateChanged = true;
	}

	/** Whether a subscriber wants event `name` from this window. */
	public function wants(name:String):Bool
		return attached && wanted.indexOf(name) >= 0;

	/** Sends an event for suit to fan out; dropped while the link is down. */
	public function emit(name:String, data:Dynamic):Void
		if (attached)
			send({version: VERSION, kind: "event", sequence: ++sequence, event: name, data: data});

	/** This window uses workspace `id`, so suit does not count its service as orphaned. */
	public function usesWorkspace(id:Null<String>):Void
		addOnce(workspaces, id);

	/** This window uses a folder's own service (one not keyed by a workspace id). */
	public function usesRoot(path:Null<String>):Void
		addOnce(roots, path);

	function addOnce(list:Array<String>, value:Null<String>):Void {
		if (value == null || value.length == 0 || list.indexOf(value) >= 0)
			return;
		list.push(value);
		stateChanged = true;
	}

	/**
		Sends a request to suit: `method` is one of the ops of suit's main pipe and `params` its fields. `done` gets the
		reply, or why there is none. A request waits for the link to attach, up to `timeout` seconds in all.
	**/
	public function call(method:String, params:Dynamic, done:(Null<Dynamic>, Null<String>) -> Void, timeout:Float = TIMEOUT):Void
		queue.push({id: "e" + nextId++, method: method, params: params == null ? {} : params, until: Sys.time() + timeout, answer: done});

	/** Moves the link along; call every frame. */
	public function poll():Void {
		var now = Sys.time();
		var stream = transport;
		if (stream != null && !stream.isOpen())
			drop("suit closed the connection");
		if (transport == null && !connecting && now >= retryAt)
			connect(now);
		stream = transport;
		if (stream != null && stream.isOpen()) {
			if (!attachSent)
				attachSent = stream.send(Bytes.ofString(Json.stringify(attachRequest())));
			for (_ in 0...64) {
				var received:Null<Bytes> = null;
				try received = stream.receive() catch (_:Dynamic) {}
				if (received == null)
					break;
				var message:Dynamic = null;
				try message = Json.parse(received.toString()) catch (_:Dynamic) {}
				if (message != null)
					handle(message);
			}
			if (attached) {
				if (stateChanged) {
					stateChanged = false;
					send({version: VERSION, kind: "event", sequence: ++sequence, event: "exosuit.state", data: stateData()});
				}
				while (queue.length > 0) {
					var request = queue.shift();
					sent.set(request.id, request);
					send({version: VERSION, kind: "request", id: request.id, method: request.method, params: request.params});
				}
			}
		}
		expire(now);
	}

	function connect(now:Float):Void {
		connecting = true;
		try {
			hub.connect(NativeRpcHub.local(SuitPaths.endpoint()), function(result:RpcConnectResult) {
				connecting = false;
				switch result {
					case Opened(opened):
						transport = cast opened;
						attachSent = false;
					default:
						failed(Sys.time());
				}
			});
		} catch (_:Dynamic) {
			connecting = false;
			failed(now);
		}
	}

	/** suit did not answer: start it (once until a link attaches again), then retry, often at first and then rarely. */
	function failed(now:Float):Void {
		if (failingSince < 0)
			failingSince = now;
		SuitClient.ensureDaemon();
		retryAt = now + (now - failingSince < FAST_SECONDS ? RETRY_FAST : RETRY_SLOW);
	}

	function attachRequest():Dynamic {
		var request:Dynamic = stateData();
		request.op = "editor-attach";
		request.version = VERSION;
		request.instance_id = windowId;
		request.pid = Sys.getPid();
		return request;
	}

	function stateData():Dynamic
		return {context: context, workspaces: workspaces.copy(), roots: roots.copy(), focusedAt: focusedAt};

	function handle(message:Dynamic):Void {
		if (!attached) {
			// The first frame back is the attach reply.
			if (Reflect.field(message, "ok") == true) {
				attached = true;
				stateChanged = false;
				failingSince = -1;
				SuitClient.daemonAnswered();
				revision++;
			} else
				drop("suit refused the link: " + Std.string(Reflect.field(message, "error")));
			return;
		}
		switch Std.string(Reflect.field(message, "kind")) {
			case "event":
				var name = Reflect.field(message, "event");
				if (Std.isOfType(name, String))
					onEvent(name, Reflect.field(message, "data"));
			case "response":
				var id = Std.string(Reflect.field(message, "id"));
				var request = sent.get(id);
				if (request == null)
					return;
				sent.remove(id);
				var error:Dynamic = Reflect.field(message, "error");
				answer(request, error == null ? Reflect.field(message, "result") : null,
					error == null ? null : Std.string(Reflect.field(error, "message")));
			case "request":
				var id:Dynamic = Reflect.field(message, "id");
				var method = Std.string(Reflect.field(message, "method"));
				var answered = false;
				var reply = function(result:Null<Dynamic>, failure:Null<ControlError>):Void {
					if (answered)
						return;
					answered = true;
					if (failure == null)
						send({version: VERSION, kind: "response", id: id, result: result == null ? {} : result});
					else
						send({version: VERSION, kind: "response", id: id, error: failure.json()});
				};
				var params:Dynamic = Reflect.field(message, "params");
				if (params == null || !Reflect.isObject(params) || Std.isOfType(params, Array))
					params = {};
				if (method == "exosuit.events.want") {
					var names:Dynamic = Reflect.field(params, "names");
					wanted = Std.isOfType(names, Array) ? [for (name in (names : Array<Dynamic>)) if (Std.isOfType(name, String)) (name : String)] : [];
					reply({}, null);
					return;
				}
				try onRequest(method, params, reply) catch (error:Dynamic) reply(null, ControlError.internal(Std.string(error)));
			default:
		}
	}

	function send(envelope:Dynamic):Void {
		var stream = transport;
		if (stream != null)
			try stream.send(Bytes.ofString(Json.stringify(envelope))) catch (_:Dynamic) {}
	}

	/** The connection ended: requests sent on it fail, queued ones wait for the next, and the next attach resends the state. */
	function drop(reason:String):Void {
		var stream = transport;
		transport = null;
		attachSent = false;
		if (stream != null)
			stream.close();
		if (attached) {
			attached = false;
			wanted = [];
			revision++;
		}
		stateChanged = true;
		var lost = [for (request in sent) request];
		for (request in lost)
			sent.remove(request.id);
		for (request in lost)
			answer(request, null, reason);
		failed(Sys.time());
	}

	function expire(now:Float):Void {
		var index = queue.length;
		while (index-- > 0)
			if (now >= queue[index].until) {
				var request = queue[index];
				queue.splice(index, 1);
				answer(request, null, "suit did not answer");
			}
		for (request in [for (request in sent) if (now >= request.until) request]) {
			sent.remove(request.id);
			answer(request, null, "suit did not answer");
		}
	}

	/** A failing callback must not take the editor's frame loop down with it. */
	function answer(request:Outgoing, reply:Null<Dynamic>, failure:Null<String>):Void
		try request.answer(reply, failure) catch (_:Dynamic) {}

	/** Closes the link when the editor exits; suit takes that as the window's end. */
	public function dispose():Void {
		var stream = transport;
		transport = null;
		if (stream != null)
			stream.close();
		hub.dispose();
		if (instance == this)
			instance = null;
	}
}
