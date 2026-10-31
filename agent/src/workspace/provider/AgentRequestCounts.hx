package workspace.provider;

/** A provider that can say how many requests (approvals, questions) wait on each of its sessions, cheaply. */
interface AgentRequestCounts {
 public function requestCounts():Map<String,Int>;
}
