package app;

import config.EditorConfig;
import config.Preferences;
import editor.Document;
import sys.io.File;
import sys.FileSystem;
import haxeon.ui.properties.PropertyValue;

class IndentationConfigurationTests {
	static function require(ok:Bool, message:String):Void { if (!ok) throw message; }
	public static function run(root:String):Void {
		FileSystem.createDirectory(root); FileSystem.createDirectory(root + "/nested");
		for (name in ["settings.json", "project-settings.json", ".editorconfig", "nested/.editorconfig"])
			if (FileSystem.exists(root + "/" + name)) FileSystem.deleteFile(root + "/" + name);
		var preferences = new Preferences(root + "/settings.json");
		var metrics = new testing.model.ModelTextMetrics("ignored.ttf", 15);
		var app = new core.Application((theme, focus, workspace, settings) -> new testing.model.ModelWorkbenchHost(metrics, theme, focus, workspace, 640, 320, settings), preferences, new session.RecentProjects(root + "/recent.conf"));
		var document = new Document(root + "/nested/Main.hx", "class A {\n  var a;\n  var b;\n  var c;\n}", app.documents.syntaxes);
		var resolver = app.configuration;
		require(resolver.settingsFor(document).tabWidth == 2 && document.indentation.source == "Detected from document", "detection not resolved");
		var stable = resolver.settingsFor(document);
		document.buffer.replaceAllText("\tfoo();\n\tbar();\n\tbaz();");
		require(resolver.settingsFor(document) == stable, "typing changed settings identity or detection");
		File.saveContent(root + "/.editorconfig", "root = true\n[*.{hx,hxml}]\nindent_style = tab\nindent_size = 4\ntab_width = 3\n");
		app.commands.perform("settings:reload", app.context);
		var ec = resolver.settingsFor(document);
		require(ec.tabWidth == 3 && ec.indentSize == 4 && !ec.insertSpaces, "EditorConfig did not override detection or split step from tab width");
		File.saveContent(root + "/nested/.editorconfig", "[Main.hx]\nindent_style = space\nindent_size = unset\ntab_width = 8\n");
		app.commands.perform("settings:reload", app.context);
		require(resolver.settingsFor(document).tabWidth == 8 && resolver.settingsFor(document).indentSize == 8 && resolver.settingsFor(document).insertSpaces, "nearest EditorConfig or unset precedence failed");
		preferences.store.set("editor/indentation/tab_width", Int(4));
		preferences.store.set("editor/indentation/insert_spaces", Bool(true));
		require(!preferences.store.isDefault("editor/indentation/tab_width") && resolver.settingsFor(document).tabWidth == 4 && resolver.settingsFor(document).insertSpaces, "explicit defaults lost to detection/EditorConfig");
		var reloaded = new Preferences(root + "/settings.json");
		require(reloaded.explicitlySets("editor/indentation/tab_width") && reloaded.explicitlySets("editor/indentation/insert_spaces"), "explicit defaults did not survive restart");
		var project = app.workspace.addProject(root), projectSettings = preferences.forProject(root + "/project-settings.json");
		project.setSettings(projectSettings);
		projectSettings.store.set("editor/indentation/tab_width", Int(2));
		projectSettings.store.set("editor/indentation/insert_spaces", Bool(false));
		require(resolver.settingsFor(document).tabWidth == 2 && !resolver.settingsFor(document).insertSpaces, "project indentation did not override user preferences");
		document.indentation.overrideWidth = 8; document.indentation.overrideSpaces = true;
		require(resolver.settingsFor(document).tabWidth == 8 && resolver.settingsFor(document).insertSpaces, "document override not highest priority");
		document.indentation.overrideWidth = null; document.indentation.overrideSpaces = null;
		projectSettings.store.resetUnder("editor/indentation"); preferences.store.resetUnder("editor/indentation");
		require(resolver.settingsFor(document).tabWidth == 8, "reset did not restore automatic policy");
		for (test in [
			{pattern: "*.hx", path: "a/b/Main.hx", matches: true},
			{pattern: "/src/*.hx", path: "src/Main.hx", matches: true},
			{pattern: "src/*.hx", path: "src/nested/Main.hx", matches: false},
			{pattern: "**/*.hx", path: "Main.hx", matches: true},
			{pattern: "**/*.{hx,{h,hpp}}", path: "a/b/main.hpp", matches: true},
			{pattern: "file{-2..3}.hx", path: "file-1.hx", matches: true},
			{pattern: "file{1..3}.hx", path: "file4.hx", matches: false},
			{pattern: "[!AB]?.hx", path: "Cx.hx", matches: true},
			{pattern: "file\\*.hx", path: "file*.hx", matches: true}
		]) require(EditorConfig.matches(test.pattern, test.path) == test.matches, "EditorConfig glob failed: " + test.pattern);
		var values:Map<String, String> = [];
		EditorConfig.apply("[*.hx]\nINDENT_STYLE = SPACE\nindent_size = 2 # not a comment\n", "Main.hx", values);
		require(values.get("indent_style") == "space" && EditorConfig.positive(values.get("indent_size")) == null, "EditorConfig case or inline-comment handling failed");
		app.shutdown();
		trace("PASS: indentation precedence, explicit defaults, project/document overrides and EditorConfig globs");
	}
}
