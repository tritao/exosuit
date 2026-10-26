package scm.git;

import haxe.Int64;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import jobs.JobHandle;
import jobs.JobScheduler;
import jobs.JobTask;
import process.OwnedProcess;
import process.ProcessManager;
import process.ProcessState;
import scm.ScmBlob;
import scm.ScmError;
import scm.ScmJob;
import scm.ScmJobResult;

/** FIFO reader for one repository's long-lived `git cat-file --batch` process. */
class GitBlobReader implements JobTask {
	public static inline final DEFAULT_MAX_BLOB_BYTES = 64 * 1024 * 1024;
	public static inline final DEFAULT_IDLE_TIMEOUT_SECONDS = 60.0;
	static inline final MAX_HEADER_BYTES = 8192;
	static inline final READ_CHUNKS_PER_STEP = 4;
	static inline final MAX_BYTES_PER_STEP = 64 * 1024;

	final processes:ProcessManager;
	final scheduler:JobScheduler;
	final git:GitProcess;
	final repositoryRoot:String;
	final restricted:Bool;
	final maxBlobBytes:Int;
	final idleTimeoutSeconds:Float;
	final clock:Void->Float;
	final queued:Array<BlobRequest> = [];
	final chunks:Array<Bytes> = [];

	var process:Null<OwnedProcess>;
	var active:Null<BlobRequest>;
	var scheduled:Bool = false;
	var handle:Null<JobHandle>;
	var disposed:Bool = false;
	var chunkIndex:Int = 0;
	var chunkOffset:Int = 0;
	var responseState:Int = 0; // header, body, delimiter
	var header:BytesBuffer = new BytesBuffer();
	var headerLength:Int = 0;
	var responseType:String = "";
	var bodyRemaining:Int64 = Int64.ofInt(0);
	var bodyOversized:Bool = false;
	var body:BytesBuffer = new BytesBuffer();
	var binary:Bool = false;
	var binaryPrefixRemaining:Int = 8000;
	var stderr:String = "";
	var lastActivity:Float = 0;

	public function new(processes:ProcessManager, scheduler:JobScheduler, git:GitProcess, repositoryRoot:String,
			restricted:Bool = false, maxBlobBytes:Int = DEFAULT_MAX_BLOB_BYTES,
			idleTimeoutSeconds:Float = DEFAULT_IDLE_TIMEOUT_SECONDS, ?clock:Void->Float) {
		this.processes = processes;
		this.scheduler = scheduler;
		this.git = git;
		this.repositoryRoot = repositoryRoot;
		this.restricted = restricted;
		this.maxBlobBytes = maxBlobBytes < 0 ? 0 : maxBlobBytes;
		this.idleTimeoutSeconds = idleTimeoutSeconds < 0 ? 0 : idleTimeoutSeconds;
		this.clock = clock == null ? Sys.time : clock;
	}

	/** Reads `<reference>:<path>`; `path` remains byte-exact up to Git's line delimiter. */
	public function read(reference:String, path:Bytes, generation:Int, complete:ScmJobResult<ScmBlob>->Void):ScmJob<ScmBlob> {
		var error = validateSpec(reference, path);
		var spec = new BytesBuffer(), prefix = Bytes.ofString(reference + ":");
		spec.add(prefix);
		spec.add(path);
		spec.addByte(10);
		return enqueue(spec.getBytes(), generation, complete, error);
	}

	/** Reads an object token directly; useful for blob ids and diagnosing ambiguous prefixes. */
	public function readObject(object:String, generation:Int, complete:ScmJobResult<ScmBlob>->Void):ScmJob<ScmBlob> {
		var error:Null<ScmError> = null;
		if (object.length == 0 || object.indexOf("\n") >= 0 || object.indexOf("\r") >= 0)
			error = new ScmError("invalid_blob_reference", "Git object reference is empty or contains a line delimiter");
		var bytes = Bytes.ofString(object);
		for (index in 0...bytes.length) if (bytes.get(index) == 0)
			error = new ScmError("invalid_blob_reference", "Git object reference cannot contain NUL");
		var spec = Bytes.alloc(bytes.length + 1);
		spec.blit(0, bytes, 0, bytes.length);
		spec.set(bytes.length, 10);
		return enqueue(spec, generation, complete, error);
	}

	function enqueue(spec:Bytes, generation:Int, complete:ScmJobResult<ScmBlob>->Void, error:Null<ScmError>):ScmJob<ScmBlob> {
		var request:Null<BlobRequest> = null;
		var job = new ScmJob<ScmBlob>(generation, function() {
			if (request != null) cancelRequest(request);
		});
		if (error != null) {
			if (job.finish()) complete(new ScmJobResult<ScmBlob>(generation, null, error));
			return job;
		}
		request = new BlobRequest(generation, spec.sub(0, spec.length), job, complete);
		if (disposed) {
			if (job.finish()) complete(new ScmJobResult<ScmBlob>(generation, null, new ScmError("operation_failed", "Blob reader is closed")));
			return job;
		}
		queued.push(request);
		ensureScheduled();
		return job;
	}

	/** Called by the repository owner after its config/commondir watch changes. */
	public function configurationChanged():Void {
		if (disposed) return;
		if (process != null) dropProcess();
		if (active != null)
			finishActive(null, new ScmError("operation_failed", "Repository configuration changed during blob read; retry the request", true));
		resetResponse();
		if (queued.length > 0) ensureScheduled();
	}

	/** The owner calls this from its regular update to retire an idle process. */
	public function expireIdle(now:Null<Float> = null):Bool {
		if (disposed || process == null || active != null || queued.length > 0) return false;
		var currentTime = now == null ? clock() : now;
		if (currentTime - lastActivity < idleTimeoutSeconds) return false;
		dropProcess();
		return true;
	}

	public function step():Bool {
		if (disposed) return true;
		if (active == null) {
			while (queued.length > 0 && active == null) {
				var next = queued.shift();
				if (!next.cancelled) { active = next; stderr = ""; }
			}
		}
		if (active == null) return finishStep();
		if (process == null) {
			try {
				process = git.startBlobBatch(repositoryRoot, restricted);
				lastActivity = clock();
			} catch (error:Dynamic) {
				finishActive(null, new ScmError("git_unavailable", "Could not start Git blob reader: " + bounded(Std.string(error), GitProcess.MAX_STDERR), true));
				return queued.length == 0 ? finishStep() : false;
			}
		}
		var child = process;
		if (child == null) return queued.length == 0 ? finishStep() : false;
		var current = active;
		if (current != null && !current.sent) {
			try {
				for (_ in 0...READ_CHUNKS_PER_STEP) {
					var remaining = current.spec.length - current.writeOffset;
					if (remaining <= 0) { current.sent = true; break; }
					var written:Int = child.writeBytes(current.spec, current.writeOffset, remaining);
					if (written < 0 || written > remaining) {
						protocolFailure("Git accepted an invalid number of request bytes");
						return queued.length == 0 ? finishStep() : false;
					}
					if (written == 0) break;
					current.writeOffset += written;
					lastActivity = clock();
				}
				if (current.writeOffset == current.spec.length) current.sent = true;
			} catch (error:Dynamic) {
				processFailure("Git blob request write failed: " + bounded(Std.string(error), GitProcess.MAX_STDERR));
				return queued.length == 0 ? finishStep() : false;
			}
		}
		if (active != null && active.sent) {
			try {
				for (_ in 0...READ_CHUNKS_PER_STEP) {
					var bytes = child.readStdoutBytes();
					if (bytes.length == 0) break;
					chunks.push(bytes);
					lastActivity = clock();
				}
				for (_ in 0...READ_CHUNKS_PER_STEP) {
					var text = child.readStderr();
					if (text.length == 0) break;
					if (stderr.length < GitProcess.MAX_STDERR)
						stderr += text.substring(0, Std.int(Math.min(text.length, GitProcess.MAX_STDERR - stderr.length)));
					lastActivity = clock();
				}
			} catch (error:Dynamic) {
				processFailure("Git blob response read failed: " + bounded(Std.string(error), GitProcess.MAX_STDERR));
				return queued.length == 0 ? finishStep() : false;
			}
			if (!consumeAvailable()) return queued.length == 0 ? finishStep() : false;
		}
		child = process;
		if (child != null && child.state() != ProcessState.RUNNING) {
			var message = stderr.length == 0 ? "Git blob reader exited before completing its response" : stderr;
			dropProcess();
			if (active != null) finishActive(null, new ScmError("operation_failed", bounded(message, GitProcess.MAX_STDERR), true));
		}
		return queued.length == 0 && active == null ? finishStep() : false;
	}

	public function cancel():Void dispose();

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		var scheduledHandle = handle;
		handle = null;
		scheduled = false;
		if (scheduledHandle != null) scheduler.cancel(scheduledHandle);
		var requests = queued.copy();
		queued.resize(0);
		if (active != null) requests.push(active);
		active = null;
		// Callers still waiting are told the reader went away, rather than left without an answer: a reader is disposed
		// when its repository's handle is, which a caller cannot see.
		for (request in requests)
			if (!request.cancelled && request.job.finish())
				request.complete(new ScmJobResult<ScmBlob>(request.generation, null,
					new ScmError("repository_closed", "The Git repository was closed while reading a blob", true)));
		dropProcess();
		resetResponse();
	}

	public function activeProcess():Bool return process != null && process.state() == ProcessState.RUNNING;
	public function activeProcessId():Int return process == null ? -1 : process.id;

	function validateSpec(reference:String, path:Bytes):Null<ScmError> {
		if (reference.length == 0 || reference.indexOf("\n") >= 0 || reference.indexOf("\r") >= 0)
			return new ScmError("invalid_blob_reference", "Git blob reference is empty or contains a line delimiter");
		var referenceBytes = Bytes.ofString(reference);
		for (index in 0...referenceBytes.length) if (referenceBytes.get(index) == 0)
			return new ScmError("invalid_blob_reference", "Git blob reference cannot contain NUL");
		for (index in 0...path.length) {
			var byte = path.get(index);
			if (byte == 10 || byte == 0)
				return new ScmError("invalid_blob_path", "Git batch blob paths cannot contain NUL or line feed bytes");
		}
		return null;
	}

	function ensureScheduled():Void {
		if (disposed || scheduled) return;
		scheduled = true;
		handle = scheduler.schedule(this);
	}

	function finishStep():Bool {
		scheduled = false;
		handle = null;
		return true;
	}

	function cancelRequest(request:BlobRequest):Void {
		if (request.cancelled || request.job.complete) return;
		request.cancelled = true;
		if (queued.remove(request)) return;
		if (active == request && !request.sent && request.writeOffset == 0) {
			active = null;
			resetResponse();
		}
		if (!disposed && (active != null || queued.length > 0)) ensureScheduled();
	}

	function consumeAvailable():Bool {
		var work = 0;
		while (work < MAX_BYTES_PER_STEP && active != null) {
			if (responseState == 0) {
				var byte = readByte();
				if (byte < 0) break;
				work++;
				if (byte == 10) {
					if (!parseHeader()) return false;
				} else {
					if (++headerLength > MAX_HEADER_BYTES) {
						protocolFailure("Git blob response header exceeded its limit");
						return false;
					}
					header.addByte(byte);
				}
			} else if (responseState == 1) {
				if (!consumeBody()) break;
			} else {
				var delimiter = readByte();
				if (delimiter < 0) break;
				work++;
				if (delimiter != 10) {
					protocolFailure("Git blob response was not followed by its required newline");
					return false;
				}
				if (bodyOversized)
					finishActive(null, new ScmError("blob_too_large", 'Git blob exceeds the $maxBlobBytes byte limit'));
				else if (responseType != "blob")
					finishActive(null, new ScmError("not_a_blob", "The selected Git object is not a blob"));
				else
					finishActive(new ScmBlob(body.getBytes(), binary), null);
			}
		}
		discardConsumedChunks();
		return active != null;
	}

	function parseHeader():Bool {
		var line = header.getBytes().toString();
		if (line == "missing" || StringTools.endsWith(line, " missing")) {
			var errorCode = stderr.toLowerCase().indexOf("ambiguous") >= 0 ? "ambiguous_object" : "missing_object";
			var message = errorCode == "ambiguous_object" ? "Git found an ambiguous blob reference" : "Git could not find the requested blob";
			finishActive(null, new ScmError(errorCode, message));
			return true;
		}
		if (line == "ambiguous" || StringTools.endsWith(line, " ambiguous")) {
			finishActive(null, new ScmError("ambiguous_object", "Git found an ambiguous blob reference"));
			return true;
		}
		var fields = line.split(" ");
		if (fields.length != 3 || fields[0].length == 0 || fields[1].length == 0) {
			protocolFailure("Git returned an invalid cat-file header");
			return false;
		}
		var size = parseSize(fields[2]);
		if (size == null) {
			protocolFailure("Git returned an invalid cat-file size");
			return false;
		}
		responseType = fields[1];
		bodyRemaining = size;
		bodyOversized = Int64.compare(size, Int64.ofInt(maxBlobBytes)) > 0;
		responseState = Int64.compare(size, Int64.ofInt(0)) == 0 ? 2 : 1;
		return true;
	}

	function consumeBody():Bool {
		while (bodyRemaining != Int64.ofInt(0)) {
			var available = currentChunkAvailable();
			if (available == 0) return false;
			var count = Int64.compare(bodyRemaining, Int64.ofInt(available)) < 0 ? Int64.toInt(bodyRemaining) : available;
			var current = chunks[chunkIndex];
			if (!bodyOversized) {
				var inspect = Std.int(Math.min(count, binaryPrefixRemaining));
				for (index in 0...inspect) if (current.get(chunkOffset + index) == 0) { binary = true; break; }
				binaryPrefixRemaining -= inspect;
				body.addBytes(current, chunkOffset, count);
			}
			chunkOffset += count;
			bodyRemaining = bodyRemaining - Int64.ofInt(count);
		}
		responseState = 2;
		return true;
	}

	function currentChunkAvailable():Int {
		while (chunkIndex < chunks.length && chunkOffset >= chunks[chunkIndex].length) {
			chunkIndex++;
			chunkOffset = 0;
		}
		return chunkIndex >= chunks.length ? 0 : chunks[chunkIndex].length - chunkOffset;
	}

	function readByte():Int {
		if (currentChunkAvailable() == 0) return -1;
		return chunks[chunkIndex].get(chunkOffset++);
	}

	function discardConsumedChunks():Void {
		if (chunkIndex > 0) {
			chunks.splice(0, chunkIndex);
			chunkIndex = 0;
		}
		if (chunks.length == 0) chunkOffset = 0;
	}

	function parseSize(value:String):Null<Int64> {
		if (value.length == 0) return null;
		for (index in 0...value.length) {
			var code = value.charCodeAt(index);
			if (code < 48 || code > 57) return null;
		}
		try {
			var parsed = Int64.parseString(value);
			return Int64.compare(parsed, Int64.ofInt(0)) < 0 ? null : parsed;
		} catch (_:Dynamic) return null;
	}

	function finishActive(blob:Null<ScmBlob>, error:Null<ScmError>):Void {
		var request = active;
		active = null;
		resetResponse();
		if (request != null && !request.cancelled && request.job.finish())
			request.complete(new ScmJobResult<ScmBlob>(request.generation, blob, error));
	}

	function protocolFailure(message:String):Void {
		dropProcess();
		if (active != null) finishActive(null, new ScmError("operation_failed", message, true));
		resetResponse();
	}

	function processFailure(message:String):Void {
		dropProcess();
		if (active != null) finishActive(null, new ScmError("operation_failed", bounded(message, GitProcess.MAX_STDERR), true));
		resetResponse();
	}

	function dropProcess():Void {
		var child = process;
		process = null;
		if (child != null) processes.release(child);
		chunks.resize(0);
		chunkIndex = 0;
		chunkOffset = 0;
		stderr = "";
	}

	function resetResponse():Void {
		responseState = 0;
		header = new BytesBuffer();
		headerLength = 0;
		responseType = "";
		bodyRemaining = Int64.ofInt(0);
		bodyOversized = false;
		body = new BytesBuffer();
		binary = false;
		binaryPrefixRemaining = 8000;
	}

	static function bounded(value:String, limit:Int):String return value.length <= limit ? value : value.substring(0, limit);
}

private class BlobRequest {
	public final generation:Int;
	public final spec:Bytes;
	public final job:ScmJob<ScmBlob>;
	public final complete:ScmJobResult<ScmBlob>->Void;
	public var writeOffset:Int = 0;
	public var sent:Bool = false;
	public var cancelled:Bool = false;

	public function new(generation:Int, spec:Bytes, job:ScmJob<ScmBlob>, complete:ScmJobResult<ScmBlob>->Void) {
		this.generation = generation;
		this.spec = spec;
		this.job = job;
		this.complete = complete;
	}
}
