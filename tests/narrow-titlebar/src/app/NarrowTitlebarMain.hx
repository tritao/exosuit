package app;

import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostOptions;
import haxeon.ui.host.UiHostContext;
import ui.ExosuitApp;
import ui.ExosuitPalette;

class NarrowTitlebarApp extends ExosuitApp {
	final desktop:UiHostContext;
	var passed = false;
	var awaitingZoom = false;
	public function new(context:UiHostContext, dark:Bool) {
		super(context.fonts, ExosuitPalette.theme(dark), context, null, null, null, false);
		desktop = context;
	}
	function find(node:RenderNode, key:String):RenderNode {
		if (node.styleKey == key) return node;
		for (child in node.children) {
			var match = find(child, key);
			if (match != null) return match;
		}
		return null;
	}
	function check(root:RenderNode, width:Float, maximized:Bool):Void {
		var left = width - 132;
		for (key in ["window-minimize", maximized ? "window-restore" : "window-maximize", "window-close"]) {
			var node = find(root, key);
			if (node == null) throw "Missing " + key;
			var bounds = node.globalBounds();
			if (Math.abs(bounds.x - left) > 1 || Math.abs(bounds.width - 44) > 1)
				throw key + " displaced at " + width + ": " + bounds;
			if (node.windowDecoration != nativekit.ffi.NativeKitTypes.WindowDecorationRegionKind.Client)
				throw key + " is not interactive";
			left += 44;
		}
		var commands = find(root, "toolbar-Commands");
		if (commands == null) throw "Commands disappeared";
		var bounds = commands.globalBounds();
		if (bounds.x < 0 || bounds.x + bounds.width > width - 132 + 1 || bounds.width < 31)
			throw "Commands clipped at " + width + ": " + bounds;
		if (width == 320 && find(root, "toolbar-Open") != null) throw "Optional shortcuts did not collapse";
		if (width == 1280 && find(root, "toolbar-New") == null) throw "Shortcuts did not return";
	}
	override public function dispose():Void {
		super.dispose();
		if (!passed) throw "Narrow titlebar acceptance did not complete";
	}
	override public function submit(frame:LayoutFrame):RenderNode {
		if (awaitingZoom && frame.width >= 320) {
			var size = nativekit.ffi.NativeKit.nk_window_get_size(cast(desktop, haxeon.ui.host.DesktopUiHostContext).window);
			if (size.status != nativekit.ffi.NativeKitTypes.Result.Ok || size.out_width < 640 || size.out_height < 400)
				throw "Zoom did not enforce the native minimum";
			check(super.submit(frame), frame.width, false);
			passed = true; awaitingZoom = false;
			Sys.println("PASS: narrow titlebar controls, Commands, responsive shortcuts, restore, resize and zoom minimum");
		}
		if (!passed && !awaitingZoom) {
			if (frame.width < 320 || frame.height < 200) throw "Initial minimum size was not enforced";
			if (desktop.windowControls == null) throw "Custom chrome unavailable";
			for (maximized in [false, true, false]) {
				desktop.windowControls.observe(maximized ? nativekit.ffi.NativeKitTypes.WindowStateFlags.Maximized
					: nativekit.ffi.NativeKitTypes.WindowStateFlags.Visible);
				for (width in [1280, 520, 400, 360, 320, 360, 1280])
					check(super.submit(new LayoutFrame(width, 600)), width, maximized);
			}
			desktop.zoom = 2;
			check(super.submit(new LayoutFrame(320, 300)), 320, false);
			awaitingZoom = true;
			requestFrame();
		}
		return super.submit(frame);
	}
}

class NarrowTitlebarMain {
	static function main():Int {
		var options = new DesktopUiHostOptions();
		options.customTitlebar = true;
		options.title = "exosuit narrow titlebar regression";
		options.width = 240; options.height = 160;
		options.minimumWidth = 320; options.minimumHeight = 200;
		options.captureDirectory = Sys.args()[0];
		options.captureSeconds = 2;
		return DesktopUiHost.run(options, function(context) return new NarrowTitlebarApp(context, Sys.args().indexOf("dark") >= 0));
	}
}
