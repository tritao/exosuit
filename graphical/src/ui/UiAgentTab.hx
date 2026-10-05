package ui;

/** Closing the view never interrupts the daemon-owned resource. */
class UiAgentTab {
	public final id:String;
	public final resource:String;
	public final workspaceRoot:String;
	public final panel:CodexSessionPanel;
	public var title:String;

	public function new(id:String, resource:String, workspaceRoot:String, title:String, panel:CodexSessionPanel) {
		this.id = id;
		this.resource = resource;
		this.workspaceRoot = workspaceRoot;
		this.title = title;
		this.panel = panel;
	}
}
