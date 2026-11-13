package workspace.provider;

/**
 * The form of a path that the file calls accept at any length. hl.exe is not marked long-path aware, so on Windows
 * `FileSystem.exists` and the others fail for a path of 260 characters or more unless it is written `\\?\C:\...` with
 * backslashes only. A provider's record lives under a folder named after the session's whole folder path, so a deep
 * session folder reaches that length. Shorter paths, other systems and paths that are not drive-absolute are returned
 * unchanged.
 */
class LongPath {
 static inline final LIMIT:Int = 240;

 public static function of(path:Null<String>):Null<String> {
  if (path == null || path.length < LIMIT || Sys.systemName() != "Windows") return path;
  if (StringTools.startsWith(path, "\\\\") || !~/^[A-Za-z]:[\\\/]/.match(path)) return path;
  return "\\\\?\\" + haxe.io.Path.normalize(path).split("/").join("\\");
 }
}
