package ui;

import LayoutAxis;
import LayoutStyle;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.View;
import nativekit.ui.widgets.KeyedView;
import nativekit.ui.widgets.controls.Button;
import nativekit.ui.widgets.layout.Column;
import nativekit.ui.widgets.layout.Row;
import nativekit.ui.widgets.scroll.ScrollView;
import nativekit.ui.widgets.text.Text;
import nativekit.ui.widgets.text.TextField;
import workspace.client.WorkspaceAgentClient;

/** Conversation controls are a client projection; shared provider owns requests and turns. */
class CodexSessionPanel implements View {
	final getClient:Void->Null<WorkspaceAgentClient>;
	final resource:String;
	final root:String;
	final frame:Void->Void;
	var prompt = "";

	public function new(getClient:Void->Null<WorkspaceAgentClient>, resource:String, root:String, frame:Void->Void) {
		this.getClient = getClient;
		this.resource = resource;
		this.root = root;
		this.frame = frame;
	}

	public function build(context:BuildContext):RenderNode {
		var client = getClient();
		var catalog = client == null ? null : client.agents();
		if (client == null || catalog == null || catalog.root != root)
			return new Text("Connect to this agent’s workspace to view its session.").build(context);
		var view = client.agentView(resource);
		if (view == null)
			return new Text(client.agentError() == null ? "Loading Codex session…" : client.agentError()).build(context);
		var id = view.record.id;
		var control = client.canControlAgents() && !client.agentBusy();
		var inputStyle = new LayoutStyle();
		inputStyle.height = LayoutAxis.fixed(80);
		inputStyle.width = LayoutAxis.grow();
		var field = new TextField("codex-prompt", prompt, function(v) {
			prompt = v;
			frame();
		}, inputStyle, null, null, null, true);
		field.label = "Codex prompt";
		field.enabled = control;
		var rows:Array<KeyedView> = [
			new KeyedView("title", new Text(view.record.name + " · " + view.record.state)),
			new KeyedView("directory", new Text(view.record.cwd)),
			new KeyedView("thread", new Text("Thread: " + view.record.thread)),
			new KeyedView("connection", new Row("codex-connection", [
				new KeyedView("connect", new Button("Reconnect / History", null, function() client.agentAction(id, "connect", "", null), "codex-connect")),
				new KeyedView("stop", new Button("Interrupt turn", null, function() client.agentAction(id, "stop", "", null), "codex-stop"))
			]))
		];
		var style = new LayoutStyle();
		style.height = LayoutAxis.fixed(220);
		style.width = LayoutAxis.grow();
		rows.push(new KeyedView("activity", new ScrollView("codex-activity", new Text(view.activity == "" ? "No activity yet" : view.activity), style)));
		rows.push(new KeyedView("prompt", field));
		rows.push(new KeyedView("send", new Button("Send prompt", null, function() {
			if (prompt != "") {
				client.agentAction(id, "prompt", prompt, null);
				prompt = "";
				frame();
			}
		}, "codex-send")));
		for (request in view.requests) {
			var r = request;
			rows.push(new KeyedView("request-" + r.id, new Text((r.method=="item/tool/requestUserInput"?"Input needed":r.method=="item/fileChange/requestApproval"?"File change approval":r.method=="item/commandExecution/requestApproval"?"Command approval":"Additional request") + "\n" + r.detail)));
			if (!r.reviewable)
				rows.push(new KeyedView("full-" + r.id, new Text("Full request exceeds this view. Review it in another compatible Codex client.")));
			if (r.method == "item/tool/requestUserInput") {
				rows.push(new KeyedView("answer-" + r.id,
					new Button("Answer using prompt (id=value per line)", null, function() client.agentAction(id, "answer", prompt, r.id))));
			} else if (r.method == "item/commandExecution/requestApproval" || r.method == "item/fileChange/requestApproval") {
				rows.push(new KeyedView("approval-" + r.id, new Row("codex-approval-" + r.id, [
					new KeyedView("approve", new Button("Approve once", null, function() client.agentAction(id, "approve", "", r.id))),
					new KeyedView("decline", new Button("Decline", null, function() client.agentAction(id, "decline", "", r.id)))
				])));
			} else
				rows.push(new KeyedView("unsupported-" + r.id, new Text("Answer this request in another compatible Codex client.")));
		}
		var error = client.agentError() == null ? view.error : client.agentError();
		if (error != null)
			rows.push(new KeyedView("error", new Text(error)));
		return new Column("codex-session", rows).build(context);
	}
}
