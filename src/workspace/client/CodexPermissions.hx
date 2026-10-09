package workspace.client;

/** Permission presets exposed by Exosuit for Codex turns. */
typedef CodexPermissionProfile = {
	var id:String;
	var label:String;
	var sandboxPolicy:String;
	var threadSandbox:String;
	var approvalPolicy:String;
}

class CodexPermissions {
	public static function profiles():Array<CodexPermissionProfile> return [
		{id: "read-only", label: "Read-only", sandboxPolicy: "readOnly", threadSandbox: "read-only", approvalPolicy: "on-request"},
		{id: "workspace-write", label: "Workspace access", sandboxPolicy: "workspaceWrite", threadSandbox: "workspace-write", approvalPolicy: "on-request"},
		{id: "full-access", label: "Full access", sandboxPolicy: "dangerFullAccess", threadSandbox: "danger-full-access", approvalPolicy: "never"}
	];

	public static function find(id:String):Null<CodexPermissionProfile> {
		for (profile in profiles()) if (profile.id == id) return profile;
		return null;
	}

	public static function labelFor(sandboxPolicy:Null<String>, approvalPolicy:Null<String>):String {
		for (profile in profiles()) if (profile.sandboxPolicy == sandboxPolicy
			&& profile.approvalPolicy == approvalPolicy) return profile.label;
		return "Custom";
	}

	public static function labelForRecord(profileId:Null<String>, sandboxPolicy:Null<String>, approvalPolicy:Null<String>):String {
		var profile = profileId == null ? null : find(profileId);
		return profile == null ? labelFor(sandboxPolicy, approvalPolicy) : profile.label;
	}

	public static function profileFor(sandboxPolicy:Null<String>, approvalPolicy:Null<String>):Null<String> {
		for (profile in profiles()) if (profile.sandboxPolicy == sandboxPolicy
			&& profile.approvalPolicy == approvalPolicy) return profile.id;
		return null;
	}

	public static function sandboxType(value:Dynamic):Null<String> {
		var raw:Dynamic = value == null ? null : Reflect.field(value, "type");
		var kind:String = Std.isOfType(raw, String) ? cast raw : "";
		return switch (kind) {
			case "readOnly", "workspaceWrite", "dangerFullAccess": kind;
			default: null;
		};
	}

	public static function approvalType(value:Dynamic):Null<String> {
		if (!Std.isOfType(value, String)) return null;
		var policy:String = cast value;
		return switch (policy) {
			case "untrusted", "on-request", "never": policy;
			default: null;
		};
	}
}
