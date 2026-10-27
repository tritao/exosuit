package workspace.client;

/** Exosuit preferences captured when a Workbench agent session is created. */
typedef AgentSessionDefaults = {
	@:optional var provider:Null<String>;
	var model:Null<String>;
	var effort:Null<String>;
	var permissionProfile:String;
}
