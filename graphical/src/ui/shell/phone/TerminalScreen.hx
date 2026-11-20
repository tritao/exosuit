package ui.shell.phone;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import ui.TerminalPane;
import workspace.sessions.SessionIndex.SessionEntry;

/**
	A session full screen (docs/phone-ui/mockups/Terminal.dc.html): back, name, `workspace · group · you have
	control`, a menu, and the existing view below. A TerminalPane shows its touch-keys row full width with Send as Enter.
	The system keyboard shrinks the screen from outside (the app keeps the shell inside the safe area).
**/
class TerminalScreen extends PhoneUi {
	final host:PhoneHost;
	final title:String;
	final entry:Null<SessionEntry>;
	final panel:View;

	public function new(host:PhoneHost, title:String, entry:Null<SessionEntry>, panel:View) {
		this.host = host;
		this.title = title;
		this.entry = entry;
		this.panel = panel;
		var pane = Std.downcast(panel, TerminalPane);
		if (pane != null) {
			pane.touchKeys = true;
			pane.enterLabel = "Send";
		}
	}

	function subtitle():String {
		var parts:Array<String> = [];
		if (entry != null) {
			parts.push(entry.workspaceName);
			if (entry.groupNames.length > 0) parts.push(entry.groupNames[entry.groupNames.length - 1]);
		}
		var pane = Std.downcast(panel, TerminalPane);
		if (pane != null) {
			var status = pane.controlStatus();
			parts.push(pane.controlling() ? "you have control" : status == null ? "watching" : status);
		}
		return parts.join(" · ");
	}

	public function build():View {
		var back = PhoneUi.tappableFit("back", PhoneUi.tile("back-tile", 44, 0, PhoneUi.SURFACE, PhoneUi.icon("back", IconName.ArrowLeft, 22, PhoneUi.TEXT)), host.back);
		var texts = PhoneUi.column("titles", [
			PhoneUi.kv("name", PhoneUi.text(PhoneUi.clip(title, 40), 16, PhoneUi.TEXT, true)),
			PhoneUi.kv("sub", PhoneUi.text(PhoneUi.clip(subtitle(), 56), 12, PhoneUi.SECONDARY, true))
		], function(s) {
			s.width = LayoutAxis.grow();
			s.clipHorizontal = true;
		});
		var parts = [PhoneUi.kv("back", back), PhoneUi.kv("titles", texts)];
		var menuEntry = entry;
		if (menuEntry != null)
			parts.push(PhoneUi.kv("menu", PhoneUi.tappableFit("menu", PhoneUi.tile("menu-tile", 44, 0, PhoneUi.SURFACE, PhoneUi.text("⋮", 24, PhoneUi.TEXT)), function() host.sessionMenu(menuEntry))));
		var header = PhoneUi.row("terminal-header", parts, function(s) {
			s.width = LayoutAxis.stretch();
			s.padding = new Insets(8, 8, 8, 8);
			s.childGap = 8;
			s.background = PhoneUi.SURFACE;
		});
		var body = PhoneUi.column("terminal-body", [PhoneUi.kv("panel", panel)], function(s) {
			s.width = LayoutAxis.grow();
			s.height = LayoutAxis.grow();
		});
		return PhoneChrome.screen("terminal-screen", [PhoneUi.kv("header", header), PhoneUi.kv("rule", PhoneUi.rule("rule")), PhoneUi.kv("body", body)], false);
	}
}
