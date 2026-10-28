package workspace.client;

/** Client-side activity window and explicit older-page availability. */
typedef AgentHistoryState = {
 var loading:Bool;
 var error:Null<String>;
 var hasOlder:Bool;
 var detached:Bool;
 var resetRequired:Bool;
}
