package workspace.provider;

/** Codex proxy uses the shared bounded JSONL transport; it never owns the native server. */
class CodexTransport extends AgentJsonTransport {
 public function new(process:process.OwnedProcess) super(process,"Codex");
}
