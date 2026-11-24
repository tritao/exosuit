package workspace.transport;

import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcError;
import haxeon.rpc.RpcMethod;

/**
 * `RpcConnection.call` with an answer and an error callback, as the workspace clients use it. Haxeon's call returns a
 * Future; exactly one of the callbacks runs when it settles, from the connection's poll, or before this returns when the
 * call could not be sent. Nothing here cancels a call, so a Cancelled or Stopped outcome cannot arrive.
 */
class RpcCalls {
	public static function call<Request, Response>(connection:RpcConnection, method:RpcMethod<Request, Response>, request:Request,
			timeoutMs:Int, response:Response->Void, failure:RpcError->Void):Void {
		connection.call(method, request, timeoutMs).onComplete(function(outcome) {
			switch outcome {
				case Success(value): response(value);
				case Failure(error): failure(Std.isOfType(error, RpcError) ? cast error : new RpcError("failed", error.message, true));
				case Cancelled | Stopped:
			}
		});
	}
}
