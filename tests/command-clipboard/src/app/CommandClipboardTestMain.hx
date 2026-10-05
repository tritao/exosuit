package app;

import commandview.CommandInput;

class CommandClipboardTestMain {
 static function require(condition:Bool, message:String):Void { if (!condition) throw message; }
 static function main():Int {
  var input = new CommandInput(), clipboard = "", changed = 0;
  input.writeClipboard = function(text) { clipboard = text; return true; };
  input.onAsyncEdit = function() changed++;
  input.insert("Olá にほん 😀"); input.selectAll();
  require(input.copy() && clipboard == "Olá にほん 😀", "clipboard Unicode copy");
  require(input.cut() && input.text == "", "clipboard cut did not preserve selection transaction");
  var pending:Null<String->Void> = null;
  input.readClipboard = function(handler) pending = handler;
  require(input.paste() && input.text == "", "paste blocked or mutated input before completion");
  var complete:Null<String->Void> = pending;
  if (complete == null) throw "clipboard read not requested";
  complete("Olá\r\nにほん\r😀");
  require(input.text == "Olá にほん 😀" && changed == 1, "asynchronous clipboard normalization or edit notification");
  input.paste(); complete = pending; input.reset();
  if (complete == null) throw "clipboard read not requested";
  complete("stale"); require(input.text == "", "paste leaked into a replacement prompt");
  input.paste(); complete = pending; input.insert("typed");
  if (complete == null) throw "clipboard read not requested";
  complete("stale"); require(input.text == "typed", "delayed paste overwrote intervening edits");
  input.paste(); complete = pending; input.invalidateClipboard();
  if (complete == null) throw "clipboard read not requested";
  complete("closed"); require(input.text == "typed", "paste survived prompt closure");
  Sys.println("PASS: host-provided asynchronous command clipboard, Unicode, and stale-completion rejection");
  return 0;
 }
}
