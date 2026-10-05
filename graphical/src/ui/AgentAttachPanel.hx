package ui;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Insets;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextField;
import workspace.client.WorkspaceWorkbenchClient;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceAgentProtocol;

/** Discovery and explicit attachment stay pinned to the group chosen when the dialog opens. */
class AgentAttachPanel implements View {
	final client:WorkspaceWorkbenchClient;
	final group:WorkspaceGroup;
	final cwd:String;
	final owner:String;
	final done:Void->Void;
	final open:String->Void;
	final requestFrame:Void->Void;
	var filter = "";
	var threadId = "";
	var last:Null<AgentDiscovery>;
	final threads:Array<AgentThread> = [];

	public function new(client:WorkspaceWorkbenchClient, group:WorkspaceGroup, cwd:String,
		done:Void->Void, open:String->Void, requestFrame:Void->Void) {
		this.client = client; this.group = group; this.cwd = cwd;
		this.done = done; this.open = open; this.requestFrame = requestFrame;
		var catalog = client.terminalCatalog(); owner = catalog == null ? "" : catalog.instance;
		client.agentService().discoverAgents(group.id, null);
	}

	public function isCurrent():Bool {
		var catalog = client.terminalCatalog();
		if (catalog == null || catalog.instance != owner) return false;
		for (candidate in catalog.groups) if (candidate.id == group.id) return candidate.revision == group.revision;
		return false;
	}

	function attach(id:String):Void {
		if (!isCurrent() || client.agentService().agentBusy()) return;
		client.agentService().createAgent(group.id, id, function(resource) { done(); open(resource); });
		requestFrame();
	}

	public function build(context:BuildContext):RenderNode {
		var service = client.agentService();
		var found = service.discoveredAgents();
		if (found != null && found != last) {
			last = found;
			for (thread in found.threads) if (thread.cwd == cwd) {
				var duplicate = false;
				for (existing in threads) if (existing.id == thread.id) duplicate = true;
				if (!duplicate) threads.push(thread);
			}
		}
		var enabled = isCurrent() && service.canControlAgents() && !service.agentBusy();
		var search = new TextField("codex-thread-search", filter, function(value) { filter = value; requestFrame(); });
		search.label = "Search Codex threads"; search.placeholder = "Search threads in this directory";
		var results:Array<KeyedView> = [];
		for (thread in threads) if (filter == "" || thread.title.toLowerCase().indexOf(filter.toLowerCase()) >= 0) {
			var selected = thread;
			var buttonStyle = new LayoutStyle(); buttonStyle.width = LayoutAxis.stretch();
			var button = new Button(thread.title == "" ? "Untitled thread" : thread.title, buttonStyle,
				function() attach(selected.id), "attach-thread-" + thread.id);
			button.enabled = enabled;
			results.push(new KeyedView(thread.id, button));
		}
		if (results.length == 0) results.push(new KeyedView("empty", new Text(found == null && service.agentError() == null
			? "Finding threads…" : threads.length == 0 ? "No threads found in this directory." : "No matching threads.")));
		if (found != null && found.next != null) {
			var more = new Button("More threads", null, function() service.discoverAgents(group.id, found.next), "codex-more-threads");
			more.enabled = enabled; results.push(new KeyedView("more", more));
		}
		var listStyle = new LayoutStyle(); listStyle.width = LayoutAxis.stretch(); listStyle.childGap = 4;
		var viewportStyle = new LayoutStyle(); viewportStyle.width = LayoutAxis.stretch(); viewportStyle.height = LayoutAxis.fixed(220);
		var id = new TextField("workbench-attach-thread", threadId, function(value) { threadId = value; requestFrame(); });
		id.label = "Existing Codex thread id"; id.placeholder = "Or paste a thread ID";
		var attachButton = new Button("Attach Codex thread", null, function() attach(StringTools.trim(threadId)), "workbench-attach-codex");
		attachButton.enabled = enabled && StringTools.trim(threadId) != "";
		var rows:Array<KeyedView> = [new KeyedView("scope", new Text("Group: " + group.name)),
			new KeyedView("directory", new Text(cwd, null, context.theme.tokens.textSecondary, null, haxeon.ui.theme.TextRole.Caption)),
			new KeyedView("search", search), new KeyedView("results", new ScrollView("codex-thread-results",
				new Column("codex-found-threads", results, listStyle), viewportStyle)),
			new KeyedView("id", id), new KeyedView("attach", attachButton)];
		if (service.agentError() != null) {
			rows.push(new KeyedView("error", new Text(service.agentError())));
			var retry = new Button("Retry discovery", null, function() service.discoverAgents(group.id, null), "codex-retry-discovery");
			retry.enabled = enabled; rows.push(new KeyedView("retry", retry));
		}
		var style = new LayoutStyle(); style.width = LayoutAxis.stretch(); style.childGap = 8;
		return new Column("codex-attach", rows, style).build(context);
	}
}
