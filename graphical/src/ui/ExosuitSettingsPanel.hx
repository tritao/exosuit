package ui;

import haxeon.ui.properties.PropertyDescriptor;
import haxeon.ui.properties.PropertyDescriptorOptions;
import haxeon.ui.properties.PropertyOption;
import haxeon.ui.properties.PropertyType;
import haxeon.ui.properties.PropertyValue;
import haxeon.ui.settings.SettingsStore;
import haxeon.ui.widgets.properties.PropertyInspector;
import haxeon.ui.widgets.settings.SettingsPanel;
import workspace.service.WorkspaceAgentProtocol.AgentModel;

/** Adds the live Codex model picker to the normal Workbench settings section. */
class ExosuitSettingsPanel extends SettingsPanel {
	final models:Void->Array<AgentModel>;
	var modelOptionsKey:String = "";
	final pathEditor:SettingsPathEditor;
	final listEditors:Array<haxeon.ui.properties.StructuredPropertyEditor> = [];

	public function new(store:SettingsStore, models:Void->Array<AgentModel>, onChanged:Void->Void, ?dialogs:platform.HostFileDialogs) {
		super("exosuit-settings", store, onChanged);
		this.models = models;
		var lists = new haxeon.ui.properties.ListPropertyEditor();
		trackDrafts(lists);
		editorRegistry.register(lists);
		pathEditor = new SettingsPathEditor(dialogs);
		editorRegistry.register(pathEditor);
		var fonts = new haxeon.ui.properties.ListPropertyEditor("exosuit.font-list");
		var chooser = dialogs;
		if (chooser != null) fonts.chooseItems = function(handler) {
			chooser.openFile(function(accepted, paths) { if (accepted) handler(paths); }, "Choose fallback fonts", null, true);
		};
		trackDrafts(fonts);
		editorRegistry.register(fonts);
		for (path in ["editor/fonts/font_fallback_paths", "files/explorer/excluded_names", "languages/haxeon/command"])
			installEditor(path, path == "editor/fonts/font_fallback_paths" ? "exosuit.font-list" : haxeon.ui.properties.ListPropertyEditor.TYPE);
		installEditor("editor/fonts/font_path", SettingsPathEditor.TYPE);
	}

	override public function build(context:haxeon.ui.core.BuildContext):haxeon.ui.core.RenderNode {
		var node = super.build(context);
		if (selectedCategory == "editor/fonts") {
			var style = new haxeon.ui.LayoutStyle();
			style.width = haxeon.ui.LayoutAxis.grow(); style.height = haxeon.ui.LayoutAxis.fit();
			var path = pathEditor.previewPath;
			node.add(new haxeon.ui.widgets.layout.Column("settings-preview", [
				new haxeon.ui.widgets.KeyedView("label", new haxeon.ui.widgets.text.Text("Font preview · " + catalog.store.getInt("editor/fonts/font_size") + " px")),
				new haxeon.ui.widgets.KeyedView("sample", new SettingsFontPreview(path == null ? catalog.store.getString("editor/fonts/font_path") : path,
					catalog.store.getInt("editor/fonts/font_size")))
			], style).build(context));
		}
		return node;
	}

	function trackDrafts(editor:haxeon.ui.properties.StructuredPropertyEditor):Void {
		editor.retainDrafts = true;
		editor.onDraftChanged = function() { if (onChanged != null) onChanged(); };
		listEditors.push(editor);
	}

	override public function hasUnsavedChanges():Bool {
		for (editor in listEditors) if (editor.hasDrafts()) return true;
		return false;
	}

	override public function discardUnsavedChanges():Void {
		for (editor in listEditors) editor.discardDrafts();
	}

	function installEditor(path:String, typeId:String):Void {
		var store = catalog.store;
		var definition = store.registry.get(path);
		if (definition == null) return;
		var options = new PropertyDescriptorOptions();
		options.recordHistory = false;
		options.category = haxeon.ui.settings.SettingsCatalog.categoryOf(definition);
		options.description = typeId == SettingsPathEditor.TYPE ? "Font file used by the editor. Enter a path and press Enter, or choose a file." :
			path == "languages/haxeon/command" ? "Executable followed by its arguments. Apply to save the list." :
			path == "files/explorer/excluded_names" ? "Names hidden from the file explorer. Apply to save the list." :
			"Fallback font files, tried in order. Apply to save the list.";
		options.restartRequired = definition.restartRequired;
		options.modified = function() return !store.isDefault(path);
		options.reset = function() store.reset(path);
		function decode(value:PropertyValue):PropertyValue {
			var text = switch value { case Text(data): data; default: ""; };
			return PropertyValue.Custom(typeId, typeId == SettingsPathEditor.TYPE ? text : haxe.Json.parse(text));
		}
		options.defaultValue = decode(definition.defaultValue);
		if (typeId != SettingsPathEditor.TYPE)
			options.structure = haxeon.ui.properties.PropertyStructure.List(
				haxeon.ui.properties.PropertyStructure.Value(PropertyType.Text), null, null, "Item");
		options.validator = function(_, value) return switch value {
			case Custom(_, data): definition.validate(PropertyValue.Text(typeId == SettingsPathEditor.TYPE ? cast data : haxe.Json.stringify(data)));
			default: "Invalid setting value";
		};
		catalog.setDescriptor(path, new PropertyDescriptor(path, definition.label, PropertyType.Custom(typeId),
			function(_) return decode(store.get(path)), function(_, value) switch value {
				case Custom(_, data):
					var error = store.set(path, PropertyValue.Text(typeId == SettingsPathEditor.TYPE ? cast data : haxe.Json.stringify(data)));
					if (error != null) throw error;
				default:
			}, options));
	}

	override public function currentInspector():Null<PropertyInspector> {
		var store = catalog.store;
		var selected = store.getString("workbench/codex/default_model");
		var options = [new PropertyOption("model-default", "Codex default")];
		var known = selected == "";
		for (model in models()) {
			options.push(new PropertyOption("model:" + model.model, model.name));
			if (model.model == selected) known = true;
		}
		if (!known) options.push(new PropertyOption("model:" + selected, selected + " (saved)"));
		var nextKey = haxe.Json.stringify([for (option in options) [option.key, option.label]]);
		if (nextKey == modelOptionsKey) return super.currentInspector();
		modelOptionsKey = nextKey;
		var config = new PropertyDescriptorOptions();
		config.category = "workbench/codex";
		config.recordHistory = false;
		config.description = "Model for new Workbench Codex sessions. Existing sessions keep their selected model.";
		config.modified = function() return !store.isDefault("workbench/codex/default_model");
		config.reset = function() store.reset("workbench/codex/default_model");
		config.defaultValue = PropertyValue.Enum("model-default");
		config.options = options;
		var modelSetting = new PropertyDescriptor("workbench/codex/default_model", "Default Model", PropertyType.Enum,
			function(_) {
				var id = store.getString("workbench/codex/default_model");
				return PropertyValue.Enum(id == "" ? "model-default" : "model:" + id);
			},
			function(_, value) switch (value) {
				case Enum(choice):
					var id = choice == "model-default" ? "" : choice.substr("model:".length);
					var error = store.set("workbench/codex/default_model", PropertyValue.Text(id));
					if (error != null) throw error;
				default:
				}, config);
		catalog.setDescriptor("workbench/codex/default_model", modelSetting);
		invalidateInspector();
		return super.currentInspector();
	}
}
