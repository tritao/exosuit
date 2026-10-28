package workspace.client;

/** Identifies completed source artifacts without interpreting or executing them. */
class SessionArtifact {
 public static function label(language:String, text:String, closed:Bool):Null<String> {
  if (!closed || text == null || StringTools.trim(text) == "") return null;
  var name = language == null ? "" : language.toLowerCase();
  if (name == "html" || name == "htm") return "HTML source";
  if (name == "svg") return "SVG source";
  if (["", "diff", "patch", "sh", "shell", "bash", "zsh", "console", "terminal", "text", "txt", "plaintext", "log", "output", "markdown", "md", "mermaid"].indexOf(name) >= 0) return null;
  return text.length >= 3000 || text.split("\n").length >= 48 ? name + " source" : null;
 }
}
