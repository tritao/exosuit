package ui;

import feedback.Notification;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.Rect;
import haxeon.ui.TextWrap;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.Icon;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.controls.CountBadge;
import haxeon.ui.widgets.text.MiddleEllipsisText;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Row;
import plugin.PluginStatusItem;
import plugin.PluginStatusSide;

/** A fixed-height status line: actions first, then messages, then document context. */
class StatusBarView implements View {
	public static inline final HEIGHT:Float = 26;
	static inline final LABEL_SIZE:Float = 13;
	final data:StatusBarData;
	public function new(data:StatusBarData) this.data = data;

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key("exosuit-status"), function() {
			var toast = data.notification;
			var showToast = toast != null && !data.notificationsVisible;
			var remote = data.remoteDetails.length > 0;
			var hasIndentation = data.indentation != null && data.openIndentation != null;
			var cursorText = data.cursor == null ? "" : data.cursor;
			var statusItems = data.items == null ? [] : data.items;
			var leftItems = itemGroup(statusItems, Left, context);
			var rightItems = itemGroup(statusItems, Right, context);
			var leftItemsWidth = contributionWidth(statusItems, Left);
			var rightItemsWidth = contributionWidth(statusItems, Right);
			// The bar's width at the last layout. Every slot is sized from it here, including the buttons, whose render
			// scopes rebuild from their constructor inputs on hover and press; a resize the root's onResolved writes is a
			// tracked change that rebuilds the bar in the same frame.
			var resolvedWidth = context.state(context.id("status-bar-width"), -1.0);
			var sizes = allocate(resolvedWidth.value > 0 ? resolvedWidth.value : context.viewportWidth, remote, showToast, data.unread,
				hasIndentation, leftItemsWidth, rightItemsWidth, cursorWidth(cursorText));
			var remoteNode:RenderNode = null;
			var dismissNode:RenderNode = null;

			var style = new LayoutStyle();
			style.width = LayoutAxis.stretch(); style.height = LayoutAxis.fixed(HEIGHT);
			style.direction = LayoutDirection.LeftToRight;
			style.childAlignY = LayoutAlignmentY.Center; style.childGap = sizes.gap;
			style.padding = new Insets(sizes.left, 0, sizes.right, 0);
			style.background = context.theme.tokens.surfaceRaised;
			// Clip bounded labels and controls, leaving tooltip overlays free.
			var root = new RenderNode(context.id("status-bar"), LayoutVisualKind.Box, style);
			WorkbenchBoundary.top(context, root);

			if (remote) {
				var connectionStyle = slotStyle(sizes.remote, HEIGHT);
				connectionStyle.padding = new Insets(8, 0, 8, 0);
				connectionStyle.childGap = 6;
				// Compact, the button is its icon alone.
				var connection = new Button(sizes.compact ? "" : "Remote", connectionStyle, data.openRemote, "status-remote", null,
					ButtonVariant.Navigation, null, ["status-remote"], null, null,
					new Icon("remote-icon", IconName.Remote, 16, context.theme.tokens.accent), null,
					sizes.compact ? null : new Text("Remote", null, null,
						new TextStyleOverride(null, LABEL_SIZE, null, TextWrap.None, null, null, null, context.theme.tokens.textSecondary)),
					null, null, data.remoteDetails + ". Open Remote Access");
				remoteNode = tooltip("remote", connection, data.remoteDetails).build(context);
				root.add(remoteNode);
			}
			var leftItemsNode:Null<RenderNode> = null;
			if (leftItems != null) {
				leftItemsNode = leftItems.build(context);
				root.add(leftItemsNode);
			}
			var document = label("document", data.document, true, context);
			var documentTip = tooltip("document", document, data.document);
			var documentNode = documentTip.build(context);
			documentNode.layout.style.width = LayoutAxis.fixed(sizes.document);
			root.add(documentNode);
			var cursorNode:Null<RenderNode> = null;
			if (cursorText.length > 0) {
				cursorNode = tooltip("cursor", label("cursor", cursorText, false, context),
					data.cursorDetails == null ? cursorText : data.cursorDetails).build(context);
				root.add(cursorNode);
			}
			var indentationNode:Null<RenderNode> = null;
			if (hasIndentation) {
				var button = new Button(data.indentation, controlStyle(sizes.indentation, 22), data.openIndentation, "status-indentation",
					null, ButtonVariant.Navigation, null, null, null, null, null, null,
					new MiddleEllipsisText("status-indentation-label", data.indentation, false,
						new TextStyleOverride(null, LABEL_SIZE, null, TextWrap.None, null, null, null, context.theme.tokens.textSecondary)),
					null, null, data.indentation + ". Choose document indentation");
				indentationNode = tooltip("indentation", button, data.indentationDetails == null ? data.indentation : data.indentationDetails).build(context);
				root.add(indentationNode);
			}
			var message:View;
			if (showToast) {
				var entry:Notification = cast toast;
				var buttonStyle = controlStyle(0, 22); buttonStyle.width = LayoutAxis.grow();
				buttonStyle.clipHorizontal = true;
				var icon = switch entry.kind { case Error: IconName.ErrorCircle; case Warning: IconName.AlertTriangle; case Information: IconName.InfoCircle; };
				var button = new Button("", buttonStyle, function() data.showNotification(entry), "status-notification", null,
					ButtonVariant.Navigation, null, null, icon, null, null, null,
					label("notification-label", entry.message, false, context), null, 14, "Show notification details: " + entry.message);
				message = tooltip("notification", button, entry.message);
			} else message = tooltip("language", label("language", data.status, false, context), data.status);
			var messageNode = message.build(context);
			messageNode.layout.style.width = LayoutAxis.fixed(sizes.message);
			root.add(messageNode);
			if (showToast) {
				var dismiss = new Button("", slotStyle(sizes.dismiss, 22), data.dismissNotification, "notification-toast-dismiss", null,
					ButtonVariant.Navigation, null, null, IconName.Close, null, null, null, null, null, 12, "Hide notification");
				dismissNode = dismiss.build(context);
				root.add(dismissNode);
			}
			// Compact, the bell has no count badge.
			var bell = new Button("", controlStyle(sizes.bell, 22), data.toggleNotifications, "notifications-toggle", null,
				ButtonVariant.Navigation, null, null, IconName.Bell, null, null,
				data.unread > 0 && !sizes.compact ? new CountBadge(data.unread) : null,
				null, null, 16, "Notifications, " + data.unread + " unread");
			var bellNode = bell.build(context);
			root.add(bellNode);
			var rightItemsNode:Null<RenderNode> = null;
			if (rightItems != null) {
				rightItemsNode = rightItems.build(context);
				root.add(rightItemsNode);
			}
			// The slots that are not buttons: sized on the built nodes, which this build owns.
			sizeSlot(documentNode, sizes.document);
			sizeSlot(messageNode, sizes.message);
			if (cursorNode != null) sizeSlot(cursorNode, sizes.cursor);
			if (indentationNode != null) { sizeSlot(indentationNode, sizes.indentation); indentationNode.layout.style.visible = sizes.indentation > 0; }
			if (remoteNode != null) sizeSlot(remoteNode, sizes.remote);
			if (leftItemsNode != null) sizeSlot(leftItemsNode, sizes.leftItems);
			if (rightItemsNode != null) sizeSlot(rightItemsNode, sizes.rightItems);
			root.onResolved(function(geometry) {
				if (resolvedWidth.value != geometry.width) resolvedWidth.update(geometry.width);
			});
			return root;
		});
	}

	/** Allocate the resolved bar width, keeping actions intact before reducing text. */
	static function allocate(width:Float, remote:Bool, toast:Bool, unread:Int, hasIndentation:Bool = false,
			leftItemsWidth:Float = 0, rightItemsWidth:Float = 0, cursorWidth:Float = 0):StatusBarSizes {
		var compact = width < 320;
		var visibleLeftItems = width >= 300 ? leftItemsWidth : 0.0;
		var visibleRightItems = width >= 380 ? rightItemsWidth : 0.0;
		var gap = width < 48 ? 0.0 : 4.0;
		var left = remote ? 0.0 : Math.min(10, Math.max(0, width - 28));
		var right = Math.min(6, Math.max(0, width - left - 28));
		var bell = Math.min(Math.max(0, width - left - right), unread > 0 && !compact ? 68.0 : 28.0);
		var dismiss = toast && width >= 160 ? 24.0 : 0.0;
		var connection = remote && width >= 96 ? (compact ? 32.0 : 84.0) : 0.0;
		// Slots remain mounted across resizes, retaining hover/focus identities.
		var remaining = Math.max(0, width - left - right - bell - dismiss - connection - visibleLeftItems - visibleRightItems
			- gap * (1 + (connection > 0 ? 1 : 0) + (dismiss > 0 ? 1 : 0)
				+ (visibleLeftItems > 0 ? 1 : 0) + (visibleRightItems > 0 ? 1 : 0)));
		var indentation = hasIndentation && width >= 480 ? 92.0 : 0.0;
		if (indentation > 0) remaining -= indentation + gap;
		// The cursor position outranks the document name but yields before the message would vanish.
		var cursor = cursorWidth > 0 && width >= 400 && remaining - cursorWidth - gap >= 48 ? cursorWidth : 0.0;
		if (cursor > 0) remaining -= cursor + gap;
		var document = remaining >= 240 ? Math.min(320, (remaining - gap) * 0.4) : 0.0;
		if (document > 0) remaining -= gap;
		return {compact: compact, gap: gap, left: left, right: right, bell: bell,
			dismiss: dismiss, remote: connection, document: document, message: remaining - document,
			indentation: indentation, cursor: cursor, leftItems: visibleLeftItems, rightItems: visibleRightItems};
	}

	function itemGroup(items:Array<PluginStatusItem>, side:PluginStatusSide, context:BuildContext):Null<View> {
		var children:Array<KeyedView> = [];
		for (item in items) if (item.side == side) {
			var style = controlStyle(statusItemWidth(item), 22);
			style.padding = new Insets(5, 0, 5, 0);
			var callback = data.runCommand;
			var command = item.command;
			var action = function() {
				if (callback != null && command != null && command.length > 0) callback(command);
			};
			var button = new Button(item.text, style, action, "status-item:" + item.owner + ":" + item.id, null,
				ButtonVariant.Navigation, null, null, item.icon, null, null, null,
				new MiddleEllipsisText("status-item-label", item.text, false,
					new TextStyleOverride(null, LABEL_SIZE, null, TextWrap.None, null, null, null, context.theme.tokens.textSecondary)),
				null, 14, item.tooltip.length == 0 ? item.text : item.tooltip);
			var description = item.tooltip.length == 0 ? item.text : item.tooltip;
			children.push(new KeyedView(item.owner + ":" + item.id,
				tooltip("status-item:" + item.owner + ":" + item.id, button, description)));
		}
		if (children.length == 0) return null;
		var style = new LayoutStyle();
		style.width = LayoutAxis.fit(); style.height = LayoutAxis.fixed(HEIGHT);
		style.direction = LayoutDirection.LeftToRight;
		style.childAlignY = LayoutAlignmentY.Center; style.childGap = 4;
		style.clipHorizontal = true;
		return new Row("status-items-" + (side == Left ? "left" : "right"), children, style);
	}

	/** Room for "Ln 12345, Col 678 (12345 selected)" style labels, measured generously at the label size. */
	static function cursorWidth(text:String):Float
		return text.length == 0 ? 0 : Math.min(220, text.length * 7.0 + 12);

	static function contributionWidth(items:Array<PluginStatusItem>, side:PluginStatusSide):Float {
		var width = 0.0, count = 0;
		for (item in items) if (item.side == side) {
			width += statusItemWidth(item);
			count++;
		}
		return count == 0 ? 0 : width + (count - 1) * 4;
	}

	static function statusItemWidth(item:PluginStatusItem):Float
		return Math.min(132, Math.max(item.icon == null ? 34 : 30, item.text.length * 7.0 + (item.icon == null ? 18 : 36)));

	static function sizeSlot(node:RenderNode, width:Float):Void {
		node.layout.style.width = LayoutAxis.fixed(width);
		node.layout.style.visible = width > 0;
		// Hidden controls retain intrinsic icon sizes; exclude them from flow.
		node.layout.style.positioning = width > 0 ? LayoutPositioning.Flow : LayoutPositioning.Absolute;
	}

	/** A button's style for a slot that is hidden and out of flow at width 0, as sizeSlot does for other slots. */
	static function slotStyle(width:Float, height:Float):LayoutStyle {
		var style = controlStyle(width, height);
		style.visible = width > 0;
		style.positioning = width > 0 ? LayoutPositioning.Flow : LayoutPositioning.Absolute;
		return style;
	}

	static function controlStyle(width:Float, height:Float):LayoutStyle {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(width); style.height = LayoutAxis.fixed(height);
		style.padding = new Insets(4, 0, 4, 0);
		style.clipHorizontal = true; style.clipVertical = true;
		return style;
	}
	function tooltip(key:String, anchor:View, text:String):TabTooltip {
		var tip = new TabTooltip("status-tooltip:" + key, anchor,
			new Text(text, null, null, TextStyleOverride.paragraph(TextWrap.WordCharacter)),
			data.viewport, data.tooltipDelay == null ? config.Settings.DEFAULT_TOOLTIP_DELAY : data.tooltipDelay, Above);
		tip.fillAnchor = true;
		return tip;
	}
	function label(key:String, text:String, middle:Bool, context:BuildContext):View {
		var singleLine = ~/\s*[\r\n]+\s*/g.replace(text, " ");
		return new MiddleEllipsisText(key, singleLine, middle,
			new TextStyleOverride(null, LABEL_SIZE, null, TextWrap.None, null, null, null, context.theme.tokens.textSecondary));
	}
}

typedef StatusBarData = {
	var document:String;
	var status:String;
	var remoteDetails:String;
	/** The caret position of the active text document, e.g. "Ln 4, Col 9 (12 selected)". */
	@:optional var cursor:String;
	@:optional var cursorDetails:String;
	@:optional var indentation:String;
	@:optional var indentationDetails:String;
	@:optional var openIndentation:Void->Void;
	@:optional var items:Array<PluginStatusItem>;
	@:optional var runCommand:String->Void;
	var notification:Null<Notification>;
	var notificationsVisible:Bool;
	var unread:Int;
	var viewport:Void->Rect;
	@:optional var tooltipDelay:Null<Float>;
	var openRemote:Void->Void;
	var showNotification:Notification->Void;
	var dismissNotification:Void->Void;
	var toggleNotifications:Void->Void;
};

private typedef StatusBarSizes = {
	var compact:Bool;
	var gap:Float;
	var left:Float;
	var right:Float;
	var bell:Float;
	var dismiss:Float;
	var remote:Float;
	var document:Float;
	var message:Float;
	var indentation:Float;
	var cursor:Float;
	var leftItems:Float;
	var rightItems:Float;
};
