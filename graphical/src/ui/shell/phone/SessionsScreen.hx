package ui.shell.phone;

import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;

/** Sessions of one workspace under group sections (docs/phone-ui/mockups/Main.dc.html, NestedGroups.dc.html). */
class SessionsScreen extends PhoneUi {
	final host:PhoneHost;

	public function new(host:PhoneHost)
		this.host = host;

	public function build():View {
		var core = host.core(), state = host.state();
		var count = core.sessionCount(state.workspace);
		var subtitle = "on " + core.machineName() + " · " + (core.machineOnline() ? "online" : "offline") + " · " + count
			+ (count == 1 ? " session" : " sessions");
		var chips:Array<KeyedView> = [
			PhoneUi.kv("group", PhoneChrome.groupChip(host)),
			PhoneUi.kv("kind", PhoneChrome.kindChip(host)),
			PhoneUi.kv("sections", PhoneChrome.sectionsPill(host, state.sessionsSectioning, false, false))
		];
		var sections = SessionList.mergeByTitle(core.index().query(state.sessionsQuery()));
		return PhoneChrome.screen("sessions-screen", [
			PhoneUi.kv("header", PhoneChrome.switcher(host, core.workspaceName(state.workspace), subtitle, PhoneChrome.newButton(host), true)),
			PhoneUi.kv("chips", PhoneChrome.chipRow("chips", chips)),
			PhoneUi.kv("rule", PhoneUi.rule("rule")),
			PhoneUi.kv("list", SessionList.build(host, sections, state.sessionsSectioning, true))
		]);
	}
}
