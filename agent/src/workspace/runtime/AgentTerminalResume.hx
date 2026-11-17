package workspace.runtime;

import workspace.provider.ClaudeTranscript;
import workspace.service.WorkspaceTerminalProtocol;

/** What a provider terminal is started with, and the conversation id its record keeps. */
typedef AgentTerminalLaunch = {
 var arguments:Array<String>;
 var session:Null<String>;
 /** Shown in the terminal above the restarted program. */
 var note:String;
}

/**
 * A provider terminal (Claude Code, Codex, Pi) continues the same conversation when it is started again after its
 * program was lost or ended.
 *
 * The conversation is the one the terminal's provider last reported (`AgentTerminalIdentity`), else the one its record
 * keeps. Claude and Pi are given an id at the first start (`--session-id`), so a terminal has one from the start; Codex
 * cannot be given one and reports it after its first turn. Without an id a restart begins a new conversation: nothing
 * is guessed from the providers' files.
 */
class AgentTerminalResume {
 /**
  * `restart` is false for the terminal's first start. `identity` is the terminal's folder in the service's state
  * (`AgentTerminalIdentity`), null without one.
  */
 public static function plan(record:TerminalRecord, restart:Bool, ?identity:String):AgentTerminalLaunch {
  var plain:AgentTerminalLaunch = {arguments: [], session: null, note: "── Shell restarted ──"};
  var provider = record.agentProvider;
  if (provider != "claude" && provider != "codex" && provider != "pi") return plain;
  var told = restart ? AgentTerminalIdentity.reported(identity) : null;
  var id = told != null ? told : record.agentSession;
  if (id != null && !valid(id)) id = null;
  var reporting = AgentTerminalIdentity.reporting(provider, identity, !restart);
  var name = provider == "claude" ? "Claude Code" : provider == "codex" ? "Codex" : "Pi";
  if (!restart) id = null;
  if (id == null) {
   if (provider == "codex")
    return {arguments: reporting, session: null, note: restart ? "── Codex restarted (new conversation) ──" : plain.note};
   id = newUuid(record.id);
   return {arguments: reporting.concat(["--session-id", id]), session: id,
    note: restart ? "── " + name + " restarted (new conversation) ──" : plain.note};
  }
  var resumed = "── " + name + " resumed ──";
  return switch (provider) {
   // Claude keeps no record of a conversation in which nothing was said yet; that one is begun again under its id.
   case "claude": ClaudeTranscript.locate(id, record.cwd) != null
    ? {arguments: reporting.concat(["--resume", id]), session: id, note: resumed}
    : {arguments: reporting.concat(["--session-id", id]), session: id, note: "── Claude Code restarted ──"};
   case "codex": {arguments: reporting.concat(["resume", id]), session: id, note: resumed};
   // Pi opens the session of that id in the folder, or begins it.
   default: {arguments: reporting.concat(["--session-id", id]), session: id, note: resumed};
  }
 }

 /** An id a provider is given on its command line: letters, digits, `.`, `_` and `-`, beginning with a letter or digit. */
 static function valid(id:String):Bool return ~/^[0-9A-Za-z][0-9A-Za-z._-]{0,127}$/.match(id);

 static function newUuid(seed:String):String {
  var hex = haxe.crypto.Sha256.encode(Std.string(Sys.time()) + ":" + Math.random() + ":" + seed);
  return hex.substr(0, 8) + "-" + hex.substr(8, 4) + "-4" + hex.substr(13, 3) + "-a" + hex.substr(17, 3) + "-" + hex.substr(20, 12);
 }
}
