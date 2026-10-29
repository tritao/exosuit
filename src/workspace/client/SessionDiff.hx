package workspace.client;

typedef SessionDiffLine = { var text:String; var kind:String; var oldLine:Int; var newLine:Int; }
typedef SessionDiffFile = { var title:String; var path:Null<String>; var lines:Array<SessionDiffLine>; }

/** Streaming-safe unified diff projection. Original source remains available to the caller. */
class SessionDiff {
  static function headerPath(line:String, prefix:String):Null<String> {
    var value = StringTools.trim(line.substr(4));
    var tab = value.indexOf("\t");
    if (tab >= 0) value = value.substr(0, tab);
    // Quoted paths can contain Git escapes; show them but never guess a navigation target.
    if (!StringTools.startsWith(value, prefix) || value.indexOf('"') >= 0) return null;
    var path = value.substr(prefix.length);
    return SessionLinkTarget.parse(path) == null ? null : path;
  }

  public static function parse(source:String):Array<SessionDiffFile> {
    var files:Array<SessionDiffFile> = [], current:SessionDiffFile = null;
    var oldPath:Null<String> = null, newPath:Null<String> = null;
    var oldLine = -1, newLine = -1, hasOld = false, hasNew = false, deleted = false;
    var inHunk = false, oldRemaining = 0, newRemaining = 0;
    function begin():Void {
      current = {title: "Changes", path: null, lines: []}; files.push(current);
      oldPath = newPath = null; oldLine = newLine = -1; hasOld = hasNew = deleted = false;
      inHunk = false; oldRemaining = newRemaining = 0;
    }
    function updateTitle():Void {
      current.path = hasNew ? (deleted ? oldPath : newPath) : null;
      current.title = current.path == null ? "Changes" : current.path;
    }
    var hunk = ~/^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@/;
    for (line in StringTools.replace(source, "\r\n", "\n").split("\n")) {
      if (StringTools.startsWith(line, "diff --git ")) begin();
      else if (!inHunk && StringTools.startsWith(line, "--- ") && current != null && hasOld && hasNew) begin();
      if (current == null) begin();
      var kind = "meta", oldNumber = -1, newNumber = -1;
      if (!inHunk && StringTools.startsWith(line, "--- ")) { hasOld = true; oldPath = headerPath(line, "a/"); updateTitle(); }
      else if (!inHunk && StringTools.startsWith(line, "+++ ")) { hasNew = true; deleted = StringTools.trim(line.substr(4)) == "/dev/null"; newPath = headerPath(line, "b/"); updateTitle(); }
      else if (hunk.match(line)) {
        kind = "hunk"; oldLine = Std.parseInt(hunk.matched(1)); newLine = Std.parseInt(hunk.matched(3));
        var oldCount = hunk.matched(2), newCount = hunk.matched(4);
        oldRemaining = oldCount == null || oldCount == "" ? 1 : Std.parseInt(oldCount);
        newRemaining = newCount == null || newCount == "" ? 1 : Std.parseInt(newCount);
        inHunk = oldRemaining > 0 || newRemaining > 0;
      } else if (inHunk && line.length > 0) {
        switch (line.charAt(0)) {
          case "+" if (newRemaining > 0): kind = "added"; newNumber = newLine++; newRemaining--;
          case "-" if (oldRemaining > 0): kind = "removed"; oldNumber = oldLine++; oldRemaining--;
          case " " if (oldRemaining > 0 && newRemaining > 0): kind = "context"; oldNumber = oldLine++; newNumber = newLine++; oldRemaining--; newRemaining--;
          default:
        }
        if (oldRemaining <= 0 && newRemaining <= 0) inHunk = false;
      }
      current.lines.push({text: line, kind: kind, oldLine: oldNumber, newLine: newNumber});
    }
    return files;
  }
}
