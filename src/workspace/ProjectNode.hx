package workspace;

class ProjectNode {
	public final name:String;
	public final path:String;
	public final directory:Bool;
	public final depth:Int;
	public final children:Array<ProjectNode> = [];
	public var expanded(default, null):Bool;
	@:allow(workspace.ProjectScan)
	public var loaded(default, null):Bool = false;

	public function new(name:String, path:String, directory:Bool, depth:Int, expanded:Bool = false) {
		this.name = name;
		this.path = path;
		this.directory = directory;
		this.depth = depth;
		this.expanded = expanded;
	}

	public function toggle():Void {
		if (directory) expanded = !expanded;
	}
}
