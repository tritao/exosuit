package view;

import config.Settings;
import renderer.Renderer;
import style.Theme;
import plugin.PluginStatusRegistry;

class StatusView {
	public static inline final HEIGHT = 24;
	final renderer:Renderer;
	final theme:Theme;
	final pluginItems:PluginStatusRegistry;
	var settings:Settings;

	public function new(renderer:Renderer, theme:Theme, settings:Settings, pluginItems:PluginStatusRegistry) {
		this.renderer = renderer;
		this.theme = theme;
		this.settings = settings;
		this.pluginItems = pluginItems;
	}

	public function applySettings(settings:Settings):Void
		this.settings = settings;

	public function text(view:Null<View>):String {
		var result:String;
		if (view == null) {
			result = "No editor";
		} else {
			var document = view.getDocument();
			if (document == null) {
				result = view.title;
			} else {
				var path = document.path == null ? document.title : document.requirePath(), selection = view.getSelection(), selectionText = "";
				if (selection != null) {
					var count = selection.rangeCount();
					if (count > 1)
						selectionText = '  $count selections';
					else if (selection.hasSelection()) {
						var length = document.buffer.offsetOf(selection.end()) - document.buffer.offsetOf(selection.start());
						selectionText = '  Selected $length';
					}
				}
				var indentation = settings.insertSpaces ? 'Spaces: ${settings.tabWidth}' : 'Tab Size: ${settings.tabWidth}';
				result = (document.dirty ? "* " : "") + path + '  Ln ${view.cursorLine() + 1}, Col ${view.cursorColumn() + 1}'
					+ selectionText + '  $indentation  ${document.encodingLabel()}  ${document.newlineLabel()}';
			}
		}
		for (item in pluginItems.items()) if (item.text.length > 0) result += "  " + item.text;
		return result;
	}

	public function draw(view:Null<View>, width:Int, height:Int):Void {
		var y = height - HEIGHT;
		renderer.clip(0, y, width, HEIGHT);
		renderer.rect(0, y, width, HEIGHT, theme.accent);
		renderer.text(8, y + 4, text(view), theme.editorBackground);
	}
}
