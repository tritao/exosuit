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
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.overlays.MenuItem;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.scroll.ScrollController;
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

private typedef SessionTextContext = { var path:String; var text:String; }
private typedef LoadedMessageContent = { var token:String; var text:String; var partial:Bool; }
private typedef SessionImageDraft = { var name:String; var id:String; var bytes:haxe.io.Bytes; var key:Int; }

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
  final openLink:Null<String->Void>;
  final workspaceActions:Null<SessionWorkspaceActions>;
  final transcriptScroll = new ScrollController();
  var requestAnchor:Null<RenderNode> = null;
  var transcriptViewport:Null<RenderNode> = null;
  var historyNodes:Map<String, RenderNode> = [];

  /** Drop the render nodes kept for scrolling. They link the whole old tree and its handlers (GraphicalMain.liveRelease). */
  public function releaseRetained():Void {
    requestAnchor = null; transcriptViewport = null; historyNodes = [];
  }
  var historyAnchor:Null<{key:String, y:Float}> = null;
  var historyReturnToLatest = false;
  var prompt = "";
  var promptRevision = 0;
  var selectedModel = "";
  var selectedEffort = "";
  var modelCatalogRequested = false;
  var diagnostics = false;
  var details = false;
  var expanded:Map<String, Bool> = [];
  var markdown:Map<String, CodexMarkdownView> = [];
  var diffs:Map<String, SessionDiffView> = [];
  var questionForms:Map<String, SessionQuestionForm> = [];
  var expandedRequestDetails:Map<String, Bool> = [];
  var copiedMessages:Map<String, String> = [];
  var promptFocusRequested = false;
  var suggestionIndex = 0;
  var dismissSuggestions = false;
  var addingContext = false;
  var contextPath = "";
  var contextError:Null<String> = null;
  var contextLoading = false;
  var contextGeneration = 0;
  var contextRevision = 0;
  var textContext:Array<SessionTextContext> = [];
  var imageDrafts:Array<SessionImageDraft> = [];
  var imageUploading = false;
  var imageError:Null<String> = null;
  var imageGeneration = 0;
  var loadedContent:Map<String,LoadedMessageContent> = [];
  var contentOrder:Array<String> = [];
  var contentErrors:Map<String,String> = [];
  var contentErrorTokens:Map<String,String> = [];
  var contentLoading:Null<String> = null;
  function imageSessionCurrent(client:WorkspaceAgentClient,id:String,thread:String):Bool {
    var current=getClient();
    if (current != client || current == null) return false;
    var catalog=current.agents(), view=current.agentView(id);
    return catalog != null && catalog.root == root && view != null && view.record.thread == thread;
  }
  function uploadImage(client:WorkspaceAgentClient,id:String,thread:String,name:String,bytes:haxe.io.Bytes,generation:Int):Void {
    client.uploadAgentImage(id,bytes,function(upload,problem) {
      if (generation != imageGeneration || !imageSessionCurrent(client,id,thread)) {
        if (upload != null) client.removeAgentImage(id,upload);
        if (generation == imageGeneration) {imageUploading=false;imageError="Session changed while uploading the image";frame();}
        return;
      }
      imageUploading=false;
      if (problem != null || upload == null) imageError=problem == null ? "Image upload failed" : problem;
      else {imageDrafts.push({name:name,id:upload,bytes:bytes,key:generation});contextRevision++;imageError=null;}
      frame();
    });
  }
  function rememberHistoryAnchor():Void {
    historyAnchor = null;
    if (transcriptViewport == null || transcriptViewport.resolved == null) return;
    var viewport = transcriptViewport.globalBounds(), firstY = Math.POSITIVE_INFINITY;
    for (key => node in historyNodes) if (node.resolved != null) {
      var bounds = node.globalBounds();
      if (bounds.y + bounds.height > viewport.y && bounds.y < viewport.y + viewport.height && bounds.y < firstY) {
        firstY = bounds.y; historyAnchor = {key:key, y:bounds.y - viewport.y};
      }
    }
  }
  function loadContent(client:WorkspaceAgentClient, session:String, item:workspace.service.WorkspaceAgentProtocol.AgentActivityItem, key:String):Void {
    if (contentLoading != null || item.contentToken == null) return;
    var token:String = cast item.contentToken;
    contentLoading = key; contentErrors.remove(key); contentErrorTokens.remove(key); frame();
    client.loadAgentContent(session,item.turn,item.id,token,function(text,partial,error) {
      contentLoading = null;
      var current = client.agentView(session), valid = false;
      if (current != null && current.items != null) for (candidate in current.items)
        if (candidate.turn == item.turn && candidate.id == item.id && candidate.contentToken == token) valid=true;
      if (valid && text != null && error == null) {
        loadedContent.set(key,{token:token,text:text,partial:partial}); contentOrder.remove(key); contentOrder.push(key);
        var bytes=0; for (saved in contentOrder) { var entry=loadedContent.get(saved); if (entry != null) bytes+=haxe.io.Bytes.ofString(entry.text).length; }
        while (contentOrder.length > 16 || bytes > 4*1024*1024) {
          var oldest=contentOrder.shift(), removed=loadedContent.get(oldest);
          if (removed != null) bytes-=haxe.io.Bytes.ofString(removed.text).length;
          loadedContent.remove(oldest);
        }
      } else if (valid) { contentErrors.set(key,error == null ? "Message content is unavailable" : error); contentErrorTokens.set(key,token); }
      frame();
    });
  }

  static function paragraph(value:String):Text {
    var style = new LayoutStyle();
    style.width = LayoutAxis.grow();
    return new Text(value, style);
  }

  static function commandStatus(state:String):String return switch state {
    case "inProgress", "running": "Running";
    case "completed": "Completed";
    case "failed": "Failed";
    case "interrupted": "Interrupted";
    case "cancelled", "canceled": "Cancelled";
    case "pending": "Pending";
    case _: "Unknown";
  }

  static function quietButton(label:String, action:Void->Void, ?key:String):Button {
    var compact = new LayoutStyle();
    compact.height = LayoutAxis.fixed(30);
    compact.padding = new Insets(8, 4, 8, 4);
    var button = new Button(label, compact, action, key);
    button.variant = ButtonVariant.Navigation;
    button.classes.push("viewport-tool");
    return button;
  }

  static function withTextContext(prompt:String, files:Array<SessionTextContext>):String {
    var result = prompt;
    for (file in files) result += "\n\n[Workspace text snapshot: " + file.path + "]\n" + file.text + "\n[End workspace text snapshot]";
    return result;
  }

  static function validContextText(value:String):Bool {
    var bytes = haxe.io.Bytes.ofString(value);
    for (index in 0...bytes.length) if (bytes.get(index) == 0) return false;
    return workspace.TextFileContent.validUtf8(bytes);
  }

  public function new(getClient:Void -> Null<WorkspaceAgentClient>, resource:String, root:String, frame:Void -> Void,
      editorPalette:style.Theme, syntaxes:SyntaxRegistry, showMenu:(Array<MenuItem>, UiEvent, Void->Bool)->Void, createReplacement:String->Void,
      ?openLink:String->Void, ?workspaceActions:SessionWorkspaceActions) {
    this.getClient = getClient;
    this.resource = resource;
    this.root = root;
    this.frame = frame;
    this.editorPalette = editorPalette;
    this.syntaxes = syntaxes;
    this.showMenu = showMenu;
    this.createReplacement = createReplacement;
    this.openLink = openLink;
    this.workspaceActions = workspaceActions;
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
    var imageThread = view.record.thread;
    // The service record is authoritative, including after rejection or an
    // external settings change. Do not present an unaccepted selection.
    selectedModel = view.record.preferredModel == null ? "" : view.record.preferredModel;
    selectedEffort = view.record.preferredEffort == null ? "" : view.record.preferredEffort;
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
    var composedPrompt = withTextContext(prompt, textContext);
    var promptBytes = haxe.io.Bytes.ofString(composedPrompt).length;
    var submitLimit = piActive ? 4096 : 8192;
    var imagesSupported = imageDrafts.length == 0 || view.supportsImageUpload == true;
    var submitAction = function(action:String) {
      var allowed = action == "queue" ? canQueue : action == "steer" ? canSteer : canSend;
      var limit = action == "queue" || action == "steer" ? 4096 : 8192;
      if (allowed && imagesSupported && !contextLoading && !imageUploading && promptBytes <= limit && (StringTools.trim(prompt) != "" || imageDrafts.length > 0)) {
        var sent = composedPrompt, draft = prompt;
        var submittedText = textContext.copy(), submittedImageDrafts = imageDrafts.copy();
        var submittedImages = [for (image in submittedImageDrafts) image.id];
        client.agentAction(id,action,sent,null,null,null,function() {
          if (prompt == draft) prompt = "";
          for (file in submittedText) if (textContext.remove(file)) contextRevision++;
          for (image in submittedImageDrafts) if (imageDrafts.remove(image)) {
            contextRevision++; client.removeAgentImage(id, image.id);
          }
          frame();
        }, null, submittedImages.length == 0 ? null : submittedImages);
      }
    };
    var submit = function() {if (view.requests.length == 0) submitAction(piActive ? "queue" : "prompt");};
    var inputStyle = new LayoutStyle();
    inputStyle.height = LayoutAxis.fixed(Math.min(160, 56 + (prompt.split("\n").length - 1) * 22));
    inputStyle.width = LayoutAxis.grow();
    inputStyle.padding = new Insets(2, 8, 2, 8);
    inputStyle.background = tokens.surfaceRaised;
    var field = new TextField("codex-prompt", prompt, function(v) {
      prompt = v;
      promptRevision++;
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
    headerStyle.wrapMode = haxeon.ui.LayoutWrapMode.Wrap;
    var headerButtonStyle = new LayoutStyle();
    headerButtonStyle.height = LayoutAxis.fixed(32);
    var titleStyle = new LayoutStyle();
    titleStyle.width = LayoutAxis.grow();
    var heading = new Column("codex-session-heading", [
      new KeyedView("name", new Text(view.record.name, null, tokens.textPrimary, TextStyleOverride.text(18))),
      new KeyedView("status", new Text(providerName(view.record.provider) + " · " + (working ? "Working…" : stateLabel), null,
        working ? tokens.accent : tokens.textSecondary, TextStyleOverride.text(12)))
    ], titleStyle);
    var header:Array<KeyedView> = [new KeyedView("title", heading)];
    if (working || ((view.record.provider == "claude" || usesSupervisedModes(view.record.provider)) && view.requests.length > 0)) header.push(new KeyedView("stop", stop));
    var permissionLabel = usesSupervisedModes(view.record.provider) ? piPermissionLabel(view.record.permissionMode) : view.record.provider == "claude" ? view.record.permissionMode : CodexPermissions.labelForRecord(view.record.permissionProfile,
      view.record.sandboxPolicy, view.record.approvalPolicy);
    var permissions = new Button("Permissions · " + permissionLabel + "  ▾", headerButtonStyle, null, "codex-permissions");
    permissions.accessibilityLabel = "Permissions · " + permissionLabel + "  ▾";
    permissions.leadingView = new SessionLineIcon("lock", tokens.textSecondary);
    permissions.enabled = control && !working && view.requests.length == 0;
    permissions.onClickEvent = function(event) {
      if (permissions.enabled) openPermissionsMenu(client, id, view.record.thread, event);
    };
    header.push(new KeyedView("details", quietButton(details ? "Hide session details" : "Session details", function() {
      details = !details;
      frame();
    }, "codex-details")));
    var rows:Array<KeyedView> = [new KeyedView("header", new Row("codex-header", header, headerStyle))];
    permissions.variant = ButtonVariant.Navigation;
    permissions.classes.push("chrome-action");
    var workspaceControls:Array<KeyedView> = [];
    var workspaceStrip:Null<KeyedView> = null;
    if (workspaceActions != null) {
      var stripItems:Array<KeyedView> = [];
      var stripTrailing:Array<KeyedView> = [];
      var hasBranch = false;
      var groupStyle = new LayoutStyle(); groupStyle.width = LayoutAxis.fit(); groupStyle.childGap = 4;
      var filesButton = quietButton("Files", workspaceActions.explore, "agent-open-files");
      filesButton.leadingIcon = IconName.FolderOpen; filesButton.iconSize = 14;
      var changesButton = quietButton("Review changes", workspaceActions.reviewChanges, "agent-review-changes");
      changesButton.leadingIcon = IconName.Activity; changesButton.iconSize = 14;
      var navigation = new KeyedView("navigation", new Row("agent-workspace-navigation", [
        new KeyedView("files", filesButton),
        new KeyedView("changes", changesButton)
      ], groupStyle));
      var repositoryItems:Array<MenuItem> = [];
      var initialThread = view.record.thread, initialCwd = view.record.cwd, initialProvider = view.record.provider;
      var menuValid = function() {
        var current = getClient();
        if (current == null || current != client) return false;
        var catalog = current.agents(), session = current.agentView(id);
        return catalog != null && catalog.root == root && session != null && session.record.thread == initialThread
          && session.record.cwd == initialCwd && session.record.provider == initialProvider;
      };
      if (workspaceActions.worktreeLabel != null && workspaceActions.selectWorktree != null && workspaceActions.canSelectWorktree != null) {
        var worktreeLabel:Void->String = cast workspaceActions.worktreeLabel;
        var label = worktreeLabel();
        var worktreeAction:Void->Void = cast workspaceActions.selectWorktree;
        var worktreeAvailable:Void->Bool = cast workspaceActions.canSelectWorktree;
        var worktree = quietButton(label + " ▾", function() { if (menuValid() && worktreeAvailable()) worktreeAction(); }, "agent-select-worktree");
        worktree.accessibilityLabel = "Select worktree"; worktree.leadingView = new SessionLineIcon("worktree", tokens.textSecondary);
        worktree.ellipsizeLabel = true; worktree.style.width = LayoutAxis.grow(124, 220); worktree.enabled = worktreeAvailable();
        stripItems.push(new KeyedView("worktree", new SessionDirectoryTooltip(worktree, view.record.cwd)));
      } else stripItems.push(new KeyedView("workspace-context", new MiddleEllipsisText("workspace-context", workspaceActions.context(), true,
        TextStyleOverride.text(12, null, tokens.textSecondary))));
      if (workspaceActions.branchLabel != null && workspaceActions.selectBranch != null && workspaceActions.canSelectBranch != null) {
        var branchLabel:Void->String = cast workspaceActions.branchLabel;
        var label = branchLabel();
        var branchAction:Void->Void = cast workspaceActions.selectBranch;
        var branchAvailable:Void->Bool = cast workspaceActions.canSelectBranch;
        var branch = quietButton(label + " ▾", function() { if (menuValid() && branchAvailable()) branchAction(); }, "agent-select-branch");
        branch.accessibilityLabel = "Select branch"; branch.leadingView = new SessionLineIcon("branch", tokens.textSecondary);
        branch.ellipsizeLabel = true; branch.style.width = LayoutAxis.grow(112, 180); branch.enabled = branchAvailable();
        hasBranch = true;
        stripTrailing.push(new KeyedView("branch", new SettingMenuButton(branch, label)));
      }
      function repositoryAction(key:String, label:String, available:Null<Void->Bool>, action:Null<Void->Void>):Void {
        if (available == null || action == null) return;
        var permitted:Void->Bool = cast available, run:Void->Void = cast action;
        if (permitted()) repositoryItems.push(new MenuItem(key, label, function() {
          if (menuValid() && permitted()) run();
        }));
      }
      repositoryAction("worktree", "New worktree", workspaceActions.canCreateWorktree, workspaceActions.newWorktree);
      repositoryAction("commit", "Commit changes", workspaceActions.canCommitChanges, workspaceActions.commitChanges);
      repositoryAction("github", "Open GitHub", workspaceActions.canOpenGithub, workspaceActions.githubRepository);
      repositoryAction("pull-request", "Open pull request page", workspaceActions.canOpenPullRequest, workspaceActions.githubPullRequest);
      if (repositoryItems.length > 0) {
        var repository = quietButton("Git ▾", function() {}, "agent-repository-actions");
        repository.accessibilityLabel = "Repository actions";
        repository.onClickEvent = function(event) { if (menuValid()) showMenu(repositoryItems, event, menuValid); };
        stripTrailing.push(new KeyedView("repository-actions", repository));
      }
      if (stripTrailing.length > 0) {
        var trailingSpace = new LayoutStyle(); trailingSpace.width = LayoutAxis.grow();
        stripTrailing.unshift(new KeyedView("spacer", new Column("workspace-strip-spacer", [], trailingSpace)));
        var trailingStyle = new LayoutStyle(); trailingStyle.width = LayoutAxis.grow(hasBranch ? 180 : 70); trailingStyle.childGap = 4;
        stripItems.push(new KeyedView("trailing", new Row("workspace-strip-trailing", stripTrailing, trailingStyle)));
      }
      workspaceControls.push(navigation);
      var stripStyle = new LayoutStyle(); stripStyle.width = LayoutAxis.grow(0, 880);
      stripStyle.padding = new Insets(10, 2, 10, 2); stripStyle.childGap = 4;
      stripStyle.wrapMode = haxeon.ui.LayoutWrapMode.Wrap;
      stripStyle.background = tokens.surfaceRaised;
      stripStyle.radiusTopLeft = stripStyle.radiusTopRight = 0;
      stripStyle.radiusBottomLeft = stripStyle.radiusBottomRight = 7;
      stripStyle.childAlignY = haxeon.ui.LayoutAlignmentY.Center;
      workspaceStrip = new KeyedView("workspace-strip", new Row("agent-workspace-strip", stripItems, stripStyle));
    }
    var workspaceStyle = new LayoutStyle(); workspaceStyle.width = LayoutAxis.grow(); workspaceStyle.childGap = 8;
    workspaceStyle.wrapMode = haxeon.ui.LayoutWrapMode.Wrap;
    rows.push(new KeyedView("workspace", new Row("agent-workspace-actions", workspaceControls, workspaceStyle)));
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
          var draft = new Button("Use as draft",null,function() {prompt=entry.text;promptRevision++;promptFocusRequested=false;frame();});
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
    var requestCards:Array<KeyedView> = [];
    requestAnchor = null;
    var retainedQuestions:Map<String, SessionQuestionForm> = [];
    var retainedRequestDetails:Map<String, Bool> = [];
    for (request in view.requests) {
      var r = request;
      var requestRows:Array<KeyedView> = [];
      var structured = r.method == "item/tool/requestUserInput" && r.questions != null && r.questions.length > 0 && r.reviewable;
      var detailExpanded = expandedRequestDetails.get(r.id) == true;
      if (detailExpanded) retainedRequestDetails.set(r.id, true);
      requestRows.push(new KeyedView(
        "request-" + r.id,
        paragraph((r.inputKind == "confirm" ? "Confirmation" : r.method == "item/tool/requestUserInput"
        ? "Input needed" : r.method == "item/fileChange/requestApproval" ? "File change approval" : r.method
        == "item/commandExecution/requestApproval" ? "Command approval" : "Additional request") + (structured ? "" : "\n" + r.detail))
      ));
      if (structured && r.detail != "") {
        requestRows.push(new KeyedView("request-detail-toggle", quietButton(detailExpanded ? "Hide request details" : "Request details", function() {
          expandedRequestDetails.set(r.id, !detailExpanded); frame();
        }, "request-detail-toggle-" + r.id)));
        if (detailExpanded) requestRows.push(new KeyedView("request-details", paragraph(r.detail)));
      }
      if (!r.reviewable) requestRows.push(new KeyedView(
        "full-" + r.id,
        paragraph("Full request exceeds this view. Review it in another compatible client.")
      ));
      if (r.method == "item/tool/requestUserInput") {
        var questions = r.questions;
        if (questions != null && questions.length > 0 && r.reviewable) {
          var form = questionForms.get(r.id);
          if (form == null) form = new SessionQuestionForm(r.id, questions, control && connectionReady, frame,
            function(json) {
              var current = getClient();
              if (current == null || !current.canControlAgents() || current.agentBusy()) return;
              var currentView = current.agentView(id), active = false;
              if (currentView != null && currentView.connectionState != "disconnected" && currentView.connectionState != "reconnecting")
                for (pending in currentView.requests) if (pending.id == r.id && pending.reviewable && pending.questions != null) active = true;
              if (active) current.agentAction(id, "answer-questions", json, r.id);
            }, view.record.provider);
          else form.update(questions, control && connectionReady);
          retainedQuestions.set(r.id, form);
          requestRows.push(new KeyedView("question-form", form));
          if (r.inputKind != null || view.record.provider == "claude") {
            var cancel = new Button("Cancel", null, function() client.agentAction(id, "decline", "", r.id));
            cancel.enabled = control;
            requestRows.push(new KeyedView("cancel-" + r.id, cancel));
          }
        } else {
        var choices = r.inputKind == "select" && r.options != null && r.options.length > 0;
        if (choices) {
          var options:Array<String> = cast r.options;
          for (index in 0...options.length) {
            var option = options[index];
            var optionStyle = new LayoutStyle(); optionStyle.width = LayoutAxis.grow(); optionStyle.height = LayoutAxis.fixed(36);
            optionStyle.padding = new Insets(10, 0, 10, 0); optionStyle.clipHorizontal = true;
            var choice = new Button(option, optionStyle, function() client.agentAction(id, "answer", option, r.id), "agent-choice-" + r.id + "-" + index);
            choice.labelView = new MiddleEllipsisText("choice-label", option, false, TextStyleOverride.text(14));
            choice.accessibilityLabel = "Choose " + option;
            choice.enabled = control && r.reviewable;
            requestRows.push(new KeyedView("choice-" + index, choice));
          }
        } else {
        if (textContext.length > 0 || imageDrafts.length > 0) requestRows.push(new KeyedView("answer-context-note-" + r.id,
          paragraph("Answer uses prompt text only; attachments stay in the composer.")));
        var answer = new Button(
          r.inputKind != null ? "Answer using prompt" : "Answer using prompt (id=value per line)",
          null,
          function() {
            var submitted = prompt, revision = promptRevision;
            client.agentAction(id, "answer", submitted, r.id, null, null, function() {
              if (promptRevision == revision && prompt == submitted) { prompt = ""; promptRevision++; }
              frame();
            });
          },
          "codex-answer-" + r.id
        );
        answer.enabled = control && r.reviewable;
        requestRows.push(new KeyedView(
          "answer-" + r.id,
          answer
        ));
        }
        if (r.inputKind != null || view.record.provider == "claude") {
          var cancel = new Button("Cancel", null, function() client.agentAction(id, "decline", "", r.id));
          cancel.enabled = control;
          requestRows.push(new KeyedView("cancel-" + r.id, cancel));
        }
        }
      } else if (r.method == "item/commandExecution/requestApproval" || r.method == "item/fileChange/requestApproval") {
        var approve = new Button(
          r.inputKind == "confirm" ? "Confirm" : "Approve once",
          null,
          function() client.agentAction(id, "approve", "", r.id),
          "codex-approve-" + r.id
        );
        approve.enabled = control && r.reviewable;
        var decline = new Button(
          r.inputKind == "confirm" ? "Cancel" : "Decline",
          null,
          function() client.agentAction(id, "decline", "", r.id),
          "codex-decline-" + r.id
        );
        decline.enabled = control;
        requestRows.push(new KeyedView(
          "approval-" + r.id,
          new Row(
            "codex-approval-" + r.id,
            [
              new KeyedView("approve", approve),
              new KeyedView("decline", decline)
            ]
          )
        ));
      } else requestRows.push(new KeyedView(
        "unsupported-" + r.id,
        paragraph("Answer this request in another compatible Codex client.")
      ));
      var requestStyle = new LayoutStyle();
      requestStyle.width = LayoutAxis.grow(0, 880);
      requestStyle.padding = new Insets(16, 14, 16, 14);
      requestStyle.childGap = 10;
      requestStyle.background = tokens.surfaceRaised;
      requestStyle.radiusTopLeft = requestStyle.radiusTopRight = requestStyle.radiusBottomLeft = requestStyle.radiusBottomRight = 10;
      var requestCard:View = new Column("agent-request-" + r.id, requestRows, requestStyle);
      if (requestCards.length == 0) requestCard = new RequestAnchor(requestCard, function(node) requestAnchor = node);
      requestCards.push(new KeyedView("request-card-" + r.id, requestCard));
    }
    questionForms = retainedQuestions;
    expandedRequestDetails = retainedRequestDetails;
    if (view.requestsOmitted != null && view.requestsOmitted > 0)
      requestCards.push(new KeyedView("requests-omitted", paragraph(view.requestsOmitted + " additional requests waiting. Resolve a displayed request to continue.")));
    var history = client.agentHistory(id);
    if (history.detached || history.resetRequired) {
      activity.push(new KeyedView("history-window-note", paragraph(history.resetRequired
        ? "This history window changed. Return to the latest messages to continue."
        : "Showing an older history window; newer messages are outside this view.")));
      activity.push(new KeyedView("history-reset", quietButton("Return to latest messages", function() {
        historyAnchor = null; historyReturnToLatest = true; client.resetAgentHistory(id); frame();
      }, "agent-history-reset")));
    }
    if (history.error != null) activity.push(new KeyedView("history-error", paragraph(history.error)));
    if (history.hasOlder && !history.resetRequired) {
      var earlier = quietButton(history.loading ? "Loading earlier messages…" : history.error != null ? "Retry earlier messages" : "Load earlier messages", function() {
        client.loadOlderAgentItems(id, function(error) {
          if (error == null) rememberHistoryAnchor();
          frame();
        });
        frame();
      }, "agent-history-earlier");
      earlier.enabled = !history.loading;
      activity.push(new KeyedView("history-earlier", earlier));
    }
    var items = view.items;
    historyNodes = [];
    if (historyAnchor != null && items != null) {
      var stillPresent = false;
      for (item in items) if (item.turn + ":" + item.id == historyAnchor.key) stillPresent = true;
      if (!stillPresent) historyAnchor = null;
    }
    if (items == null) activity.push(new KeyedView(
      "legacy",
      paragraph(view.activity == "" ? "No activity yet" : view.activity)
    ));
    else {
      var retained:Map<String, Bool> = [];
      var retainedMarkdown:Map<String, CodexMarkdownView> = [];
      var retainedDiffs:Map<String, SessionDiffView> = [];
      var retainedCopies:Map<String, String> = [];
      var retainedErrors:Map<String, String> = [], retainedErrorTokens:Map<String, String> = [];
      for (item in items) {
        var key = item.turn + ":" + item.id;
        if (contentErrorTokens.exists(key) && contentErrorTokens.get(key) != item.contentToken) { contentErrors.remove(key); contentErrorTokens.remove(key); }
        var content = loadedContent.get(key);
        if (content != null && content.token != item.contentToken) { loadedContent.remove(key); contentOrder.remove(key); contentErrors.remove(key); }
        if (markdown.exists(key)) retainedMarkdown.set(key, markdown.get(key));
        if (markdown.exists(key + ":detail")) retainedMarkdown.set(key + ":detail", markdown.get(key + ":detail"));
        if (diffs.exists(key)) retainedDiffs.set(key, diffs.get(key));
        if (expanded.get(key) == true) retained.set(key, true);
        var visibleText = content == null ? item.text : content.text;
        if (copiedMessages.get(key) == visibleText) retainedCopies.set(key, visibleText);
        if (contentErrors.exists(key)) { retainedErrors.set(key,contentErrors.get(key)); retainedErrorTokens.set(key,contentErrorTokens.get(key)); }
      }
      contentErrors = retainedErrors; contentErrorTokens = retainedErrorTokens;
      expanded = retained;
      markdown = retainedMarkdown;
      diffs = retainedDiffs;
      copiedMessages = retainedCopies;
      if (items.length == 0) {
        var emptyStyle = new LayoutStyle();
        emptyStyle.width = LayoutAxis.grow();
        emptyStyle.padding = new Insets(20, 28, 20, 28);
        emptyStyle.childGap = 8;
        emptyStyle.background = tokens.surfaceRaised;
        emptyStyle.radiusTopLeft = emptyStyle.radiusTopRight = emptyStyle.radiusBottomLeft = emptyStyle.radiusBottomRight = 12;
        activity.push(new KeyedView("empty", new Column("codex-empty", [
          new KeyedView("title", new Text("Start a conversation", null, tokens.textPrimary, TextStyleOverride.text(18))),
          new KeyedView("description", new Text("Ask " + providerName(view.record.provider) + " a question or describe a task in this workspace.", null, tokens.textSecondary))
        ], emptyStyle)));
      }
      if (view.supportsMessageContent == true && contentLoading == null) {
        var latest:Null<workspace.service.WorkspaceAgentProtocol.AgentActivityItem> = null;
        for (candidate in items) if ((candidate.kind == "agentMessage" || candidate.kind == "plan") && candidate.state == "completed") latest=candidate;
        if (latest != null && latest.truncated && latest.contentToken != null) {
          var latestKey = latest.turn + ":" + latest.id;
          if (!loadedContent.exists(latestKey) && !contentErrors.exists(latestKey)) loadContent(client,id,latest,latestKey);
        }
      }
      for (item in items) {
        var key = item.turn + ":" + item.id;
        var full = loadedContent.get(key);
        var displayText = full != null && full.token == item.contentToken ? full.text : item.text;
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
          commandStyle.childAlignY = haxeon.ui.LayoutAlignmentY.Center;
          var toggle=quietButton("",function() {expanded.set(key,expanded.get(key)!=true);frame();},"command-toggle-"+key);
          toggle.style.width=LayoutAxis.fixed(30);
          toggle.accessibilityLabel=expanded.get(key)==true ? "Hide details" : "Show details";
          toggle.leadingIcon=expanded.get(key)==true ? IconName.ChevronDown : IconName.ChevronRight;
          toggle.iconSize=16;
          var status=commandStatus(item.state);
          message.push(new KeyedView("command-" + key, new Row("codex-command-" + key, [
            new KeyedView("summary", new MiddleEllipsisText("summary",
              item.title + (summary == "" ? "" : " · " + summary), false)),
            new KeyedView("status",new Text(status,null,item.state=="failed" ? tokens.danger : tokens.textSecondary,TextStyleOverride.text(12))),
            new KeyedView("toggle",toggle)
          ], commandStyle)));
        } else if (reasoning) message.push(new KeyedView("reasoning-" + key,
          quietButton((expanded.get(key) == true ? "Hide reasoning" : "Show reasoning") + (item.state == "completed" ? "" : " · " + item.state), function() {
            expanded.set(key, expanded.get(key) != true);
            frame();
          })));
        else {
          var roleStyle = new LayoutStyle();
          roleStyle.width = LayoutAxis.grow();
          roleStyle.childGap = 8;
          var labelStyle = new LayoutStyle();
          labelStyle.width = LayoutAxis.grow();
          var role = item.kind == "userMessage" ? "You" : item.kind == "agentMessage" ? providerName(view.record.provider) : item.title + " · " + item.state;
          var roleChildren:Array<KeyedView> = [new KeyedView("label", new Text(role, labelStyle,
            item.kind == "agentMessage" ? tokens.accent : tokens.textSecondary, TextStyleOverride.text(12)))];
          if ((!tool || item.kind == "plan") && displayText != "") {
            var copyText = displayText;
            var copied = copiedMessages.get(key) == copyText;
            var copy = quietButton("", function() { context.clipboard.writeText(copyText); copiedMessages.set(key, copyText); frame(); }, "agent-copy-" + key);
            copy.accessibilityLabel = copied ? "Copied" : item.truncated && (full == null || full.partial) ? "Copy preview" : item.kind == "plan" ? "Copy plan" : "Copy message";
            copy.leadingIcon = copied ? IconName.Check : IconName.Copy;
            copy.iconSize = 16;
            roleChildren.push(new KeyedView("copy", copy));
          }
          message.push(new KeyedView("title-" + key, new Row("codex-message-heading-" + key, roleChildren, roleStyle)));
        }
        if (item.kind == "fileChange" && item.files != null && item.files.length > 0) {
          message.push(new KeyedView("files-" + key, new SessionChangeSummaryView(item.files, detail, openLink)));
        } else if (displayText != "" && ((!reasoning && !command) || expanded.get(key) == true)) {
          if (item.kind == "agentMessage" || item.kind == "plan") {
            var rendered = markdown.get(key);
            if (rendered == null) { rendered = new CodexMarkdownView(displayText, editorPalette, syntaxes, openLink,
              workspaceActions == null ? null : workspaceActions.resolveImage, frame,
              workspaceActions == null ? null : workspaceActions.previewArtifact,
              workspaceActions == null ? null : workspaceActions.loadImage); markdown.set(key, rendered); }
            rendered.update(displayText);
            message.push(new KeyedView("text-" + key, rendered));
          } else message.push(new KeyedView("text-" + key, paragraph(item.text)));
        }
        if (item.kind == "userMessage" && item.images != null) for (index in 0...item.images.length) {
          var image=item.images[index], imageId=image.id, turn=item.turn, itemId=item.id;
          var imageKey="sent-image-"+key+"-"+index;
          var opener=workspaceActions == null ? null : workspaceActions.openMessageImage;
          if(imageId==null) message.push(new KeyedView(imageKey,new Text("Sent image is unavailable",null,tokens.textSecondary)));
          else {
           var retainedId:String=cast imageId;
           message.push(new KeyedView(imageKey,new SessionMessageImageView(imageKey,retainedId,
             function(done) client.loadAgentImage(id,turn,itemId,retainedId,done),
             opener == null ? null : function(bytes) opener(turn,itemId,retainedId,bytes),frame)));
          }
        }
        if (item.kind == "imageView" || item.kind == "imageGeneration") {
          var destination=workspace.client.SessionImageActivity.target(root,view.record.cwd,item.imagePath);
          if (destination == null) message.push(new KeyedView("native-image-unavailable-" + key,
            new Text(item.imagePath == null && item.state == "inProgress" ? "Image is not available yet"
              : "Image preview is unavailable in this workspace",null,tokens.textSecondary)));
          else {
            var resolve=workspaceActions == null ? null : workspaceActions.resolveImage;
            var load=workspaceActions == null ? null : workspaceActions.loadImage;
            message.push(new KeyedView("native-image-" + key,new SessionImageView("native-image-" + key,
              item.kind == "imageView" ? "Viewed image" : "Generated image",destination,resolve,openLink,frame,load)));
          }
        }
        if (detail != "" && reasoning && expanded.get(key) == true) message.push(new KeyedView("detail-" + key, paragraph(detail)));
        if (detail != "" && command && expanded.get(key) == true) message.push(new KeyedView("detail-" + key,
          new SessionToolOutputView("tool-output-" + key,detail,item.truncated)));
        if ((detail != "" || (item.kind == "fileChange" && item.files != null && item.files.length > 0)) && !reasoning && !command) {
          message.push(new KeyedView("toggle-" + key,
            quietButton(expanded.get(key) == true ? "Hide details" : "Show details", function() {
            expanded.set(key, expanded.get(key) != true);
            frame();
          }
          )));
          if (expanded.get(key) == true) {
            if (item.kind == "fileChange") {
              var rendered = diffs.get(key);
              if (rendered == null) { rendered = new SessionDiffView(detail, openLink, item.files); diffs.set(key, rendered); }
              rendered.update(detail, item.files);
              message.push(new KeyedView("detail-" + key, rendered));
            } else message.push(new KeyedView("detail-" + key, new SessionToolOutputView("tool-output-" + key,detail,item.truncated)));
          }
        }
        if (item.truncated && (!command || expanded.get(key) == true)) {
          if ((item.kind == "agentMessage" || item.kind == "plan") && full != null && !full.partial) {}
          else if ((item.kind == "agentMessage" || item.kind == "plan") && full != null && full.partial)
            message.push(new KeyedView("truncated-" + key, paragraph("Response exceeds the 256 KiB display limit; showing its beginning.")));
          else {
            message.push(new KeyedView("truncated-" + key, paragraph(contentErrors.exists(key) ? contentErrors.get(key) : "This item is truncated in the current view.")));
            if ((item.kind == "agentMessage" || item.kind == "plan") && item.state == "completed" && view.supportsMessageContent == true && item.contentToken != null) {
              var contentLabel = item.kind == "plan" ? "plan" : "response";
              var load = quietButton(contentLoading == key ? "Loading " + contentLabel + "…" : contentErrors.exists(key) ? "Retry full " + contentLabel : "Load full " + contentLabel, function() loadContent(client,id,item,key));
              load.enabled = contentLoading == null;
              message.push(new KeyedView("load-content-" + key,load));
            }
          }
        }
        var messageStyle = new LayoutStyle();
        messageStyle.width = LayoutAxis.grow(0, 880);
        messageStyle.padding = tool ? new Insets(8, 3, 8, 3) : new Insets(16, 12, 16, 12);
        messageStyle.childGap = tool ? 4 : 8;
        messageStyle.background = item.kind == "userMessage" ? tokens.surfaceRaised : tokens.surface;
        messageStyle.radiusTopLeft = messageStyle.radiusTopRight = messageStyle.radiusBottomLeft = messageStyle.radiusBottomRight = 6;
        activity.push(new KeyedView("message-" + key, new RequestAnchor(new Column("codex-message-" + key, message, messageStyle), function(node) {
          historyNodes.set(key, node);
          if (historyAnchor != null && historyAnchor.key == key) node.onResolved(function(_) {
            var anchor = historyAnchor;
            if (anchor == null || transcriptViewport == null || transcriptViewport.resolved == null) return;
            var delta = node.globalBounds().y - transcriptViewport.globalBounds().y - anchor.y;
            if (Math.abs(delta) <= 0.5) { historyAnchor = null; return; }
            if (transcriptScroll.jumpTo(transcriptScroll.offsetX, transcriptScroll.offsetY + delta)) context.requestLayoutFeedback();
            else historyAnchor = null;
          });
        })));
      }
    }
    for (requestCard in requestCards) activity.push(requestCard);
    if (details && diagnostics) activity.push(new KeyedView("diagnostics", paragraph(view.activity)));
    if (working) {
      var workingStyle = new LayoutStyle();
      workingStyle.width = LayoutAxis.grow();
      workingStyle.padding = new Insets(16, 10, 16, 10);
      activity.push(new KeyedView("working", new Text("●  " + providerName(view.record.provider) + " is working…", workingStyle, tokens.accent)));
    }

    var error = client.agentError() == null ? view.error : client.agentError();
    if ((view.record.state == "reconnect-failed" || connectionState == "disconnected")
      && error == view.error && !(details && diagnostics)) error = null;
    if (error != null) activity.push(new KeyedView("error", paragraph(error)));
    var activityStyle = new LayoutStyle();
    activityStyle.width = LayoutAxis.grow();
    activityStyle.childAlignX = haxeon.ui.LayoutAlignmentX.Center;
    activityStyle.childGap = 12;
    activityStyle.padding = new Insets(0, 12, 0, 16);
    if (view.requests.length > 0) {
      var requestCount = view.requests.length + (view.requestsOmitted == null ? 0 : view.requestsOmitted);
      var noticeStyle = new LayoutStyle(); noticeStyle.width = LayoutAxis.grow(); noticeStyle.childGap = 8;
      noticeStyle.childAlignY = haxeon.ui.LayoutAlignmentY.Center; noticeStyle.wrapMode = haxeon.ui.LayoutWrapMode.Wrap;
      var noticeLabel = new LayoutStyle(); noticeLabel.width = LayoutAxis.grow();
      rows.push(new KeyedView("request-notice", new Row("agent-request-notice", [
        new KeyedView("label", new Text("Input needed · " + requestCount + (requestCount == 1 ? " request" : " requests"), noticeLabel, tokens.textSecondary)),
        new KeyedView("review", quietButton("Review request", function() {
          if (requestAnchor == null || transcriptViewport == null || requestAnchor.resolved == null || transcriptViewport.resolved == null) return;
          var target = requestAnchor.globalBounds(), viewport = transcriptViewport.globalBounds();
          transcriptScroll.jumpTo(transcriptScroll.offsetX, transcriptScroll.offsetY + target.y - viewport.y - 4);
          frame();
        }, "agent-review-request"))
      ], noticeStyle)));
    }
    rows.push(new KeyedView("activity", new AgentTranscript(new Column("codex-items", activity, activityStyle), style, transcriptScroll, frame,
      function(node) transcriptViewport = node, historyAnchor != null, historyReturnToLatest,
      function() historyReturnToLatest = false)));
    if (transcriptScroll.maxScrollY - transcriptScroll.offsetY > 2) rows.push(new KeyedView("jump-latest",
      new Button("Jump to latest", null, function() {
        transcriptScroll.jumpTo(transcriptScroll.offsetX, transcriptScroll.maxScrollY);
        frame();
      }, "agent-jump-latest")));
    var suggestions = (canSend || (canQueue && view.requests.length == 0)) && !dismissSuggestions ? AgentCommandCompletion.matches(view.commands,prompt) : [];
    if (suggestionIndex >= suggestions.length) suggestionIndex = 0;
    var completionRows:Array<KeyedView> = [];
    function complete(index:Int):Void {
      if (index < 0 || index >= suggestions.length) return;
      prompt = AgentCommandCompletion.insert(suggestions[index]);
      promptRevision++;
      suggestionIndex = 0;dismissSuggestions = false;promptFocusRequested = false;
      frame();
    }
    for (index in 0...suggestions.length) {
      var choice = index;
      var label = AgentCommandCompletion.label(suggestions[index],StringTools.startsWith(prompt,"$"));
      completionRows.push(new KeyedView("suggestion-"+index,new Button((index == suggestionIndex ? "› " : "")+label,null,
        function() complete(choice),"agent-command-suggestion-"+index)));
    }
    var sendStyle = new LayoutStyle(); sendStyle.width = LayoutAxis.fixed(34); sendStyle.height = LayoutAxis.fixed(34);
    sendStyle.padding = new Insets(9, 9, 9, 9);
    sendStyle.radiusTopLeft = sendStyle.radiusTopRight = sendStyle.radiusBottomLeft = sendStyle.radiusBottomRight = 17;
    var send = new Button("", sendStyle, function() submitAction(piActive ? "queue" : "prompt"), "codex-send");
    send.accessibilityLabel = piActive ? "Queue message" : "Send";
    send.leadingIcon = IconName.ArrowUp; send.iconSize = 16;
    send.variant = ButtonVariant.Primary;
    send.enabled = (piActive ? canQueue : canSend) && imagesSupported && !contextLoading && !imageUploading && promptBytes <= submitLimit && (StringTools.trim(prompt) != "" || imageDrafts.length > 0);
    var hint = new Text((piActive ? (view.requests.length > 0 ? "Answer the request, or use Queue / Steer" : "Enter to queue · Shift+Enter for newline") : "Enter to send · Shift+Enter for newline") + (view.commands == null ? "" : " · / commands · $ skills"), paragraph("").style, tokens.mutedText);
    var footerControls:Array<KeyedView> = [];
    if (piActive) {
      var steer = new Button("Steer now",null,function() submitAction("steer"),"agent-steer");
      steer.enabled = canSteer && imagesSupported && !contextLoading && !imageUploading && promptBytes <= 4096 && (StringTools.trim(prompt) != "" || imageDrafts.length > 0);
      footerControls.push(new KeyedView("steer",steer));
    }
    footerControls.push(new KeyedView("send",send));
    var settingThread = view.record.thread;
    var settingValid = function() {
      var current = getClient();
      if (current == null || current != client || !current.canControlAgents() || current.agentBusy()) return false;
      var currentCatalog = current.agents();
      if (currentCatalog == null || currentCatalog.root != root) return false;
      var latest = current.agentView(id);
      return latest != null && latest.record.thread == settingThread && latest.record.state != "working";
    };
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
      var currentModel = findModel(view.models, view.currentModel);
      var currentModelLabel = currentModel != null ? currentModel.name : view.currentModel == null || view.currentModel == "" ? "Current model" : view.currentModel;
      var chosenModel = findModel(view.models, selectedModel);
      var modelLabel = chosenModel != null ? chosenModel.name : selectedModel != "" ? selectedModel : currentModelLabel;
      var chooser = quietButton(modelLabel + " ▾", function() {}, "codex-model");
      chooser.accessibilityLabel = "Conversation model"; chooser.ellipsizeLabel = true;
      chooser.leadingView = new SessionLineIcon("model", tokens.textSecondary);
      chooser.style.width = LayoutAxis.fixed(145); chooser.style.padding = new Insets(4, 4, 4, 4); chooser.style.childGap = 4;
      chooser.enabled = control && !working;
      chooser.onClickEvent = function(event) {
        var items:Array<MenuItem> = [];
        items.push(new MenuItem("current", currentModelLabel, function() {
          if (settingValid()) { client.agentAction(id, "model-settings", "", null, null, null); frame(); }
        }));
        for (model in view.models) {
          var choice = model;
          items.push(new MenuItem(choice.model, choice.name, function() {
            if (settingValid()) { client.agentAction(id, "model-settings", "", null, choice.model, null); frame(); }
          }));
        }
        showMenu(items, event, settingValid);
      };
      modelControls.push(new KeyedView("chooser", new SettingMenuButton(chooser, modelLabel)));
      if (view.modelsNext != null) {
        moreModels = new Button("More models", null, function() client.agentAction(id, "models", "", view.modelsNext));
        moreModels.enabled = control && !working;
      }
    }
    var defaultEffortLabel = selectedModel == "" && view.currentEffort != null
      ? "Keep current (" + view.currentEffort + ")" : "Model default";
    var availableEfforts:Array<String> = effortModel == null || effortModel.supportedEfforts == null
      ? [] : effortModel.supportedEfforts;
    var effortText = selectedEffort != "" ? effortLabel(selectedEffort)
      : (selectedModel == "" && view.currentEffort != null ? effortLabel(view.currentEffort) : "Model default");
    if (StringTools.endsWith(effortText, " effort")) effortText = effortText.substr(0, effortText.length - 7);
    var effortChooser = quietButton(effortText + " ▾", function() {}, "codex-effort");
    effortChooser.accessibilityLabel = "Reasoning effort"; effortChooser.ellipsizeLabel = true;
    effortChooser.leadingView = new SessionLineIcon("reasoning", tokens.textSecondary);
    effortChooser.style.width = LayoutAxis.fixed(90);
    effortChooser.style.padding = new Insets(4, 4, 4, 4); effortChooser.style.childGap = 4;
    effortChooser.enabled = control && !working && effortModel != null && availableEfforts.length > 0;
    effortChooser.onClickEvent = function(event) {
      var expectedModel = selectedModel;
      var expectedCurrentModel = view.currentModel;
      var effortValid = function() {
        if (!settingValid()) return false;
        var latest = client.agentView(id);
        return latest != null && (latest.record.preferredModel == null ? "" : latest.record.preferredModel) == expectedModel
          && (expectedModel != "" || latest.currentModel == expectedCurrentModel);
      };
      var items:Array<MenuItem> = [new MenuItem("model-default", defaultEffortLabel, function() {
        if (effortValid()) { client.agentAction(id, "model-settings", "", null, expectedModel == "" ? null : expectedModel, null); frame(); }
      })];
      for (effort in availableEfforts) {
        var choice = effort;
        items.push(new MenuItem("effort-" + choice, effortLabel(choice), function() {
          if (effortValid()) { client.agentAction(id, "model-settings", "", null, expectedModel == "" ? null : expectedModel, choice); frame(); }
        }));
      }
      showMenu(items, event, effortValid);
    };
    modelControls.push(new KeyedView("effort", new SettingMenuButton(effortChooser, effortText)));
    if (moreModels != null) modelControls.push(new KeyedView("more", moreModels));
    if (view.record.provider == "pi") {
      var refresh = new Button(view.commandsLoading == true ? "Loading commands…" : "Refresh commands",null,
        function() client.agentAction(id,"commands","",null),"agent-refresh-commands");
      refresh.enabled = canSend && view.commandsLoading != true;
      modelControls.push(new KeyedView("commands",refresh));
    }
    var modelControlsStyle = new LayoutStyle();
    modelControlsStyle.width = LayoutAxis.grow(); modelControlsStyle.childGap = 6;
    modelControlsStyle.childAlignY = haxeon.ui.LayoutAlignmentY.Center;
    modelControlsStyle.wrapMode = haxeon.ui.LayoutWrapMode.Wrap;
    var composerStyle = new LayoutStyle();
    composerStyle.width = LayoutAxis.grow();
    composerStyle.childGap = 8;
    composerStyle.padding = new Insets(14, 12, 14, 12);
    composerStyle.background = tokens.surfaceRaised;
    composerStyle.radiusTopLeft = composerStyle.radiusTopRight = composerStyle.radiusBottomLeft = composerStyle.radiusBottomRight = 8;
    if (workspaceStrip != null) composerStyle.radiusBottomLeft = composerStyle.radiusBottomRight = 0;
    // Capture on a stable parent so the field's own patch updates retain keyboard behavior.
    var promptStyle = new LayoutStyle();
    promptStyle.width = LayoutAxis.grow();
    var promptNode = new Column("codex-prompt-keys", [new KeyedView("field", field)], promptStyle).build(context);
    promptNode.walk(function(child) {
      if (child.focusable && child.semantics != null && (child.semantics.label == "Codex prompt" || child.semantics.label == "Claude prompt" || child.semantics.label == "Pi prompt" || child.semantics.label == "Exosuit prompt")) {
        child.onResolved(function(_) {
          if (!promptFocusRequested && child.enabled) promptFocusRequested = context.requestFocus(child.id);
        });
      }
    });
    promptNode.on(UiEventKind.KeyDown, function(event) {
      if (event.key == UiKey.V && (event.modifiers & (UiModifier.Control | UiModifier.Super)) != 0
          && (event.modifiers & UiModifier.Alt) == 0 && workspaceActions != null && workspaceActions.pasteImage != null
          && view.supportsImageUpload == true && control && connectionReady) {
        var readClipboard:Void->{bytes:Null<haxe.io.Bytes>, error:Null<String>} = cast workspaceActions.pasteImage;
        var pasted = readClipboard();
        if (pasted.bytes != null || pasted.error != null) {
          event.preventDefault(); event.stopImmediatePropagation();
          if (imageUploading) imageError = "Wait for the current image upload";
          else if (imageDrafts.length >= 2) imageError = "Remove an image before pasting another";
          else if (pasted.error != null) imageError = pasted.error;
          else {
            var generation = ++imageGeneration;
            imageUploading = true; imageError = null;
            uploadImage(client,id,imageThread,"Pasted image.png",cast pasted.bytes,generation);
          }
          frame(); return;
        }
      }
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
    var composerFrame = new LayoutStyle();
    composerFrame.width = LayoutAxis.grow(0, 880);
    composerFrame.padding = new Insets(1, 1, 1, 1);
    composerFrame.childGap = workspaceStrip == null ? 0 : 1;
    composerFrame.background = tokens.border;
    composerFrame.radiusTopLeft = composerFrame.radiusTopRight = composerFrame.radiusBottomLeft = composerFrame.radiusBottomRight = 8;
    var contextRows:Array<KeyedView> = [];
    var contextActions:Array<KeyedView> = [];
    if (workspaceActions != null && workspaceActions.chooseImage != null && view.supportsImageUpload == true) {
      var chooseImage:((Null<String>, Null<haxe.io.Bytes>, Null<String>)->Void)->Void = cast workspaceActions.chooseImage;
      var imageAction = quietButton("", function() {
        if (imageUploading) { imageGeneration++; imageUploading = false; frame(); return; }
        var generation = ++imageGeneration;
        imageUploading = true; imageError = null; frame();
        chooseImage(function(name, bytes, error) {
          if (generation != imageGeneration) return;
          if (!imageSessionCurrent(client,id,imageThread)) {imageUploading=false;imageError="Session changed while choosing an image";frame();return;}
          if (error != null || bytes == null || name == null) {
            imageUploading = false; imageError = error; frame(); return;
          }
          uploadImage(client,id,imageThread,name,bytes,generation);
        });
      }, "agent-add-image");
      imageAction.accessibilityLabel = imageUploading ? "Cancel image upload" : imageError == null ? "Add image" : "Try image again";
      if (imageUploading) imageAction.leadingIcon = IconName.Close;
      else imageAction.leadingView = new SessionLineIcon("attachment", tokens.textSecondary);
      imageAction.iconSize = 16; imageAction.style.width = LayoutAxis.fixed(34);
      imageAction.style.height = LayoutAxis.fixed(34); imageAction.style.padding = new Insets(9, 9, 9, 9);
      imageAction.enabled = control && connectionReady && (imageUploading || imageDrafts.length < 2);
      contextActions.push(new KeyedView("image-action", imageAction));
    }
    for (index in 0...imageDrafts.length) {
      var image = imageDrafts[index], imageIndex = index;
      var imageStyle = new LayoutStyle(); imageStyle.width = LayoutAxis.grow(); imageStyle.childGap = 8;
      imageStyle.childAlignY = haxeon.ui.LayoutAlignmentY.Center;
      var imageLabel = new MiddleEllipsisText("image-label-" + index, image.name + " · image attached", true,
        TextStyleOverride.text(12, null, tokens.textSecondary));
      var removeImage = quietButton("", function() {
        imageDrafts.splice(imageIndex, 1); contextRevision++; client.removeAgentImage(id, image.id); frame();
      }, "agent-remove-image-" + index);
      removeImage.accessibilityLabel = "Remove image";
      removeImage.leadingIcon = IconName.Close; removeImage.iconSize = 14;
      removeImage.style.width = LayoutAxis.fixed(30);
      contextRows.push(new KeyedView("image-" + image.key, new Row("agent-image-" + image.key, [
        new KeyedView("thumbnail", new SessionDraftThumbnail("draft-preview-" + image.key, image.name, image.bytes)),
        new KeyedView("name", imageLabel), new KeyedView("remove", removeImage)
      ], imageStyle)));
    }
    if (!imagesSupported) contextRows.push(new KeyedView("images-unavailable", new Text("Image input is unavailable; remove images or reconnect.", null, tokens.textSecondary)));
    if (imageUploading) contextRows.push(new KeyedView("image-progress", new Text("Adding image…", null, tokens.textSecondary)));
    if (imageError != null) contextRows.push(new KeyedView("image-error", new Text(imageError, null, tokens.danger)));
    if (workspaceActions != null && workspaceActions.readContext != null) {
      var readContext:(String, (Null<String>, Null<String>)->Void)->Void = cast workspaceActions.readContext;
      var addContext = quietButton("", function() {
        addingContext = !addingContext; contextGeneration++; contextLoading = false; contextError = null; frame();
      }, "agent-add-context");
      addContext.accessibilityLabel = addingContext ? "Cancel adding text" : "Add workspace text";
      addContext.leadingIcon = IconName.NewFile; addContext.iconSize = 16; addContext.style.width = LayoutAxis.fixed(34);
      addContext.style.height = LayoutAxis.fixed(34); addContext.style.padding = new Insets(9, 9, 9, 9);
      addContext.enabled = control && connectionReady;
      contextActions.push(new KeyedView("add", addContext));
      if (addingContext) {
        var pathStyle = new LayoutStyle(); pathStyle.width = LayoutAxis.grow(); pathStyle.height = LayoutAxis.fixed(32);
        var pathField = new TextField("agent-context-path", contextPath, function(value) { contextPath = value; contextError = null; frame(); }, pathStyle);
        pathField.label = "Workspace text path"; pathField.placeholder = "Path relative to session directory";
        pathField.enabled = !contextLoading;
        contextRows.push(new KeyedView("path", pathField));
        var load = quietButton(contextLoading ? "Reading…" : "Include text", function() {
          var path = StringTools.trim(contextPath);
          if (path == "" || ~/[\x00-\x1f\x7f]/.match(path)) { contextError = "Enter a valid workspace path."; frame(); return; }
          var generation = ++contextGeneration;
          contextLoading = true; contextError = null; frame();
          readContext(path, function(value, error) {
            if (generation != contextGeneration) return;
            contextLoading = false;
            if (error != null || value == null) contextError = error == null ? "Could not read workspace text" : error;
            else if (!validContextText(value))
              contextError = "Only UTF-8 text files can be included.";
            else if (textContext.length >= 2 || haxe.io.Bytes.ofString(value).length > 4096)
              contextError = "Add up to two text files of at most 4096 bytes each.";
            else {
              textContext.push({path:path, text:value}); contextRevision++; contextPath = ""; addingContext = false;
            }
            frame();
          });
        }, "agent-include-context");
        load.enabled = !contextLoading && StringTools.trim(contextPath) != "" && textContext.length < 2;
        contextRows.push(new KeyedView("load", load));
      }
    }
    for (index in 0...textContext.length) {
      var file = textContext[index], fileIndex = index;
      var fileStyle = new LayoutStyle(); fileStyle.width = LayoutAxis.grow(); fileStyle.childGap = 8;
      fileStyle.childAlignY = haxeon.ui.LayoutAlignmentY.Center;
      var pathLabel = new MiddleEllipsisText("context-file-label-" + index, file.path + " · included as text", true,
        TextStyleOverride.text(12, null, tokens.textSecondary));
      var removeText = quietButton("", function() {
        textContext.splice(fileIndex, 1); contextRevision++; frame();
      }, "agent-remove-context-" + index);
      removeText.accessibilityLabel = "Remove";
      removeText.leadingIcon = IconName.Close; removeText.iconSize = 14;
      removeText.style.width = LayoutAxis.fixed(30);
      contextRows.push(new KeyedView("file-" + index, new Row("agent-context-file-" + index, [
        new KeyedView("path", pathLabel), new KeyedView("remove", removeText)
      ], fileStyle)));
    }
    if (contextError != null) contextRows.push(new KeyedView("error", new Text(contextError, null, tokens.danger)));
    if (promptBytes > submitLimit) contextRows.push(new KeyedView("limit", new Text("Message and included text exceed the " + submitLimit + " byte limit.", null, tokens.danger)));
    modelControls.push(new KeyedView("permissions", new SettingMenuButton(permissions, permissionLabel)));
    var spacerStyle = new LayoutStyle(); spacerStyle.width = LayoutAxis.grow();
    var trailing:Array<KeyedView> = [new KeyedView("spacer", new Column("composer-spacer", [], spacerStyle))];
    for (action in contextActions) trailing.push(action);
    for (action in footerControls) trailing.push(action);
    var trailingStyle = new LayoutStyle(); trailingStyle.width = LayoutAxis.grow(piActive ? 170 : 110); trailingStyle.childGap = 6;
    trailingStyle.childAlignY = haxeon.ui.LayoutAlignmentY.Center;
    modelControls.push(new KeyedView("trailing", new Row("composer-trailing", trailing, trailingStyle)));
    var composerChildren:Array<KeyedView> = [new KeyedView("content", new Column("codex-composer", [
      new KeyedView("prompt", new CodexPromptNode(promptNode)),
      new KeyedView("context", new Column("agent-context", contextRows)),
      new KeyedView("suggestions", new Column("agent-command-suggestions",completionRows)),
      new KeyedView("commands-error", new Text(view.commandsError == null ? "" : view.commandsError)),
      new KeyedView("models", new Row("codex-model-controls", modelControls, modelControlsStyle))
    ], composerStyle))];
    if (workspaceStrip != null) composerChildren.push(workspaceStrip);
    rows.push(new KeyedView("composer", new Column("codex-composer-frame", composerChildren, composerFrame)));
    if (piActive) rows.push(new KeyedView("composer-hint", hint));
    var viewport = new LayoutStyle();
    viewport.height = LayoutAxis.grow(MIN_SESSION_HEIGHT + inputStyle.height.value - 56);
    viewport.width = LayoutAxis.grow();
    viewport.childAlignX = haxeon.ui.LayoutAlignmentX.Center;
    viewport.background = tokens.surface;
    viewport.padding = new Insets(20, 16, 20, 16);
    viewport.childGap = 12;
    // Preserve a usable activity viewport. When the header and composer cannot
    // fit, scroll the whole session rather than clipping its action controls.
    var scrollStyle = new LayoutStyle();
    scrollStyle.height = LayoutAxis.grow();
    scrollStyle.width = LayoutAxis.grow();
    scrollStyle.background = tokens.surface;
    var session = new ScrollView("codex-session-viewport", new Column("codex-session", rows, viewport), scrollStyle);
    session.fillViewport = true;
    return session.build(context);
  }
}

/** Show the session's full directory in a tooltip over the worktree menu button. */
private class SessionDirectoryTooltip implements View {
  final button:Button;
  final path:String;
  public function new(button:Button, path:String) { this.button = button; this.path = path; }
  public function build(context:BuildContext):RenderNode {
    var tip = new TabTooltip("session-directory-tooltip", new SettingMenuButton(button, path), new Text(path),
      function() return new haxeon.ui.Rect(0, 0, context.viewportWidth, context.viewportHeight),
      config.Settings.DEFAULT_TOOLTIP_DELAY, haxeon.ui.widgets.overlays.TooltipPlacement.Above);
    tip.fillAnchor = true;
    var node = tip.build(context);
    node.layout.style.width = LayoutAxis.grow(124, 220);
    return node;
  }
}

/** Expose the selected setting and menu affordance on the native button. */
private class SettingMenuButton implements View {
  final button:Button;
  final value:String;
  public function new(button:Button, value:String) { this.button = button; this.value = value; }
  public function build(context:BuildContext):RenderNode {
    var node = button.build(context);
    if (node.semantics != null) {
      node.semantics.value = value;
      node.semantics.states |= haxeon.ui.semantics.AccessibilityState.HasPopup;
    }
    return node;
  }
}

private class CodexPromptNode implements View {
  final node:RenderNode;
  public function new(node:RenderNode) this.node = node;
  public function build(context:BuildContext):RenderNode return node;
}

private class RequestAnchor implements View {
  final child:View;
  final capture:RenderNode->Void;
  public function new(child:View, capture:RenderNode->Void) { this.child = child; this.capture = capture; }
  public function build(context:BuildContext):RenderNode { var node = child.build(context); capture(node); return node; }
}

/** History has its own scroll extent; its natural height must not push the composer out of the viewport. */
private class AgentTranscript implements View {
  final content:View;
  final style:LayoutStyle;
  final controller:ScrollController;
  final frame:Void->Void;
  final capture:RenderNode->Void;
  final preserveAnchor:Bool;
  final forceFollow:Bool;
  final followed:Void->Void;
  public function new(content:View, style:LayoutStyle, controller:ScrollController, frame:Void->Void, capture:RenderNode->Void, preserveAnchor:Bool, forceFollow:Bool, followed:Void->Void) {this.content = content;this.style = style;this.controller = controller;this.frame = frame;this.capture = capture;this.preserveAnchor = preserveAnchor;this.forceFollow = forceFollow;this.followed = followed;}
  public function build(context:BuildContext):RenderNode {
    var node:Null<RenderNode> = null;
    // Follow new output only while the reader is already at the bottom.
    var follow = forceFollow || (!preserveAnchor && controller.maxScrollY - controller.offsetY <= 2);
    var scroll = new ScrollView("codex-activity",content,style, haxeon.ui.widgets.scroll.ScrollAxis.Vertical, controller);
    scroll.onScroll = function(_) frame();
    scroll.contentExtentProvider = function(width,height) {
      var geometry = node == null || node.children.length == 0 ? null : node.children[0].resolved;
      return {width:width,height:geometry == null ? height : Math.max(geometry.height,geometry.contentBounds.y+geometry.contentBounds.height)};
    };
    node = scroll.build(context);
    capture(node);
    node.on(UiEventKind.KeyDown, function(_) frame());
    node.on(UiEventKind.PointerUp, function(_) frame());
    if (node.children.length > 0) node.children[0].onResolved(function(_) {
      if (follow && controller.jumpTo(controller.offsetX, controller.maxScrollY)) context.requestLayoutFeedback();
      if (forceFollow) followed();
    });
    return node;
  }
}
