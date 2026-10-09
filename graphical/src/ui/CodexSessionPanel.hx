package ui;

import haxeon.ui.LayoutAxis;
import haxeon.ui.Insets;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ComboBox;
import haxeon.ui.widgets.controls.SelectOption;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.overlays.MenuItem;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.MiddleEllipsisText;
import haxeon.ui.widgets.text.TextField;
import workspace.client.WorkspaceAgentClient;
import workspace.client.CodexPermissions;
import workspace.service.WorkspaceAgentProtocol.AgentModel;

private typedef CodexRecoveryPresentation = {
  var label:String;
  var message:String;
  var retryLabel:Null<String>;
}

/** Conversation controls are a client projection; shared provider owns requests and turns. */
class CodexSessionPanel implements View {
  static inline final MIN_ACTIVITY_HEIGHT:Float = 180;
  // Reserve header, spacing, a one-line composer and a usable activity area.
  static inline final MIN_SESSION_HEIGHT:Float = 480;
  final getClient:Void -> Null<WorkspaceAgentClient>;
  final resource:String;
  final root:String;
  final frame:Void -> Void;
  final editorPalette:style.Theme;
  final showMenu:(Array<MenuItem>, UiEvent, Void->Bool)->Void;
  final createReplacement:String->Void;
  var prompt = "";
  var selectedModel = "";
  var selectedEffort = "";
  var selectionLoaded = false;
  var modelCatalogRequested = false;
  var diagnostics = false;
  var details = false;
  var expanded:Map<String, Bool> = [];
  var markdown:Map<String, CodexMarkdownView> = [];
  var promptFocusRequested = false;

  static function paragraph(value:String):Text {
    var style = new LayoutStyle();
    style.width = LayoutAxis.grow();
    return new Text(value, style);
  }

  public function new(getClient:Void -> Null<WorkspaceAgentClient>, resource:String, root:String, frame:Void -> Void,
      editorPalette:style.Theme, showMenu:(Array<MenuItem>, UiEvent, Void->Bool)->Void, createReplacement:String->Void) {
    this.getClient = getClient;
    this.resource = resource;
    this.root = root;
    this.frame = frame;
    this.editorPalette = editorPalette;
    this.showMenu = showMenu;
    this.createReplacement = createReplacement;
  }

  static function findModel(models:Null<Array<AgentModel>>, slug:String):Null<AgentModel> {
    if (models != null && slug != null && slug != "") for (model in models) if (model.model == slug) return model;
    return null;
  }

  static function effortLabel(value:String):String {
    return switch (value) {
      case "xhigh": "Extra high effort";
      case "max": "Maximum effort";
      case "none": "No reasoning effort";
      case "minimal": "Minimal effort";
      default: (value.length == 0 ? value : value.substr(0, 1).toUpperCase() + value.substr(1) + " effort");
    };
  }

  static function recoveryPresentation(reason:Null<String>):CodexRecoveryPresentation {
    return switch (reason) {
      case "thread-unavailable": {label: "Thread unavailable", message: "Codex could not locate this thread in the current workspace’s history. Retrying will not create a replacement. Create a new session below, or attach the thread if it is still available. This saved session record will remain in Workbench.", retryLabel: null};
      case "active-writer": {label: "Open in another client", message: "Another Codex client currently owns this thread. Finish or close the session there, then check its availability here.", retryLabel: "Check availability"};
      case "workspace-mismatch": {label: "Different workspace", message: "This thread belongs to a different workspace. Switch to that workspace or attach a thread from the current one.", retryLabel: null};
      case "setup-required": {label: "Codex setup needed", message: "Codex needs setup before this session can reconnect. Check the installation and sign-in, then retry.", retryLabel: "Retry connection"};
      default: {label: "Connection interrupted", message: "Exosuit could not reach this Codex session. It will keep trying to reconnect; you can also retry now.", retryLabel: "Reconnect now"};
    }
  }

  function openPermissionsMenu(client:WorkspaceAgentClient, id:String, thread:String, event:UiEvent):Void {
    var initial = client.agentView(id);
    if (initial == null) return;
    var selectedLabel = CodexPermissions.labelForRecord(initial.record.permissionProfile,
      initial.record.sandboxPolicy, initial.record.approvalPolicy);
    var items:Array<MenuItem> = [];
    for (profile in CodexPermissions.profiles()) {
      var choice = profile;
      var selected = selectedLabel == profile.label;
      items.push(new MenuItem(profile.id, profile.label + (selected ? "  ✓" : ""), function() {
        var currentClient = getClient();
        if (currentClient != null && currentClient.canControlAgents() && !currentClient.agentBusy())
          currentClient.agentAction(id, "permissions", choice.id, null);
      }));
    }
    showMenu(items, event, function() {
      var currentClient = getClient();
      if (currentClient == null || currentClient != client || !currentClient.canControlAgents()
          || currentClient.agentBusy())
        return false;
      var currentCatalog = currentClient.agents();
      if (currentCatalog == null || currentCatalog.root != root) return false;
      var current = currentClient.agentView(id);
      return current != null && current.record.thread == thread && current.record.state != "working"
        && current.record.state != "needs-attention" && current.requests.length == 0;
    });
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
    if (!selectionLoaded) {
      selectedModel = view.record.preferredModel == null ? "" : view.record.preferredModel;
      selectedEffort = view.record.preferredEffort == null ? "" : view.record.preferredEffort;
      selectionLoaded = true;
    }
    var control = client.canControlAgents() && !client.agentBusy();
    var tokens = context.theme.tokens;
    var working = view.record.state == "working";
    var connectionState = view.connectionState == null
      ? (view.record.state == "reconnecting" ? "reconnecting"
        : view.record.state == "disconnected" || view.record.state == "reconnect-failed" || view.record.state == "creating" || view.record.state == "uncertain"
          ? "disconnected" : "connected")
      : view.connectionState;
    var connectionReady = connectionState == "connected";
    var canSend = control && connectionReady && !working && view.requests.length == 0;
    var recovery = recoveryPresentation(view.recoveryReason);
    var stateLabel = view.record.state == "reconnecting" ? "Reconnecting…"
      : view.record.state == "reconnect-failed" ? recovery.label : view.record.state;
    var effortModel = findModel(view.models, selectedModel == "" ? view.currentModel : selectedModel);
    var submit = function() {
      if (canSend && StringTools.trim(prompt) != "") {
        client.agentAction(id, "prompt", prompt, null);
        prompt = "";
        frame();
      }
    };
    var inputStyle = new LayoutStyle();
    inputStyle.height = LayoutAxis.fixed(Math.min(160, 56 + (prompt.split("\n").length - 1) * 22));
    inputStyle.width = LayoutAxis.grow();
    inputStyle.padding = new Insets(12, 10, 12, 10);
    var field = new TextField("codex-prompt", prompt, function(v) {
      prompt = v;
      frame();
    }, inputStyle, null, null, null, true);
    field.label = "Codex prompt";
    field.placeholder = "Message Codex…";
    field.enabled = client.canControlAgents() && connectionReady;
    var stop = new Button("Stop", null,
      function() client.agentAction(id, "stop", "", null), "codex-stop");
    stop.enabled = control && connectionReady;
    var headerStyle = new LayoutStyle();
    headerStyle.width = LayoutAxis.grow();
    headerStyle.childGap = 12;
    var headerButtonStyle = new LayoutStyle();
    headerButtonStyle.height = LayoutAxis.fixed(40);
    var heading = paragraph(view.record.name + " · " + (working ? "Working…" : stateLabel));
    var header:Array<KeyedView> = [new KeyedView("title", heading)];
    if (working) header.push(new KeyedView("stop", stop));
    var permissions = new Button("Permissions · " + CodexPermissions.labelForRecord(view.record.permissionProfile,
      view.record.sandboxPolicy, view.record.approvalPolicy) + "  ▾", headerButtonStyle, null, "codex-permissions");
    permissions.enabled = control && !working && view.requests.length == 0;
    permissions.onClickEvent = function(event) {
      if (permissions.enabled) openPermissionsMenu(client, id, view.record.thread, event);
    };
    header.push(new KeyedView("permissions", permissions));
    header.push(new KeyedView("details", new Button(details ? "Hide session details" : "Session details", headerButtonStyle, function() {
      details = !details;
      frame();
    }, "codex-details")));
    var rows:Array<KeyedView> = [new KeyedView("header", new Row("codex-header", header, headerStyle))];
    if (details) {
      rows.push(new KeyedView("directory", paragraph(view.record.cwd)));
      rows.push(new KeyedView("thread", paragraph("Thread: " + view.record.thread)));
      rows.push(new KeyedView("connection", paragraph("Connection: " + connectionState)));
      rows.push(new KeyedView("diagnostics-toggle", new Button(diagnostics ? "Hide diagnostics" : "Show diagnostics", null, function() {
        diagnostics = !diagnostics;
        frame();
      })));
    }
    if (view.record.thread != "" && (view.record.state == "reconnect-failed" || connectionState == "disconnected")) {
      var recoveryStyle = new LayoutStyle();
      recoveryStyle.width = LayoutAxis.grow();
      recoveryStyle.childGap = 10;
      var recoveryControls = [new KeyedView("message", paragraph(recovery.message))];
      if (view.recoveryReason == "thread-unavailable") {
        var create = new Button("Create new session", null,
          function() createReplacement(view.record.group), "codex-create-replacement");
        create.enabled = control;
        recoveryControls.push(new KeyedView("create-replacement", create));
      } else if (recovery.retryLabel != null) {
        var retry = new Button(recovery.retryLabel, null,
          function() client.agentAction(id, "connect", "", null), "codex-retry-connection");
        retry.enabled = control;
        recoveryControls.push(new KeyedView("retry", retry));
      }
      rows.push(new KeyedView("recovery-error", new Row("codex-recovery-error", recoveryControls, recoveryStyle)));
    }
    var style = new LayoutStyle();
    style.height = LayoutAxis.grow(MIN_ACTIVITY_HEIGHT);
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
        var answer = new Button(
          "Answer using prompt (id=value per line)",
          null,
          function() client.agentAction(id, "answer", prompt, r.id),
          "codex-answer-" + r.id
        );
        answer.enabled = control;
        activity.push(new KeyedView(
          "answer-" + r.id,
          answer
        ));
      } else if (r.method == "item/commandExecution/requestApproval" || r.method == "item/fileChange/requestApproval") {
        var approve = new Button(
          "Approve once",
          null,
          function() client.agentAction(id, "approve", "", r.id),
          "codex-approve-" + r.id
        );
        approve.enabled = control;
        var decline = new Button(
          "Decline",
          null,
          function() client.agentAction(id, "decline", "", r.id),
          "codex-decline-" + r.id
        );
        decline.enabled = control;
        activity.push(new KeyedView(
          "approval-" + r.id,
          new Row(
            "codex-approval-" + r.id,
            [
              new KeyedView("approve", approve),
              new KeyedView("decline", decline)
            ]
          )
        ));
      } else activity.push(new KeyedView(
        "unsupported-" + r.id,
        paragraph("Answer this request in another compatible Codex client.")
      ));
    }
    var items = view.items;
    if (items == null) activity.push(new KeyedView(
      "legacy",
      paragraph(view.activity == "" ? "No activity yet" : view.activity)
    ));
    else {
      var retained:Map<String, Bool> = [];
      var retainedMarkdown:Map<String, CodexMarkdownView> = [];
      for (item in items) {
        var key = item.turn + ":" + item.id;
        if (markdown.exists(key)) retainedMarkdown.set(key, markdown.get(key));
        if (expanded.get(key) == true) retained.set(key, true);
      }
      expanded = retained;
      markdown = retainedMarkdown;
      if (items.length == 0) activity.push(new KeyedView("empty", paragraph("No messages yet")));
      for (item in items) {
        var key = item.turn + ":" + item.id;
        var reasoning = item.kind == "reasoning";
        var command = item.kind == "commandExecution";
        if (reasoning && item.state == "completed" && StringTools.trim(item.text + item.detail) == "" && !item.truncated) continue;
        var tool = item.kind != "agentMessage" && item.kind != "userMessage";
        var detail = item.detail;
        var message:Array<KeyedView> = [];
        if (command) {
          var summary = ~/\s+/g.replace(StringTools.trim(item.text), " ");
          var commandStyle = new LayoutStyle();
          commandStyle.width = LayoutAxis.grow();
          commandStyle.childGap = 8;
          message.push(new KeyedView("command-" + key, new Row("codex-command-" + key, [
            new KeyedView("summary", new MiddleEllipsisText("summary",
              item.title + " · " + item.state + (summary == "" ? "" : " · " + summary), false)),
            new KeyedView("toggle", new Button(expanded.get(key) == true ? "Hide details" : "Show details", null, function() {
              expanded.set(key, expanded.get(key) != true);
              frame();
            }))
          ], commandStyle)));
        } else if (reasoning) message.push(new KeyedView("reasoning-" + key,
          new Button((expanded.get(key) == true ? "Hide reasoning" : "Show reasoning") + (item.state == "completed" ? "" : " · " + item.state), null, function() {
            expanded.set(key, expanded.get(key) != true);
            frame();
          })));
        else message.push(new KeyedView("title-" + key, new Text(item.title + (tool ? " · " + item.state : ""), null, tokens.mutedText)));
        if (item.text != "" && ((!reasoning && !command) || expanded.get(key) == true)) {
          if (item.kind == "agentMessage") {
            var rendered = markdown.get(key);
            if (rendered == null) { rendered = new CodexMarkdownView(item.text, editorPalette); markdown.set(key, rendered); }
            rendered.update(item.text);
            message.push(new KeyedView("text-" + key, rendered));
          } else message.push(new KeyedView("text-" + key, paragraph(item.text)));
        }
        if (detail != "" && reasoning && expanded.get(key) == true) message.push(new KeyedView("detail-" + key, paragraph(detail)));
        if (detail != "" && command && expanded.get(key) == true) message.push(new KeyedView("detail-" + key, paragraph(detail)));
        if (detail != "" && !reasoning && !command) {
          message.push(new KeyedView("toggle-" + key,
            new Button(expanded.get(key) == true ? "Hide details" : "Show details", null, function() {
            expanded.set(key, expanded.get(key) != true);
            frame();
          }
          )));
          if (expanded.get(key) == true) message.push(new KeyedView("detail-" + key, paragraph(detail)));
        }
        if (item.truncated && (!command || expanded.get(key) == true)) message.push(new KeyedView(
          "truncated-" + key,
          paragraph("This item is truncated in the current view.")
        ));
        var messageStyle = new LayoutStyle();
        messageStyle.width = LayoutAxis.grow(0, 880);
        messageStyle.padding = new Insets(16, item.kind == "userMessage" ? 8 : 0, 16, item.kind == "userMessage" ? 8 : 0);
        messageStyle.childGap = 4;
        messageStyle.background = item.kind == "userMessage" ? tokens.surfaceRaised : tokens.surface;
        messageStyle.radiusTopLeft = messageStyle.radiusTopRight = messageStyle.radiusBottomLeft = messageStyle.radiusBottomRight = 10;
        activity.push(new KeyedView("message-" + key, new Column("codex-message-" + key, message, messageStyle)));
      }
    }
    if (details && diagnostics) activity.push(new KeyedView("diagnostics", paragraph(view.activity)));
    if (working) activity.push(new KeyedView("working", new Text("Codex is working…", null, tokens.mutedText)));

    var error = client.agentError() == null ? view.error : client.agentError();
    if ((view.record.state == "reconnect-failed" || connectionState == "disconnected")
      && error == view.error && !(details && diagnostics)) error = null;
    if (error != null) activity.push(new KeyedView("error", paragraph(error)));
    var activityStyle = new LayoutStyle();
    activityStyle.width = LayoutAxis.grow();
    activityStyle.childGap = 16;
    activityStyle.padding = new Insets(0, 12, 0, 12);
    rows.push(new KeyedView("activity", new ScrollView("codex-activity", new Column("codex-items", activity, activityStyle), style)));
    var send = new Button("Send", null, submit, "codex-send");
    send.enabled = canSend && StringTools.trim(prompt) != "";
    var footerStyle = new LayoutStyle();
    footerStyle.width = LayoutAxis.grow();
    footerStyle.childGap = 12;
    var hint = new Text("Enter to send · Shift+Enter for newline", paragraph("").style, tokens.mutedText);
    var modelControls:Array<KeyedView> = [];
    var moreModels:Button = null;
    if (view.models == null) {
      if ((selectedModel != "" || selectedEffort != "") && !modelCatalogRequested && !client.agentBusy()) {
        modelCatalogRequested = true;
        client.agentAction(id, "models", "", null);
      }
      var load = new Button("Choose model…", null, function() {
        modelCatalogRequested = true;
        client.agentAction(id, "models", "", null);
      }, "codex-models");
      load.enabled = control && !working;
      modelControls.push(new KeyedView("load", load));
    } else {
      var options = [new SelectOption<String>("current", "Conversation model", "")];
      for (model in view.models) options.push(new SelectOption<String>(model.model, model.name, model.model));
      var chooser = new ComboBox<String>("codex-model", options, selectedModel, function(value) {
        selectedModel = value;
        selectedEffort = "";
        client.agentAction(id, "model-settings", "", null, selectedModel == "" ? null : selectedModel, null);
        frame();
      });
      chooser.enabled = control && !working;
      modelControls.push(new KeyedView("chooser", chooser));
      if (view.modelsNext != null) {
        moreModels = new Button("More models", null, function() client.agentAction(id, "models", "", view.modelsNext));
        moreModels.enabled = control && !working;
      }
    }
    var defaultEffortLabel = selectedModel == "" && view.currentEffort != null
      ? "Effort: Keep current (" + view.currentEffort + ")" : "Effort: Model default";
    var effortOptions = [new SelectOption<String>("model-default", defaultEffortLabel, "")];
    var availableEfforts:Array<String> = effortModel == null || effortModel.supportedEfforts == null
      ? [] : effortModel.supportedEfforts;
    for (effort in availableEfforts) effortOptions.push(new SelectOption<String>("effort-" + effort, effortLabel(effort), effort));
    var effortChooser = new ComboBox<String>("codex-effort", effortOptions, selectedEffort, function(value) {
      selectedEffort = value;
      client.agentAction(id, "model-settings", "", null, selectedModel == "" ? null : selectedModel,
        selectedEffort == "" ? null : selectedEffort);
      frame();
    });
    effortChooser.enabled = control && !working && effortModel != null && availableEfforts.length > 0;
    modelControls.push(new KeyedView("effort", effortChooser));
    if (moreModels != null) modelControls.push(new KeyedView("more", moreModels));
    var composerStyle = new LayoutStyle();
    composerStyle.width = LayoutAxis.grow();
    composerStyle.childGap = 8;
    composerStyle.padding = new Insets(12, 12, 12, 12);
    composerStyle.background = tokens.surfaceRaised;
    composerStyle.radiusTopLeft = composerStyle.radiusTopRight = composerStyle.radiusBottomLeft = composerStyle.radiusBottomRight = 12;
    // Capture on a stable parent so the field's own patch updates retain keyboard behavior.
    var promptStyle = new LayoutStyle();
    promptStyle.width = LayoutAxis.grow();
    var promptNode = new Column("codex-prompt-keys", [new KeyedView("field", field)], promptStyle).build(context);
    promptNode.walk(function(child) {
      if (child.focusable && child.semantics != null && child.semantics.label == "Codex prompt") {
        child.onResolved(function(_) {
          if (!promptFocusRequested && child.enabled) promptFocusRequested = context.requestFocus(child.id);
        });
      }
    });
    promptNode.on(UiEventKind.KeyDown, function(event) {
      if (event.key == UiKey.Enter && (event.modifiers & UiModifier.Shift) == 0) {
        event.preventDefault();
        event.stopImmediatePropagation();
        submit();
      }
    }, "capture");
    rows.push(new KeyedView("composer", new Column("codex-composer", [
      new KeyedView("models", new Row("codex-model-controls", modelControls, footerStyle)),
      new KeyedView("prompt", new CodexPromptNode(promptNode)),
      new KeyedView("footer", new Row("codex-composer-footer", [new KeyedView("hint", hint), new KeyedView("send", send)], footerStyle))
    ], composerStyle)));
    var viewport = new LayoutStyle();
    viewport.height = LayoutAxis.grow(MIN_SESSION_HEIGHT + inputStyle.height.value - 56);
    viewport.width = LayoutAxis.grow();
    viewport.padding = new Insets(20, 16, 20, 16);
    viewport.childGap = 12;
    // Preserve a usable activity viewport. When the header and composer cannot
    // fit, scroll the whole session rather than clipping its action controls.
    var scrollStyle = new LayoutStyle();
    scrollStyle.height = LayoutAxis.grow();
    scrollStyle.width = LayoutAxis.grow();
    var session = new ScrollView("codex-session-viewport", new Column("codex-session", rows, viewport), scrollStyle);
    session.fillViewport = true;
    return session.build(context);
  }
}

private class CodexPromptNode implements View {
  final node:RenderNode;
  public function new(node:RenderNode) this.node = node;
  public function build(context:BuildContext):RenderNode return node;
}
