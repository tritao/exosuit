package ui;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.*;
import haxeon.ui.properties.*;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.*;
import haxeon.ui.widgets.layout.*;
import haxeon.ui.widgets.text.Text;

/** Model selection and live loading controls share one inspector row. */
class SettingsModelEditor extends StructuredPropertyEditor {
	public static inline var TYPE = "exosuit.codex-model";
	final status:Void->SettingsModelPickerState;
	public function new(status:Void->SettingsModelPickerState) { super(TYPE); this.status = status; }
	override public function display(value:Dynamic):String return Std.string(value);
	override public function editableText(value:Dynamic):String return Std.string(value);
	override public function parse(text:String):Null<Dynamic> return text;
	override public function validate(context:CommandContext, descriptor:PropertyDescriptor, value:Dynamic):Null<String>
		return Std.isOfType(value, String) && descriptor.option(cast value) != null ? null : "Choose an available model";
	override public function build(key:String, descriptor:PropertyDescriptor, value:PropertyValue,
		context:BuildContext, enabled:Bool, apply:PropertyValue->Void):View {
		var selected = switch value { case Custom(_, data): Std.string(data); default: "model-default"; };
		var state = status();
		var options = [for (option in descriptor.options) new SelectOption(option.key, option.label, option.key)];
		var pickerStyle = new LayoutStyle(); pickerStyle.width = LayoutAxis.grow();
		var picker = new Select(key + ":picker", options, selected, choice -> apply(Custom(TYPE, choice)), pickerStyle);
		picker.accessibilityLabel = descriptor.label;
		picker.enabled = enabled;
		var children:Array<KeyedView> = [new KeyedView("picker", picker)];
		var actions:Array<KeyedView> = [];
		function action(id:String, label:String, callback:Void->Void):Void {
			var button = new Button(label, null, callback, key + ":" + id);
			button.enabled = enabled && !state.loading;
			actions.push(new KeyedView(id, button));
		}
		action("refresh", "Refresh models", state.refresh);
		if (state.hasMore && state.error == null) action("more", "More models", state.more);
		if (state.error != null) action("retry", "Retry", state.retry);
		var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.childGap = 4;
		children.push(new KeyedView("actions", new Row(key + ":actions", actions, style)));
		if (state.loading || state.error != null) children.push(new KeyedView("status", new Text(
			state.loading ? "Loading Codex models…" : state.error, style, null,
			TextStyleOverride.paragraph(haxeon.ui.TextWrap.WordCharacter))));
		return new Column(key, children, style);
	}
}
