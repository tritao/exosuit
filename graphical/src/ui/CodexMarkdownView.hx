package ui;

import workspace.client.CodexMarkdown;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutWrapMode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Insets;
import haxeon.ui.FontFamily;
import haxeon.ui.TextStyle;
import haxeon.ui.TextLayout;
import haxeon.ui.TextLayout.TextPosition;
import haxeon.ui.theme.TextRole;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.CursorShape;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityAction;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextArea;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.scroll.ScrollAxis;
import syntax.SyntaxRegistry;

/** Read-only Markdown projection using the editor's syntax engine and palette. */
class CodexMarkdownView implements View {
  var value:String;
  final diffs:Map<String, SessionDiffView> = [];
  final palette:style.Theme;
  final syntaxes:SyntaxRegistry;
  final openLink:String->Void;
  final resolveImage:Null<String->Null<String>>;
  final frame:Void->Void;
  final previewArtifact:Null<(String, String)->Void>;
  final loadImage:Null<(String, (Null<haxe.io.Bytes>, Null<String>)->Void)->Void>;

  public function new(value:String, palette:style.Theme, syntaxes:SyntaxRegistry, ?openLink:String->Void,
      ?resolveImage:String->Null<String>, ?frame:Void->Void, ?previewArtifact:(String, String)->Void,
      ?loadImage:(String, (Null<haxe.io.Bytes>, Null<String>)->Void)->Void) {
    this.value = value;
    this.palette = palette;
    this.syntaxes = syntaxes;
    this.resolveImage = resolveImage;
    this.frame = frame == null ? function() {} : frame;
    this.previewArtifact = previewArtifact;
    this.loadImage = loadImage;
    this.openLink = openLink == null ? function(destination) {
      if (workspace.client.SessionLinkTarget.external(destination) && NativeKit.nk_shell_open_url(destination) != Result.Ok)
        throw "Unable to open link: " + NativeKit.nk_last_error();
    } : openLink;
  }

  public function update(value:String):Void this.value = value;

  static function tableCells(line:String):Array<String> {
    var value = StringTools.trim(line);
    if (StringTools.startsWith(value, "|")) value = value.substr(1);
    if (StringTools.endsWith(value, "|")) value = value.substr(0, value.length - 1);
    return [for (cell in value.split("|")) StringTools.trim(cell)];
  }

  static function isTable(text:String):Bool {
    var lines = text.split("\n");
    if (lines.length < 2 || lines[0].indexOf("|") < 0 || text.indexOf("\\|") >= 0) return false;
    var heading = tableCells(lines[0]), divider = tableCells(lines[1]);
    if (heading.length < 2 || heading.length != divider.length) return false;
    for (cell in divider) if (!~/^:?-{3,}:?$/.match(cell)) return false;
    for (index in 2...lines.length) if (tableCells(lines[index]).length != heading.length) return false;
    return true;
  }

  public function build(context:BuildContext):RenderNode {
    var faces = context.resourceState(context.id("markdown-emphasis-faces"), MarkdownEmphasis.acquire, function(value) value.dispose()).value;
    var emphasisRuns = 0;
    function emphasisFace(value:String, bold:Bool, italic:Bool):Null<haxeon.ui.FontCollection> {
      if ((!bold && !italic) || emphasisRuns >= 256 || haxe.io.Bytes.ofString(value).length > 512) return null;
      var face = faces.face(bold, italic);
      if (face != null) emphasisRuns++;
      return face;
    }
    var rows:Array<KeyedView> = [];
    var spaceWidths:Map<String, Float> = [];
    var index = 0;
    for (block in CodexMarkdown.parse(value)) {
      var key = "block-" + index++;
      if (block.kind == "code" && (block.language == "diff" || block.language == "patch")) {
        var diff = diffs.get(key);
        if (diff == null) { diff = new SessionDiffView(block.text, openLink, null, block.source); diffs.set(key, diff); }
        diff.update(block.text, null, block.source);
        rows.push(new KeyedView(key, diff));
      } else if (block.kind == "image") {
        rows.push(new KeyedView(key, new SessionImageView(key, block.text, block.language, resolveImage, openLink, frame, loadImage)));
      } else if (block.kind == "code") {
        var artifact = workspace.client.SessionArtifact.label(block.language, block.text, block.closed == true);
        var shown = context.state(context.id(key + "-artifact-open"), false);
        var raw = block.source == null ? block.text : block.source;
        if (artifact != null && shown.value != true) {
          var bar = new LayoutStyle(); bar.width = LayoutAxis.grow(); bar.childGap = 8; bar.wrapMode = LayoutWrapMode.Wrap;
          bar.padding = new Insets(12, 8, 12, 8); bar.background = context.theme.tokens.surfaceSunken;
          bar.radiusTopLeft = bar.radiusTopRight = bar.radiusBottomLeft = bar.radiusBottomRight = 6;
          var title = new LayoutStyle(); title.width = LayoutAxis.grow();
          var actionStyle = new LayoutStyle(); actionStyle.height = LayoutAxis.fixed(30); actionStyle.padding = new Insets(6, 4, 6, 4);
          var show = new Button("Show source", actionStyle, function() shown.update(true), key + "-show-source");
          show.variant = ButtonVariant.Navigation;
          var copy = new Button("", actionStyle, function() context.clipboard.writeText(raw), key + "-copy-source");
          copy.accessibilityLabel = "Copy source"; copy.leadingIcon = IconName.Copy; copy.iconSize = 16; copy.variant = ButtonVariant.Navigation;
          var controls:Array<KeyedView> = [new KeyedView("title", new Text(artifact, title, context.theme.tokens.textSecondary))];
          if (previewArtifact != null && (block.language == "html" || block.language == "htm" || block.language == "svg")) {
            var preview:(String, String)->Void = cast previewArtifact;
            var language = block.language;
            var button = new Button(language == "svg" ? "Open static SVG" : "Preview HTML", actionStyle, function() preview(language, raw), key + "-render");
            button.variant = ButtonVariant.Navigation;
            controls.push(new KeyedView("preview", button));
          }
          controls.push(new KeyedView("show", show)); controls.push(new KeyedView("copy", copy));
          rows.push(new KeyedView(key, new Row(key + "-artifact", controls, bar)));
          if (block.language == "svg") rows.push(new KeyedView(key + "-svg", new SessionSvgView(key + "-svg", raw, frame)));
          continue;
        }
        var state = context.resourceState(context.id(key + "-code-model"), function() return new SessionCodeModelState(), function(value) value.dispose()).value;
        var model = state.model;
        var definition=syntaxes.findFence(block.language);
        if (model == null || model.buffer.text != block.text || model.syntax != definition) {
          state.dispose();
          model = new WorkspaceFileTextModel("snippet", block.text, syntaxes, palette, definition);
          state.model = model;
        }
        model.updateTheme(palette);
        var lines = block.text.split("\n"), longest = 0;
        for (line in lines) if (line.length > longest) longest = line.length;
        var body = new LayoutStyle();
        body.width = LayoutAxis.fixed(Math.max(280, longest * 10 + 32));
        body.height = LayoutAxis.fit();
        body.padding = new Insets(0, 4, 0, 4);
        var field = TextArea.withDocument(key + "-code", model.document(), null, body,
          "Code block: " + (block.language == "" ? "plain text" : block.language), new TextStyle(15, FontFamily.Monospace), context.theme.tokens.text);
        field.readOnly = true;
        field.colorRangeProvider = model.foregroundProvider;
        field.presentationRevision = model.presentationRevision;
        var code = raw;
        var copyStyle = new LayoutStyle(); copyStyle.height = LayoutAxis.fixed(30); copyStyle.padding = new Insets(8, 4, 8, 4);
        var copy = new Button("", copyStyle, function() context.clipboard.writeText(code), key + "-copy");
        copy.accessibilityLabel = "Copy code";
        copy.leadingIcon = IconName.Copy;
        copy.iconSize = 16;
        copy.variant = ButtonVariant.Navigation;
        copy.classes.push("viewport-tool");
        var header = new LayoutStyle(); header.width = LayoutAxis.fit(); header.childGap = 8;
        header.childAlignY = haxeon.ui.LayoutAlignmentY.Center;
        var label = new LayoutStyle(); label.width = LayoutAxis.fit();
        var scroll = new LayoutStyle(); scroll.width = LayoutAxis.grow(); scroll.height = body.height;
        var card = new LayoutStyle(); card.width = LayoutAxis.grow(); card.childGap = 12;
        card.padding = new Insets(12, 10, 12, 10); card.background = context.theme.tokens.surfaceSunken;
        card.radiusTopLeft = card.radiusTopRight = card.radiusBottomLeft = card.radiusBottomRight = 7;
        var cardFrame = new LayoutStyle(); cardFrame.width = LayoutAxis.grow();
        cardFrame.padding = new Insets(1, 1, 1, 1); cardFrame.background = WorkbenchBoundary.color(context);
        cardFrame.radiusTopLeft = cardFrame.radiusTopRight = cardFrame.radiusBottomLeft = cardFrame.radiusBottomRight = 8;
        header.width = LayoutAxis.grow();
        label.width = LayoutAxis.grow();
        var heading:Array<KeyedView> = [new KeyedView("language", new Text(artifact == null ? (block.language == "" ? "Code" : block.language) : artifact, label, context.theme.tokens.mutedText))];
        if (artifact != null) heading.push(new KeyedView("hide", new Button("Hide source", null, function() shown.update(false), key + "-hide-source")));
        heading.push(new KeyedView("copy", copy));
        rows.push(new KeyedView(key, new Column(key + "-frame", [new KeyedView("card", new Column(key, [
          new KeyedView("header", new Row(key + "-header", heading, header)),
          new KeyedView("code", new ScrollView(key + "-scroll", field, scroll, ScrollAxis.Horizontal))
        ], card))], cardFrame)));
        if (artifact != null && block.language == "svg") rows.push(new KeyedView(key + "-svg", new SessionSvgView(key + "-svg", raw, frame)));
      } else if (isTable(block.text)) {
        var tableRows:Array<KeyedView> = [];
        var lines = block.text.split("\n");
        for (rowIndex in 0...lines.length) {
          if (rowIndex == 1) continue;
          var cells:Array<KeyedView> = [];
          var values = tableCells(lines[rowIndex]);
          for (cellIndex in 0...values.length) {
            var cellStyle = new LayoutStyle(); cellStyle.width = LayoutAxis.fixed(180);
            cellStyle.padding = new Insets(10, 7, 10, 7);
            cells.push(new KeyedView("cell-" + cellIndex, new Text(values[cellIndex], cellStyle,
              rowIndex == 0 ? context.theme.tokens.textPrimary : context.theme.tokens.textSecondary)));
          }
          var rowStyle = new LayoutStyle(); rowStyle.width = LayoutAxis.fit();
          rowStyle.background = rowIndex == 0 ? context.theme.tokens.surfaceRaised : context.theme.tokens.surfaceSunken;
          tableRows.push(new KeyedView("row-" + rowIndex, new Row(key + "-row-" + rowIndex, cells, rowStyle)));
        }
        var tableStyle = new LayoutStyle(); tableStyle.width = LayoutAxis.fit(); tableStyle.childGap = 1;
        var tableScroll = new LayoutStyle(); tableScroll.width = LayoutAxis.grow(); tableScroll.height = LayoutAxis.fit();
        rows.push(new KeyedView(key, new ScrollView(key + "-table-scroll", new Column(key + "-table", tableRows, tableStyle), tableScroll, ScrollAxis.Horizontal)));
      } else {
        var text = block.text;
        var quote = ~/^\s*> ?/;
        var quoted = true;
        for (line in text.split("\n")) if (!quote.match(line)) quoted = false;
        if (quoted) text = ~/^\s*> ?/gm.replace(text, "");
        var heading = ~/^ {0,3}(#{1,6}) +/;
        var size = 16.0;
        if (heading.match(text)) { size = 24 - heading.matched(1).length; text = heading.replace(text, ""); }
        var prose = new LayoutStyle(); prose.width = LayoutAxis.grow();
        if (quoted) {
          prose.padding = new Insets(14, 8, 14, 8);
          prose.background = context.theme.tokens.surfaceRaised;
          prose.radiusTopLeft = prose.radiusTopRight = prose.radiusBottomLeft = prose.radiusBottomRight = 6;
        }
        text = ~/^[-*+] /gm.replace(text, "• ");
        if (text.indexOf("`") < 0 && text.indexOf("](") < 0 && text.indexOf("*") < 0 && text.indexOf("_") < 0) rows.push(new KeyedView(key, new Text(text, prose, null, TextStyleOverride.text(size))));
        else {
          var lines:Array<KeyedView> = [], lineIndex = 0;
          for (line in text.split("\n")) {
            var lineKey = key + "-line-" + lineIndex++;
            var pieces:Array<KeyedView> = [], word:Array<KeyedView> = [], part = 0;
            // Whitespace separates layout groups; adjacent punctuation and code
            // stay together. Trailing spaces on Text widgets are not measurable.
            function flushWord():Void {
              if (word.length == 0) return;
              var wordStyle = new LayoutStyle(); wordStyle.width = LayoutAxis.fit();
              pieces.push(new KeyedView("word-" + part++, new Row(lineKey + "-word-" + part, word, wordStyle)));
              word = [];
            }
            function appendText(value:String, bold:Bool, italic:Bool):Void {
              var tokens = ~/\s+|\S+/g, offset = 0;
              while (tokens.matchSub(value, offset)) {
                var token = tokens.matched(0), position = tokens.matchedPos();
                offset = position.pos + position.len;
                if (~/^\s/.match(token)) flushWord();
                else {
                  var face = emphasisFace(token, bold, italic);
                  var run:View = face == null ? new Text(token, null, null, TextStyleOverride.text(size)) :
                    new ui.MarkdownEmphasis.MarkdownEmphasisText(token, size, context.theme.tokens.textPrimary, face, (bold ? "b" : "") + (italic ? "i" : ""));
                  word.push(new KeyedView("text-" + part++, run));
                }
              }
            }
            for (span in CodexMarkdown.inlineSpans(line)) {
              if (span.kind == "text") appendText(span.text, span.bold == true, span.italic == true);
              else if (span.destination != null) word.push(new KeyedView("link-" + part++,
                new CodexMarkdownLink(span.text, span.destination, size, openLink,
                  span.kind == "code" ? null : emphasisFace(span.text, span.bold == true, span.italic == true), span.kind == "code",
                  (span.bold == true ? "b" : "") + (span.italic == true ? "i" : ""))));
              else {
                var chip = new LayoutStyle(); chip.padding = new Insets(4, 1, 4, 1); chip.background = context.theme.tokens.surfaceSunken;
                word.push(new KeyedView("inline-" + part++, new Text(span.text, chip, null,
                  TextStyleOverride.text(size - 1, null, null, FontFamily.Monospace))));
              }
            }
            flushWord();
            var spaceKey = Std.string(size);
            var spaceWidth = spaceWidths.get(spaceKey);
            if (spaceWidth == null) {
              spaceWidth = size / 3;
              if (context.fonts != null) {
                var typography = context.resolveTextRole(TextRole.Body, TextStyleOverride.text(size));
                var probe = TextLayout.createStyled(context.fonts, "x x", 1000, typography.textStyle, typography.paragraphStyle);
                spaceWidth = probe.caret(new TextPosition(2, 0)).x - probe.caret(new TextPosition(1, 0)).x;
                probe.dispose();
              }
              spaceWidths.set(spaceKey, spaceWidth);
            }
            var lineStyle = new LayoutStyle(); lineStyle.width = LayoutAxis.grow();
            lineStyle.childGap = spaceWidth;
            lineStyle.wrapMode = LayoutWrapMode.Wrap;
            lineStyle.rowGap = 3;
            lines.push(new KeyedView(lineKey, new Row(lineKey + "-inline", pieces, lineStyle)));
          }
          prose.childGap = 3;
          rows.push(new KeyedView(key, new Column(key + "-lines", lines, prose)));
        }
      }
    }
    var layout = new LayoutStyle(); layout.width = LayoutAxis.grow(); layout.childGap = 12;
    return new Column("codex-markdown", rows, layout).build(context);
  }
}

/** Native grammar scanners follow the lifetime of the displayed code block. */
private class SessionCodeModelState {
  public var model:Null<WorkspaceFileTextModel>;
  public function new() {}
  public function dispose():Void { if (model != null) model.dispose(); model = null; }
}

private class CodexMarkdownLink implements View {
  final label:String;
  final destination:String;
  final size:Float;
  final openLink:String->Void;
  final face:Null<haxeon.ui.FontCollection>;
  final code:Bool;
  final variant:String;

  public function new(label:String, destination:String, size:Float, openLink:String->Void, ?face:haxeon.ui.FontCollection, code:Bool = false, variant:String = "") {
    this.label = label; this.destination = destination; this.size = size; this.openLink = openLink; this.face = face; this.code = code; this.variant = variant;
  }

  public function build(context:BuildContext):RenderNode {
    var layout = new LayoutStyle(); layout.width = LayoutAxis.fit();
    var view:View = face == null || code ? new Text(label, layout, context.theme.tokens.accent,
      TextStyleOverride.text(size, null, null, code ? FontFamily.Monospace : FontFamily.Default)) :
      new ui.MarkdownEmphasis.MarkdownEmphasisText(label, size, context.theme.tokens.accent, face, variant);
    var node = view.build(context);
    node.focusable = true;
    node.cursor = CursorShape.Hand;
    var semantics = new Semantics(AccessibilityRole.Link, label, destination);
    semantics.actions = AccessibilityAction.Activate;
    node.semantics = semantics;
    node.on(UiEventKind.Click, function(_) openLink(destination));
    node.on(UiEventKind.Activate, function(_) openLink(destination));
    return node;
  }
}
