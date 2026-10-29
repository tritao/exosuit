package workspace.client;

/** Validate provider-reported image paths before exposing any file actions. */
class SessionImageActivity {
 public static function target(root:String,cwd:String,path:Null<String>):Null<String> {
  if (root == null || root == "" || cwd == null || cwd == "" || path == null || path == "" || path.length > 1024) return null;
  var target=SessionLinkTarget.parse(path);
  if (target == null || target.line >= 0 || target.path != path) return null;
  var absolute=target.resolve(cwd), relative=SessionLinkTarget.relativeWithin(root,absolute);
  if (relative == null || relative == "") return null;
  return absolute;
 }
}
