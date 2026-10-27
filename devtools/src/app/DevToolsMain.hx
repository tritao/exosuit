package app;

import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostOptions;

class DevToolsMain {
	static function main():Int {
		var endpoint = "";
		var profilerPort = 0;
		var inspectionCapture = "";
		var profileCapture = "";
		var saveInspection = "";
		var capturePath = "devtools-" + Std.int(Sys.time()) + ".hlpc";
		var options = new DesktopUiHostOptions();
		options.title = "Haxeon DevTools";
		options.applicationId = "Haxeon.DevTools";
		options.width = 1200; options.height = 850;
		for (arg in Sys.args()) {
			if (StringTools.startsWith(arg, "--endpoint=")) endpoint = arg.substr(11);
			if (StringTools.startsWith(arg, "--profiler-port=")) profilerPort = Std.parseInt(arg.substr(16));
			if (StringTools.startsWith(arg, "--capture-path=")) capturePath = arg.substr(15);
			if (StringTools.startsWith(arg, "--inspection-capture=")) inspectionCapture = arg.substr(21);
			if (StringTools.startsWith(arg, "--profile-capture=")) profileCapture = arg.substr(18);
			if (StringTools.startsWith(arg, "--save-inspection=")) saveInspection = arg.substr(18);
			if (StringTools.startsWith(arg, "--capture-seconds=")) options.captureSeconds = Std.parseFloat(arg.substr(18));
			if (StringTools.startsWith(arg, "--capture-dir=")) options.captureDirectory = arg.substr(14);
			if (StringTools.startsWith(arg, "--smoke-frames=")) options.frameLimit = Std.parseInt(arg.substr(15));
		}
		if (endpoint.length == 0 && inspectionCapture.length == 0 && profileCapture.length == 0 && profilerPort == 0)
			throw "DevTools requires an endpoint, profiler port, or capture file";
		var app:Null<DevToolsApp> = null;
		options.captureReady = function() {
			if (app != null && saveInspection.length > 0 && app.hasInspection()) { app.saveInspection(saveInspection); saveInspection = ""; }
			return true;
		};
		return DesktopUiHost.run(options, function(host) {
			app = new DevToolsApp(host, endpoint, profilerPort, capturePath, inspectionCapture, profileCapture);
			if (Sys.args().indexOf("--start-sampling") >= 0) app.startSampling();
			return app;
		});
	}
}
