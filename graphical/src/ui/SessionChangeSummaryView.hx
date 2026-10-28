package ui;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.MiddleEllipsisText;
import haxeon.ui.widgets.text.Text;
import workspace.client.SessionDiff;
import workspace.client.SessionLinkTarget;
import workspace.service.WorkspaceAgentProtocol.AgentFileChange;

/** Compact summaries use only provider-associated slices of this item's preview. */
class SessionChangeSummaryView implements View {
  final files:Array<AgentFileChange>;
  final detail:String;
  final openLink:Null<String->Void>;
  public function new(files:Array<AgentFileChange>, detail:String, ?openLink:String->Void) {
    this.files = files; this.detail = detail; this.openLink = openLink;
  }
  public function build(context:BuildContext):RenderNode {
    var rows:Array<KeyedView> = [], tokens = context.theme.tokens;
    for (index in 0...files.length) {
      var file = files[index], path = file.path;
      var validSlice = file.offset >= 0 && file.length >= 0 && file.offset <= detail.length && file.length <= detail.length - file.offset;
      var additions = 0, removals = 0, hasHunk = false;
      if (validSlice) for (part in SessionDiff.parse(detail.substring(file.offset, file.offset + file.length))) for (line in part.lines) {
        if (line.kind == "hunk") hasHunk = true;
        else if (line.kind == "added") additions++;
        else if (line.kind == "removed") removals++;
      }
      var meta = file.kind + (hasHunk ? "  +" + additions + "  −" + removals : "")
        + (file.truncated ? "  ·  partial" : "") + (!validSlice ? "  ·  preview unavailable" : "");
      var pathView:View;
      if (openLink != null && SessionLinkTarget.parse(path) != null) {
        var buttonStyle = new LayoutStyle(); buttonStyle.width = LayoutAxis.grow(); buttonStyle.height = LayoutAxis.fixed(30);
        buttonStyle.padding = new Insets(6, 4, 6, 4);
        var navigate:String->Void = cast openLink;
        var button = new Button(path, buttonStyle, function() navigate(path), "change-file-" + index);
        button.variant = ButtonVariant.Navigation; button.classes.push("viewport-tool"); button.ellipsizeLabel = true;
        pathView = button;
      } else pathView = new MiddleEllipsisText("change-file-" + index, path, true, TextStyleOverride.text(13));
      var rowStyle = new LayoutStyle(); rowStyle.width = LayoutAxis.grow(); rowStyle.childGap = 8;
      rows.push(new KeyedView("file-" + index, new Row("change-summary-" + index, [
        new KeyedView("path", pathView),
        new KeyedView("meta", new Text(meta, null, tokens.textSecondary, TextStyleOverride.text(12)))
      ], rowStyle)));
    }
    var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.childGap = 2;
    return new Column("change-summary", rows, style).build(context);
  }
}
