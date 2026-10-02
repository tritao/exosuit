package ui;

/** Single owner of a live terminal session, transferable between UI hosts. */
class UiTerminalTab {
	public final id:String;
	public final title:String;
	public final cwd:String;
	public final panel:TerminalPanel;
	public var disposed(default, null):Bool = false;

	public function new(id:String, title:String, cwd:String, panel:TerminalPanel) {
		this.id = id;
		this.title = title;
		this.cwd = cwd;
		this.panel = panel;
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		panel.close();
	}
}
