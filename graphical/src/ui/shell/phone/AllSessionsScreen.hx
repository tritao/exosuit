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
		fieldStyle.background = PhoneUi.CHIP;
		PhoneUi.radius(fieldStyle, 10);
		var field = new SearchField("session-search", state.text, function(value) {
			state.text = value;
			host.refresh();
		}, fieldStyle, "Search sessions on " + core.machineName());
		var searchRow = PhoneUi.column("search-row", [PhoneUi.kv("field", field)], function(s) {
			s.width = LayoutAxis.stretch();
			s.padding = new Insets(16, 0, 16, 10);
			s.background = PhoneUi.SURFACE;
		});
		var chips:Array<KeyedView> = [
			PhoneUi.kv("workspace", PhoneChrome.workspaceChip(host)),
			PhoneUi.kv("group", PhoneChrome.groupChip(host)),
			PhoneUi.kv("kind", PhoneChrome.kindChip(host)),
			PhoneUi.kv("sections", PhoneChrome.sectionsPill(host, state.allSectioning, true, true))
		];
		var sections = SessionList.mergeByTitle(core.index().query(state.allQuery()));
		return PhoneChrome.screen("all-sessions-screen", [
			PhoneUi.kv("header", PhoneChrome.switcher(host, core.machineName(), subtitle, null, false)),
			PhoneUi.kv("search", searchRow),
			PhoneUi.kv("chips", PhoneChrome.chipRow("chips", chips)),
			PhoneUi.kv("rule", PhoneUi.rule("rule")),
			PhoneUi.kv("list", SessionList.build(host, sections, state.allSectioning, false))
		]);
	}
}
