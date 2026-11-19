package exohost;

import haxe.Json;
import haxe.io.Bytes;
import exohost.ExohostRecord.ExohostRecords;
import exohost.LinkedEditor;
import exohost.control.ControlError;
import exohost.remote.DeferredReply;
import workspace.transport.NativeRpcTransport;

private typedef Entry = {
	var editor:LinkedEditor;
	var transport:NativeRpcTransport;
}

private typedef Asked = {
	var entry:Entry;
	var done:(Null<Dynamic>, Null<ControlError>) -> Void;
	var until:Float;
	var method:String;
}

/**
	The editor windows linked to exohost (ExohostLink on the editor's side; docs/design/exohostctl/TDD-exosuit-ctl.md §5.3).
	A window is listed from its `editor-attach` until its link closes, which is how exohost learns that it exited: there is
	no registry record for editors. The directory carries the window's requests to exohost's op handler, pushes events to
	every window, sends a window requests (control methods, `exosuit.quit`) and hands the events a window sends to
	`onEvent`.
**/
class EditorDirectory {
	/** How long a window has to answer a request (Pragtical's request timeout). */
	public static inline final REQUEST_SECONDS = 10.0;
	/** A quit, and a request that waits on the user (a save prompt), may wait longer: Pragtical's deferred timeout. */
	public static inline final DEFERRED_SECONDS = 300.0;

	final entries:Array<Entry> = [];
	final asked:Map<String, Asked> = [];
	/** Window requests whose reply is still being made (a pairing step). */
	final deferred:Array<{entry:Entry, id:Dynamic, reply:DeferredReply}> = [];
	var nextId = 1;
	var sequence = 0;
	/** Changes whenever a window links, unlinks or changes its state. */
	public var revision(default, null):Int = 0;
	/** An event a window sent, with the window that sent it (its state already applied for `exosuit.state`). */
	public var onEvent:(LinkedEditor, String, Dynamic) -> Void = function(_, _, _) {};
	/** A window linked (true) or its link closed (false). */
	public var onLinked:(LinkedEditor, Bool) -> Void = function(_, _) {};

	public function new() {}

	/** Takes over a connection whose first request was `editor-attach`. False when the request is not valid. */
	public function attach(transport:NativeRpcTransport, request:Dynamic):Bool {
		var window = ExohostRecords.stringField(request, "instance_id"), pid = ExohostRecords.intField(request, "pid");
		// The window id is also a Pragtical instance id: a file name and part of a pipe name.
		if (window == null || pid == null || pid <= 0 || !~/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.match(window)) {
			transport.send(Bytes.ofString(Json.stringify({ok: false, error: "editor-attach needs instance_id and pid"})));
			return false;
		}
		var now = Sys.time();
		var editor:LinkedEditor = {window: window, pid: pid, context: null, workspaces: [], roots: [], started: now, focusedAt: now * 1000};
		readState(editor, request);
		entries.push({editor: editor, transport: transport});
		transport.send(Bytes.ofString(Json.stringify({ok: true, exohost: {pid: Sys.getPid()}})));
		revision++;
		onLinked(editor, true);
		return true;
	}

	/** The linked windows, oldest link first. */
	public function editors():Array<LinkedEditor>
		return [for (entry in entries) entry.editor];

	/** Where each window is focused, for `exosuit.machine.changed`. */
	public function windows():Array<WindowFocus>
		return [for (entry in entries) if (entry.editor.context != null) {window: entry.editor.window, pid: entry.editor.pid, context: entry.editor.context}];

	public function linked(pid:Int):Bool {
		for (entry in entries)
			if (entry.editor.pid == pid)
				return true;
		return false;
	}

	/**
		Reads what every window sent: state and other events (to `onEvent`), requests (answered by `handle`, exohost's op
		handler, with the method as the op) and responses to exohost's own requests. A window whose link closed is dropped,
		and what it was asked fails.
	**/
	public function poll(handle:Dynamic->Dynamic):Void {
		var index = entries.length;
		while (index-- > 0) {
			var entry = entries[index];
			for (_ in 0...64) {
				var message:Null<Bytes> = null;
				try message = entry.transport.receive() catch (_:Dynamic) entry.transport.close();
				if (message == null)
					break;
				var envelope:Dynamic = null;
				try envelope = Json.parse(message.toString()) catch (_:Dynamic) {}
				if (envelope != null)
					read(entry, envelope, handle);
			}
			if (!entry.transport.isOpen()) {
				entries.splice(index, 1);
				revision++;
				// A window that closes while asked to quit has done what it was asked, answered or not.
				for (id in [for (id => item in asked) if (item.entry == entry && item.method == "exosuit.quit") id])
					finishAsked(id, {closing: true, closed: true}, null);
				for (id in [for (id => item in asked) if (item.entry == entry) id])
					finishAsked(id, null, ControlError.internal("the window closed"));
				onLinked(entry.editor, false);
			}
		}
		var held = deferred.length;
		while (held-- > 0) {
			var item = deferred[held];
			if (item.reply.reply != null || !item.entry.transport.isOpen()) {
				deferred.splice(held, 1);
				respond(item.entry, item.id, item.reply.reply);
			}
		}
		var now = Sys.time();
		for (id in [for (id => item in asked) if (now >= item.until) id])
			finishAsked(id, null, ControlError.retry("timeout", "the window did not answer"));
	}

	function read(entry:Entry, envelope:Dynamic, handle:Dynamic->Dynamic):Void {
		switch Std.string(Reflect.field(envelope, "kind")) {
			case "event":
				var name = ExohostRecords.stringField(envelope, "event");
				// Focus alone does not change what windows are pushed: only context, workspaces or roots bump the revision.
				if (name == "exosuit.state" && readState(entry.editor, Reflect.field(envelope, "data")))
					revision++;
				if (name != null)
					onEvent(entry.editor, name, Reflect.field(envelope, "data"));
			case "request":
				var id:Dynamic = Reflect.field(envelope, "id");
				var method = ExohostRecords.stringField(envelope, "method");
				var params:Dynamic = Reflect.field(envelope, "params");
				var request:Dynamic = params == null || !Reflect.isObject(params) ? {} : Reflect.copy(params);
				request.op = method;
				var reply:Dynamic;
				try reply = handle(request) catch (error:Dynamic) reply = {ok: false, error: Std.string(error)};
				if (Std.isOfType(reply, DeferredReply))
					deferred.push({entry: entry, id: id, reply: cast reply});
				else
					respond(entry, id, reply);
			case "response":
				var id = Std.string(Reflect.field(envelope, "id"));
				var error:Dynamic = Reflect.field(envelope, "error");
				if (asked.exists(id))
					finishAsked(id, error == null ? Reflect.field(envelope, "result") : null, error == null ? null : ControlError.read(error));
			default:
		}
	}

	/** Answers a window's request with exohost's reply: a result, or the error of a reply that is not ok. */
	function respond(entry:Entry, id:Dynamic, reply:Dynamic):Void {
		var envelope:Dynamic = reply != null && Reflect.field(reply, "ok") == true
			? {version: 1, kind: "response", id: id, result: reply}
			: {version: 1, kind: "response", id: id,
				error: {code: "internal", message: reply == null ? "no reply" : Std.string(Reflect.field(reply, "error")), retryable: false}};
		send(entry, envelope);
	}

	/** Pushes an event to every linked window. */
	public function push(event:String, data:Dynamic):Void {
		sequence++;
		for (entry in entries)
			send(entry, {version: 1, kind: "event", sequence: sequence, event: event, data: data});
	}

	/**
		Asks the window `window` to run a control method (docs/design/exohostctl/TDD-exosuit-ctl.md §8). `done` gets its
		result, or the error the window answered or why there is none. False when no such window is linked.
	**/
	public function request(window:String, method:String, params:Dynamic, done:(Null<Dynamic>, Null<ControlError>) -> Void):Bool {
		for (entry in entries)
			if (entry.editor.window == window) {
				ask(entry, method, params, method == "exosuit.quit" ? DEFERRED_SECONDS : REQUEST_SECONDS, done);
				return true;
			}
		return false;
	}

	/**
		Asks the window of process `pid` to quit (`prompt` asks about unsaved work; `recover` keeps it for the next start and
		closes at once). `done` gets the window's answer or why there is none; the window's exit shows as its link closing.
		False when no window of that process is linked.
	**/
	public function quit(pid:Int, mode:String, done:(Null<Dynamic>, Null<ControlError>) -> Void):Bool {
		var found = false;
		for (entry in entries)
			if (entry.editor.pid == pid) {
				ask(entry, "exosuit.quit", {mode: mode}, DEFERRED_SECONDS, done);
				found = true;
			}
		return found;
	}

	function ask(entry:Entry, method:String, params:Dynamic, seconds:Float, done:(Null<Dynamic>, Null<ControlError>) -> Void):Void {
		var id = "s" + nextId++;
		asked.set(id, {entry: entry, done: done, until: Sys.time() + seconds, method: method});
		send(entry, {version: 1, kind: "request", id: id, method: method, params: params == null ? {} : params});
	}

	function finishAsked(id:String, result:Null<Dynamic>, failure:Null<ControlError>):Void {
		var item = asked.get(id);
		if (item == null)
			return;
		asked.remove(id);
		try item.done(result, failure) catch (_:Dynamic) {}
	}

	function send(entry:Entry, envelope:Dynamic):Void
		try entry.transport.send(Bytes.ofString(Json.stringify(envelope))) catch (_:Dynamic) {}

	/** The windows a running daemon links (its `editors` reply), for the CLI's inventory; none when no daemon answers. */
	public static function fromDaemon():Array<LinkedEditor> {
		var reply = ExohostControl.request({op: "editors"}, 2);
		var listed:Dynamic = reply == null ? null : Reflect.field(reply, "editors");
		var result:Array<LinkedEditor> = [];
		if (Std.isOfType(listed, Array))
			for (entry in (listed : Array<Dynamic>)) {
				var window = ExohostRecords.stringField(entry, "window"), pid = ExohostRecords.intField(entry, "pid");
				if (window == null || pid == null)
					continue;
				var editor:LinkedEditor = {window: window, pid: pid, context: null, workspaces: [], roots: [],
					started: number(Reflect.field(entry, "started")), focusedAt: 0};
				readState(editor, entry);
				result.push(editor);
			}
		return result;
	}

	/** Reads a window's state; whether its context, workspaces or roots changed. */
	static function readState(editor:LinkedEditor, data:Dynamic):Bool {
		if (data == null)
			return false;
		var context = ExohostRecords.stringField(data, "context");
		var workspaces = strings(Reflect.field(data, "workspaces")), roots = strings(Reflect.field(data, "roots"));
		var changed = context != editor.context || workspaces.join("\n") != editor.workspaces.join("\n")
			|| roots.join("\n") != editor.roots.join("\n");
		editor.context = context;
		editor.workspaces = workspaces;
		editor.roots = roots;
		var focused = number(Reflect.field(data, "focusedAt"));
		if (focused > editor.focusedAt)
			editor.focusedAt = focused;
		return changed;
	}

	static function number(value:Dynamic):Float
		return Std.isOfType(value, Float) || Std.isOfType(value, Int) ? (value : Float) : 0;

	static function strings(value:Dynamic):Array<String> {
		var result:Array<String> = [];
		if (Std.isOfType(value, Array))
			for (item in (value : Array<Dynamic>))
				if (Std.isOfType(item, String) && result.length < 256)
					result.push(item);
		return result;
	}

	public function dispose():Void {
		for (entry in entries)
			entry.transport.close();
		entries.resize(0);
	}
}
