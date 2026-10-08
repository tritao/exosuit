package app;

import feedback.Notification;
import feedback.NotificationKind;
import feedback.NotificationText;
import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostOptions;
import ui.ExosuitApp;
import ui.ExosuitPalette;

class NotificationsSmokeApp extends ExosuitApp {
	var stage = 100;
	final desktopContext:haxeon.ui.host.UiHostContext;
	final crash:Notification;
	var copied = false;
	var recovered = false;
	var passed = false;

	public function new(context:haxeon.ui.host.UiHostContext) {
		super(context.fonts, ExosuitPalette.theme(false), context, null, null, null, false);
		desktopContext = context;
		var center = host.getNotifications();
		center.clear();
		center.publish("A background task completed.", Information, "tasks");
		center.publish("A connection was interrupted.", Warning, "workspace");
		crash = center.publish("Fixture HashLink fatal error\nInspect a retained core with: coredumpctl debug 1234", Error, "workspace");
		center.dismissToast();
	}

	function find(node:RenderNode, key:String):Null<RenderNode> {
		if (node.styleKey == key) return node;
		for (child in node.children) {
			var result = find(child, key);
			if (result != null) return result;
		}
		return null;
	}

	function hasText(node:RenderNode, text:String):Bool {
		if (node.semantics != null && node.semantics.label != null && node.semantics.label.indexOf(text) >= 0) return true;
		for (child in node.children) if (hasText(child, text)) return true;
		return false;
	}

	function click(root:RenderNode, key:String):Void {
		var node = find(root, key);
		if (node == null) throw "Missing notification control: " + key;
		var bounds = node.globalBounds();
		ui.pointerDown(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
		ui.pointerUp(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
	}

	override public function submit(frame:LayoutFrame):RenderNode {
		var root = super.submit(frame), center = host.getNotifications();
		switch stage {
			case 100:
				if (desktopContext.windowControls == null) throw "Custom titlebar did not activate";
				var titlebar:RenderNode = cast find(root, "exosuit-titlebar");
				if (titlebar.windowDecoration != nativekit.ffi.NativeKitTypes.WindowDecorationRegionKind.Drag)
					throw "Titlebar has no native drag region";
				var closeButton:RenderNode = cast find(root, "window-close");
				if (closeButton.windowDecoration != nativekit.ffi.NativeKitTypes.WindowDecorationRegionKind.Client)
					throw "Window buttons were swallowed by the drag region";
				var edges = 0; root.walk(function(node) { if (node.windowDecoration != null && node.windowDecoration >= 2) edges++; });
				if (edges != 8) throw "Custom frame has missing resize regions";
				desktopContext.zoom = 1.25; stage++;
			case 101:
				if (Math.abs(frame.width - 880) > 1) throw "Zoom did not resize the custom titlebar layout";
				desktopContext.windowControls.observe(nativekit.ffi.NativeKitTypes.WindowStateFlags.Maximized); stage++;
			case 102:
				if (find(root, "window-restore") == null) throw "Maximized titlebar did not offer Restore";
				var edges = 0; root.walk(function(node) { if (node.windowDecoration != null && node.windowDecoration >= 2) edges++; });
				if (edges != 0) throw "Maximized window still exposes resize edges";
				desktopContext.windowControls.observe(nativekit.ffi.NativeKitTypes.WindowStateFlags.Visible); stage++;
			case 103:
				if (find(root, "window-maximize") == null) throw "Restored titlebar did not offer Maximize";
				application.newDocument();
				var documentView:ui.UiDocumentView = cast host.activeView();
				documentView.document.buffer.replaceAllText("Unsaved titlebar close fixture", documentView.selection);
				click(root, "window-close"); stage++;
			case 104:
				if (find(root, "save-confirmation-cancel") == null) throw "Custom Close bypassed unsaved changes";
				click(root, "save-confirmation-cancel"); desktopContext.zoom = 1; stage = 0;
			case 0:
				if (center.unreadCount() != 3 || find(root, "status-notification") != null) throw "Hidden notifications lost history or stayed in the status bar";
				click(root, "notifications-toggle"); stage++;
			case 1:
				if (center.unreadCount() != 0 || !hasText(root, "A connection was interrupted.")) throw "Opening history did not reveal retained notifications";
				if (find(root, "notification-copy:" + crash.id) != null) throw "Collapsed notification exposes utility controls";
				click(root, "notification-details:" + crash.id); stage++;
			case 2:
				if (!hasText(root, crash.message)) throw "Full notification details missing";
				click(root, "notification-copy:" + crash.id);
				ui.clipboard.readText(function(value) copied = value == NotificationText.details(crash));
				click(root, "notification-report:" + crash.id); stage++;
			case 3:
				if (hasText(root, "Fixture retained crash report")) {
					if (!copied) throw "Copy details did not preserve the diagnostic";
					click(root, "notification-dismiss:" + crash.id); stage++;
				}
			case 4:
				if (center.entries.length != 2 || hasText(root, crash.message)) throw "Dismiss did not remove the selected entry";
				center.publish("New while history is open", Information, "tasks",
					[new feedback.NotificationAction("Recover", function() recovered = true)]); stage++;
			case 5:
				if (!hasText(root, "Unread") || center.unreadCount() != 1) throw "New notifications were marked read without review";
				click(root, "notification-action:" + center.entries[2].id + ":0");
				if (!recovered) throw "Notification recovery action did not run";
				click(root, "notifications-read"); stage++;
			case 6:
				if (center.unreadCount() != 0 || center.entries.length != 3) throw "Mark all read discarded history";
				click(root, "notifications-clear"); stage++;
			case 7:
				if (!hasText(root, "No notifications yet.") || center.entries.length != 0) throw "Clear all left stale history";
				if (find(root, "notification-center").globalBounds().height > 100) { requestFrame(); return root; }
				ui.key(UiEventKind.KeyDown, UiKey.Escape); stage++;
			case 8:
				if (find(root, "notifications-close") != null) throw "Escape did not dismiss notification history";
				center.publish("Terminal 1: The terminal session is no longer available", Error, "terminal",
					[new feedback.NotificationAction("Create terminal", function() recovered = true)]);
				click(root, "notifications-toggle"); stage++;
			case 9:
				var panelHeight = find(root, "notification-center").globalBounds().height;
				var contentHeight = find(root, "notification-list").globalBounds().height;
				if (Math.abs(panelHeight - contentHeight - 44) > 2) { requestFrame(); return root; }
				if (panelHeight > 200) throw "Single notification wastes vertical space";
				passed = true; stage++;
				Sys.println("PASS: custom titlebar regions, zoom, window-state controls, unsaved close confirmation; hidden notification history, unread badge, details/copy, retained crash report, recovery action, adaptive height, dismiss, read/clear and Escape");
			default:
		}
		if (!passed) requestFrame();
		return root;
	}

	override public function dispose():Void {
		super.dispose();
		if (!passed) throw "Notification UI acceptance stalled at stage " + stage;
	}
}

class NotificationsSmokeMain {
	static function main():Int {
		var options = new DesktopUiHostOptions();
		options.customTitlebar = true;
		options.title = "exosuit notification smoke"; options.width = 1100; options.height = 760;
		options.captureDirectory = Sys.args()[0]; options.captureSeconds = 4;
		return DesktopUiHost.run(options, function(context) return new NotificationsSmokeApp(context));
	}
}
