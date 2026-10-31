package workspace;

/** What switching back to a context needs: where it is, how it is named and the folder a group works in. */
class ContextInfo {
	public var machine:String;
	public var workspace:String;
	public final group:String;
	public final label:String;
	public final workspaceLabel:String;
	public final directory:String;
	public function new(machine:String, workspace:String, group:String, label:String, workspaceLabel:String, directory:String) {
		this.machine = machine; this.workspace = workspace; this.group = group;
		this.label = label; this.workspaceLabel = workspaceLabel; this.directory = directory;
	}
	public function key():String return ContextKey.make(machine, workspace, group);
	public function isRoot():Bool return group.length == 0;
}
