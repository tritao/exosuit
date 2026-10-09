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

/** A fixed-height status line: actions first, then messages, then document context. */
class StatusBarView implements View {
	public static inline final HEIGHT:Float = 26;
	final data:StatusBarData;
	public function new(data:StatusBarData) this.data = data;

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key("exosuit-status"), function() {
			var toast = data.notification;
			var showToast = toast != null && !data.notificationsVisible;
			var remote = data.remoteDetails.length > 0;
			var hasIndentation = data.indentation != null && data.openIndentation != null;
			var sizes = allocate(context.viewportWidth, remote, showToast, data.unread, hasIndentation);
			var remoteNode:RenderNode = null, remoteLabel:RenderNode = null;
			var dismissNode:RenderNode = null;

			var style = new LayoutStyle();
			style.width = LayoutAxis.stretch(); style.height = LayoutAxis.fixed(HEIGHT);
			style.direction = LayoutDirection.LeftToRight;
			style.childAlignY = LayoutAlignmentY.Center; style.childGap = sizes.gap;
			style.padding = new Insets(sizes.left, 0, sizes.right, 0);
			style.background = context.theme.tokens.surfaceRaised;
			// Clip bounded labels and controls, leaving tooltip overlays free.
			var root = new RenderNode(context.id("status-bar"), LayoutVisualKind.Box, style);

			if (remote) {
				var connectionStyle = controlStyle(sizes.remote, HEIGHT);
				connectionStyle.padding = new Insets(8, 0, 8, 0);
				var connection = new Button("Remote", connectionStyle, data.openRemote, "status-remote");
				connection.variant = ButtonVariant.Navigation;
				connection.classes.push("status-remote");
				connection.leadingView = new Icon("remote-icon", IconName.Remote, 16, context.theme.tokens.accent);
				connection.labelView = new Text("Remote", null, null,
					new TextStyleOverride(null, 12, null, TextWrap.None, null, null, null, context.theme.tokens.textSecondary));
				connection.accessibilityLabel = data.remoteDetails + ". Open Remote Access";
				remoteNode = tooltip("remote", connection, data.remoteDetails).build(context);
				remoteNode.layout.style.width = LayoutAxis.fixed(sizes.remote);
				remoteLabel = remoteNode.children[0].children[1];
				root.add(remoteNode);
			}
			var document = label("document", data.document, true, context);
			var documentTip = tooltip("document", document, data.document);
			var documentNode = documentTip.build(context);
			documentNode.layout.style.width = LayoutAxis.fixed(sizes.document);
			root.add(documentNode);
			var indentationNode:Null<RenderNode> = null;
			if (hasIndentation) {
				var button = new Button(data.indentation, controlStyle(sizes.indentation, 22), data.openIndentation, "status-indentation");
				button.variant = ButtonVariant.Navigation;
				button.accessibilityLabel = data.indentation + ". Choose document indentation";
				indentationNode = tooltip("indentation", button, data.indentationDetails == null ? data.indentation : data.indentationDetails).build(context);
				root.add(indentationNode);
			}
			var message:View;
			if (showToast) {
				var entry:Notification = cast toast;
				var buttonStyle = controlStyle(0, 22); buttonStyle.width = LayoutAxis.grow();
				buttonStyle.clipHorizontal = true;
				var button = new Button("", buttonStyle, function() data.showNotification(entry), "status-notification");
				button.variant = ButtonVariant.Navigation;
				button.leadingIcon = switch entry.kind { case Error: IconName.ErrorCircle; case Warning: IconName.AlertTriangle; case Information: IconName.InfoCircle; };
				button.iconSize = 14;
				button.labelView = label("notification-label", entry.message, false, context);
				button.accessibilityLabel = "Show notification details: " + entry.message;
				message = tooltip("notification", button, entry.message);
			} else message = tooltip("language", label("language", data.status, false, context), data.status);
			var messageNode = message.build(context);
			messageNode.layout.style.width = LayoutAxis.fixed(sizes.message);
			root.add(messageNode);
			if (showToast) {
				var dismiss = new Button("", controlStyle(sizes.dismiss, 22), data.dismissNotification, "notification-toast-dismiss");
				dismiss.variant = ButtonVariant.Navigation; dismiss.leadingIcon = IconName.Close; dismiss.iconSize = 12;
				dismiss.accessibilityLabel = "Hide notification";
				dismissNode = dismiss.build(context);
				root.add(dismissNode);
			}
			var bell = new Button("", controlStyle(sizes.bell, 22), data.toggleNotifications, "notifications-toggle");
			bell.variant = ButtonVariant.Navigation; bell.leadingIcon = IconName.Bell; bell.iconSize = 16;
			bell.accessibilityLabel = "Notifications, " + data.unread + " unread";
			if (data.unread > 0) bell.trailingView = new CountBadge(data.unread);
			var bellNode = bell.build(context);
			root.add(bellNode);
			var apply = function(next:StatusBarSizes) {
				root.layout.style.childGap = next.gap;
				root.layout.style.padding = new Insets(next.left, 0, next.right, 0);
				sizeSlot(documentNode, next.document);
				sizeSlot(messageNode, next.message);
				if (indentationNode != null) { sizeSlot(indentationNode, next.indentation); indentationNode.layout.style.visible = next.indentation > 0; }
				bellNode.layout.style.width = LayoutAxis.fixed(next.bell);
				bellNode.layout.style.childGap = next.compact ? 0 : 8;
				if (data.unread > 0) {
					var badge = bellNode.children[1];
					badge.layout.style.visible = !next.compact;
					badge.layout.style.width = next.compact ? LayoutAxis.fixed(0) : LayoutAxis.fit(22);
				}
				if (remoteNode != null && remoteLabel != null) {
					sizeSlot(remoteNode, next.remote);
					remoteNode.children[0].layout.style.childGap = next.compact ? 0 : 6;
					remoteLabel.layout.style.visible = !next.compact;
					remoteLabel.layout.style.width = next.compact ? LayoutAxis.fixed(0) : LayoutAxis.fit();
				}
				if (dismissNode != null) {
					sizeSlot(dismissNode, next.dismiss);
				}
			};
			apply(sizes);
			var lastWidth = context.viewportWidth;
			root.onResolved(function(geometry) {
				if (lastWidth == geometry.width) return;
				lastWidth = geometry.width;
				apply(allocate(geometry.width, remote, showToast, data.unread, hasIndentation));
				context.requestLayoutFeedback();
			});
			return root;
		});
	}

	/** Allocate the resolved bar width, keeping actions intact before reducing text. */
	static function allocate(width:Float, remote:Bool, toast:Bool, unread:Int, hasIndentation:Bool = false):StatusBarSizes {
		var compact = width < 320;
		var gap = width < 48 ? 0.0 : 4.0;
		var left = remote ? 0.0 : Math.min(10, Math.max(0, width - 28));
		var right = Math.min(6, Math.max(0, width - left - 28));
		var bell = Math.min(Math.max(0, width - left - right), unread > 0 && !compact ? 68.0 : 28.0);
		var dismiss = toast && width >= 160 ? 24.0 : 0.0;
		var connection = remote && width >= 96 ? (compact ? 32.0 : 84.0) : 0.0;
		// Slots remain mounted across resizes, retaining hover/focus identities.
		var remaining = Math.max(0, width - left - right - bell - dismiss - connection
			- gap * (1 + (connection > 0 ? 1 : 0) + (dismiss > 0 ? 1 : 0)));
		var indentation = hasIndentation && width >= 480 ? 92.0 : 0.0;
		if (indentation > 0) remaining -= indentation + gap;
		var document = remaining >= 240 ? Math.min(320, (remaining - gap) * 0.4) : 0.0;
		if (document > 0) remaining -= gap;
		return {compact: compact, gap: gap, left: left, right: right, bell: bell,
			dismiss: dismiss, remote: connection, document: document, message: remaining - document, indentation: indentation};
	}

	static function sizeSlot(node:RenderNode, width:Float):Void {
		node.layout.style.width = LayoutAxis.fixed(width);
		node.layout.style.visible = width > 0;
		// Hidden controls retain intrinsic icon sizes; exclude them from flow.
		node.layout.style.positioning = width > 0 ? LayoutPositioning.Flow : LayoutPositioning.Absolute;
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
			new Text(text, null, null, new TextStyleOverride(null, 12, null, TextWrap.WordCharacter)),
			data.viewport, 0.5, Above);
		tip.fillAnchor = true;
		return tip;
	}
	function label(key:String, text:String, middle:Bool, context:BuildContext):View {
		var singleLine = ~/\s*[\r\n]+\s*/g.replace(text, " ");
		return new MiddleEllipsisText(key, singleLine, middle,
			new TextStyleOverride(null, 12, null, TextWrap.None, null, null, null, context.theme.tokens.textSecondary));
	}
}

typedef StatusBarData = {
	var document:String;
	var status:String;
	var remoteDetails:String;
	@:optional var indentation:String;
	@:optional var indentationDetails:String;
	@:optional var openIndentation:Void->Void;
	var notification:Null<Notification>;
	var notificationsVisible:Bool;
	var unread:Int;
	var viewport:Void->Rect;
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
};
