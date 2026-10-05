package app;

import config.Preferences;
import core.Application;
import editor.BufferPosition;
import platform.Platform;
import testing.model.ModelTextMetrics;
import plugin.DynamicPlugin;
import plugin.PluginManifest;
import sys.io.File;
import testing.model.ModelWorkbenchHost;

class ReleaseBenchmarkMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function main():Int {
		var arguments = Sys.args();
		require(arguments.length == 3, "expected fixture root, plugin manifest and plugin source");
		var rootPath = arguments[0], smallPath = rootPath + "/small.hx", largePath = rootPath + "/large.txt",
			longPath = rootPath + "/long.txt";
		File.saveContent(smallPath, "function main():Int return 42;\n");
		File.saveContent(largePath, repeated("0123456789abcdef\n", 10 * 1024 * 1024));
		File.saveContent(longPath, repeated("x", 1024 * 1024) + "\n");

		var started = Sys.time();

		var metrics = new ModelTextMetrics("ignored-headlessly.ttf", 15),
			application = new Application((theme, focus, workspace, settings) -> new ModelWorkbenchHost(metrics, theme, focus, workspace, 1280, 720, settings),
				new Preferences()),
			root:ModelWorkbenchHost = cast application.root, startupMs = elapsed(started);
		var firstStarted = Sys.time(), view = application.open(smallPath);
		advanceModel(application);
		var firstDocumentMs = elapsed(firstStarted);

		var typing:Array<Float> = [];
		for (_ in 0...200) {
			var before = Sys.time();
			view.textInput("x");
			application.update();
			advanceModel(application);
			typing.push(elapsed(before));
		}
		var idle:Array<Float> = [];
		for (_ in 0...500) {
			var before = Sys.time();
			application.update();
			idle.push(elapsed(before));
		}
		var idleWallStarted = Sys.time(), idleCpuStarted = Sys.cpuTime();
		while (Sys.time() - idleWallStarted < 1.0) {
			application.update();
			Sys.sleep(0.001);
		}
		var idleWall = Sys.time() - idleWallStarted, idleCpuPercent = (Sys.cpuTime() - idleCpuStarted) * 100.0 / idleWall;

		var largeStarted = Sys.time(), largeView = application.open(largePath), largeOpenMs = elapsed(largeStarted);
		var largeDocument = largeView.getDocument();
		if (largeDocument == null) throw "large document view lost its document";
		largeView.restoreCursor(largeDocument.buffer.lineCount() - 1, 0);
		var scroll:Array<Float> = [];
		for (_ in 0...200) {
			var before = Sys.time();
			largeView.wheel(-100, 0);
			advanceModel(application);
			scroll.push(elapsed(before));
		}
		var longStarted = Sys.time(), longView = application.open(longPath), longOpenMs = elapsed(longStarted);
		longView.restoreCursor(0, 1024 * 1024);
		advanceModel(application);

		var soakStarted = Sys.time(), soak:Array<Float> = [];
		for (index in 0...50) {
			var before = Sys.time();
			var document = application.documents.createUntitled(), temporaryView = application.add(document);
			temporaryView.textInput("iteration " + index);
			document.saveAs(rootPath + "/soak-" + index + ".txt");
			root.closeActiveTab(true);
			soak.push(elapsed(before));
		}
		var soakMs = elapsed(soakStarted);
		var plugin = new DynamicPlugin(new PluginManifest(arguments[1])), pluginSource = File.getContent(arguments[2]), reload:Array<Float> = [];
		require(application.plugins.load(plugin), "benchmark plugin did not load");
		for (index in 0...20) {
			File.saveContent(arguments[2], pluginSource + '\n// benchmark reload $index\n');
			var before = Sys.time();
			require(plugin.refresh(), 'benchmark plugin reload $index failed: ${plugin.lastError}');
			reload.push(elapsed(before));
		}
		require(application.plugins.unload(plugin.id()), "benchmark plugin did not unload");

		Sys.println('BENCH startup_ms=$startupMs first_document_ms=$firstDocumentMs typing_p95_ms=${percentile(typing, 95)} idle_p95_ms=${percentile(idle, 95)} idle_cpu_percent=$idleCpuPercent');
		Sys.println('BENCH large_open_ms=$largeOpenMs long_line_open_ms=$longOpenMs scroll_p95_ms=${percentile(scroll, 95)}');
		Sys.println('BENCH soak_50_ms=$soakMs soak_first10_p95_ms=${percentile(soak.slice(0, 10), 95)} soak_last10_p95_ms=${percentile(soak.slice(40, 50), 95)}');
		Sys.println('BENCH plugin_reload_20_p95_ms=${percentile(reload, 95)} plugin_first5_median_ms=${percentile(reload.slice(0, 5), 50)} plugin_last5_median_ms=${percentile(reload.slice(15, 20), 50)} typing_target_ms=50 idle_target_ms=8');
		require(percentile(typing, 95) < 50.0, "typing-to-frame p95 exceeded 50 ms");
		require(percentile(idle, 95) < 8.0, "idle update p95 exceeded 8 ms");
		require(percentile(scroll, 95) < 50.0, "large-document scroll p95 exceeded 50 ms");
		require(idleCpuPercent < 5.0, "headless idle service CPU exceeded 5 percent");
		require(percentile(soak.slice(40, 50), 50) <= percentile(soak.slice(0, 10), 50) * 2.0 + 2.0,
			"document lifecycle soak developed progressive latency");
		require(percentile(reload.slice(15, 20), 50) <= percentile(reload.slice(0, 5), 50) * 2.0 + 2.0,
			"plugin reload soak developed progressive latency");
		application.shutdown();

		return 0;
	}

	static function advanceModel(application:Application):Void {
		var root:ModelWorkbenchHost = cast application.root;

		root.update();

	}

	static function repeated(unit:String, minimum:Int):String {
		var value = unit;
		while (value.length < minimum) value += value;
		return value.substring(0, minimum);
	}

	static function elapsed(started:Float):Float
		return (Sys.time() - started) * 1000.0;

	static function percentile(values:Array<Float>, percent:Int):Float {
		var ordered = values.copy();
		ordered.sort(function(left, right) return left < right ? -1 : left > right ? 1 : 0);
		var index = Std.int((ordered.length - 1) * percent / 100);
		return ordered[index];
	}

}
