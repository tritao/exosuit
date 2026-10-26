package workspace.client;

/** Exosuit preferences captured when a Workbench Codex thread is created. */
typedef CodexSessionDefaults = {
	@:optional var provider:Null<String>;
	var model:Null<String>;
	var effort:Null<String>;
	var permissionProfile:String;
}
