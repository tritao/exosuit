package workspace.provider;

/** Codex proxy uses the shared bounded JSONL transport; it never owns the native server. */
class CodexTransport extends AgentJsonTransport {
 public static inline final MAX_FRAME_BYTES=6*1024*1024;
 public static inline final MAX_QUEUE_BYTES=8*1024*1024;
 public function new(process:process.OwnedProcess) super(process,"Codex",MAX_FRAME_BYTES,MAX_QUEUE_BYTES);
}
