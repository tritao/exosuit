import config.PreferencesRegistry;
import haxeon.ui.properties.PropertyValue;
import haxeon.ui.settings.SettingsStore;
import ui.ExosuitSettingsPanel;

class SettingsUiTests {
 static function check(value:Bool, message:String):Void { if (!value) throw message; }
 static function modelControls():Void {
  var refreshes = 0, retries = 0, pages = 0;
  var state = new ui.SettingsModelPickerState(false, null, true, function() { refreshes++; },
   function() { pages++; }, function() { retries++; });
  var store = new SettingsStore(PreferencesRegistry.create());
  var panel = new ExosuitSettingsPanel(store, function() return [], function() {}, null, function() return state);
  panel.setFilter("default model");
  function root():haxeon.ui.core.RenderNode {
   var inspector:haxeon.ui.widgets.properties.PropertyInspector = cast panel.currentInspector();
   var descriptor = inspector.descriptors[0];
   var extension = panel.editorRegistry.get(ui.SettingsModelEditor.TYPE);
   var context = new haxeon.ui.core.BuildContext(new haxeon.ui.core.StateStore());
   return extension.build("model", descriptor, descriptor.readValue(null), context, true, function(_) {}).build(context);
  }
  function control(tree:haxeon.ui.core.RenderNode, label:String):haxeon.ui.core.RenderNode {
   var found:Null<haxeon.ui.core.RenderNode> = null;
   tree.walk(function(node) { if (node.semantics != null && node.semantics.label == label) found = node; });
   if (found == null) throw "Missing inline model control: " + label;
   return found;
  }
  function activate(tree:haxeon.ui.core.RenderNode, label:String):Void {
   var dispatcher = new haxeon.ui.core.EventDispatcher(new haxeon.ui.core.FocusManager());
   dispatcher.setRoot(tree);
   dispatcher.targetEvent(haxeon.ui.core.UiEventKind.Activate, control(tree, label).id);
  }
  var tree = root();
  activate(tree, "Refresh models"); activate(tree, "More models");
  check(refreshes == 1 && pages == 1, "inline model buttons invoke their paging actions");
  state = new ui.SettingsModelPickerState(true, null, true, state.refresh, state.more, state.retry);
  tree = root();
  check(!control(tree, "Refresh models").enabled && !control(tree, "More models").enabled,
   "loading disables duplicate model requests");
  state = new ui.SettingsModelPickerState(false, "Could not load models", true, state.refresh, state.more, state.retry);
  tree = root(); activate(tree, "Retry");
  check(retries == 1, "failed model requests can be retried beside the picker");
  check(control(tree, "Could not load models") != null, "model errors appear inline");
  store.set("workbench/codex/default_model", PropertyValue.Text("saved-model"));
  var inspector:haxeon.ui.widgets.properties.PropertyInspector = cast panel.currentInspector();
  var model = inspector.descriptors[0];
  check(model.option("model:saved-model") != null, "saved model remains selectable before discovery");
  var binding = new haxeon.ui.properties.PropertyBinding(model, new haxeon.ui.core.CommandContext(), panel.editorRegistry);
  binding.apply(PropertyValue.Custom(ui.SettingsModelEditor.TYPE, "model-default"));
  check(store.getString("workbench/codex/default_model") == "", "model picker preserves default storage semantics");
 }

 public static function main():Int {
  var store = new SettingsStore(PreferencesRegistry.create());
  var panel = new ExosuitSettingsPanel(store, function() return [], function() {});
  var definition:haxeon.ui.settings.SettingDefinition = cast store.registry.get("files/explorer/excluded_names");
  var list = panel.catalog.descriptor(definition);
  check(list.structure != null, "excluded names use a structured list");
  var data = PropertyValue.Custom("ui.list", ["build", "vendor"]);
  check(list.validateValue(null, data) == null, "string lists validate");
  list.write(null, data);
  check(store.getString(definition.path) == '["build","vendor"]', "list edits retain JSON storage compatibility");
  check(list.validateValue(null, PropertyValue.Custom("ui.list", [1])) != null, "non-string entries are rejected");
  var fonts = panel.catalog.descriptor(store.registry.get("editor/fonts/font_fallback_paths"));
  check(fonts.structure != null && fonts.restartRequired, "fallback font list keeps restart metadata");
  var font = panel.catalog.descriptor(store.registry.get("editor/fonts/font_path"));
  font.write(null, PropertyValue.Custom("exosuit.font-path", "/tmp/font.ttf"));
  check(store.getString("editor/fonts/font_path") == "/tmp/font.ttf", "chosen font saves as a normal path");
  panel.setFilter("default model");
  var inspector = panel.currentInspector();
  check(inspector != null && inspector.descriptors.length == 1, "model picker remains searchable");
  for (entry in [["editor/fonts/font_size", "px"], ["appearance/workbench/zoom_percent", "%"], ["editor/display/tab_tooltip_delay", "seconds"]]) {
   var setting:haxeon.ui.settings.SettingDefinition = cast store.registry.get(entry[0]);
   check(setting.unit == entry[1], "numeric setting exposes readable units: " + entry[0]);
  }
  modelControls();
  Sys.println("Settings UI adapter tests passed");
  return 0;
 }
}
