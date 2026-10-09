package ui;

import haxe.Int64;
import haxe.io.Bytes;
import workspace.TextFileContent;
import haxe.io.BytesBuffer;
import workspace.client.WorkspaceFileClient;
import workspace.service.WorkspaceFileProtocol.FileReadChunkResult;
import workspace.service.WorkspaceFileProtocol.FileReadOpenResult;

/** Bounded, revision-checked read that never materializes data until EOF. */
class WorkspaceFileReader {
	public static inline final MAX_PREVIEW_BYTES = 16777216;
	static inline final CHUNK_BYTES = 262144;

	public static function previewSize(size:Int64):Null<Int> {
		if (size == null || Int64.compare(size, Int64.ofInt(0)) < 0
			|| Int64.compare(size, Int64.ofInt(MAX_PREVIEW_BYTES)) > 0) return null;
		return Int64.toInt(size);
	}

	public static function read(client:WorkspaceFileClient, workspace:String, root:String, path:String,
			expectedRevision:Null<String>, complete:WorkspaceFileReadResult->Void, ?wanted:Void->Bool):Void {
		if (client == null || complete == null) {
			if (complete != null) complete({contents: null, revision: null, sizeBytes: 0,
				error: "Workspace file service is unavailable"});
			return;
		}
		if (wanted != null && !wanted()) {
			complete({contents: null, revision: null, sizeBytes: 0, error: "File preview was superseded"});
			return;
		}
		client.openRead(workspace, root, path, expectedRevision, function(opened:FileReadOpenResult) {
			if (opened == null || opened.workspace != workspace || opened.root != root || opened.path != path
				|| opened.handle == null || opened.handle.length == 0
				|| expectedRevision != null && opened.revision != expectedRevision
				|| opened.revision == null || opened.revision.length == 0
				|| opened.size == null || Int64.compare(opened.size, Int64.ofInt(0)) < 0) {
				if (opened != null && opened.handle != null && opened.handle.length > 0)
					client.closeRead(workspace, opened.handle, function(_) {}, function(_) {});
				complete({contents: null, revision: null, sizeBytes: 0, error: "Workspace returned invalid file metadata"});
				return;
			}
			var sizeBytes = previewSize(opened.size);
			if (sizeBytes == null) {
				client.closeRead(workspace, opened.handle, function(_) complete({contents: null, revision: null,
					sizeBytes: 0, error: "File is larger than the 16 MiB preview limit"}),
					function(_) complete({contents: null, revision: null, sizeBytes: 0,
						error: "File is larger than the 16 MiB preview limit"}));
				return;
			}
			var handle = opened.handle;
			var size = opened.size;
			var revision = opened.revision;
			var buffer = new BytesBuffer();
			var closed = false;
			var finished = false;
			var close = function(done:Null<String>->Void):Void {
				if (closed) { done(null); return; }
				closed = true;
				client.closeRead(workspace, handle, function(_) done(null), function(error)
					done(error == null ? "Could not close workspace file handle" : error.message));
			};
			var fail = function(message:String):Void {
				if (finished) return;
				finished = true;
				close(function(_) {});
				complete({contents: null, revision: null, sizeBytes: 0, error: message});
			};
			var readNext:Int64->Void = null;
			readNext = function(offset:Int64):Void {
				if (finished) return;
				if (wanted != null && !wanted()) { fail("File preview was superseded"); return; }
				var remaining = Int64.sub(size, offset);
				if (Int64.compare(remaining, Int64.ofInt(0)) == 0) {
					finished = true;
					// Handle cleanup must not add a network round trip before showing valid bytes.
					close(function(_) {});
					var bytes = buffer.getBytes();
					if (!TextFileContent.validUtf8(bytes)) {
						complete({contents: null, revision: null, sizeBytes: 0, error: "File is not valid UTF-8 text"});
						return;
					}
					for (index in 0...bytes.length) if (bytes.get(index) == 0) {
						complete({contents: null, revision: null, sizeBytes: 0,
							error: "Binary files cannot be previewed as text"});
						return;
					}
					complete({contents: bytes.toString(), revision: revision, sizeBytes: sizeBytes, error: null});
					return;
				}
				var count = Int64.compare(remaining, Int64.ofInt(CHUNK_BYTES)) < 0
					? Int64.toInt(remaining) : CHUNK_BYTES;
				client.readChunk(workspace, handle, offset, count, function(chunk:FileReadChunkResult) {
					if (chunk == null || chunk.handle != handle || chunk.revision != revision || chunk.offset == null
						|| Int64.compare(chunk.offset, offset) != 0 || chunk.bytes == null || chunk.bytes.length != count) {
						fail("File changed or returned an invalid read chunk");
						return;
					}
					buffer.addBytes(chunk.bytes, 0, chunk.bytes.length);
					var next = Int64.add(offset, Int64.ofInt(chunk.bytes.length));
					if (chunk.eof) {
						if (Int64.compare(next, size) != 0) { fail("Workspace ended the file read early"); return; }
						readNext(next);
					} else if (Int64.compare(next, size) >= 0) {
						fail("Workspace returned an invalid end-of-file marker");
					} else readNext(next);
				}, function(error) fail(error == null ? "Could not read workspace file" : error.message));
			};
			if (opened.initialBytes != null) {
				if (opened.initialBytes.length != sizeBytes || sizeBytes > CHUNK_BYTES) {
					fail("Workspace returned invalid initial file bytes");
					return;
				}
				buffer.addBytes(opened.initialBytes, 0, opened.initialBytes.length);
				readNext(size);
			} else readNext(Int64.ofInt(0));
		}, function(error) {
			if (error != null && error.code == "revision_changed" && expectedRevision != null) {
				// The listing became stale before open. Re-open against a fresh observed revision;
				// subsequent chunks still have to match that exact revision.
				read(client, workspace, root, path, null, complete, wanted);
				return;
			}
			complete({contents: null, revision: null, sizeBytes: 0,
				error: error == null ? "Could not open workspace file" : error.message});
		}, 5000, CHUNK_BYTES);
	}

}
