package app;

import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutSession;
import haxeon.ui.FontCollection;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.RenderNode;
import ui.CodexMarkdownView;

class CodexMarkdownLayoutMain {
  static function require(value:Bool, message:String):Void { if (!value) throw message; }

  static function find(root:RenderNode, label:String):RenderNode {
    var found:RenderNode = null;
    root.walk(function(node) {
      if (found == null && node.semantics != null && node.semantics.label == label) found = node;
    });
    if (found == null) throw "Missing text: " + label;
    return found;
  }

  static function main():Int {
    var fonts = FontCollection.create();
    fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
    var session = LayoutSession.create();
    var context = new UiContext(session, fonts);
    var view = new CodexMarkdownView("Pushed `main` to `origin`. It now points to `e53ac13`, and the local branch is up to date with the remote.", new style.Theme());
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
    var destination = "https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/rename-wrename?view=msvc-170";
    var opened:String = null;
    var links = new CodexMarkdownView("Microsoft documents `_wrename` ([Microsoft Learn](" + destination + ")).", new style.Theme(), function(url) opened = url);
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
    var nested = workspace.client.CodexMarkdown.inlineSpans("[Docs](https://example.com/a_(b)?x=1)");
    require(nested.length == 1 && nested[0].destination == "https://example.com/a_(b)?x=1", "Lost URL parentheses");
    for (literal in ["[unfinished](https://example.com", "[unsafe](javascript:alert(1))", "`[literal](https://example.com)`"])
      for (span in workspace.client.CodexMarkdown.inlineSpans(literal)) require(span.kind != "link", "Made literal or unsupported content clickable");
    context.dispose(); session.dispose(); fonts.dispose();
    trace("PASS: Markdown spacing, punctuation, wrapping, line breaks, link labels, destinations and activation");
    return 0;
  }
}
