package editor;

import workspace.EditorFileSystem;
import workspace.FileStamp;

/** A file read and prepared for a document (Document.load): what is costly about opening one, so it can be made away
	from the UI thread and turned into a document there (Document.fromLoaded). */
class LoadedFile {
	public final path:String;
	public final fileSystem:EditorFileSystem;
	/** The file's text as read, which external-change checks compare with. */
	public final raw:String;
	public final hasBom:Bool;
	public final newline:String;
	/** The text with its byte-order mark removed and line endings normalized, already split into the buffer. */
	public final buffer:TextBuffer;
	/** The file's stamp, when it vouches for `raw`. */
	public final stamp:Null<FileStamp>;

	public function new(path:String, fileSystem:EditorFileSystem, raw:String, hasBom:Bool, newline:String, buffer:TextBuffer,
			stamp:Null<FileStamp>) {
		this.path = path;
		this.fileSystem = fileSystem;
		this.raw = raw;
		this.hasBom = hasBom;
		this.newline = newline;
		this.buffer = buffer;
		this.stamp = stamp;
	}
}
