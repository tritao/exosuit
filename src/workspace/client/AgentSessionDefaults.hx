package workspace.client;

/** Exosuit preferences captured when a Workbench agent session is created. */
typedef AgentSessionDefaults = {
	@:optional var provider:Null<String>;
	var model:Null<String>;
	var effort:Null<String>;
	var permissionProfile:String;
	/** The session's working directory chosen with Change…; null resolves it from the group on the host. */
	@:optional var directory:Null<String>;
}
