package app;

import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostOptions;
import ui.ExosuitApp;

@:access(ui.ExosuitApp)
class ManageMenuSmokeApp extends ExosuitApp {
	var stage = 0;
	var passed = false;
	public function new(context:haxeon.ui.host.UiHostContext) {
		super(context.fonts, ui.ExosuitPalette.theme(false), context, null, null, null, false);
	}
	function find(root:RenderNode, key:String):Null<RenderNode> {
		if (root.styleKey == key) return root;
		for (child in root.children) { var found = find(child, key); if (found != null) return found; }
		return null;
	}
	function click(root:RenderNode, key:String):Void {
		var node = find(root, key);
		if (node == null) throw 'Missing control: $key';
		var bounds = node.globalBounds();
		ui.pointerDown(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
		ui.pointerUp(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
	}
	override public function submit(frame:LayoutFrame):RenderNode {
		var root = super.submit(frame);
		switch stage {
			case 0:
				var gear = find(root, 'activity-manage');
				if (gear == null || gear.globalBounds().y < frame.height - 100) throw 'Manage gear is not pinned to bottom';
				click(root, 'activity-manage'); stage++;
			case 1:
				for (key in ['manage-palette', 'manage-settings', 'manage-keyboard', 'manage-themes'])
					if (find(root, key) == null) throw 'Missing menu item: $key';
				var first = find(root, 'manage-palette').globalBounds();
				var last = find(root, 'manage-themes').globalBounds();
				var gear = find(root, 'activity-manage').globalBounds();
				if (first.x < gear.x + gear.width || last.y + last.height > gear.y + gear.height + 1) {
					requestFrame(); return root;
				}
				var paletteItem:RenderNode = cast find(root, 'manage-palette');
				var settingsItem:RenderNode = cast find(root, 'manage-settings');
				ui.focusWidget(paletteItem.id);
				ui.key(UiEventKind.KeyDown, UiKey.Down);
				if (!settingsItem.id.equals(ui.focus.focusedId)) throw 'Down did not move menu focus';
				ui.key(UiEventKind.KeyDown, UiKey.Up);
				if (!paletteItem.id.equals(ui.focus.focusedId)) throw 'Up did not move menu focus';
				ui.key(UiEventKind.KeyDown, UiKey.Escape); stage++;
			case 2:
				if (find(root, 'manage-settings') != null) throw 'Escape did not dismiss menu';
				click(root, 'activity-manage'); stage = 20;
			case 20:
				ui.pointerDown(frame.width - 20, 100, 0);
				ui.pointerUp(frame.width - 20, 100, 0);
				stage++;
			case 21:
				if (find(root, 'manage-settings') != null) throw 'Outside click did not dismiss menu';
				click(root, 'activity-manage'); stage = 3;
			case 3: click(root, 'manage-settings'); stage++;
			case 4:
				if (settingsPanel == null) throw 'Settings action failed';
				click(root, 'settings-close'); stage++;
			case 5: click(root, 'activity-manage'); stage++;
			case 6: click(root, 'manage-keyboard'); stage++;
			case 7:
				if (settingsPanel == null || settingsPanel.selectedCategory != 'editor/keyboard' || !settingsPanel.showAdvanced)
					throw 'Keyboard shortcut action selected wrong preferences';
				click(root, 'settings-close'); stage++;
			case 8: click(root, 'activity-manage'); stage++;
			case 9: click(root, 'manage-themes'); stage++;
			case 10:
				if (settingsPanel == null || settingsPanel.selectedCategory != 'appearance/colors' || !settingsPanel.showAdvanced)
					throw 'Themes action selected wrong preferences';
				click(root, 'settings-close'); stage++;
			case 11: click(root, 'activity-manage'); stage++;
			case 12: click(root, 'manage-palette'); stage++;
			case 13:
				if (!paletteVisible || contextMenu != null) throw 'Command palette action failed';
				passed = true; stage++;
				Sys.println('PASS: bottom Manage gear, anchored menu, Escape, settings, shortcuts, colors and command palette');
			default:
		}
		if (!passed) requestFrame();
		return root;
	}
	override public function dispose():Void {
		super.dispose();
		if (!passed) throw 'Manage menu test stalled at stage $stage';
	}
}

class ManageMenuSmokeMain {
	static function main():Int {
		var options = new DesktopUiHostOptions();
		options.title = 'Manage menu smoke'; options.width = 1100; options.height = 760;
		options.captureDirectory = Sys.args()[0]; options.captureSeconds = 5;
		return DesktopUiHost.run(options, function(context) return new ManageMenuSmokeApp(context));
	}
}
