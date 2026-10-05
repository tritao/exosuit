package app;

import core.Application;
import platform.Platform;
import testing.model.ModelTextMetrics;
import testing.model.ModelWorkbenchHost;

class BuildTaskSmokeMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function main():Int {
		var arguments = Sys.args();
		require(arguments.length == 1, "build task smoke requires repository root");

		var metrics = new ModelTextMetrics("ignored-headlessly.ttf", 15),
			application = new Application((theme, focus, workspace, settings) -> new ModelWorkbenchHost(metrics, theme, focus, workspace, 640, 320, settings)),
			root:ModelWorkbenchHost = cast application.root;
		application.workspace.addProject(arguments[0]);
		require(application.commands.perform("build:run-task", application.context) && root.commandView.results.length >= 2
			&& root.commandView.results[0].label == "build-headless", "repository build task was not offered deliberately");
		application.keyPressed(Platform.KEY_ENTER, 0);
		var deadline = Sys.time() + 60.0;
		while (application.build.active != null && Sys.time() < deadline) application.update();
		var transcript = [for (line in application.build.output.lines) line.text].join("\n");
		require(application.build.active == null && StringTools.endsWith(transcript, "Process exited with status 0")
			&& transcript.indexOf("compiled") >= 0, "repository headless build did not complete successfully through the task controller");
		application.shutdown();

		Sys.println("PASS: repository headless build ran through deliberate project task UI");
		return 0;
	}
}
