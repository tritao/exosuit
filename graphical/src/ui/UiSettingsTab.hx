package ui;

import haxeon.ui.core.View;
import haxeon.ui.widgets.settings.SettingsPanel;

/** Settings shares normal tab movement and closing, with its own draft guard. */
class UiSettingsTab {
	public static inline var KEY = "settings";
	public var panel:SettingsPanel;
	public var content:String->View;
	public var requestClose:Void->Bool;
	public var onClosed:Void->Void;
	public var allowClose:Bool = false;
	public function new(panel:SettingsPanel) {
		this.panel = panel;
		content = function(_) return panel;
		requestClose = function() return true;
		onClosed = function() {};
	}
}
