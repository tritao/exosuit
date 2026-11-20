package ui.shell.phone;

import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.Text;
import workspace.sessions.SessionIndex.SessionEntry;
import workspace.sessions.SessionIndex.SessionKind;
import workspace.sessions.SessionIndex.SessionSection;
import workspace.sessions.SessionIndex.SessionSectioning;
import workspace.sessions.SessionIndex.SessionState;

/** Section headers and session rows shared by the Sessions and All sessions screens. */
class SessionList extends PhoneUi {
	public static function kindLabel(kind:SessionKind):String
		return switch kind {
			case Claude: "Claude";
			case Codex: "Codex";
			case Terminal: "terminal";
			case Chat: "chat";
			case Other: "session";
		};

	public static function stateColor(state:SessionState):Color
		return switch state {
			case Attention: PhoneUi.ATTENTION;
			case Working: PhoneUi.ACCENT;
			case Idle | Exited: PhoneUi.IDLE;
		};

	static function badgeColors(state:SessionState):{fill:Color, ink:Color}
		return switch state {
			case Attention: {fill: PhoneUi.ATTENTION_TINT, ink: PhoneUi.ATTENTION_TEXT};
			case Working: {fill: PhoneUi.ACCENT_TINT, ink: PhoneUi.ACCENT_DARK};
			case Idle | Exited: {fill: PhoneUi.CHIP, ink: PhoneUi.SECTION};
		};

	static function lastGroup(entry:SessionEntry):String
		return entry.groupNames.length == 0 ? "" : entry.groupNames[entry.groupNames.length - 1];

	/** The row's second line: its last line of output, else the kind and group. */
	public static function secondLine(entry:SessionEntry):String {
		if (entry.last != null && entry.last != "") return entry.last;
		var group = lastGroup(entry);
		return kindLabel(entry.kind) + (group == "" ? "" : " · " + group);
	}

	/** `workspace · group · kind`, the All sessions row's second line. */
	public static function whereLine(entry:SessionEntry):String {
		var parts = [entry.workspaceName];
		var group = lastGroup(entry);
		if (group != "") parts.push(group);
		parts.push(kindLabel(entry.kind));
		return parts.join(" · ");
	}

	/** Sections of one state label are merged (Idle and Exited are both RECENT). */
	public static function mergeByTitle(sections:Array<SessionSection>):Array<SessionSection> {
		var result:Array<SessionSection> = [];
		for (section in sections) {
			var last = result.length == 0 ? null : result[result.length - 1];
			if (last != null && last.title.join("/") == section.title.join("/")) last.entries = last.entries.concat(section.entries);
			else result.push({id: section.id, title: section.title, entries: section.entries.copy()});
		}
		return result;
	}

	/**
		Builds the list: for each section a header (collapsible with a count when the sectioning is Group), then its rows.
		`tiles` picks the Sessions PhoneUi.row (icon tile, last line, state badge); otherwise the All sessions PhoneUi.row (state dot,
		workspace · group · kind, age).
	**/
	public static function build(host:PhoneHost, sections:Array<SessionSection>, sectioning:SessionSectioning, tiles:Bool):View {
		var children:Array<KeyedView> = [];
		var collapsible = sectioning == SessionSectioning.Group;
		for (section in sections) {
			var folded = collapsible && host.state().collapsed.exists(section.id);
			if (sectioning != SessionSectioning.None) children.push(PhoneUi.kv("h:" + section.id, header(host, section, sectioning, collapsible, folded)));
			if (folded) continue;
			for (entry in section.entries)
				children.push(PhoneUi.kv("r:" + entry.workspaceId + ":" + entry.id, tiles ? tileRow(host, entry) : dotRow(host, entry)));
		}
		if (sections.length == 0 || children.length == 0)
			children.push(PhoneUi.kv("empty", PhoneUi.column("empty", [PhoneUi.kv("t", PhoneUi.text("No sessions match.", 15, PhoneUi.SECONDARY))], function(s) {
				s.padding = new Insets(16, 24, 16, 24);
			})));
		children.push(PhoneUi.kv("end", PhoneUi.filler("end", 24)));
		var content = PhoneUi.column("list-content", children, function(s) s.width = LayoutAxis.stretch());
		var viewport = new LayoutStyle();
		viewport.width = LayoutAxis.stretch();
		viewport.height = LayoutAxis.grow();
		return new ScrollView("list-scroll", content, viewport);
	}

	static function stateInk(section:SessionSection):Color {
		var first = section.entries.length == 0 ? null : section.entries[0].state;
		if (first == SessionState.Attention) return PhoneUi.ATTENTION_TEXT;
		return first == SessionState.Working ? PhoneUi.ACCENT_DARK : PhoneUi.SECTION;
	}

	static function header(host:PhoneHost, section:SessionSection, sectioning:SessionSectioning, collapsible:Bool, folded:Bool):View {
		var parts:Array<KeyedView> = [];
		var title = section.title.length == 0 ? ["Ungrouped"] : section.title;
		if (collapsible) parts.push(PhoneUi.kv("chev", PhoneUi.icon("chev", folded ? IconName.ChevronRight : IconName.ChevronDown, 14, PhoneUi.SECTION)));
		if (sectioning == SessionSectioning.Group && title.length > 1) {
			var parents = title.slice(0, title.length - 1).join(" / ") + " /";
			parts.push(PhoneUi.kv("parents", PhoneUi.text(parents, 12, PhoneUi.MUTED, false, 0.6)));
			parts.push(PhoneUi.kv("last", PhoneUi.text(title[title.length - 1].toUpperCase(), 12, PhoneUi.SECTION, true, 0.6)));
		} else {
			var label = sectioning == SessionSectioning.Group ? title[0] : title.join(" / ").toUpperCase();
			parts.push(PhoneUi.kv("title", PhoneUi.text(label, 12, sectioning == SessionSectioning.State ? stateInk(section) : PhoneUi.SECTION, true, 0.6)));
		}
		if (collapsible)
			parts.push(PhoneUi.kv("count", PhoneUi.text(section.entries.length + (folded ? " · collapsed" : ""), 12, PhoneUi.SECONDARY)));
		var line = PhoneUi.row("header", parts, function(s) {
			s.width = LayoutAxis.stretch();
			s.padding = new Insets(16, 14, 16, 6);
			s.childGap = 8;
		});
		if (!collapsible) return line;
		var id = section.id;
		return PhoneUi.tappable("header-tap", line, function() {
			if (host.state().collapsed.exists(id)) host.state().collapsed.remove(id); else host.state().collapsed.set(id, true);
			host.refresh();
		});
	}

	static function tileRow(host:PhoneHost, entry:SessionEntry):View {
		var colors = badgeColors(entry.state);
		var tileIcon = PhoneUi.icon("i", entry.kind == SessionKind.Chat ? IconName.InfoCircle : IconName.Terminal, 20, PhoneUi.ACCENT);
		var texts = PhoneUi.column("texts", [
			PhoneUi.kv("name", PhoneUi.text(PhoneUi.clip(entry.name, 48), 16, PhoneUi.TEXT, true)),
			PhoneUi.kv("last", PhoneUi.text(PhoneUi.clip(secondLine(entry), 60), 13, PhoneUi.SECONDARY, true))
		], function(s) {
			s.width = LayoutAxis.grow();
			s.clipHorizontal = true;
		});
		var line = PhoneUi.row("row", [
			PhoneUi.kv("tile", PhoneUi.tile("tile", 40, 10, PhoneUi.ACCENT_TINT, tileIcon)),
			PhoneUi.kv("texts", texts),
			PhoneUi.kv("badge", PhoneUi.badge("badge", entry.state, colors.fill, colors.ink))
		], function(s) {
			s.width = LayoutAxis.stretch();
			s.height = LayoutAxis.fit(72);
			s.padding = new Insets(16, 14, 16, 14);
			s.childGap = 14;
			s.background = PhoneUi.SURFACE;
		});
		return entryView(host, entry, line);
	}

	static function dotRow(host:PhoneHost, entry:SessionEntry):View {
		var texts = PhoneUi.column("texts", [
			PhoneUi.kv("name", PhoneUi.text(PhoneUi.clip(entry.name, 48), 15, PhoneUi.TEXT, true)),
			PhoneUi.kv("where", PhoneUi.text(PhoneUi.clip(whereLine(entry), 60), 13, PhoneUi.SECONDARY, true))
		], function(s) {
			s.width = LayoutAxis.grow();
			s.clipHorizontal = true;
		});
		var line = PhoneUi.row("row", [
			PhoneUi.kv("dot", PhoneUi.dot("dot", stateColor(entry.state))),
			PhoneUi.kv("texts", texts),
			PhoneUi.kv("age", PhoneUi.text(PhoneUi.age(entry.lastActive), 12, PhoneUi.SECONDARY))
		], function(s) {
			s.width = LayoutAxis.stretch();
			s.height = LayoutAxis.fit(64);
			s.padding = new Insets(16, 10, 16, 10);
			s.childGap = 12;
			s.background = PhoneUi.SURFACE;
		});
		return entryView(host, entry, line);
	}

	static function entryView(host:PhoneHost, entry:SessionEntry, line:View):View {
		return PhoneUi.column("entry", [
			PhoneUi.kv("tap", PhoneUi.tappable("tap", line, function() host.openSession(entry), function() host.sessionMenu(entry))),
			PhoneUi.kv("rule", PhoneUi.rule("rule", PhoneUi.RULE_SOFT))
		], function(s) s.width = LayoutAxis.stretch());
	}
}
