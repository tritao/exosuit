package workspace;

interface EditorFileSystem {
	function normalize(path:String):String;
	function exists(path:String):Bool;
	function isDirectory(path:String):Bool;
	function entries(path:String):Array<String>;
	function join(parent:String, name:String):String;
	function read(path:String):String;
	/** The file's stamp, or null when it is missing or cannot be stamped. */
	function stamp(path:String):Null<FileStamp>;
	function writeAtomic(path:String, content:String):Bool;
	function createFile(path:String):Bool;
	function createFolder(path:String):Bool;
	function rename(path:String, destination:String):Bool;
	function deleteFile(path:String):Bool;
}
