package workspace.provider;

import haxe.Json;
import haxe.io.Bytes;
import workspace.service.WorkspaceAgentProtocol.AgentQuestion;
import workspace.service.WorkspaceAgentProtocol.AgentQuestionOption;

/** Complete, bounded provider question projection and answer validation. */
class StructuredQuestions {
  static function field(value:Dynamic, name:String):Null<String> {
    var item:Dynamic = value == null ? null : Reflect.field(value, name);
    return Std.isOfType(item, String) ? cast item : null;
  }
  static function flag(value:Dynamic, name:String):Null<Bool> {
    var item:Dynamic = value == null ? null : Reflect.field(value, name);
    return item == null ? false : Std.isOfType(item, Bool) ? cast item : null;
  }
  static function valid(value:Null<String>, limit:Int, empty:Bool = false):Bool
    return value != null && (empty || value.length > 0) && Bytes.ofString(value).length <= limit;

  /** Returns null unless every field can be shown without truncation or guessing. */
  public static function project(provider:String, input:Dynamic):Null<Array<AgentQuestion>> {
    if (provider != "codex" && provider != "claude") return null;
    if (input == null || !Reflect.isObject(input) || Std.isOfType(input, Array)) return null;
    var raw:Dynamic = Reflect.field(input, "questions");
    if (!Std.isOfType(raw, Array)) return null;
    var source:Array<Dynamic> = cast raw;
    if (source.length == 0 || source.length > 8) return null;
    var result:Array<AgentQuestion> = [], ids:Map<String,Bool> = [], texts:Map<String,Bool> = [];
    for (index in 0...source.length) {
      var item = source[index];
      if (item == null || !Reflect.isObject(item) || Std.isOfType(item, Array)) return null;
      var id = provider == "codex" ? field(item,"id") : Std.string(index);
      var header = field(item,"header"), question = field(item,"question");
      var other = provider == "codex" ? flag(item,"isOther") : true;
      var secret = provider == "codex" ? flag(item,"isSecret") : false;
      var multiple = provider == "claude" ? flag(item,"multiSelect") : false;
      if (!valid(id,128) || !valid(header,128,true) || !valid(question,1024) || other == null || secret == null || multiple == null
        || ids.exists(id) || provider == "claude" && texts.exists(question)) return null;
      ids.set(id,true); texts.set(question,true);
      var rawOptions:Dynamic = Reflect.field(item,"options"), options:Array<AgentQuestionOption> = [], labels:Map<String,Bool> = [];
      if (rawOptions != null) {
        if (!Std.isOfType(rawOptions,Array) || (cast rawOptions:Array<Dynamic>).length > 8) return null;
        for (option in (cast rawOptions:Array<Dynamic>)) {
          if (option == null || !Reflect.isObject(option) || Std.isOfType(option, Array)) return null;
          var label = field(option,"label"), description = field(option,"description");
          if (!valid(label,256) || !valid(description,512,true) || labels.exists(label)
            || provider == "claude" && multiple && label.indexOf(",") >= 0) return null;
          labels.set(label,true); options.push({label:label,description:description});
        }
      }
      if (multiple && options.length == 0) return null;
      result.push({id:id,header:header,question:question,multiple:multiple,secret:secret,
        allowOther:options.length == 0 || other,options:options});
    }
    return Bytes.ofString(Json.stringify(result)).length <= 2048 ? result : null;
  }

  /** Validate all answer identities and values against the retained provider request. */
  public static function answers(questions:Array<AgentQuestion>, text:String, provider:String):Null<Map<String,Array<String>>> {
    if (questions == null || text == null || Bytes.ofString(text).length > 8192) return null;
    var raw:Dynamic;
    try raw = Json.parse(text) catch (_:Dynamic) return null;
    if (!Std.isOfType(raw,Array) || (cast raw:Array<Dynamic>).length != questions.length) return null;
    var result:Map<String,Array<String>> = [];
    for (answer in (cast raw:Array<Dynamic>)) {
      if (answer == null || !Reflect.isObject(answer) || Std.isOfType(answer, Array)) return null;
      var id = field(answer,"id"), values:Dynamic = Reflect.field(answer,"answers");
      if (id == null || result.exists(id) || !Std.isOfType(values,Array)) return null;
      var question:Null<AgentQuestion> = null;
      for (candidate in questions) if (candidate.id == id) { question = candidate; break; }
      if (question == null) return null;
      var supplied:Array<Dynamic> = cast values;
      if (supplied.length == 0 || (!question.multiple && supplied.length != 1) || supplied.length > question.options.length + 1) return null;
      var seen:Map<String,Bool> = [], accepted:Array<String> = [], custom = 0;
      for (value in supplied) {
        if (!Std.isOfType(value,String) || !valid(cast value,4096) || seen.exists(cast value)) return null;
        var textValue:String = cast value;
        if (provider == "claude" && question.multiple && textValue.indexOf(",") >= 0) return null;
        var known = false; for (option in question.options) if (option.label == textValue) known = true;
        if (!known && (!question.allowOther || ++custom > 1)) return null;
        seen.set(textValue,true); accepted.push(textValue);
      }
      result.set(id,accepted);
    }
    return result;
  }
}
