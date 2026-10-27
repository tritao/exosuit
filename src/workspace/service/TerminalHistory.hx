package workspace.service;

import haxe.io.Bytes;

/** Rendered output only: replay never restores a dead shell's input modes. */
@:wire typedef TerminalHistory = {
  @:id(1) var version:Int;
  @:id(2) var columns:Int;
  @:id(3) var rows:Int;
  @:id(4) var data:Bytes;
}
