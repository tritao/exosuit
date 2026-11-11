package app;

import controller.LiveBuildFeed;
import core.Application;
import sys.FileSystem;
import sys.io.File;
import testing.model.ModelTextMetrics;
import testing.model.ModelWorkbenchHost;

/**
	The live watcher's events file (haxeon `run --watch --live`, HAXEON_WATCH_EVENTS) reaches Build Output's "Live build",
	Problems and notifications. The failing rebuild is the one a user hit on 2026-11-11: a lowering error with no
	`path:line:` prefix, which must still point at the class's source.
**/
class LiveBuildFeedTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function event(kind:String, time:Float, fields:String = ""):String
		return '{"kind":"$kind","time":$time' + (fields.length == 0 ? "" : "," + fields) + "}\n";

	static function line(time:Float, text:String):String
		return event("output-line", time, '"build":2,"line":' + haxe.Json.stringify(text));

	static function main():Int {
		var temporary = Sys.getEnv("TEMP");
		var project = haxe.io.Path.join([temporary != null ? temporary : "/tmp", "exosuit-live-feed-" + Std.random(1000000)]);
		for (directory in [project, project + "/src", project + "/src/ui"]) FileSystem.createDirectory(directory);
		File.saveContent(project + "/haxeon.json", '{"version":1,"package":{"name":"fixture"},"entry":"Main","sourceRoots":["src"]}');
		File.saveContent(project + "/src/ui/EditorPane.hx", "package ui;\n\nclass EditorPane {\n\tpublic function build(context:Int):Int {\n\t\treturn 0;\n\t}\n}\n");
		var events = project + "/live.hl.watch-events.jsonl";

		var metrics = new ModelTextMetrics("ignored-headlessly.ttf", 15),
			application = new Application((theme, focus, workspace, settings) -> new ModelWorkbenchHost(metrics, theme, focus, workspace, 640, 320, settings)),
			root:ModelWorkbenchHost = cast application.root;
		var feed = new LiveBuildFeed(application.root, events, project, 1000);
		application.build.watchLive(feed);
		var notifications = application.root.getNotifications();
		function live():Array<feedback.Notification> return [for (entry in notifications.entries) if (entry.source == "live") entry];
		var before = live().length;

		// An event before the feed started (a reloaded module reads the file again) is shown, not announced.
		File.saveContent(events, event("rebuild-started", 500, '"build":1,"changedFiles":["src/ui/EditorPane.hx"]')
			+ event("build-failed", 600, '"build":1'));
		require(feed.update(1) && feed.state == "failed" && live().length == before,
			"an old failure is replayed quietly");

		var text = event("rebuild-started", 2000, '"build":2,"changedFiles":["src/ui/EditorPane.hx"]')
			+ line(2001, "resuming the published live module AAAAgKEBAAAjYRMOAQAAAA==:1")
			+ line(2002, "compiling entry app.GraphicalMain")
			+ line(2003, 'HashLink lowering failed for $$lambda:ui.EditorPane.build:build#onResolved(0)@2CCE83B3#1: Unknown IR object "$$lambda-env:ui.EditorPane.build:build#onResolved(0)@2CCE83B3#1"')
			+ line(2004, "[compile-project:exosuit-graphical:HashLinkModule:windows-x86_64-msvc:] failed: Action exited with status 1")
			+ line(2005, "C:\\src\\Other.hx:7:3: E1001: Expected ;")
			+ line(2005, "ui/EditorPane.hx:5:3: E1003: Type mismatch for return")
			+ event("build-failed", 2006, '"build":2');
		// Half of the last event: nothing past the last whole line is read.
		File.saveContent(events, File.getContent(events) + text.substr(0, text.length - 10));
		require(feed.update(2) && feed.state == "building", "whole lines are read as they arrive: " + feed.state);
		File.saveContent(events, File.getContent(events) + text.substr(text.length - 10));
		require(!feed.update(2.1), "the file is checked at most every quarter second");
		require(feed.update(3) && feed.state == "failed", "the rebuild failed: " + feed.state);

		var output = [for (entry in feed.output.lines) entry.text].join("\n");
		for (expected in ["resuming the published live module", "compiling entry app.GraphicalMain", "HashLink lowering failed for $lambda:ui.EditorPane.build",
				"[compile-project:exosuit-graphical", "Live build failed"])
			require(output.indexOf(expected) >= 0, 'Build Output lacks "$expected":\n$output');

		var problems = [for (problem in application.root.getProblems().values()) if (problem.owner == "live") problem];
		require(problems.length == 3, "one problem per located error: " + [for (problem in problems) problem.message].join(" | "));
		var lowering = problems[0], location = lowering.location;
		require(location != null && StringTools.replace(location.path, "\\", "/") == project.split("\\").join("/") + "/src/ui/EditorPane.hx"
			&& location.line == 3 && lowering.message.indexOf("HashLink lowering failed") == 0,
			"the lowering error points at EditorPane.build: " + (location == null ? "no location" : location.path + ":" + location.line));
		var other = problems[1].location;
		require(other != null && other.path == "C:\\src\\Other.hx" && other.line == 6 && other.column == 2, "a Windows path diagnostic keeps its drive");
		var relative = problems[2].location;
		require(relative != null && StringTools.replace(relative.path, "\\", "/") == project.split("\\").join("/") + "/src/ui/EditorPane.hx"
			&& relative.line == 4, "a path relative to its source root is found there: " + (relative == null ? "no location" : relative.path));

		require(live().length == before + 1, "one notification for the failure: " + [for (entry in notifications.entries) entry.source + ": " + entry.message].join(" | "));
		var failure = live()[live().length - 1];
		require(failure.kind == feedback.NotificationKind.Error && failure.message.indexOf("Live build failed: HashLink lowering failed") == 0
			&& failure.actions.length == 1 && failure.actions[0].label == "Show output", "the failure notification: " + failure.message);
		failure.actions[0].run();
		require(application.commands.perform(LiveBuildFeed.SHOW_OUTPUT, application.context), "the live output command exists");

		File.saveContent(events, File.getContent(events) + event("rebuild-started", 3000, '"build":3') + event("build-ok", 3001, '"build":3,"revision":5')
			+ event("patch-published", 3002, '"build":3,"revision":5,"reloadReasons":[]') + event("patch-applied", 3003, '"revision":5,"message":"patched the running app to revision 5"'));
		require(feed.update(4) && feed.state == "ok" && feed.revision == 5, "a later build succeeds");
		require([for (problem in application.root.getProblems().values()) if (problem.owner == "live") problem].length == 0, "success clears the live problems");
		var success = live()[live().length - 1];
		require(live().length == before + 2 && success.kind == feedback.NotificationKind.Information
			&& success.message == "Live build succeeded (revision 5)", "a quiet notification after the failure");

		File.saveContent(events, File.getContent(events) + event("patch-rejected", 4000, '"revision":6,"message":"revision 6 refused, still running revision 5: x"'));
		require(feed.update(5) && feed.state == "patch-rejected", "a refused patch");
		require(live()[live().length - 1].message == "Live patch rejected: revision 6 refused, still running revision 5: x",
			"a refused patch is announced");

		// A new watch empties the file: reading starts over.
		File.saveContent(events, event("rebuild-started", 5000, '"build":1'));
		require(feed.update(6) && feed.state == "building", "a restarted watch is followed from its start");

		application.shutdown();
		for (path in [events, project + "/src/ui/EditorPane.hx", project + "/haxeon.json"]) FileSystem.deleteFile(path);
		for (path in [project + "/src/ui", project + "/src", project]) FileSystem.deleteDirectory(path);
		Sys.println("PASS: live watch events reach Build Output, Problems and notifications");
		return 0;
	}
}
