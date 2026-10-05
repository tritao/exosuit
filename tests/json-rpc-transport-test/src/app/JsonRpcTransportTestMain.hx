package app;

import language.JsonRpcResponse;
import language.JsonRpcTransport;
import platform.Platform;
import process.ProcessManager;

class JsonRpcTransportTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function pump(transport:JsonRpcTransport, condition:Void->Bool, timeout:Float):Void {
		var deadline = Sys.time() + timeout;
		while (!condition() && Sys.time() < deadline) transport.update(Sys.time());
		require(condition(), "JSON-RPC condition timed out");
	}

	static function response(value:Null<JsonRpcResponse>, message:String):JsonRpcResponse {
		if (value == null) throw message;
		return value;
	}

	static function main():Int {

		var arguments = Sys.args();
		require(arguments.length == 1, "transport test requires fake server path");
		var manager = new ProcessManager(), process = manager.start("python3", [arguments[0]]), transport = new JsonRpcTransport(process, 4096);
		var order:Array<String> = [], fast:Null<JsonRpcResponse> = null, held:Null<JsonRpcResponse> = null;
		transport.request("hold", {}, Sys.time(), 5.0, response -> {
			held = response;
			order.push("held");
		});
		transport.request("fast", {}, Sys.time(), 5.0, response -> {
			fast = response;
			order.push("fast");
		});
		pump(transport, () -> held != null && fast != null, 5.0);
		require(order.length == 2 && order[0] == "fast" && order[1] == "held", "out-of-order responses were not correlated by id");
		var fastResponse = response(fast, "fast response missing"), heldResponse = response(held, "held response missing");
		require(fastResponse.error == null && fastResponse.result == "Olá 😀" && heldResponse.result == "held",
			'framed Unicode response was corrupted: fast=${Std.string(fastResponse.result)}, held=${Std.string(heldResponse.result)}, error=${fastResponse.error}');

		var timedOut:Null<JsonRpcResponse> = null, cancelSeen = false;
		transport.notification = (method, params) -> {
			if (method == "cancelSeen") cancelSeen = true;
		};
		transport.request("never", {}, Sys.time(), 0.01, response -> timedOut = response);
		pump(transport, () -> timedOut != null, 1.0);
		pump(transport, () -> cancelSeen, 1.0);
		require(response(timedOut, "timeout response missing").error == "request timed out", "request timeout was not reported");

		var flooded:Null<JsonRpcResponse> = null;
		transport.request("stderrFlood", {}, Sys.time(), 5.0, response -> flooded = response);
		pump(transport, () -> flooded != null, 5.0);
		require(transport.stderr.length <= JsonRpcTransport.MAX_STDERR_BYTES, "language server stderr retention was unbounded");
		var oversized = "x";
		for (_ in 0...12) oversized += oversized;
		oversized += "x";
		require(!transport.notify("oversized", {text: oversized}), "oversized JSON-RPC frame entered the output queue");

		var quit = false;
		transport.request("quit", {}, Sys.time(), 5.0, response -> quit = response.error == null);
		pump(transport, () -> quit, 5.0);
		manager.release(process);
		manager.shutdown();

		Sys.println("PASS: bounded framed JSON-RPC transport, correlation, timeout, cancellation, and Unicode");
		return 0;
	}
}
