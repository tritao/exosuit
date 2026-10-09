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
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextArea;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.scroll.ScrollAxis;
import syntax.SyntaxRegistry;
import syntax.BuiltinSyntax;
import syntax.SyntaxDefinition;
import syntax.HighlightToken;

/** Read-only Markdown projection using the editor's syntax engine and palette. */
class CodexMarkdownView implements View {
  var value:String;
  final models:Map<String, WorkspaceFileTextModel> = [];
  final palette:style.Theme;
  final openLink:String->Void;
  static var syntaxes:Null<SyntaxRegistry>;

  public function new(value:String, palette:style.Theme, ?openLink:String->Void) {
    this.value = value;
    this.palette = palette;
    this.openLink = openLink == null ? function(destination) {
      if (NativeKit.nk_shell_open_url(destination) != Result.Ok)
        throw "Unable to open link: " + NativeKit.nk_last_error();
    } : openLink;
  }

  public function update(value:String):Void this.value = value;

  static function registry():SyntaxRegistry {
    if (syntaxes != null) return syntaxes;
    var result = new SyntaxRegistry();
    BuiltinSyntax.install(result);
    var python:Map<String, Int> = [];
    for (word in "and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield".split(" ")) python.set(word, HighlightToken.KEYWORD);
    for (word in ["True", "False", "None"]) python.set(word, HighlightToken.LITERAL);
    result.add(new SyntaxDefinition("Python", [".py"], true, python, [], "#", "", "", '"""', '"""'));
    var js:Map<String, Int> = [];
    for (word in "async await break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new return static super switch throw try typeof var void while with yield".split(" ")) js.set(word, HighlightToken.KEYWORD);
    for (word in ["true", "false", "null", "undefined"]) js.set(word, HighlightToken.LITERAL);
    result.add(new SyntaxDefinition("JavaScript", [".js", ".ts", ".jsx", ".tsx"], true, js));
    syntaxes = result;
    return result;
  }

  static function extension(language:String):String return switch language {
    case "python", "py": "py";
    case "javascript", "js", "jsx": "js";
    case "typescript", "ts", "tsx": "ts";
    case "c++", "cpp", "cxx": "cpp";
    case "haxe", "hx": "hx";
    case "json": "json";
    case "c", "h": "c";
    default: "txt";
  };

  public function build(context:BuildContext):RenderNode {
    var rows:Array<KeyedView> = [];
    var spaceWidths:Map<String, Float> = [];
    var index = 0;
    for (block in CodexMarkdown.parse(value)) {
      var key = "block-" + index++;
      if (block.kind == "code") {
        var model = models.get(key);
        if (model == null || model.buffer.text != block.text || model.syntax != registry().find("snippet." + extension(block.language))) {
          model = new WorkspaceFileTextModel("snippet." + extension(block.language), block.text, registry(), palette);
          models.set(key, model);
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
        var code = block.text;
        var copy = new Button("Copy code", null, function() context.clipboard.writeText(code), key + "-copy");
        var header = new LayoutStyle(); header.width = LayoutAxis.fit(); header.childGap = 8;
        header.childAlignY = haxeon.ui.LayoutAlignmentY.Center;
        var label = new LayoutStyle(); label.width = LayoutAxis.fit();
        var scroll = new LayoutStyle(); scroll.width = LayoutAxis.grow(); scroll.height = body.height;
        var card = new LayoutStyle(); card.width = LayoutAxis.grow(); card.childGap = 12;
        card.padding = new Insets(12, 10, 12, 10); card.background = context.theme.tokens.surfaceSunken;
        card.radiusTopLeft = card.radiusTopRight = card.radiusBottomLeft = card.radiusBottomRight = 8;
        rows.push(new KeyedView(key, new Row(key, [
          new KeyedView("code", new ScrollView(key + "-scroll", field, scroll, ScrollAxis.Horizontal)),
          new KeyedView("header", new Row(key + "-header", [
            new KeyedView("language", new Text(block.language == "" ? "Code" : block.language, label, context.theme.tokens.mutedText)),
            new KeyedView("copy", copy)
          ], header))
        ], card)));
      } else {
        var text = block.text;
        var heading = ~/^(#{1,6}) +/;
        var size = 16.0;
        if (heading.match(text)) { size = 24 - heading.matched(1).length; text = heading.replace(text, ""); }
        var prose = new LayoutStyle(); prose.width = LayoutAxis.grow();
        text = ~/^[-*+] /gm.replace(text, "• ");
        if (text.indexOf("`") < 0 && text.indexOf("](") < 0) rows.push(new KeyedView(key, new Text(text, prose, null, TextStyleOverride.text(size))));
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
            function appendText(value:String):Void {
              var tokens = ~/\s+|\S+/g, offset = 0;
              while (tokens.matchSub(value, offset)) {
                var token = tokens.matched(0), position = tokens.matchedPos();
                offset = position.pos + position.len;
                if (~/^\s/.match(token)) flushWord();
                else word.push(new KeyedView("text-" + part++, new Text(token, null, null, TextStyleOverride.text(size))));
              }
            }
            for (span in CodexMarkdown.inlineSpans(line)) {
              if (span.kind == "text") appendText(span.text);
              else if (span.kind == "link") word.push(new KeyedView("link-" + part++,
                new CodexMarkdownLink(span.text, span.destination, size, openLink)));
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

private class CodexMarkdownLink implements View {
  final label:String;
  final destination:String;
  final size:Float;
  final openLink:String->Void;

  public function new(label:String, destination:String, size:Float, openLink:String->Void) {
    this.label = label; this.destination = destination; this.size = size; this.openLink = openLink;
  }

  public function build(context:BuildContext):RenderNode {
    var layout = new LayoutStyle(); layout.width = LayoutAxis.fit();
    var node = new Text(label, layout, context.theme.tokens.accent, TextStyleOverride.text(size)).build(context);
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
