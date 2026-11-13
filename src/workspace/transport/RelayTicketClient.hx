package workspace.transport;

import haxe.io.Bytes;
import haxeon.platform.event.EventPump;
import haxeon.platform.event.EventSubscription;
import haxeon.platform.event.PlatformEvent;
import nativekit.ffi.NativeKitNet;
import nativekit.ffi.NativeKitNetConstants;
import nativekit.ffi.NativeKitNetTypes.HttpClientOptions;
import nativekit.ffi.NativeKitNetTypes.HttpHeader;
import nativekit.ffi.NativeKitNetTypes.HttpMethod;
import nativekit.ffi.NativeKitNetTypes.HttpRequestMode;
import nativekit.ffi.NativeKitNetTypes.HttpRequestOptions;
import nativekit.ffi.NativeKitNetTypes.OwnedHttpClientHandle;
import nativekit.ffi.NativeKitTypes.Result;

private typedef TicketPending = {
	var attempt:RelayTicketAttempt;
	var complete:Null<haxeon.platform.http.HttpResponse>->Null<String>->Void;
}

/** Fetches short-lived relay WebSocket tickets without exposing reusable credentials in URLs. */
class RelayTicketClient {
	final owner:OwnedHttpClientHandle;
	final subscription:EventSubscription;
	final pending:Map<String, TicketPending> = [];
	final allowLoopbackHttp:Bool;
	var disposed:Bool = false;
	/**
		The relay's Retry-After (milliseconds, 1 to 30 seconds) from the last 429 it gave the challenge request, else 0. The
		dialer's own backoff is the retry loop (there is no timer here); the host waits at least this long.
	**/
	public var retryAfterMilliseconds(default, null):Int = 0;

	public function new(events:EventPump, allowLoopbackHttp:Bool = false) {
		if (events == null)
			throw "Relay ticket client requires the shared NativeKit event pump";
		var options = new HttpClientOptions();
		if (allowLoopbackHttp)
			options.set_flags(NativeKitNetConstants.NK_HTTP_CLIENT_ALLOW_HTTP);
		this.allowLoopbackHttp = allowLoopbackHttp;
		var created = NativeKitNet.nk_http_client_create(options);
		if (created.status != Result.Ok)
			throw "Could not create the NativeKit HTTP client";
		owner = created.out_client;
		subscription = events.listen(onEvent);
	}

	/** Enrolls the bearer once; Worker registration is idempotent for the same key. */
	public function register(endpoint:RelayMachineEndpoint, machineToken:String, complete:Null<String>->Void):RelayTicketAttempt {
		if (complete == null)
			throw "Relay registration callback cannot be null";
		return send(endpoint, machineToken, endpoint == null ? "" : endpoint.registrationUrl(), HttpMethod.Post, "{}", function(response, error) {
			if (error != null) {
				complete(error);
				return;
			}
			if (response == null) {
				complete("ticket_transport_failed");
				return;
			}
			if (response.statusCode == 201 || response.statusCode == 204) {
				complete(null);
				return;
			}
			complete(statusError(response.statusCode));
		});
	}

	/**
		Registers the bearer with a proof that this machine holds the key its relay id is derived from: asks the relay for a
		one-use challenge key, then registers with the proof (`RelayRegistrationProver`). A relay that accepts it gives the id
		to this machine even when another bearer registered it first. A relay without proven registration (the Worker before
		it) answers the challenge with 404: then `relay_registration_unproven`.
	**/
	public function registerProven(endpoint:RelayMachineEndpoint, machineToken:String, prover:RelayRegistrationProver,
		complete:Null<String>->Void):RelayTicketAttempt {
		if (complete == null || prover == null)
			throw "Relay proven registration needs a prover and a callback";
		var current:Null<RelayTicketAttempt> = null;
		var outer = new RelayTicketAttempt(function() {
			if (current != null)
				current.cancel();
		});
		current = send(endpoint, machineToken, endpoint == null ? "" : endpoint.registrationChallengeUrl(), HttpMethod.Post, "{}", function(response, error) {
			if (error != null || response == null) {
				outer.finish();
				complete(error == null ? "ticket_transport_failed" : error);
				return;
			}
			if (response.statusCode == 404 || response.statusCode == 405) {
				outer.finish();
				complete("relay_registration_unproven");
				return;
			}
			if (response.statusCode == 429) {
				retryAfterMilliseconds = retryAfterOf(response);
				outer.finish();
				complete(statusError(429));
				return;
			}
			if (response.statusCode != 201) {
				outer.finish();
				complete(statusError(response.statusCode));
				return;
			}
			retryAfterMilliseconds = 0;
			var body:Null<String> = null;
			try {
				var value:Dynamic = haxe.Json.parse(response.body.toString());
				var challenge:Dynamic = value == null ? null : Reflect.field(value, "challenge");
				if (Std.isOfType(challenge, String) && ~/^[0-9a-f]{64}$/.match(challenge))
					body = prover.body(challenge, machineToken);
			} catch (_:Dynamic) {}
			if (body == null) {
				outer.finish();
				complete("invalid_relay_challenge");
				return;
			}
			current = send(endpoint, machineToken, endpoint.registrationUrl(), HttpMethod.Post, body, function(proven, provenError) {
				outer.finish();
				if (provenError != null || proven == null)
					complete(provenError == null ? "ticket_transport_failed" : provenError);
				else if (proven.statusCode == 201 || proven.statusCode == 204)
					complete(null);
				else
					complete(statusError(proven.statusCode));
			});
		});
		return outer;
	}

	/**
		Starts one authenticated POST. The machine bearer is copied into the request
		header by NativeKit and is never put into the WebSocket URL or diagnostics.
	*/
	public function request(endpoint:RelayMachineEndpoint, machineToken:String,
		complete:Null<RelaySocketTicket>->Null<String>->Void):RelayTicketAttempt {
		if (complete == null)
			throw "Relay ticket completion callback cannot be null";
		return send(endpoint, machineToken, endpoint == null ? "" : endpoint.ticketUrl(), HttpMethod.Post, "{}", function(response, error) {
			if (error != null) {
				complete(null, error);
				return;
			}
			if (response == null) {
				complete(null, "ticket_transport_failed");
				return;
			}
			if (response.statusCode != 201) {
				complete(null, statusError(response.statusCode));
				return;
			}
			var ticket:Null<RelaySocketTicket> = null;
			try
				ticket = RelaySocketTicket.parse(response.body)
			catch (_:Dynamic) {
				complete(null, "invalid_relay_ticket");
				return;
			}
			complete(ticket, null);
		});
	}

	public function createPairing(endpoint:RelayMachineEndpoint, machineToken:String, channelId:String,
		secret:String, ttlSeconds:Int, complete:Null<String>->Void):RelayTicketAttempt {
		if (complete == null)
			throw "Pairing creation callback cannot be null";
		if (endpoint == null || channelId == null || secret == null || !RelaySocketTicket.isToken(secret)
			|| ttlSeconds < 1 || ttlSeconds > 300) {
			complete("invalid_pairing_request");
			return new RelayTicketAttempt(function() {});
		}
		try RelayFrameCodec.decodeChannelId(channelId) catch (_:Dynamic) {
			complete("invalid_pairing_request");
			return new RelayTicketAttempt(function() {});
		}
		var path = endpoint.pairingsUrl();
		return send(endpoint, machineToken, path, HttpMethod.Post,
			haxe.Json.stringify({channelId: channelId, secret: secret, ttlSeconds: ttlSeconds}), function(response, error) {
			if (error != null) complete(error);
			else if (response == null) complete("pairing_transport_failed");
			else if (response.statusCode == 201) complete(null);
			else complete(statusError(response.statusCode));
		});
	}

	public function registerDevice(endpoint:RelayMachineEndpoint, machineToken:String, deviceId:String,
		deviceToken:String, complete:Null<String>->Void):RelayTicketAttempt {
		if (complete == null)
			throw "Device registration callback cannot be null";
		if (endpoint == null || deviceId == null || deviceToken == null || !RelaySocketTicket.isToken(deviceToken)) {
			complete("invalid_device_registration");
			return new RelayTicketAttempt(function() {});
		}
		var path:String;
		try path = endpoint.deviceUrl(deviceId) catch (_:Dynamic) {
			complete("invalid_device_registration");
			return new RelayTicketAttempt(function() {});
		}
		return send(endpoint, machineToken, path, HttpMethod.Put, haxe.Json.stringify({token: deviceToken}), function(response, error) {
			if (error != null) complete(error);
			else if (response == null) complete("device_registration_transport_failed");
			else if (response.statusCode == 201 || response.statusCode == 204) complete(null);
			else complete(statusError(response.statusCode));
		});
	}

	public function revokeDevice(endpoint:RelayMachineEndpoint, machineToken:String, deviceId:String,
		complete:Null<String>->Void):RelayTicketAttempt {
		if (complete == null)
			throw "Device revocation callback cannot be null";
		var path:String;
		try path = endpoint == null ? "" : endpoint.deviceUrl(deviceId) catch (_:Dynamic) {
			complete("invalid_device_id");
			return new RelayTicketAttempt(function() {});
		}
		return send(endpoint, machineToken, path, HttpMethod.Delete, "", function(response, error) {
			if (error != null) complete(error);
			else if (response == null) complete("device_revocation_transport_failed");
			else if (response.statusCode == 204 || response.statusCode == 404) complete(null);
			else complete(statusError(response.statusCode));
		});
	}

	function send(endpoint:RelayMachineEndpoint, machineToken:String, url:String, method:HttpMethod, body:String,
		complete:Null<haxeon.platform.http.HttpResponse>->Null<String>->Void):RelayTicketAttempt {
		var requestId:Null<haxe.Int64> = null;
		var key:Null<String> = null;
		var attempt = new RelayTicketAttempt(function() {
			if (key != null)
				pending.remove(key);
			if (requestId != null)
				NativeKitNet.nk_http_cancel(requestId);
		});
		if (disposed) {
			attempt.finish();
			complete(null, "ticket_client_closed");
			return attempt;
		}
		if (endpoint == null || machineToken == null || !RelaySocketTicket.isToken(machineToken) || url == "") {
			attempt.finish();
			complete(null, "invalid_relay_credentials");
			return attempt;
		}
		if (endpoint.isLoopbackHttp && !allowLoopbackHttp) {
			attempt.finish();
			complete(null, "loopback_http_disabled");
			return attempt;
		}
		if (pendingCount() >= 8) {
			attempt.finish();
			complete(null, "ticket_request_limit");
			return attempt;
		}

		var startFailed = false;
		try {
			var authorization = new HttpHeader();
			authorization.set_name_bytes(Bytes.ofString("Authorization"));
			authorization.set_value_bytes(Bytes.ofString("Bearer " + machineToken));
			var contentType = new HttpHeader();
			contentType.set_name_bytes(Bytes.ofString("Content-Type"));
			contentType.set_value_bytes(Bytes.ofString("application/json"));
			var requestOptions = new HttpRequestOptions();
			requestOptions.set_method(method);
			requestOptions.set_url(url);
			requestOptions.set_headers([authorization, contentType]);
			requestOptions.set_body_bytes(Bytes.ofString(body));
			requestOptions.set_mode(HttpRequestMode.Buffered);
			requestOptions.set_timeout_ms(10000);
			requestOptions.set_max_response_size(4096);
			var started = NativeKitNet.nk_http_request(owner.borrow(), requestOptions);
			if (started.status == Result.Ok) {
				requestId = started.out_request;
				key = Std.string(requestId);
				pending.set(key, {attempt: attempt, complete: complete});
			} else {
				startFailed = true;
			}
		} catch (_:Dynamic) {
			startFailed = true;
		}
		if (startFailed) {
			attempt.cancel();
			complete(null, "ticket_request_failed");
		}
		return attempt;
	}

	/** The Retry-After header in whole seconds, clamped to 1..30; 2 seconds when absent or not a number. */
	static function retryAfterOf(response:haxeon.platform.http.HttpResponse):Int {
		var seconds = 2;
		for (header in response.headers) {
			if (header.name.toLowerCase() == "retry-after") {
				var parsed = Std.parseInt(StringTools.trim(header.value));
				if (parsed != null)
					seconds = parsed;
			}
		}
		return Std.int(Math.max(1, Math.min(30, seconds))) * 1000;
	}

	static function statusError(status:Int):String
		return status == 401 || status == 403 ? "relay_unauthorized"
			: status == 409 ? "machine_identity_conflict"
			: status == 429 ? "relay_rate_limited"
			: status >= 500 ? "relay_unavailable" : "relay_rejected";

	function pendingCount():Int {
		var count = 0;
		for (_ in pending)
			count++;
		return count;
	}

	function onEvent(value:PlatformEvent):Void {
		switch value {
			case HttpComplete(_, id, result, response):
				// Buffered HTTP events have no source handle. NativeKit allocates request
				// IDs globally, so the request ID is the stable shared-pump correlation key.
				var key = Std.string(id);
				var item = pending.get(key);
				if (item == null)
					return;
				pending.remove(key);
				item.attempt.finish();
				if (result != Result.Ok) {
					item.complete(null, "ticket_transport_failed");
					return;
				}
				item.complete(response, null);
			default:
		}
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		subscription.dispose();
		for (item in pending)
			item.attempt.finish();
		pending.clear();
		owner.close();
	}
}
