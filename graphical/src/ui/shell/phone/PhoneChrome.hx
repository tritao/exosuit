package ui.shell.phone;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAlignmentX;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.navigation.Chip;
import haxeon.ui.widgets.navigation.ChipTrailing;
import workspace.sessions.SessionIndex;
import workspace.sessions.SessionIndex.SessionSectioning;

/** The header, filter chips and screen frame the list screens share. */
class PhoneChrome extends PhoneUi {
	/** A screen: the children stacked, filling the stack's page on the ground colour. */
	public static function screen(key:String, children:Array<KeyedView>, background = true):View
		return column(key, children, function(s) {
			s.width = LayoutAxis.grow();
			s.height = LayoutAxis.stretch();
			if (background) s.background = GROUND;
		});

	/** `Machines`, `Files`: a plain heading over a white band. */
	public static function heading(title:String):View
		return column("heading", [
			kv("t", text(title, 26, TEXT)),
			kv("rule", filler("gap", 12))
		], function(s) {
			s.width = LayoutAxis.stretch();
			s.padding = new Insets(16, 20, 16, 0);
			s.background = SURFACE;
		});

	/** The title switcher: `name ▾` over a subtitle. */
	public static function switcher(host:PhoneHost, title:String, subtitle:String, trailing:Null<View>, belowRule:Bool):View {
		var label = row("switch-label", [
			kv("t", text(clip(title, 24), 22, TEXT)),
			kv("c", icon("c", IconName.ChevronDown, 18, TEXT))
		], function(s) s.childGap = 6);
		var block = column("switch-block", [
			kv("tap", tappableFit("tap", label, host.chooseScope)),
			kv("sub", text(clip(subtitle, 52), 13, SECONDARY))
		], function(s) {
			s.width = LayoutAxis.grow();
			s.childGap = 2;
		});
		var parts = [kv("block", block)];
		if (trailing != null) parts.push(kv("trailing", trailing));
		var bar = row("switch-bar", parts, function(s) {
			s.width = LayoutAxis.stretch();
			s.padding = new Insets(16, 14, 16, 14);
			s.childGap = 12;
			s.background = SURFACE;
		});
		return belowRule ? column("switch-framed", [kv("bar", bar), kv("rule", rule("rule"))], function(s) s.width = LayoutAxis.stretch()) : bar;
	}

	/** The round accent "+" button. */
	public static function newButton(host:PhoneHost):View
		return tappableFit("new-session", tile("new-tile", 44, 22, ACCENT, icon("plus", IconName.Plus, 20, WHITE)), host.newSession);

	static function groupName(index:SessionIndex, id:String):String {
		for (entry in index.entries) for (i in 0...entry.groupPath.length)
			if (entry.groupPath[i] == id && i < entry.groupNames.length) return entry.groupNames[i];
		return id;
	}

	static function filterChip(key:String, none:String, names:Array<String>, onOpen:Void->Void, onClear:Void->Void):View {
		if (names.length == 0) return new Chip(key, none, onOpen, false, ChipTrailing.Chevron);
		var label = names.length == 1 ? clip(names[0], 18) : none + " · " + names.length;
		return new Chip(key, label, onOpen, true, ChipTrailing.Clear(onClear));
	}

	public static function groupChip(host:PhoneHost):View {
		var index = host.core().index();
		var names = [for (id in host.state().groups) groupName(index, id)];
		return filterChip("chip-group", "Group", names, host.chooseGroups, function() {
			host.state().groups = [];
			host.refresh();
		});
	}

	public static function kindChip(host:PhoneHost):View {
		var names = [for (kind in host.state().kinds) SessionList.kindLabel(kind)];
		return filterChip("chip-kind", "Kind", names, host.chooseKinds, function() {
			host.state().kinds = [];
			host.refresh();
		});
	}

	public static function workspaceChip(host:PhoneHost):View {
		var names = [for (id in host.state().workspaces) host.core().workspaceName(id)];
		return filterChip("chip-workspace", "Workspace", names, host.chooseWorkspaces, function() {
			host.state().workspaces = [];
			host.refresh();
		});
	}

	/** `Sections: group`, the tinted pill that opens the sectioning choice. */
	public static function sectionsPill(host:PhoneHost, value:SessionSectioning, all:Bool, compact:Bool):View {
		var label = "Sections: " + PhoneState.sectioningLabel(value);
		var pillView = compact ? pill("pill", label, ACCENT_TINT, ACCENT_DARK, 13, 12, 7, 16) : pill("pill", label, ACCENT_TINT, ACCENT_DARK, 14, 14, 8, 18);
		return tappableFit("sections", pillView, function() host.chooseSectioning(all));
	}

	public static function chipRow(key:String, chips:Array<KeyedView>):View
		return row(key, chips, function(s) {
			s.width = LayoutAxis.stretch();
			s.padding = new Insets(16, 10, 16, 10);
			s.childGap = 8;
			s.background = SURFACE;
			s.clipHorizontal = true;
		});
}
