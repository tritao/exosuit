package ui.shell.phone;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.SearchField;

/** Every session of the machine, sectioned by state (docs/phone-ui/mockups/AllSessions.dc.html). */
class AllSessionsScreen extends PhoneUi {
	final host:PhoneHost;

	public function new(host:PhoneHost)
		this.host = host;

	public function build():View {
		var core = host.core(), state = host.state();
		var count = core.sessionCount(null);
		var subtitle = "all workspaces · " + count + (count == 1 ? " session" : " sessions");
		var fieldStyle = new LayoutStyle();
		fieldStyle.width = LayoutAxis.stretch();
		fieldStyle.height = LayoutAxis.fixed(44);
		fieldStyle.padding = new Insets(12, 0, 12, 0);
		fieldStyle.background = CHIP;
		radius(fieldStyle, 10);
		var field = new SearchField("session-search", state.text, function(value) {
			state.text = value;
			host.refresh();
		}, fieldStyle, "Search sessions on " + core.machineName());
		var searchRow = column("search-row", [kv("field", field)], function(s) {
			s.width = LayoutAxis.stretch();
			s.padding = new Insets(16, 0, 16, 10);
			s.background = SURFACE;
		});
		var chips:Array<KeyedView> = [
			kv("workspace", PhoneChrome.workspaceChip(host)),
			kv("group", PhoneChrome.groupChip(host)),
			kv("kind", PhoneChrome.kindChip(host)),
			kv("sections", PhoneChrome.sectionsPill(host, state.allSectioning, true, true))
		];
		var sections = SessionList.mergeByTitle(core.index().query(state.allQuery()));
		return PhoneChrome.screen("all-sessions-screen", [
			kv("header", PhoneChrome.switcher(host, core.machineName(), subtitle, null, false)),
			kv("search", searchRow),
			kv("chips", PhoneChrome.chipRow("chips", chips)),
			kv("rule", rule("rule")),
			kv("list", SessionList.build(host, sections, state.allSectioning, false))
		]);
	}
}
