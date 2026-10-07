package ui;

import haxe.Int64;
import haxe.io.Bytes;
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
			expectedRevision:Null<String>, complete:WorkspaceFileReadResult->Void):Void {
		if (client == null || complete == null) {
			if (complete != null) complete({contents: null, revision: null, sizeBytes: 0,
				error: "Workspace file service is unavailable"});
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
				close(function(_) complete({contents: null, revision: null, sizeBytes: 0, error: message}));
			};
			var readNext:Int64->Void = null;
			readNext = function(offset:Int64):Void {
				if (finished) return;
				var remaining = Int64.sub(size, offset);
				if (Int64.compare(remaining, Int64.ofInt(0)) == 0) {
					finished = true;
					close(function(closeError) {
						if (closeError != null) { complete({contents: null, revision: null, sizeBytes: 0, error: closeError}); return; }
						var bytes = buffer.getBytes();
						if (!validUtf8(bytes)) {
							complete({contents: null, revision: null, sizeBytes: 0, error: "File is not valid UTF-8 text"});
							return;
						}
						for (index in 0...bytes.length) if (bytes.get(index) == 0) {
							complete({contents: null, revision: null, sizeBytes: 0,
								error: "Binary files cannot be previewed as text"});
							return;
						}
						complete({contents: bytes.toString(), revision: revision, sizeBytes: sizeBytes, error: null});
					});
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
			readNext(Int64.ofInt(0));
		}, function(error) {
			if (error != null && error.code == "revision_changed" && expectedRevision != null) {
				// The listing became stale before open. Re-open against a fresh observed revision;
				// subsequent chunks still have to match that exact revision.
				read(client, workspace, root, path, null, complete);
				return;
			}
			complete({contents: null, revision: null, sizeBytes: 0,
				error: error == null ? "Could not open workspace file" : error.message});
		});
	}

	static function validUtf8(bytes:Bytes):Bool {
		var index = 0;
		while (index < bytes.length) {
			var first = bytes.get(index++);
			if (first <= 0x7f) continue;
			var continuation:Int;
			var secondMin = 0x80, secondMax = 0xbf;
			if (first >= 0xc2 && first <= 0xdf) continuation = 1;
			else if (first == 0xe0) { continuation = 2; secondMin = 0xa0; }
			else if (first >= 0xe1 && first <= 0xec || first >= 0xee && first <= 0xef) continuation = 2;
			else if (first == 0xed) { continuation = 2; secondMax = 0x9f; }
			else if (first == 0xf0) { continuation = 3; secondMin = 0x90; }
			else if (first >= 0xf1 && first <= 0xf3) continuation = 3;
			else if (first == 0xf4) { continuation = 3; secondMax = 0x8f; }
			else return false;
			if (index + continuation > bytes.length) return false;
			var second = bytes.get(index++);
			if (second < secondMin || second > secondMax) return false;
			for (_ in 1...continuation) {
				var next = bytes.get(index++);
				if (next < 0x80 || next > 0xbf) return false;
			}
		}
		return true;
	}
}
