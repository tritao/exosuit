package app;

import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutSession;
import haxeon.ui.FontCollection;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.RenderNode;
import ui.CodexMarkdownView;

@:access(haxeon.ui.core.StateStore)
@:access(syntax.Highlighter)
@:access(ui.MarkdownEmphasis)
@:access(haxeon.ui.core.RenderNode)
class CodexMarkdownLayoutMain {
  static function require(value:Bool, message:String):Void { if (!value) throw message; }

  static function codeModel(context:UiContext):ui.WorkspaceFileTextModel {
    for (id in context.stateStore.paths.keys()) {
      var path = context.stateStore.paths.get(id);
      if (path != null && path.indexOf("code-model") >= 0 && context.stateStore.values.exists(id)) {
        var model:ui.WorkspaceFileTextModel = cast Reflect.field(context.stateStore.values.get(id),"model");
        if (model != null) return model;
      }
    }
    throw "Code model resource missing";
  }

  static function find(root:RenderNode, label:String):RenderNode {
    var found:RenderNode = null;
    root.walk(function(node) {
      if (found == null && node.semantics != null && node.semantics.label == label) found = node;
    });
    if (found == null) throw "Missing text: " + label;
    return found;
  }

  static function main():Int {
    var initialFaceLeases = ui.MarkdownEmphasis.leases;
    var fonts = FontCollection.create();
    fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
    var session = LayoutSession.create();
    var context = new UiContext(session, fonts);
    var syntaxes = new syntax.SyntaxRegistry();
    var view = new CodexMarkdownView("Pushed `main` to `origin`. It now points to `e53ac13`, and the local branch is up to date with the remote.", new style.Theme(), syntaxes);
    var root = context.submit(view, new LayoutFrame(1400, 400));
    for (pair in [["Pushed", "main"], ["main", "to"], ["It", "now"], ["now", "points"]]) {
      var before = find(root, pair[0]).globalBounds(), after = find(root, pair[1]).globalBounds();
      require(after.x - before.x - before.width > 2, "Missing space between " + pair.join(" and "));
    }
    var code = find(root, "origin").globalBounds(), punctuation = find(root, ".").globalBounds();
    require(Math.abs(punctuation.x - code.x - code.width) < 0.5, "Added a space before punctuation");
    root = context.submit(view, new LayoutFrame(180, 600));
    require(find(root, "remote.").globalBounds().y > find(root, "Pushed").globalBounds().y, "Prose did not wrap");
    view.update("First `line`.\nSecond `line`.");
    root = context.submit(view, new LayoutFrame(1000, 400));
    require(find(root, "Second").globalBounds().y > find(root, "First").globalBounds().y + 10, "Merged explicit lines");
    var boundarySource = "# Result\nBody text\n> Quoted text\n- First item\n- Second item\nNext paragraph";
    var boundaryBlocks = workspace.client.CodexMarkdown.parse(boundarySource);
    require(boundaryBlocks.length == 5 && boundaryBlocks[0].text == "# Result" && boundaryBlocks[1].text == "Body text"
      && boundaryBlocks[2].text == "> Quoted text" && boundaryBlocks[3].text == "- First item\n- Second item",
      "Markdown structural lines merged without blank separators");
    var boundaries = new CodexMarkdownView(boundarySource, new style.Theme(), syntaxes);
    root = context.submit(boundaries,new LayoutFrame(420,600));
    require(find(root,"Body text").globalBounds().y > find(root,"Result").globalBounds().y + 20,
      "Heading swallowed the following paragraph");
    require(find(root,"Quoted text").globalBounds().y > find(root,"Body text").globalBounds().y,
      "Quote did not retain its block");
    var multiCode = workspace.client.CodexMarkdown.inlineSpans("Use `` `literal` `` and ` normal `, then ``unfinished");
    require(multiCode.length == 5 && multiCode[1].kind == "code" && multiCode[1].text == "`literal`"
      && multiCode[3].text == "normal" && multiCode[4].text == ", then ``unfinished",
      "Multi-backtick or unfinished inline code lost source");
    var literalImage = workspace.client.CodexMarkdown.parse("`` ` ![literal](x.png) ``");
    require(literalImage.length == 1 && literalImage[0].kind == "text", "Inline-code image became a preview");
    var destination = "https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/rename-wrename?view=msvc-170";
    var opened:String = null;
    var links = new CodexMarkdownView("Microsoft documents `_wrename` ([Microsoft Learn](" + destination + ")).", new style.Theme(), syntaxes, function(url) opened = url);
    root = context.submit(links, new LayoutFrame(1000, 400));
    var link = find(root, "Microsoft Learn");
    require(link.semantics != null && link.semantics.role == haxeon.ui.semantics.AccessibilityRole.Link && link.focusable, "Link is not keyboard accessible");
    require(link.semantics != null && link.semantics.value == destination, "Changed the link destination");
    root.walk(function(node) {
      if (node.semantics != null && node.semantics.label != null)
        require(node.semantics.label.indexOf("https://") < 0, "Rendered raw Markdown URL");
    });
    var bounds = link.globalBounds();
    context.pointerDown(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
    context.pointerUp(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
    require(opened == destination, "Click did not open the link");
    opened = null;
    require(context.focus.focus(link.id), "Could not focus the link");
    context.events.key(haxeon.ui.core.UiEventKind.KeyDown, haxeon.ui.core.UiKey.Enter);
    require(opened == destination, "Keyboard activation did not open the link");
    var emphasis = new CodexMarkdownView("Normal **strong** and *italic* with **[bold link](src/Main.hx)**.\n\nA second **paragraph**.", new style.Theme(), syntaxes, function(url) opened=url);
    root = context.submit(emphasis, new LayoutFrame(400, 400));
    var strong = find(root, "strong"), italic = find(root, "italic"), emphasizedLink = find(root, "bold link");
    if (Sys.systemName() == "Windows" && sys.FileSystem.exists("C:/Windows/Fonts/segoeuib.ttf") && sys.FileSystem.exists("C:/Windows/Fonts/segoeuii.ttf")) {
      require(strong.styleType == "markdown-emphasis" && italic.styleType == "markdown-emphasis", "Emphasis did not use real font faces");
      var faces = ui.MarkdownEmphasis.acquire(), boldFonts = faces.face(true, false);
      var normalFonts = FontCollection.create(); normalFonts.add("C:/Windows/Fonts/segoeui.ttf");
      var normal = haxeon.ui.TextLayout.create(normalFonts, "Strong emphasis sample", 1000, new haxeon.ui.TextStyle(16));
      var bold = haxeon.ui.TextLayout.create(boldFonts, "Strong emphasis sample", 1000, new haxeon.ui.TextStyle(16));
      var end = new haxeon.ui.TextLayout.TextPosition("Strong emphasis sample".length, 0);
      require(Math.abs(normal.caret(end).x - bold.caret(end).x) > 0.1, "Bold font metrics matched regular font");
      normal.dispose(); bold.dispose(); normalFonts.dispose(); faces.dispose();
    }
    var emphasizedSemantics:haxeon.ui.semantics.Semantics = cast emphasizedLink.semantics;
    require(emphasizedLink.focusable && emphasizedSemantics.role == haxeon.ui.semantics.AccessibilityRole.Link,
      "Emphasized link lost its accessible action");
    var emphasizedBounds = emphasizedLink.globalBounds(); opened = null;
    context.pointerDown(emphasizedBounds.x + emphasizedBounds.width / 2, emphasizedBounds.y + emphasizedBounds.height / 2, 0);
    context.pointerUp(emphasizedBounds.x + emphasizedBounds.width / 2, emphasizedBounds.y + emphasizedBounds.height / 2, 0);
    require(opened == "src/Main.hx", "Emphasized link did not activate");
    var changing = new CodexMarkdownView("**tone**", new style.Theme(), syntaxes);
    var changingRoot = context.submit(changing, new LayoutFrame(400, 200));
    var boldKey = find(changingRoot, "tone").paintCacheKeys[0];
    changing.update("*tone*"); changingRoot = context.submit(changing, new LayoutFrame(400, 200));
    require(boldKey != find(changingRoot, "tone").paintCacheKeys[0], "Changing emphasis retained the old paint cache");
    root = context.submit(emphasis, new LayoutFrame(160, 400));
    require(find(root, "italic").globalBounds().y >= find(root, "Normal").globalBounds().y, "Emphasis wrapping lost text");
    var international = new CodexMarkdownView("**Résumé 日本語**", new style.Theme(), syntaxes);
    root = context.submit(international, new LayoutFrame(400, 200));
    find(root, "Résumé"); find(root, "日本語");
    ui.MarkdownEmphasis.unavailable.set("bold", true);
    root = context.submit(new CodexMarkdownView("**Readable**", new style.Theme(), syntaxes), new LayoutFrame(400, 200));
    require(find(root, "Readable").styleType != "markdown-emphasis", "Missing face did not use readable text fallback");
    ui.MarkdownEmphasis.unavailable.remove("bold");
    root = context.submit(new CodexMarkdownView("   ## Indented heading", new style.Theme(), syntaxes), new LayoutFrame(400, 200));
    find(root, "Indented heading");
    view.update("```python\nprint('hello')\n```");
    root = context.submit(view, new LayoutFrame(1000, 400));
    var codeLabel = find(root, "Code block: python").globalBounds();
    var codeHeader = find(root, "python").globalBounds();
    require(codeLabel.y >= codeHeader.y + codeHeader.height, "Code block header must precede its body");
    find(root, "Copy code");
    for (dark in [false, true]) {
      var themed = new UiContext(null, fonts, ui.ExosuitPalette.theme(dark));
      var longCode = new CodexMarkdownView("```python\n" + [for (_ in 0...100) "x"].join("") + "\n```", new style.Theme(), syntaxes);
      for (width in [320.0, 1000.0]) {
        var cardRoot = themed.submit(longCode, new LayoutFrame(width, 400));
        var frame:RenderNode = null, scroll:RenderNode = null;
        cardRoot.walk(function(node) {
          if (node.styleKey != null && StringTools.endsWith(node.styleKey, "-frame")) frame = node;
          if (node.styleType == "scroll-view") scroll = node;
        });
        require(frame != null && frame.children.length == 1, "Code card edge or content missing");
        var outer = frame.globalBounds(), inner = frame.children[0].globalBounds();
        require(Math.abs(inner.x - outer.x - 1) < 0.1 && Math.abs(inner.width - outer.width + 2) < 0.1,
          "Code card edge changed content bounds at " + width);
        var copyBounds = find(cardRoot, "Copy code").globalBounds();
        require(copyBounds.x >= outer.x && copyBounds.x + copyBounds.width <= outer.x + outer.width + 0.1,
          "Code copy action escapes its card");
        require(scroll != null && scroll.layout.style.clipHorizontal && find(cardRoot, "Code block: python").focusable,
          "Code card lost horizontal clipping or selectable content");
      }
      themed.dispose();
    }
    var oldModel = codeModel(context); oldModel.highlighter.line(0);
    view.update("```python\nprint('updated')\n```");
    root = context.submit(view,new LayoutFrame(1000,400));
    require(oldModel.highlighter.validatedThrough == -1,"Replaced code retained its grammar resources");
    var currentModel = codeModel(context); currentModel.highlighter.line(0);
    view.update("Code removed");
    root = context.submit(view,new LayoutFrame(1000,400));
    require(currentModel.highlighter.validatedThrough == -1,"Removed code retained its grammar resources");
    var artifactSource = "<!doctype html>\r\n<h1>Hello</h1>\r\n";
    var artifact = workspace.client.CodexMarkdown.parse("```html\r\n" + artifactSource + "```\r\n")[0];
    require(artifact.closed == true && artifact.source == artifactSource, "Artifact lost exact source or fence state");
    var previewLanguage:Null<String> = null, previewSource:Null<String> = null;
    var previewView = new CodexMarkdownView("```html\r\n" + artifactSource + "```\r\n", new style.Theme(), syntaxes,
      null, null, null, function(language, source) { previewLanguage = language; previewSource = source; });
    var previewRoot = context.submit(previewView, new LayoutFrame(600, 400));
    var previewBounds = find(previewRoot, "Preview HTML").globalBounds();
    context.pointerDown(previewBounds.x + previewBounds.width / 2, previewBounds.y + previewBounds.height / 2, 0);
    context.pointerUp(previewBounds.x + previewBounds.width / 2, previewBounds.y + previewBounds.height / 2, 0);
    require(previewLanguage == "html" && previewSource == artifactSource, "Preview did not receive exact artifact source");
    var unfinished = workspace.client.CodexMarkdown.parse("```html\n<h1>Still streaming")[0];
    require(unfinished.closed == false && workspace.client.SessionArtifact.label(unfinished.language, unfinished.text, unfinished.closed == true) == null, "Unfinished fence promoted to artifact");
    require(workspace.client.SessionArtifact.label("diff", StringTools.lpad("", "x", 4000), true) == null, "Diff promoted to source artifact");
    var svg = workspace.client.SessionSvg.parse('<svg viewBox="0 0 100 50"><rect x="2" y="3" width="20" height="10" fill="#123456"/><path d="M 0 0 l 10 10 H 20 V 4 Z" stroke="red" fill="none"/></svg>');
    require(svg != null && svg.shapes.length == 2 && svg.shapes[1].commands[2].values[0] == 20, "Valid SVG geometry was not parsed");
    for (unsafe in ['<svg viewBox="0 0 10 10"><script/></svg>', '<svg viewBox="0 0 10 10"><rect width="1" height="1" fill="url(http://x)"/></svg>', '<svg viewBox="0 0 10 10"><path d="M0 0 A1 1 0 0 0 2 2"/></svg>', '<svg viewBox="0 0 10 10"><rect width="1" height="1" transform="scale(2)"/></svg>', '<svg viewBox="0 0 10 10"><svg viewBox="0 0 2 2"><rect width="1" height="1"/></svg></svg>', '<svg viewBox="0 0 10 10"><path d="M 999999 0 l 2 0"/></svg>', '<svg viewBox="0 0 10 10"><rect width="1e999" height="1"/></svg>'])
      require(workspace.client.SessionSvg.parse(unsafe) == null, "Unsafe or unsupported SVG was accepted");
    view.update("```html\r\n" + artifactSource + "```\r\n");
    root = context.submit(view, new LayoutFrame(600, 400));
    find(root, "HTML source");
    var showSource = find(root, "Show source");
    var showBounds = showSource.globalBounds();
    context.pointerDown(showBounds.x + showBounds.width / 2, showBounds.y + showBounds.height / 2, 0);
    context.pointerUp(showBounds.x + showBounds.width / 2, showBounds.y + showBounds.height / 2, 0);
    root = context.submit(view, new LayoutFrame(600, 400));
    find(root, "Hide source"); find(root, "Code block: html");
    view.update("> Quoted note\n> Second line");
    root = context.submit(view, new LayoutFrame(1000, 400));
    find(root, "Quoted note\nSecond line");
    view.update("| Name | State |\n| --- | --- |\n| Build | Passed |");
    root = context.submit(view, new LayoutFrame(1000, 400));
    require(find(root, "State").globalBounds().x > find(root, "Name").globalBounds().x, "Table columns were not laid out side by side");
    require(find(root, "Build").globalBounds().y > find(root, "Name").globalBounds().y, "Table body did not follow its header");
    var nested = workspace.client.CodexMarkdown.inlineSpans("[Docs](https://example.com/a_(b)?x=1)");
    require(nested.length == 1 && nested[0].destination == "https://example.com/a_(b)?x=1", "Lost URL parentheses");
    var local = workspace.client.CodexMarkdown.inlineSpans("[source](src/Main.hx:12:3)");
    require(local.length == 1 && local[0].kind == "link" && local[0].destination == "src/Main.hx:12:3", "Lost local file destination");
    var image = workspace.client.CodexMarkdown.parse("Before\n![Diagram](images/flow.png)\nAfter");
    require(image.length == 3 && image[1].kind == "image" && image[1].text == "Diagram" && image[1].language == "images/flow.png", "Image block lost its identity");
    for (bad in ["![bad](javascript:alert(1))", "![bad](data:image/png;base64,AA)", "![unfinished](x.png", "Text ![inline](x.png)"])
      require(workspace.client.CodexMarkdown.image(bad) == null, "Accepted unsafe or incomplete image syntax");
    var inlineImages = workspace.client.CodexMarkdown.parse("Before ![one](image.png) between ![two](folder/other.png) after");
    require(inlineImages.length == 5 && inlineImages[0].text == "Before " && inlineImages[1].kind == "image" && inlineImages[2].text == " between "
      && inlineImages[3].kind == "image" && inlineImages[4].text == " after", "Inline image lost adjacent prose");
    var literal = workspace.client.CodexMarkdown.parse("`![code](x.png)` and \\![escaped](y.png) and ![unfinished](x.png");
    require(literal.length == 1 && literal[0].kind == "text", "Code, escaped or incomplete image markup was interpreted");
    var raster = sys.io.File.getBytes("../../graphical/assets/icons/exosuit-16.png");
    var dataUrl = "data:image/png;base64," + haxe.crypto.Base64.encode(raster);
    var inlineData = workspace.client.CodexMarkdown.parse("before ![icon](" + dataUrl + ") after");
    var decodedData:haxe.io.Bytes = cast ui.SessionImageProbe.dataUrl(dataUrl);
    require(inlineData.length == 3 && inlineData[1].language == dataUrl && decodedData != null && decodedData.length == raster.length,
      "Inline data image lost its source or bytes");
    require(ui.SessionImageProbe.dataUrl("data:image/jpeg;base64," + haxe.crypto.Base64.encode(raster)) == null
      && ui.SessionImageProbe.dataUrl("data:image/png;base64,AA=A") == null
      && ui.SessionImageProbe.dataUrl("data:image/svg+xml;base64,AAAA") == null, "Invalid image data was accepted");
    var png = haxe.io.Bytes.alloc(24);
    var signature = [137,80,78,71,13,10,26,10];
    for (i in 0...signature.length) png.set(i, signature[i]);
    png.blit(12, haxe.io.Bytes.ofString("IHDR"), 0, 4);
    png.set(18, 1); png.set(22, 1);
    require(ui.SessionImageProbe.dimensions(png) != null, "Rejected bounded PNG dimensions");
    png.set(16, 1);
    require(ui.SessionImageProbe.dimensions(png) == null, "Accepted oversized PNG dimensions");
    require(workspace.client.SessionLinkTarget.parse("C:/project/file.txt:stream") == null, "Accepted an extra drive-path colon");
    var patch = "diff --git a/old.txt b/new.txt\n--- a/old.txt\n+++ b/new.txt\n@@ -2,2 +4,2 @@\n same\n-old\n+new\n";
    var fallbackPath:String = null;
    var fallback = new ui.SessionDiffView(patch, function(path) fallbackPath = path,
      [{path:"bad.txt",kind:"update",offset:999999,length:20,truncated:false}]);
    root = context.submit(fallback, new LayoutFrame(600, 500));
    var openDiff = find(root, "Open file"), openBounds = openDiff.globalBounds();
    context.pointerDown(openBounds.x + openBounds.width / 2, openBounds.y + openBounds.height / 2, 0);
    context.pointerUp(openBounds.x + openBounds.width / 2, openBounds.y + openBounds.height / 2, 0);
    require(fallbackPath == "new.txt", "Invalid metadata hid original diff path");
    var partial = new ui.SessionDiffView(patch, null,
      [{path:"new.txt",kind:"update",offset:0,length:patch.length,truncated:true}]);
    root = context.submit(partial, new LayoutFrame(600, 500));
    var toggleDiff = find(root, "▾ update new.txt"), toggleBounds = toggleDiff.globalBounds();
    context.pointerDown(toggleBounds.x + toggleBounds.width / 2, toggleBounds.y + toggleBounds.height / 2, 0);
    context.pointerUp(toggleBounds.x + toggleBounds.width / 2, toggleBounds.y + toggleBounds.height / 2, 0);
    root = context.submit(partial, new LayoutFrame(600, 500));
    find(root, "+1  −1 · partial");
    var parsed = workspace.client.SessionDiff.parse(patch);
    require(parsed.length == 1 && parsed[0].path == "new.txt", "Rename did not target the new file");
    var body = parsed[0].lines;
    require(body[4].oldLine == 2 && body[4].newLine == 4 && body[5].oldLine == 3 && body[6].newLine == 5,
      "Incorrect diff line counters");
    var deleted = workspace.client.SessionDiff.parse("--- a/gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-old");
    require(deleted[0].path == "gone.txt", "Deletion lost its old path");
    var quoted = workspace.client.SessionDiff.parse('--- a/old.txt\n+++ "b/new file.txt"\n@@ -1 +1 @@\n-x\n+y');
    require(quoted[0].path == null, "Guessed a quoted Git path");
    var streaming = workspace.client.SessionDiff.parse("@@ -1 +1 @@\n-before\n+aft");
    require(streaming[0].path == null && streaming[0].lines[2].newLine == 1, "Lost an incomplete streaming diff");
    var headerLikeContent = workspace.client.SessionDiff.parse("--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n--- content\n+++ content");
    require(headerLikeContent.length == 1 && headerLikeContent[0].path == "file.txt"
      && headerLikeContent[0].lines[3].kind == "removed" && headerLikeContent[0].lines[4].kind == "added", "Mistook hunk content for file headers");
    links.update("```diff\n" + patch + "```");
    root = context.submit(links, new LayoutFrame(1000, 800));
    find(root, "Copy diff");
    require(find(root, "Diff line 5").focusable, "Diff content is not selectable");
    var openFile = find(root, "Open file").globalBounds();
    opened = null;
    context.pointerDown(openFile.x + openFile.width / 2, openFile.y + openFile.height / 2, 0);
    context.pointerUp(openFile.x + openFile.width / 2, openFile.y + openFile.height / 2, 0);
    require(opened == "new.txt", "Diff did not open the new file");
    var longPatch = "@@ -1,30 +1,30 @@\n";
    for (i in 0...30) longPatch += " context " + i + "\n";
    links.update("```diff\n" + longPatch + "```");
    root = context.submit(links, new LayoutFrame(1000, 1000));
    var diffScroll:RenderNode = null;
    root.walk(function(node) { if (node.styleType == "scroll-view" && node.styleKey == "diff-scroll-0") diffScroll = node; });
    require(diffScroll != null && diffScroll.globalBounds().height <= 320.1, "Long diff exceeded its viewport");
    require(diffScroll.layout.style.clipHorizontal && diffScroll.layout.style.clipVertical, "Diff must scroll on both axes");
    for (dark in [false, true]) {
      var themed = new UiContext(null, fonts, ui.ExosuitPalette.theme(dark));
      var borderedDiff = new ui.SessionDiffView(patch, function(_) {});
      for (width in [320.0, 1000.0]) {
        var diffRoot = themed.submit(borderedDiff, new LayoutFrame(width, 800));
        var diffFrame:RenderNode = null, framedScroll:RenderNode = null;
        diffRoot.walk(function(node) {
          if (node.styleKey == "diff-file-frame-0") diffFrame = node;
          if (node.styleType == "scroll-view" && node.styleKey == "diff-scroll-0") framedScroll = node;
        });
        require(diffFrame != null && diffFrame.children.length == 1, "Diff edge or content missing");
        var outer = diffFrame.globalBounds(), inner = diffFrame.children[0].globalBounds();
        require(Math.abs(inner.x - outer.x - 1) < 0.1 && Math.abs(inner.width - outer.width + 2) < 0.1,
          "Diff edge changed viewport bounds at " + width);
        require(framedScroll != null && framedScroll.layout.style.clipHorizontal && framedScroll.layout.style.clipVertical,
          "Framed diff lost two-axis clipping");
        require(find(diffRoot, "Diff line 5").focusable, "Framed diff lost selectable text");
        var action = find(diffRoot, "Open file").globalBounds();
        require(action.x >= outer.x && action.x + action.width <= outer.x + outer.width + 0.1,
          "Diff action escaped its edge");
      }
      themed.dispose();
    }
    for (literal in ["[unfinished](https://example.com", "[unsafe](javascript:alert(1))", "`[literal](https://example.com)`"])
      for (span in workspace.client.CodexMarkdown.inlineSpans(literal)) require(span.kind != "link", "Made literal or unsupported content clickable");
    context.dispose(); session.dispose(); fonts.dispose();
    require(ui.MarkdownEmphasis.leases == initialFaceLeases, "Unmounted Markdown retained emphasis font collections");
    trace("PASS: Markdown spacing, punctuation, wrapping, line breaks, link labels, destinations and activation");
    return 0;
  }
}
