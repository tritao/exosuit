package ui;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.CommandContext;
import haxeon.ui.core.View;
import haxeon.ui.properties.PropertyDescriptor;
import haxeon.ui.properties.PropertyValue;
import haxeon.ui.properties.StructuredPropertyEditor;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.text.TextField;
import platform.HostFileDialogs;

/** Font chooser uses the same validation and mutation callback as typed paths. */
class SettingsPathEditor extends StructuredPropertyEditor {
	public static inline var TYPE = "exosuit.font-path";
	public var previewPath:Null<String>;
	var previewBase:Null<String>;
	final dialogs:Null<HostFileDialogs>;
	public function new(dialogs:Null<HostFileDialogs>) { super(TYPE); this.dialogs = dialogs; }
	override public function display(value:Dynamic):String return Std.string(value);
	override public function editableText(value:Dynamic):String return Std.string(value);
	override public function parse(text:String):Null<Dynamic> return text;
	override public function validate(context:CommandContext, descriptor:PropertyDescriptor, value:Dynamic):Null<String>
		return Std.isOfType(value, String) ? null : "A font path is required";
	override public function build(key:String, descriptor:PropertyDescriptor, value:PropertyValue,
		context:BuildContext, enabled:Bool, apply:PropertyValue->Void):View {
		var path = switch value { case Custom(_, data): Std.string(data); default: ""; };
		if (previewBase != path) { previewBase = path; previewPath = null; }
		var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.childGap = 4;
		var field = new TextField(key + ":path", path, function(text) { previewPath = text; context.commands.refresh(); }, style, descriptor.label);
		field.enabled = enabled;
		field.onSubmit = text -> apply(Custom(TYPE, text));
		var children = [new KeyedView("path", field)];
		var chooser = dialogs;
		if (chooser != null) {
			var browse = new Button("Choose font…", null, function() {
				chooser.openFile(function(accepted, paths) {
					if (accepted && paths.length > 0) apply(Custom(TYPE, paths[0]));
				}, "Choose font", path);
			}, key + ":browse");
			browse.enabled = enabled;
			children.push(new KeyedView("browse", browse));
		}
		return new Column(key, children, style);
	}
}
