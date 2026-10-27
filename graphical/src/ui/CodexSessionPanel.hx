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
import haxeon.ui.widgets.controls.Select;
import haxeon.ui.widgets.controls.SelectOption;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.overlays.MenuItem;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.MiddleEllipsisText;
import haxeon.ui.widgets.text.TextField;
import workspace.client.WorkspaceAgentClient;
import workspace.client.AgentCommandCompletion;
import workspace.client.CodexPermissions;
import workspace.service.WorkspaceAgentProtocol.AgentModel;
import workspace.service.WorkspaceAgentProtocol.AgentInputMessage;
import workspace.service.WorkspaceAgentProtocol.AgentNativeInput;
import syntax.SyntaxRegistry;

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
  final syntaxes:SyntaxRegistry;
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
  var suggestionIndex = 0;
  var dismissSuggestions = false;

  static function paragraph(value:String):Text {
    var style = new LayoutStyle();
    style.width = LayoutAxis.grow();
    return new Text(value, style);
  }

  public function new(getClient:Void -> Null<WorkspaceAgentClient>, resource:String, root:String, frame:Void -> Void,
      editorPalette:style.Theme, syntaxes:SyntaxRegistry, showMenu:(Array<MenuItem>, UiEvent, Void->Bool)->Void, createReplacement:String->Void) {
    this.getClient = getClient;
    this.resource = resource;
    this.root = root;
    this.frame = frame;
    this.editorPalette = editorPalette;
    this.syntaxes = syntaxes;
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

  /** Pi and the built-in Exosuit agent share the supervised / auto-accept / full-access permission modes. */
  static function usesSupervisedModes(provider:Null<String>):Bool {
    return provider == "pi" || provider == "agentkit";
  }

  static function providerName(provider:Null<String>):String {
    return provider == "claude" ? "Claude" : provider == "pi" ? "Pi" : provider == "agentkit" ? "Exosuit" : "Codex";
  }

  static function piPermissionLabel(mode:String):String {
    return switch (mode) {
      case "supervised": "Supervised";
      case "acceptEdits": "Auto-accept edits";
      case "fullAccess": "Full access";
      default: "Supervised";
    };
  }

  static function recoveryPresentation(reason:Null<String>):CodexRecoveryPresentation {
    return switch (reason) {
      case "explicit-resume": {label: "Resume session", message: "Resume the saved conversation. Messages with uncertain delivery will not be resent. Recent activity is a shortened snapshot of the conversation.", retryLabel: "Resume session"};
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
    if (initial.record.provider == "claude" || usesSupervisedModes(initial.record.provider)) {
      var choices:Array<MenuItem> = [];
      for (mode in (usesSupervisedModes(initial.record.provider) ? ["supervised", "acceptEdits", "fullAccess"] : ["default", "acceptEdits", "plan"])) {
        var selectedMode = mode;
        choices.push(new MenuItem(mode, (usesSupervisedModes(initial.record.provider) ? piPermissionLabel(mode) : mode) + (initial.record.permissionMode == mode ? "  ✓" : ""), function() {
          client.agentAction(id, "permissions", selectedMode, null);
        }));
      }
      showMenu(choices, event, function() return !client.agentBusy());
      return;
    }
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
    var piActive = view.supportsQueue == true && (working || view.record.state == "needs-attention");
    var canQueue = control && connectionReady && view.supportsQueue == true && view.inputToken != null;
    var canSteer = control && connectionReady && view.supportsSteering == true && view.inputToken != null && view.inputBusy != true;
    var recovery = recoveryPresentation(view.recoveryReason);
    var stateLabel = view.record.state == "reconnecting" ? "Reconnecting…"
      : view.record.state == "reconnect-failed" ? recovery.label : view.record.state;
    var effortModel = findModel(view.models, selectedModel == "" ? view.currentModel : selectedModel);
    var submitAction = function(action:String) {
      var allowed = action == "queue" ? canQueue : action == "steer" ? canSteer : canSend;
      if (allowed && StringTools.trim(prompt) != "") {
        var sent = prompt;
        client.agentAction(id,action,sent,null,null,null,function() {
          if (prompt == sent) prompt = "";
          frame();
        });
      }
    };
    var submit = function() {if (view.requests.length == 0) submitAction(piActive ? "queue" : "prompt");};
    var inputStyle = new LayoutStyle();
    inputStyle.height = LayoutAxis.fixed(Math.min(160, 56 + (prompt.split("\n").length - 1) * 22));
    inputStyle.width = LayoutAxis.grow();
    inputStyle.padding = new Insets(12, 10, 12, 10);
    var field = new TextField("codex-prompt", prompt, function(v) {
      prompt = v;
      suggestionIndex = 0;dismissSuggestions = false;
      frame();
    }, inputStyle, null, null, null, true);
    field.label = providerName(view.record.provider) + " prompt";
    field.placeholder = "Message " + providerName(view.record.provider) + "…";
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
    if (working || ((view.record.provider == "claude" || usesSupervisedModes(view.record.provider)) && view.requests.length > 0)) header.push(new KeyedView("stop", stop));
    var permissions = new Button("Permissions · " + (usesSupervisedModes(view.record.provider) ? piPermissionLabel(view.record.permissionMode) : view.record.provider == "claude" ? view.record.permissionMode : CodexPermissions.labelForRecord(view.record.permissionProfile,
      view.record.sandboxPolicy, view.record.approvalPolicy)) + "  ▾", headerButtonStyle, null, "codex-permissions");
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
      // The built-in agent has no native thread to show; its identity is the Workbench resource.
      if (view.record.provider != "agentkit") rows.push(new KeyedView("thread", paragraph((view.record.provider == "claude" ? "Claude session: " : "Thread: ") + view.record.thread)));
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
    var pending = view.pendingInputs == null ? [] : view.pendingInputs;
    var queuedCount = 0;
    for (input in pending) {
      if (input.kind == "queue" && input.state == "queued") queuedCount++;
      if (input.state == "steering") continue;
      var entry = input;
      var title = (entry.kind == "queue" ? "Follow-up" : entry.kind == "steer" ? "Steering" : "Clear Pi queue") + " · " + entry.state;
      var message = title + "\n" + entry.text.substr(0,512);
      if (entry.text.length > 512) message += "\nPreview shortened. Use as draft to review the full message.";
      if (entry.error != null) message += "\n" + entry.error;
      if (entry.state == "uncertain") message += "\nDelivery is uncertain. Check Pi’s history before sending a new copy.";
      var controls:Array<KeyedView> = [];
      if (entry.state == "queued" || entry.state == "uncertain" || entry.state == "rejected") {
        var remove = new Button(entry.state == "queued" ? "Remove queued message" : "Dismiss input",null,
          function() client.agentAction(id,"remove-input","",entry.id),"agent-remove-input-"+entry.id);
        remove.enabled = control;
        controls.push(new KeyedView("remove",remove));
        if (entry.text != "") {
          var draft = new Button("Use as draft",null,function() {prompt=entry.text;promptFocusRequested=false;frame();});
          draft.enabled = control;
          controls.push(new KeyedView("draft",draft));
        }
      }
      activity.push(new KeyedView("pending-input-"+entry.id,new Column("pending-input-"+entry.id,[
        new KeyedView("text",paragraph(message)),new KeyedView("controls",new Row("controls",controls))
      ])));
    }
    if (view.supportsQueue == true && queuedCount > 0) {
      var queueControl = new Button(view.queuePaused == true ? "Resume queued messages" : "Pause queued messages",null,
        function() client.agentAction(id,view.queuePaused == true ? "resume-queue" : "pause-queue","",null),"agent-queue-policy");
      queueControl.enabled = control && (view.queuePaused != true || connectionReady);
      activity.unshift(new KeyedView("queue-state",new Column("agent-queue-state",[
        new KeyedView("label",paragraph(Std.string(queuedCount)+" queued follow-up(s)"+(view.queuePaused == true ? " · Paused" : ""))),
        new KeyedView("control",queueControl)
      ])));
    }
    var nativePending = view.nativePending == null ? [] : view.nativePending;
    if (nativePending.length > 0) {
      var clear = new Button("Clear Pi pending messages",null,function() client.agentAction(id,"clear-native-queue","",null),"agent-clear-native-inputs");
      clear.enabled = control && connectionReady && view.inputBusy != true;
      activity.push(new KeyedView("native-clear",clear));
      for (index in 0...nativePending.length) {
        var nativeInput = nativePending[index];
        activity.push(new KeyedView("native-input-"+index,paragraph("Pi pending · "+(nativeInput.kind == "steer" ? "Steering" : "Follow-up")+"\n"+nativeInput.text+(nativeInput.truncated ? "\nPreview shortened" : ""))));
      }
    }
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
        paragraph("Full request exceeds this view. Decline it or use a client that can display the full request.")
      ));
      if (r.method == "item/tool/requestUserInput") {
        var answer = new Button(
          r.inputKind != null ? "Answer using prompt" : "Answer using prompt (id=value per line)",
          null,
          function() client.agentAction(id, "answer", prompt, r.id),
          "codex-answer-" + r.id
        );
        answer.enabled = control && r.reviewable;
        activity.push(new KeyedView(
          "answer-" + r.id,
          answer
        ));
        if (r.inputKind != null || view.record.provider == "claude") activity.push(new KeyedView("cancel-" + r.id,
          new Button("Cancel", null, function() client.agentAction(id, "decline", "", r.id))));
      } else if (r.method == "item/commandExecution/requestApproval" || r.method == "item/fileChange/requestApproval") {
        var approve = new Button(
          "Approve once",
          null,
          function() client.agentAction(id, "approve", "", r.id),
          "codex-approve-" + r.id
        );
        approve.enabled = control && r.reviewable;
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
            if (rendered == null) { rendered = new CodexMarkdownView(item.text, editorPalette, syntaxes); markdown.set(key, rendered); }
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
    if (working) activity.push(new KeyedView("working", new Text(providerName(view.record.provider) + " is working…", null, tokens.mutedText)));

    var error = client.agentError() == null ? view.error : client.agentError();
    if ((view.record.state == "reconnect-failed" || connectionState == "disconnected")
      && error == view.error && !(details && diagnostics)) error = null;
    if (error != null) activity.push(new KeyedView("error", paragraph(error)));
    var activityStyle = new LayoutStyle();
    activityStyle.width = LayoutAxis.grow();
    activityStyle.childGap = 16;
    activityStyle.padding = new Insets(0, 12, 0, 12);
    rows.push(new KeyedView("activity", new AgentTranscript(new Column("codex-items", activity, activityStyle), style)));
    var suggestions = (canSend || (canQueue && view.requests.length == 0)) && !dismissSuggestions ? AgentCommandCompletion.matches(view.commands,prompt) : [];
    if (suggestionIndex >= suggestions.length) suggestionIndex = 0;
    var completionRows:Array<KeyedView> = [];
    function complete(index:Int):Void {
      if (index < 0 || index >= suggestions.length) return;
      prompt = AgentCommandCompletion.insert(suggestions[index]);
      suggestionIndex = 0;dismissSuggestions = false;promptFocusRequested = false;
      frame();
    }
    for (index in 0...suggestions.length) {
      var choice = index;
      var label = AgentCommandCompletion.label(suggestions[index],StringTools.startsWith(prompt,"$"));
      completionRows.push(new KeyedView("suggestion-"+index,new Button((index == suggestionIndex ? "› " : "")+label,null,
        function() complete(choice),"agent-command-suggestion-"+index)));
    }
    var send = new Button(piActive ? "Queue message" : "Send", null, function() submitAction(piActive ? "queue" : "prompt"), "codex-send");
    send.enabled = (piActive ? canQueue : canSend) && StringTools.trim(prompt) != "";
    var footerStyle = new LayoutStyle();
    footerStyle.width = LayoutAxis.grow();
    footerStyle.childGap = 12;
    var hint = new Text((piActive ? (view.requests.length > 0 ? "Answer the request, or use Queue / Steer" : "Enter to queue · Shift+Enter for newline") : "Enter to send · Shift+Enter for newline") + (view.commands == null ? "" : " · / commands · $ skills"), paragraph("").style, tokens.mutedText);
    var footerControls:Array<KeyedView> = [new KeyedView("hint",hint)];
    if (piActive) {
      var steer = new Button("Steer now",null,function() submitAction("steer"),"agent-steer");
      steer.enabled = canSteer && StringTools.trim(prompt) != "";
      footerControls.push(new KeyedView("steer",steer));
    }
    footerControls.push(new KeyedView("send",send));
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
      var chooser = new Select<String>("codex-model", options, selectedModel, function(value) {
        selectedModel = value;
        selectedEffort = "";
        client.agentAction(id, "model-settings", "", null, selectedModel == "" ? null : selectedModel, null);
        frame();
      });
      chooser.accessibilityLabel = "Conversation model";
      chooser.enabled = control && !working;
      modelControls.push(new KeyedView("chooser", chooser));
      if (view.modelsNext != null) {
        moreModels = new Button("More models", null, function() client.agentAction(id, "models", "", view.modelsNext));
        moreModels.enabled = control && !working;
      }
    }
    var defaultEffortLabel = selectedModel == "" && view.currentEffort != null
      ? "Keep current (" + view.currentEffort + ")" : "Model default";
    var effortOptions = [new SelectOption<String>("model-default", defaultEffortLabel, "")];
    var availableEfforts:Array<String> = effortModel == null || effortModel.supportedEfforts == null
      ? [] : effortModel.supportedEfforts;
    for (effort in availableEfforts) effortOptions.push(new SelectOption<String>("effort-" + effort, effortLabel(effort), effort));
    var effortChooser = new Select<String>("codex-effort", effortOptions, selectedEffort, function(value) {
      selectedEffort = value;
      client.agentAction(id, "model-settings", "", null, selectedModel == "" ? null : selectedModel,
        selectedEffort == "" ? null : selectedEffort);
      frame();
    });
    effortChooser.accessibilityLabel = "Reasoning effort";
    effortChooser.enabled = control && !working && effortModel != null && availableEfforts.length > 0;
    modelControls.push(new KeyedView("effort", effortChooser));
    if (moreModels != null) modelControls.push(new KeyedView("more", moreModels));
    if (view.record.provider == "pi") {
      var refresh = new Button(view.commandsLoading == true ? "Loading commands…" : "Refresh commands",null,
        function() client.agentAction(id,"commands","",null),"agent-refresh-commands");
      refresh.enabled = canSend && view.commandsLoading != true;
      modelControls.push(new KeyedView("commands",refresh));
    }
    var modelControlsStyle = footerStyle.copy();
    modelControlsStyle.wrapMode = haxeon.ui.LayoutWrapMode.Wrap;
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
      if (child.focusable && child.semantics != null && (child.semantics.label == "Codex prompt" || child.semantics.label == "Claude prompt" || child.semantics.label == "Pi prompt")) {
        child.onResolved(function(_) {
          if (!promptFocusRequested && child.enabled) promptFocusRequested = context.requestFocus(child.id);
        });
      }
    });
    promptNode.on(UiEventKind.KeyDown, function(event) {
      if (suggestions.length > 0 && (event.modifiers & (UiModifier.Shift | UiModifier.Control | UiModifier.Alt)) == 0) {
        if (event.key == UiKey.Down || event.key == UiKey.Up) {
          event.preventDefault();event.stopImmediatePropagation();
          suggestionIndex = (suggestionIndex + (event.key == UiKey.Down ? 1 : suggestions.length-1)) % suggestions.length;
          frame();return;
        }
        if (event.key == UiKey.Tab || event.key == UiKey.Enter) {
          event.preventDefault();event.stopImmediatePropagation();complete(suggestionIndex);return;
        }
        if (event.key == UiKey.Escape) {
          event.preventDefault();event.stopImmediatePropagation();dismissSuggestions = true;frame();return;
        }
      }
      if (event.key == UiKey.Enter && (event.modifiers & UiModifier.Shift) == 0) {
        event.preventDefault();
        event.stopImmediatePropagation();
        submit();
      }
    }, "capture");
    rows.push(new KeyedView("composer", new Column("codex-composer", [
      new KeyedView("models", new Row("codex-model-controls", modelControls, modelControlsStyle)),
      new KeyedView("prompt", new CodexPromptNode(promptNode)),
      new KeyedView("suggestions", new Column("agent-command-suggestions",completionRows)),
      new KeyedView("commands-error", new Text(view.commandsError == null ? "" : view.commandsError)),
      new KeyedView("footer", new Row("codex-composer-footer", footerControls, footerStyle))
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

/** History has its own scroll extent; its natural height must not push the composer out of the viewport. */
private class AgentTranscript implements View {
  final content:View;
  final style:LayoutStyle;
  public function new(content:View, style:LayoutStyle) {this.content = content;this.style = style;}
  public function build(context:BuildContext):RenderNode {
    var node:Null<RenderNode> = null;
    var scroll = new ScrollView("codex-activity",content,style);
    scroll.contentExtentProvider = function(width,height) {
      var geometry = node == null || node.children.length == 0 ? null : node.children[0].resolved;
      return {width:width,height:geometry == null ? height : Math.max(geometry.height,geometry.contentBounds.y+geometry.contentBounds.height)};
    };
    node = scroll.build(context);
    return node;
  }
}
