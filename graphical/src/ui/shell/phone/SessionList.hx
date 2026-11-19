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
			case Attention: ATTENTION;
			case Working: ACCENT;
			case Idle | Exited: IDLE;
		};

	static function badgeColors(state:SessionState):{fill:Color, ink:Color}
		return switch state {
			case Attention: {fill: ATTENTION_TINT, ink: ATTENTION_TEXT};
			case Working: {fill: ACCENT_TINT, ink: ACCENT_DARK};
			case Idle | Exited: {fill: CHIP, ink: SECTION};
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
		`tiles` picks the Sessions row (icon tile, last line, state badge); otherwise the All sessions row (state dot,
		workspace · group · kind, age).
	**/
	public static function build(host:PhoneHost, sections:Array<SessionSection>, sectioning:SessionSectioning, tiles:Bool):View {
		var children:Array<KeyedView> = [];
		var collapsible = sectioning == SessionSectioning.Group;
		for (section in sections) {
			var folded = collapsible && host.state().collapsed.exists(section.id);
			if (sectioning != SessionSectioning.None) children.push(kv("h:" + section.id, header(host, section, sectioning, collapsible, folded)));
			if (folded) continue;
			for (entry in section.entries)
				children.push(kv("r:" + entry.workspaceId + ":" + entry.id, tiles ? tileRow(host, entry) : dotRow(host, entry)));
		}
		if (sections.length == 0 || children.length == 0)
			children.push(kv("empty", column("empty", [kv("t", text("No sessions match.", 15, SECONDARY))], function(s) {
				s.padding = new Insets(16, 24, 16, 24);
			})));
		children.push(kv("end", filler("end", 24)));
		var content = column("list-content", children, function(s) s.width = LayoutAxis.stretch());
		var viewport = new LayoutStyle();
		viewport.width = LayoutAxis.stretch();
		viewport.height = LayoutAxis.grow();
		return new ScrollView("list-scroll", content, viewport);
	}

	static function stateInk(section:SessionSection):Color {
		var first = section.entries.length == 0 ? null : section.entries[0].state;
		if (first == SessionState.Attention) return ATTENTION_TEXT;
		return first == SessionState.Working ? ACCENT_DARK : SECTION;
	}

	static function header(host:PhoneHost, section:SessionSection, sectioning:SessionSectioning, collapsible:Bool, folded:Bool):View {
		var parts:Array<KeyedView> = [];
		var title = section.title.length == 0 ? ["Ungrouped"] : section.title;
		if (collapsible) parts.push(kv("chev", icon("chev", folded ? IconName.ChevronRight : IconName.ChevronDown, 14, SECTION)));
		if (sectioning == SessionSectioning.Group && title.length > 1) {
			var parents = title.slice(0, title.length - 1).join(" / ") + " /";
			parts.push(kv("parents", text(parents, 12, MUTED, false, 0.6)));
			parts.push(kv("last", text(title[title.length - 1].toUpperCase(), 12, SECTION, true, 0.6)));
		} else {
			var label = sectioning == SessionSectioning.Group ? title[0] : title.join(" / ").toUpperCase();
			parts.push(kv("title", text(label, 12, sectioning == SessionSectioning.State ? stateInk(section) : SECTION, true, 0.6)));
		}
		if (collapsible)
			parts.push(kv("count", text(section.entries.length + (folded ? " · collapsed" : ""), 12, SECONDARY)));
		var line = row("header", parts, function(s) {
			s.width = LayoutAxis.stretch();
			s.padding = new Insets(16, 14, 16, 6);
			s.childGap = 8;
		});
		if (!collapsible) return line;
		var id = section.id;
		return tappable("header-tap", line, function() {
			if (host.state().collapsed.exists(id)) host.state().collapsed.remove(id); else host.state().collapsed.set(id, true);
			host.refresh();
		});
	}

	static function tileRow(host:PhoneHost, entry:SessionEntry):View {
		var colors = badgeColors(entry.state);
		var tileIcon = icon("i", entry.kind == SessionKind.Chat ? IconName.InfoCircle : IconName.Terminal, 20, ACCENT);
		var texts = column("texts", [
			kv("name", text(clip(entry.name, 48), 16, TEXT, true)),
			kv("last", text(clip(secondLine(entry), 60), 13, SECONDARY, true))
		], function(s) {
			s.width = LayoutAxis.grow();
			s.clipHorizontal = true;
		});
		var line = row("row", [
			kv("tile", tile("tile", 40, 10, ACCENT_TINT, tileIcon)),
			kv("texts", texts),
			kv("badge", badge("badge", entry.state, colors.fill, colors.ink))
		], function(s) {
			s.width = LayoutAxis.stretch();
			s.height = LayoutAxis.fit(72);
			s.padding = new Insets(16, 14, 16, 14);
			s.childGap = 14;
			s.background = SURFACE;
		});
		return entryView(host, entry, line);
	}

	static function dotRow(host:PhoneHost, entry:SessionEntry):View {
		var texts = column("texts", [
			kv("name", text(clip(entry.name, 48), 15, TEXT, true)),
			kv("where", text(clip(whereLine(entry), 60), 13, SECONDARY, true))
		], function(s) {
			s.width = LayoutAxis.grow();
			s.clipHorizontal = true;
		});
		var line = row("row", [
			kv("dot", dot("dot", stateColor(entry.state))),
			kv("texts", texts),
			kv("age", text(age(entry.lastActive), 12, SECONDARY))
		], function(s) {
			s.width = LayoutAxis.stretch();
			s.height = LayoutAxis.fit(64);
			s.padding = new Insets(16, 10, 16, 10);
			s.childGap = 12;
			s.background = SURFACE;
		});
		return entryView(host, entry, line);
	}

	static function entryView(host:PhoneHost, entry:SessionEntry, line:View):View {
		return column("entry", [
			kv("tap", tappable("tap", line, function() host.openSession(entry), function() host.sessionMenu(entry))),
			kv("rule", rule("rule", RULE_SOFT))
		], function(s) s.width = LayoutAxis.stretch());
	}
}
