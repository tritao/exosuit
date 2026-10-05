package app;

import editor.TextBuffer;
import editor.BufferSelection;

/** Core smoke entry. The desktop application is graphical/app.GraphicalMain. */
class Main {
 static function main():Int {
  var buffer = new TextBuffer(), selection = new BufferSelection();
  buffer.insert(selection, "Exosuit core");
  if (buffer.text != "Exosuit core" || !buffer.undo(selection) || buffer.text != "") throw "core document smoke failed";
  Sys.println("PASS: Exosuit core document model");
  return 0;
 }
}
