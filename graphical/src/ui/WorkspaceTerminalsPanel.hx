package ui;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Insets;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ComboBox;
import haxeon.ui.widgets.controls.SelectOption;
import haxeon.ui.widgets.text.TextField;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.collections.VirtualList;
import haxeon.ui.widgets.scroll.ScrollController;
import workspace.client.WorkspaceTerminalCatalogClient;
import workspace.service.WorkspaceTerminalProtocol;

private class TerminalDraft {
  public final base:TerminalRecord;
  public var name:String;
  public var group:String;
  public function new(base:TerminalRecord) {
    this.base = base;
    name = base.name;
    group = base.group;
  }
  public function dirty():Bool return name != base.name || group != base.group;
}
/** A view of service-owned resources, independent of the editor's open tabs. */
class WorkspaceTerminalsPanel implements View {
  final client:WorkspaceTerminalCatalogClient;
  final open:TerminalRecord -> Bool;
  final forget:TerminalRecord -> Void;
  final requestFrame:Void -> Void;
  final drafts:Map<String, TerminalDraft> = [];
  final scroll = new ScrollController();
  public function new(
    client:WorkspaceTerminalCatalogClient,
    open:TerminalRecord -> Bool,
    forget:TerminalRecord -> Void,
    requestFrame:Void -> Void
  ) {
    this.client = client;
    this.open = open;
    this.forget = forget;
    this.requestFrame = requestFrame;
  }
  static function fill():LayoutStyle {
    var s = new LayoutStyle();
    s.width = LayoutAxis.grow();
    s.height = LayoutAxis.grow();
    return s;
  }
  public function build(context:BuildContext):RenderNode {
    var catalog = client.terminalCatalog();
    var rows:Array<KeyedView> = [new KeyedView("refresh", new Button("Refresh", null, function() {
      client.refreshTerminals(true);
      requestFrame();
    }, "terminal-catalog-refresh"))];
    var failure = client.terminalCatalogError();
    if (failure != null) rows.push(new KeyedView("error", new Text(failure)));
    if (catalog == null) rows.push(new KeyedView(
      "empty",
      new Text(failure == null ? "Connecting to workspace terminals…" : "No session list available")
    ));
    else {
      var live:Map<String, Bool> = [];
      for (record in catalog.terminals) live.set(record.id, true);
      for (id in[for (id in drafts.keys()) id]) if (!live.exists(id)) drafts.remove(id);
      if (catalog.terminals.length == 0) rows.push(new KeyedView("empty", new Text("No workspace terminals yet")));
      rows.push(new KeyedView("sessions",
        new VirtualList("workspace-terminal-records", catalog.terminals.length, 132, function(index) {
        var record = catalog.terminals[index];
        var draft = drafts.get(record.id);
        if (draft == null || !draft.dirty() || draft.base.cwd != record.cwd
          || draft.base.instance != record.instance ||(draft.name == record.name && draft.group == record.group)) {
          draft = new TerminalDraft(record);
          drafts.set(record.id, draft);
        }
        var groupName = record.group;
        for (group in catalog.groups) if (group.id == record.group) groupName = group.name;
        var inputStyle = new LayoutStyle();
        inputStyle.width = LayoutAxis.grow();
        var field = new TextField("terminal-name:" + record.id, draft.name, function(value) {
          draft.name = value;
          requestFrame();
        }, inputStyle);
        field.enabled = !client.terminalCatalogBusy();
        field.label = "Session name";
        var options = [for (group in catalog.groups) new SelectOption<String>(group.id, group.name, group.id)];
        var select = new ComboBox<String>("terminal-group:" + record.id, options, draft.group, function(value) {
          draft.group = value;
          requestFrame();
        }
        );
        select.enabled = !client.terminalCatalogBusy();
        var save = new Button("Save name/group", null, function() {
          client.renameTerminal(draft.base, draft.name, draft.group);
          requestFrame();
        }, "terminal-rename:" + record.id);
        save.enabled = draft.dirty() && !client.terminalCatalogBusy();
        var reload = new Button("Reload", null, function() {
          drafts.set(record.id, new TerminalDraft(record));
          requestFrame();
        }, "terminal-reload:" + record.id);
        reload.enabled = draft.dirty() && !client.terminalCatalogBusy();
        var reopen = new Button("Open", null, function() open(record), "terminal-open:" + record.id);
        reopen.enabled = record.available && !client.terminalCatalogBusy();
        var stop = new Button("Stop", null, function() {
          client.stopTerminal(record);
          requestFrame();
        }, "terminal-stop:" + record.id);
        stop.enabled = record.available && record.state == "running" && !client.terminalCatalogBusy();
        var remove = new Button("Remove", null, function() forget(record), "terminal-forget:" + record.id);
        remove.enabled = record.state != "running" && record.state != "starting" && !client.terminalCatalogBusy();
        var rowStyle = new LayoutStyle();
        rowStyle.width = LayoutAxis.grow();
        rowStyle.height = LayoutAxis.fixed(132);
        rowStyle.padding = new Insets(4, 8, 4, 8);
        return new Column(
          "terminal-record:" + record.id,
          [
            new KeyedView(
              "summary",
              new Text(groupName + " · " + record.state +(record.available
          ? "" : " · unavailable") + " · " + record.cwd)
        ),
          new KeyedView(
            "name",
            new Row(
              "terminal-name-row:" + record.id,
              [
                new KeyedView(
                  "name",
                  field
                ),
                new KeyedView(
                  "save",
                  save
                ),
                new KeyedView(
                  "reload",
                  reload
                )
              ]
            )
          ),
          new KeyedView(
            "actions",
            new Row(
              "terminal-record-actions:" + record.id,
              [
                new KeyedView(
                  "group",
                  select
                ),
                new KeyedView(
                  "open",
                  reopen
                ),
                new KeyedView(
                  "stop",
                  stop
                ),
                new KeyedView(
                  "remove",
                  remove
                )
              ]
            )
          )
        ],
          rowStyle
        );
      }, fill(), null, scroll)));
    }
    return new Column("workspace-terminal-browser", rows, fill()).build(context);
  }
}
