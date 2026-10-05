package ui;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextField;
import workspace.client.WorkspaceAgentClient;

/** Conversation controls are a client projection; shared provider owns requests and turns. */
class CodexSessionPanel implements View {
  final getClient:Void -> Null<WorkspaceAgentClient>;
  final resource:String;
  final root:String;
  final frame:Void -> Void;
  var prompt = "";
  var diagnostics = false;
  var expanded:Map<String, Bool> = [];

  static function paragraph(value:String):Text {
    var style = new LayoutStyle();
    style.width = LayoutAxis.grow();
    return new Text(value, style);
  }

  public function new(getClient:Void -> Null<WorkspaceAgentClient>, resource:String, root:String, frame:Void -> Void) {
    this.getClient = getClient;
    this.resource = resource;
    this.root = root;
    this.frame = frame;
  }

  public function build(context:BuildContext):RenderNode {
    var client = getClient();
    var catalog = client == null ? null : client.agents();
    if (client == null || catalog == null
      || catalog.root != root) return paragraph("Connect to this agent’s workspace to view its session.").build(context);
    var view = client.agentView(resource);
    if (view == null) return paragraph(client.agentError()
      == null ? "Loading Codex session…" : client.agentError()).build(context);
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
    field.placeholder = "Message Codex…";
    field.enabled = control;
    var rows:Array<KeyedView> = [
      new KeyedView("title", paragraph(view.record.name + " · " + view.record.state)),
      new KeyedView(
        "directory",
        paragraph(view.record.cwd)
      ),
      new KeyedView(
        "thread",
        paragraph("Thread: " + view.record.thread)
      ),
      new KeyedView(
        "connection",
        new Row(
          "codex-connection",
          [
            new KeyedView(
              "connect",
              new Button(
                "Reconnect / History",
                null,
                function() client.agentAction(
                  id,
                  "connect",
                  "",
                  null
                ),
                "codex-connect"
              )
            ),
            new KeyedView(
              "stop",
              new Button(
                "Interrupt turn",
                null,
                function() client.agentAction(
                  id,
                  "stop",
                  "",
                  null
                ),
                "codex-stop"
              )
            )
          ]
        )
      )
    ];
    var style = new LayoutStyle();
    style.height = LayoutAxis.grow();
    style.width = LayoutAxis.grow();
    var activity:Array<KeyedView> = [];
    for (request in view.requests) {
      var r = request;
      activity.push(new KeyedView(
        "request-" + r.id,
        paragraph((r.method == "item/tool/requestUserInput"
        ? "Input needed" : r.method == "item/fileChange/requestApproval" ? "File change approval" : r.method
        == "item/commandExecution/requestApproval" ? "Command approval" : "Additional request") + "\n" + r.detail)
      ));
      if (!r.reviewable) activity.push(new KeyedView(
        "full-" + r.id,
        paragraph("Full request exceeds this view. Review it in another compatible Codex client.")
      ));
      if (r.method == "item/tool/requestUserInput") {
        activity.push(new KeyedView(
          "answer-" + r.id,
          new Button(
            "Answer using prompt (id=value per line)",
            null,
            function() client.agentAction(
              id,
              "answer",
              prompt,
              r.id
            )
          )
        ));
      } else if (r.method == "item/commandExecution/requestApproval" || r.method == "item/fileChange/requestApproval") {
        activity.push(new KeyedView(
          "approval-" + r.id,
          new Row(
            "codex-approval-" + r.id,
            [
              new KeyedView(
                "approve",
                new Button(
                  "Approve once",
                  null,
                  function() client.agentAction(
                    id,
                    "approve",
                    "",
                    r.id
                  )
                )
              ),
              new KeyedView(
                "decline",
                new Button(
                  "Decline",
                  null,
                  function() client.agentAction(
                    id,
                    "decline",
                    "",
                    r.id
                  )
                )
              )
            ]
          )
        ));
      } else activity.push(new KeyedView(
        "unsupported-" + r.id,
        paragraph("Answer this request in another compatible Codex client.")
      ));
    }
    var items = view.items;
    if (view.itemsOmitted == true) activity.push(new KeyedView(
      "omitted",
      paragraph("Showing recent activity. Earlier items are not included in this view.")
    ));
    if (items == null) activity.push(new KeyedView(
      "legacy",
      paragraph(view.activity == "" ? "No activity yet" : view.activity)
    ));
    else {
      var retained:Map<String, Bool> = [];
      for (item in items) {
        var key = item.turn + ":" + item.id;
        if (expanded.get(key) == true) retained.set(key, true);
      }
      expanded = retained;
      if (items.length == 0) activity.push(new KeyedView("empty", paragraph("No messages yet")));
      for (item in items) {
        var key = item.turn + ":" + item.id;
        var tool = item.kind != "agentMessage" && item.kind != "userMessage";
        var detail = item.detail;
        activity.push(new KeyedView("title-" + key, paragraph(item.title + (tool ? " · " + item.state : ""))));
        if (item.text != "") activity.push(new KeyedView("text-" + key, paragraph(item.text)));
        if (detail != "") {
          activity.push(new KeyedView("toggle-" + key,
            new Button(expanded.get(key) == true ? "Hide details" : "Show details", null, function() {
            expanded.set(key, expanded.get(key) != true);
            frame();
          }
          )));
          if (expanded.get(key) == true) activity.push(new KeyedView("detail-" + key, paragraph(detail)));
        }
        if (item.truncated) activity.push(new KeyedView(
          "truncated-" + key,
          paragraph("This item is truncated in the current view.")
        ));
      }
    }
    activity.push(new KeyedView("diagnostics-toggle",
      new Button(diagnostics ? "Hide diagnostics" : "Show diagnostics", null, function() {
      diagnostics = !diagnostics;
      frame();
    }
    )));
    if (diagnostics) activity.push(new KeyedView("diagnostics", paragraph(view.activity)));

    var error = client.agentError() == null ? view.error : client.agentError();
    if (error != null) activity.push(new KeyedView("error", paragraph(error)));
    rows.push(new KeyedView("activity", new ScrollView("codex-activity", new Column("codex-items", activity), style)));
    rows.push(new KeyedView("prompt", field));
    rows.push(new KeyedView("send", new Button("Send prompt", null, function() {
      if (prompt != "") {
        client.agentAction(id, "prompt", prompt, null);
        prompt = "";
        frame();
      }
    }, "codex-send")));
    var viewport = new LayoutStyle();
    viewport.height = LayoutAxis.grow();
    viewport.width = LayoutAxis.grow();
    return new Column("codex-session", rows, viewport).build(context);
  }
}
