package workspace.client;

/**
	A running workspace service as suit hands it out: the generation and root its IDENTITY answers with, which the
	client checks once connected, and how to reach it. An editor on this machine gets the pipe the service listens on
	(`workspace.open` on its suit link); a paired device gets `connector`, a stream of its machine's relay channel that
	suit forwards to that pipe (`DeviceMachine.openService`), and `endpoint` is then empty.
**/
typedef OpenedService = {
	var endpoint:String;
	var generation:String;
	var root:String;
	@:optional var connector:Null<haxeon.rpc.RpcConnector>;
}

/** Asks for workspace `id`'s running service, which is started first when it is idle; `done` gets it, or why not. */
typedef ServiceOpener = (id:String, done:(Null<OpenedService>, Null<String>) -> Void) -> Void;
