package ui;

import haxeon.ui.Color;
import haxeon.ui.FontFamily;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.scroll.ScrollAxis;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextArea;
import workspace.client.SessionDiff;
import workspace.client.SessionDiff.SessionDiffFile;
import workspace.service.WorkspaceAgentProtocol.AgentFileChange;

/** Unified diff presentation; the raw input is retained for exact copying. */
class SessionDiffView implements View {
  var source:String;
  var copySource:String;
  var reportedFiles:Null<Array<AgentFileChange>>;
  final openLink:Null<String->Void>;
  public function new(source:String, ?openLink:String->Void, ?reportedFiles:Array<AgentFileChange>, ?copySource:String) {
    this.source = source; this.copySource = copySource == null ? source : copySource; this.openLink = openLink; this.reportedFiles = reportedFiles;
  }
  public function update(source:String, ?reportedFiles:Array<AgentFileChange>, ?copySource:String):Void {
    this.source = source; this.copySource = copySource == null ? source : copySource; this.reportedFiles = reportedFiles;
  }

  static function action(label:String, handler:Void->Void, key:String):Button {
    var style = new LayoutStyle(); style.height = LayoutAxis.fixed(30); style.padding = new Insets(8, 4, 8, 4);
    var button = new Button(label, style, handler, key); button.variant = ButtonVariant.Navigation;
    button.classes.push("viewport-tool"); return button;
  }

  public function build(context:BuildContext):RenderNode {
    var tokens = context.theme.tokens, rows:Array<KeyedView> = [];
    var copy = action("", function() context.clipboard.writeText(copySource), "copy-diff");
    copy.accessibilityLabel = "Copy diff"; copy.leadingIcon = IconName.Copy; copy.iconSize = 16;
    var top = new LayoutStyle(); top.width = LayoutAxis.grow(); top.childGap = 8;
    var title = new LayoutStyle(); title.width = LayoutAxis.grow();
    rows.push(new KeyedView("heading", new Row("diff-heading", [
      new KeyedView("label", new Text("Changes", title, tokens.textSecondary, TextStyleOverride.text(12))),
      new KeyedView("copy", copy)
    ], top)));
    var files:Array<SessionDiffFile> = [];
    var truncations:Array<Bool> = [];
    var invalidSlice = false;
    if (reportedFiles != null && reportedFiles.length > 0) {
      for (reported in reportedFiles) {
        if (reported.length == 0 && reported.truncated) continue;
        if (reported.offset < 0 || reported.length < 0 || reported.offset > source.length || reported.length > source.length - reported.offset) { invalidSlice = true; continue; }
        var lines:Array<workspace.client.SessionDiff.SessionDiffLine> = [];
        for (part in SessionDiff.parse(source.substring(reported.offset, reported.offset + reported.length)))
          for (line in part.lines) lines.push(line);
        var validPath = workspace.client.SessionLinkTarget.parse(reported.path) == null ? null : reported.path;
        files.push({title: reported.kind + " " + reported.path, path: validPath, lines: lines});
        truncations.push(reported.truncated);
      }
    }
    // Older or malformed metadata must never make the original patch disappear.
    if (files.length == 0) files = SessionDiff.parse(source);
    for (index in 0...files.length) {
      var file = files[index], fileIndex = index;
      var collapsed = context.state(context.id("diff-collapsed-" + index), false);
      var additions = 0, removals = 0;
      for (line in file.lines) { if (line.kind == "added") additions++; else if (line.kind == "removed") removals++; }
      var fileRows:Array<KeyedView> = [];
      var fileHeader = new LayoutStyle(); fileHeader.width = LayoutAxis.grow(); fileHeader.childGap = 6;
      var toggle = action((collapsed.value == true ? "▸ " : "▾ ") + file.title, function() {
        collapsed.update(collapsed.value != true);
      }, "diff-file-toggle-" + index);
      toggle.style.width = LayoutAxis.grow(); toggle.ellipsizeLabel = true;
      var header:Array<KeyedView> = [new KeyedView("toggle", toggle),
        new KeyedView("counts", new Text("+" + additions + "  −" + removals
          + (index < truncations.length && truncations[index] ? " · partial" : ""), null, tokens.textSecondary, TextStyleOverride.text(12)))];
      if (file.path != null && openLink != null) {
        var path = file.path;
        var navigate:String->Void = cast openLink;
        header.push(new KeyedView("open", action("Open file", function() navigate(path), "diff-open-" + index)));
      }
      fileRows.push(new KeyedView("header", new Row("diff-file-header-" + index, header, fileHeader)));
      if (collapsed.value != true) {
        var lineRows:Array<KeyedView> = [], longest = 0;
        for (line in file.lines) if (line.text.length > longest) longest = line.text.length;
        var contentWidth = Math.max(320, longest * 8 + 95);
        var limit = Std.int(Math.min(file.lines.length, 500));
        for (lineIndex in 0...limit) {
          var line = file.lines[lineIndex];
          var color = line.kind == "added" ? tokens.success : line.kind == "removed" ? tokens.danger : tokens.textSecondary;
          var tint = line.kind == "added" || line.kind == "removed" ? Color.rgba(color.red, color.green, color.blue, 0.12) : tokens.surfaceSunken;
          var lineStyle = new LayoutStyle(); lineStyle.width = LayoutAxis.grow(contentWidth); lineStyle.height = LayoutAxis.fixed(24); lineStyle.background = tint;
          var numberStyle = new LayoutStyle(); numberStyle.width = LayoutAxis.fixed(72); numberStyle.padding = new Insets(6, 3, 4, 3);
          var lineTextStyle = new LayoutStyle(); lineTextStyle.width = LayoutAxis.grow(); lineTextStyle.height = LayoutAxis.fixed(24); lineTextStyle.padding = new Insets(2, 3, 4, 3); lineTextStyle.background = tint;
          var field = new TextArea("diff-line-" + index + "-" + lineIndex, line.text, null, lineTextStyle,
            "Diff line " + (lineIndex + 1), new TextStyle(13, FontFamily.Monospace), tokens.textPrimary);
          field.readOnly = true;
          lineRows.push(new KeyedView("line-" + lineIndex, new Row("diff-row-" + index + "-" + lineIndex, [
            new KeyedView("numbers", new Text((line.oldLine < 0 ? "" : Std.string(line.oldLine)) + "  " + (line.newLine < 0 ? "" : Std.string(line.newLine)), numberStyle, color, TextStyleOverride.text(11, null, null, FontFamily.Monospace))),
            new KeyedView("text", field)
          ], lineStyle)));
        }
        if (file.lines.length > limit) lineRows.push(new KeyedView("limit", new Text("Additional lines are available by copying the diff.", null, tokens.textSecondary)));
        var body = new LayoutStyle(); body.width = LayoutAxis.grow(contentWidth); body.childGap = 0;
        var scroll = new LayoutStyle(); scroll.width = LayoutAxis.grow();
        scroll.height = LayoutAxis.fixed(Math.min(320, limit * 24 + (file.lines.length > limit ? 24 : 0)));
        var viewport = new ScrollView("diff-scroll-" + index, new Column("diff-lines-" + index, lineRows, body), scroll, ScrollAxis.Both);
        viewport.fillViewport = true;
        fileRows.push(new KeyedView("body", viewport));
        if (index < truncations.length && truncations[index]) fileRows.push(new KeyedView("truncated", new Text("Diff preview truncated.", null, tokens.textSecondary)));
      }
      var fileStyle = new LayoutStyle(); fileStyle.width = LayoutAxis.grow(); fileStyle.childGap = 2;
      fileStyle.background = tokens.surfaceSunken;
      fileStyle.radiusTopLeft = fileStyle.radiusTopRight = fileStyle.radiusBottomLeft = fileStyle.radiusBottomRight = 5;
      var frameStyle = new LayoutStyle(); frameStyle.width = LayoutAxis.grow();
      frameStyle.padding = new Insets(1, 1, 1, 1); frameStyle.background = WorkbenchBoundary.color(context);
      frameStyle.radiusTopLeft = frameStyle.radiusTopRight = frameStyle.radiusBottomLeft = frameStyle.radiusBottomRight = 6;
      rows.push(new KeyedView("file-" + index, new Column("diff-file-frame-" + index, [
        new KeyedView("content", new Column("diff-file-" + index, fileRows, fileStyle))
      ], frameStyle)));
    }
    if (invalidSlice && truncations.length > 0) {
      rows.push(new KeyedView("unassociated-label", new Text("Full patch · file metadata incomplete", null, tokens.textSecondary)));
      rows.push(new KeyedView("unassociated-patch", new SessionDiffView(source)));
    }
    var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.childGap = 4;
    return new Column("session-diff", rows, style).build(context);
  }
}
