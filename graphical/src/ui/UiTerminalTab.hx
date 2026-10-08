package ui;

/** Single owner of a live terminal session, transferable between UI hosts. */
class UiTerminalTab {
	public final id:String;
	public var title:String;
	public final remote:Bool;
	public final resourceId:String;
	public var cwd:String;
	public final workspaceRoot:String;
	public final panel:TerminalPanel;
	public var disposed(default, null):Bool = false;
	public var retainOnClose:Bool = false;

	public function new(id:String, title:String, cwd:String, panel:TerminalPanel, remote:Bool = false, ?resourceId:String, ?workspaceRoot:String) {
		this.id = id;
		this.remote = remote;
		this.resourceId = resourceId == null ? id : resourceId;
		this.title = title;
		this.cwd = cwd;
		this.workspaceRoot = workspaceRoot == null ? cwd : workspaceRoot;
		this.panel = panel;
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		panel.close();
	}
}
