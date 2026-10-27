import haxeon.agent.*;
import haxeon.agent.nativekit.NativeKitHttpTransport;
import haxeon.platform.NativeKitRuntime;

private class UpperTool extends AgentTool {
	public function new()
		super("upper", "Uppercase text", new ToolSchema().string("text", "Text"), ReadOnly);

	override function execute(input:JsonObject, context:ToolContext, done:ToolResult->Void):Void
		done(ToolResult.ok(input.string("text").toUpperCase()));
}

/**
	End-to-end check against a local Anthropic-compatible server (see run.py):
	NativeKit streaming HTTP, the Anthropic stream decoder and a full tool round trip.
**/
class NativeTransportCheck {
	static function main():Void {
		var port = Sys.args()[0];
		var runtime = NativeKitRuntime.start();
		var transport = new NativeKitHttpTransport(runtime.events, true);
		var provider = new AnthropicProvider(transport, "sk-local", "http://127.0.0.1:" + port);
		var agent = new Agent(new AgentOptions(provider, "mock-model", "be terse", [new UpperTool()], new SupervisedPolicy()));
		var transcript:Array<String> = [];
		var ended = false;
		agent.onEvent = function(event) switch event {
			case TextDelta(text):
				transcript.push("text:" + text);
			case ToolCompleted(call, result):
				transcript.push("tool:" + call.name + "=" + result.content);
			case RunEnded(reason):
				ended = true;
				transcript.push(switch reason {
					case Failed(message): "failed:" + message;
					case Aborted: "aborted";
					default: "ended";
				});
			default:
		};
		agent.send("shout hello");
		var deadline = Sys.time() + 20;
		while (!ended && Sys.time() < deadline) {
			runtime.events.wait(0.02);
			while (runtime.events.poll()) {}
		}
		Sys.println(transcript.join("|"));
		transport.dispose();
		runtime.dispose();
		Sys.exit(ended ? 0 : 3);
	}
}
