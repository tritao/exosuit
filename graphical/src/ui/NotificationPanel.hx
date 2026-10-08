package ui;

import feedback.Notification;
import feedback.NotificationCenter;
import feedback.NotificationText;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.Icon;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.layout.Spacer;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.Text;
import process.CrashReportReader;
import process.ProcessManager;

/** One projection of the shared bounded history; closing never discards notifications. */
class NotificationPanel implements View {
	final center:NotificationCenter;
	final copy:String->Void;
	final changed:Void->Void;
	final dismiss:Void->Void;
	final report:CrashReportReader;
	public var preferredHeight(default, null):Float = 120;
	var expanded:Int = 0;
	var reportEntry:Int = 0;
	var focusRequested:Bool = false;

	public function new(center:NotificationCenter, copy:String->Void, changed:Void->Void,
			dismiss:Void->Void, processes:ProcessManager) {
		this.center = center;
		this.copy = copy;
		this.changed = changed;
		this.dismiss = dismiss;
		report = new CrashReportReader(processes);
	}

	public function open(?entry:Notification):Void {
		focusRequested = false;
		center.markAllRead();
		if (entry != null) expanded = entry.id;
		changed();
	}

	public function close():Void report.close();

	public function poll():Void {
		var previous = report.revision;
		report.poll();
		if (previous != report.revision) changed();
	}

	function button(label:String, action:Void->Void, key:String, ?icon:IconName):Button {
		var style = new LayoutStyle();
		style.height = LayoutAxis.fixed(26);
		style.padding = new Insets(6, 2, 6, 2);
		var result = new Button(label, style, action, key);
		result.variant = ButtonVariant.Navigation;
		result.leadingIcon = icon;
		result.iconSize = 14;
		return result;
	}

	public function build(context:BuildContext):RenderNode {
		var headerStyle = new LayoutStyle();
		headerStyle.width = LayoutAxis.grow();
		headerStyle.childAlignY = LayoutAlignmentY.Center;
		headerStyle.childGap = 4;
		headerStyle.height = LayoutAxis.fixed(32);
		var read = button("", function() { center.markAllRead(); changed(); }, "notifications-read", IconName.Check);
		read.accessibilityLabel = "Mark all notifications read";
		read.enabled = center.unreadCount() > 0;
		var clear = button("", function() {
			center.clear(); expanded = 0; reportEntry = 0; report.close(); changed();
		}, "notifications-clear", IconName.Trash);
		clear.accessibilityLabel = "Clear all notifications";
		clear.enabled = center.entries.length > 0;
		var close = button("", dismiss, "notifications-close", IconName.Close);
		close.accessibilityLabel = "Close notifications";
		var header = new Row("notifications-header", [
			new KeyedView("title", new Text("Notifications", null, context.theme.tokens.textPrimary, TextStyleOverride.text(14))),
			new KeyedView("space", new Spacer("space", LayoutAxis.grow(), LayoutAxis.fixed(1))),
			new KeyedView("read", read), new KeyedView("clear", clear), new KeyedView("close", close)
		], headerStyle);
		var rows:Array<KeyedView> = [];
		if (center.entries.length == 0) rows.push(new KeyedView("empty", new Text("No notifications yet.", null, context.theme.tokens.textSecondary)));
		for (entry in center.history()) {
			var id = entry.id;
			var rowStyle = new LayoutStyle();
			rowStyle.width = LayoutAxis.grow();
			rowStyle.padding = new Insets(12, 10, 12, 10);
			rowStyle.childGap = 5;
			rowStyle.background = entry.read ? context.theme.tokens.surface : context.theme.tokens.surfaceRaised;
			var metadata = (entry.source == "" ? NotificationText.severity(entry) : entry.source)
				+ " · " + NotificationText.time(entry) + (entry.read ? "" : " · Unread");
			var remove = button("", function() {
				center.dismiss(id);
				if (reportEntry == id) { report.close(); reportEntry = 0; }
				changed();
			}, "notification-dismiss:" + id, IconName.Close);
			remove.accessibilityLabel = "Dismiss notification " + id;
			var lineStyle = new LayoutStyle(); lineStyle.width = LayoutAxis.grow();
			lineStyle.childGap = 8; lineStyle.childAlignY = LayoutAlignmentY.Center;
			var textStyle = new LayoutStyle(); textStyle.width = LayoutAxis.grow();
			var details = button("", function() {
				expanded = expanded == id ? 0 : id; center.markRead(id); changed();
			}, "notification-details:" + id, expanded == id ? IconName.ChevronDown : IconName.ChevronRight);
			details.accessibilityLabel = (expanded == id ? "Hide" : "Show") + " notification details";
			var severityIcon = switch entry.kind { case Error: IconName.ErrorCircle; case Warning: IconName.AlertTriangle; case Information: IconName.InfoCircle; };
			var severityColor = switch entry.kind { case Error: context.theme.tokens.danger; case Warning: context.theme.tokens.warning; case Information: context.theme.tokens.info; };
			var summary = new Row("notification-summary", [
				new KeyedView("severity", new Icon("notification-severity", severityIcon, 18, severityColor, NotificationText.severity(entry))),
				new KeyedView("summary", new Text(NotificationText.summary(entry, 240), textStyle, context.theme.tokens.textPrimary, TextStyleOverride.text(14))),
				new KeyedView("details", details), new KeyedView("dismiss", remove)
			], lineStyle);
			var actions:Array<KeyedView> = [];
			for (index in 0...entry.actions.length) {
				var action = entry.actions[index];
				actions.push(new KeyedView("action:" + index, button(action.label, action.run, "notification-action:" + id + ":" + index)));
			}
			if (expanded == id) actions.push(new KeyedView("copy",
				button("Copy details", function() copy(NotificationText.details(entry)), "notification-copy:" + id, IconName.Copy)));
			var pid = NotificationText.crashPid(entry);
			if (pid != null && Sys.systemName() == "Linux") {
				var crashPid:Int = pid;
				actions.push(new KeyedView("report", button("Open crash report", function() {
					expanded = id; reportEntry = id; center.markRead(id); report.open(crashPid); changed();
				}, "notification-report:" + id)));
			}
			var content:Array<KeyedView> = [new KeyedView("summary", summary),
				new KeyedView("metadata", new Text(metadata, null, context.theme.tokens.textSecondary, TextStyleOverride.text(11)))];
			var actionStyle = new LayoutStyle(); actionStyle.width = LayoutAxis.grow(); actionStyle.childGap = 4;
			actionStyle.wrapMode = haxeon.ui.LayoutWrapMode.Wrap;
			if (actions.length > 0) content.push(new KeyedView("actions", new Row("notification-actions", actions, actionStyle)));
			if (expanded == id) {
				content.push(new KeyedView("full-details", new Text(entry.message, null, context.theme.tokens.textPrimary, TextStyleOverride.text(12))));
				if (reportEntry == id) {
					content.push(new KeyedView("crash-report", new Text(report.loading ? "Loading crash report…" : report.text,
						null, context.theme.tokens.textPrimary, TextStyleOverride.text(12))));
					if (!report.loading && report.text != "") content.push(new KeyedView("copy-report",
						button("Copy crash report", function() copy(report.text), "notification-copy-report:" + id, IconName.Copy)));
				}
			}
			var separator = new LayoutStyle(); separator.width = LayoutAxis.grow(); separator.height = LayoutAxis.fixed(1);
			separator.background = context.theme.tokens.border;
			var divider = new Spacer("separator", separator.width, separator.height); divider.style.background = separator.background;
			rows.push(new KeyedView("separator:" + id, divider));
			rows.push(new KeyedView("notification:" + id, new Column("notification", content, rowStyle)));
		}
		var listStyle = new LayoutStyle(); listStyle.width = LayoutAxis.grow(); listStyle.childGap = 0;
		var scrollStyle = new LayoutStyle(); scrollStyle.width = LayoutAxis.grow(); scrollStyle.height = LayoutAxis.grow();
		var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.grow();
		style.padding = new Insets(8, 4, 8, 4); style.childGap = 4; style.background = context.theme.tokens.surface;
		var node = new Column("notification-center", [new KeyedView("header", header),
			new KeyedView("history", new ScrollView("notification-history", new Column("notification-list", rows, listStyle), scrollStyle))
		], style).build(context);
		node.walk(function(child) {
			if (child.styleKey == "notification-list") child.onResolved(function(geometry) {
				var height = Math.ceil(44 + geometry.height);
				if (Math.abs(preferredHeight - height) > 1) { preferredHeight = height; changed(); }
			});
		});
		if (!focusRequested) {
			focusRequested = true;
			focusFirst(node, context);
		}
		return node;
	}

	function focusFirst(node:RenderNode, context:BuildContext):Bool {
		if (node.focusable && node.enabled) { context.requestFocusAfterLayout(node.id); return true; }
		for (child in node.children) if (focusFirst(child, context)) return true;
		return false;
	}
}
