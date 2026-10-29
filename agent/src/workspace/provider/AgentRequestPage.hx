package workspace.provider;

import haxeon.wire.MessagePack;
import workspace.service.WorkspaceAgentProtocol.AgentRequest;

/** Keep pending decisions inside relay-sized snapshots without losing their queue. */
class AgentRequestPage {
 public static inline final MAX_BYTES = 8192;
 public static function project(pending:Array<AgentRequest>):{requests:Array<AgentRequest>, omitted:Int} {
  var requests:Array<AgentRequest> = [];
  for (request in pending) {
   if (requests.length >= 8) break;
   var candidate:Array<AgentRequest> = requests.concat([request]);
   if (MessagePack.encode(candidate).length > MAX_BYTES) {
    if (requests.length > 0) break;
    // Keep the first item's identity and any provider-supported dismissal action.
    requests.push({id:request.id, method:request.method,
     detail:"This request exceeds the display limit. Review it in another compatible client.",reviewable:false});
    break;
   }
   requests.push(request);
  }
  return {requests:requests, omitted:pending.length-requests.length};
 }
}
