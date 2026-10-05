package testing.model;

import view.View;
import view.LayoutKind;

import config.Settings;
import style.Theme;
import plugin.PluginStatusRegistry;
import feedback.ProblemRegistry;

class ModelStatusView {
	public static inline final HEIGHT = 24;
	final metrics:testing.model.ModelTextMetrics;
	final theme:Theme;
	final pluginItems:PluginStatusRegistry;
	final problems:ProblemRegistry;
	var settings:Settings;

	public function new(metrics:testing.model.ModelTextMetrics, theme:Theme, settings:Settings, pluginItems:PluginStatusRegistry, problems:ProblemRegistry) {
		this.metrics = metrics;
		this.theme = theme;
		this.settings = settings;
		this.pluginItems = pluginItems;
		this.problems = problems;
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
		var problemCount = problems.values().length;
		if (problemCount > 0) result += "  Problems: " + problemCount;
		return result;
	}

}
