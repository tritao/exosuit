package workspace.provider;

/** Where the built-in agent talks to and which model it starts with. Read once by the daemon. */
class AgentKitSettings {
	public static inline var DefaultModel = "claude-sonnet-5-5";

	public final apiKey:Null<String>;
	public final baseUrl:String;
	public final model:String;
	public final stateDirectory:String;

	public function new(apiKey:Null<String>, baseUrl:String, model:String, stateDirectory:String) {
		this.apiKey = apiKey;
		this.baseUrl = baseUrl;
		this.model = model;
		this.stateDirectory = stateDirectory;
	}

	/** `EXOSUIT_AGENT_API_KEY` wins over `ANTHROPIC_API_KEY`; `EXOSUIT_AGENT_API_URL` and `EXOSUIT_AGENT_MODEL` override defaults. */
	public static function fromEnvironment(stateDirectory:String):AgentKitSettings {
		var key = nonEmpty(Sys.getEnv("EXOSUIT_AGENT_API_KEY"));
		if (key == null)
			key = nonEmpty(Sys.getEnv("ANTHROPIC_API_KEY"));
		var url = nonEmpty(Sys.getEnv("EXOSUIT_AGENT_API_URL"));
		var model = nonEmpty(Sys.getEnv("EXOSUIT_AGENT_MODEL"));
		return new AgentKitSettings(key, url == null ? haxeon.agent.AnthropicProvider.DefaultBaseUrl : url, model == null ? DefaultModel : model,
			stateDirectory);
	}

	/** Plain HTTP is only meaningful for a local gateway or a test server. */
	public function allowsPlainHttp():Bool
		return StringTools.startsWith(baseUrl, "http://");

	static function nonEmpty(value:Null<String>):Null<String>
		return value == null || value == "" ? null : value;
}
