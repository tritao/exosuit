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
    context.dispose(); session.dispose(); fonts.dispose();
    trace("PASS: inline Markdown spaces, punctuation, wrapping and line breaks");
    return 0;
  }
}
