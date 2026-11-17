package app;

import workspace.client.WorkspaceLinks;
import workspace.client.WorkspaceServiceTarget;

/** WorkspaceLinks, with an exohost stand-in that records which workspaces were asked for and never answers. */
class WorkspaceLinksTests {
	static function require(value:Bool, message:String):Void {
		if (!value) throw message;
	}

	/**
		The window's links: one per workspace, made on first use, reused after; a link not used for LINGER_MS closes; the
		link of no workspace never asks for a service.
	**/
	public static function run(runtime:haxeon.platform.Runtime):Void {
		var clockNow = 0.0;
		var asked:Array<String> = [];
		var all = new WorkspaceLinks(runtime.events, function() return clockNow, function(id, _) asked.push(id));
		var here = Sys.getCwd();
		var a = WorkspaceServiceTarget.forWorkspace("a", [here], null), b = WorkspaceServiceTarget.forWorkspace("b", [here], null);
		var first = all.use(a, true);
		require(all.use(a, false) == first && asked.join(",") == "a", "a workspace has one link, asked for once: " + asked);
		all.use(b, false);
		require(all.count() == 2 && asked.join(",") == "a,b" && all.none.workspace == "", "one link per workspace; the window's own has none");
		clockNow += WorkspaceLinks.LINGER_MS - 1000;
		all.touch("a");
		clockNow += 2000;
		all.poll();
		require(all.get("a") == first && all.get("b") == null, "an unused link closes after the linger, a used one stays: " + all.ids());
		require(all.use(b, false) != null && asked.join(",") == "a,b,b", "a closed link is made again on its next use");
		all.dispose();
		require(all.count() == 0, "disposing closes every link");
		Sys.println("PASS: one link per workspace in use; unused links close after the linger");
	}

}
