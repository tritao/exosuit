package app;

import haxe.io.Bytes;
import NativeKitRuntime;
import nativekit.ffi.NativeKit;
import workspace.transport.*;
import workspace.service.*;
import workspace.service.WorkspaceProtocol;
import haxeon.rpc.*;

class BrowserRpcMain {
	static final key = Bytes.alloc(64);
	static var runtime:Null<NativeKitRuntime>;
	static var hub:Null<NativeRpcHub>;
	static var connector:Null<SessionRpcConnector>;
	static var client:Null<RpcClient>;
	static var replica:Null<WorkspaceReplica>;
	static var starts:Int = 0;
	static var lastEpoch:String = "";
	static var epochs:Int = 0;

	@:expose public static function epochChanges():Int
		return epochs;

	@:expose public static function diagnostic():Int {
		var current = client;
		if (current == null || current.lastError == null)
			return 0;
		return switch current.lastError.code {
			case "connect_failed": 1;
			case "connect_timeout": 2;
			case "disconnected": 3;
			case "authentication_timeout": 4;
			case _: 9;
		};
	}

	@:expose public static function credential(index:Int, value:Int):Void {
		key.set(index, value);
	}

	@:expose public static function start(port:Int):Void {
		runtime = NativeKitRuntime.start();
		hub = new NativeRpcHub(runtime.events);
		var clock = function() return NativeKit.nk_time_seconds() * 1000;
		connector = new SessionRpcConnector(new NativeRpcConnector(hub, NativeRpcHub.websocket(port)), key.toString(), clock);
		replica = new WorkspaceReplica("workspace", 1000);
		client = new RpcClient(connector, clock, function() return 0.5,
			new RpcPeerOptions("browser-test/1", [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS], [], 1000, 262144, 32, 1048576),
			function(connection, generation, _) {
				starts++;
				var current = client, view = replica;
				if (current == null || view == null)
					throw "Missing browser client";
				view.restore(connection, function() return current.isCurrent(generation));
			}, 50, 200, 2000);
	}

	@:expose public static function frame():Int {
		var events = runtime, authenticated = connector, current = client, view = replica;
		if (events == null || authenticated == null || current == null || view == null)
			return -1;
		for (_ in 0...128)
			if (!events.events.poll())
				break;
		authenticated.poll();
		current.poll();
		if (current.state == Closed || view.error != null)
			return -2;
		if (view.ready && view.view().length == 1) {
			if (view.epoch != lastEpoch) {
				lastEpoch = view.epoch;
				epochs++;
			}
			return starts;
		}
		return 0;
	}

	@:expose public static function suspend():Void {
		var current = client;
		if (current != null) {
			var connection = current.current();
			if (connection != null)
				connection.close();
		}
	}

	public static function main():Void {}
}
