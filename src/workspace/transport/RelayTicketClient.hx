package workspace.transport;

import haxe.io.Bytes;
import haxeon.platform.NativeKitEvents;
import haxeon.platform.NativeKitEvents.NativeKitEventSubscription;
import haxeon.platform.NativeKitEventValue;
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
	var complete:Null<RelaySocketTicket>->Null<String>->Void;
}

/** Fetches short-lived relay WebSocket tickets without exposing reusable credentials in URLs. */
class RelayTicketClient {
	final owner:OwnedHttpClientHandle;
	final subscription:NativeKitEventSubscription;
	final pending:Map<String, TicketPending> = [];
	final allowLoopbackHttp:Bool;
	var disposed:Bool = false;

	public function new(events:NativeKitEvents, allowLoopbackHttp:Bool = false) {
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

	/**
		Starts one authenticated POST. The machine bearer is copied into the request
		header by NativeKit and is never put into the WebSocket URL or diagnostics.
	*/
	public function request(endpoint:RelayMachineEndpoint, machineToken:String,
		complete:Null<RelaySocketTicket>->Null<String>->Void):RelayTicketAttempt {
		if (complete == null)
			throw "Relay ticket completion callback cannot be null";
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
		if (endpoint == null || machineToken == null || !RelaySocketTicket.isToken(machineToken)) {
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
			requestOptions.set_method(HttpMethod.Post);
			requestOptions.set_url(endpoint.ticketUrl());
			requestOptions.set_headers([authorization, contentType]);
			requestOptions.set_body_bytes(Bytes.ofString("{}"));
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

	function pendingCount():Int {
		var count = 0;
		for (_ in pending)
			count++;
		return count;
	}

	function onEvent(value:NativeKitEventValue):Void {
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
				if (response.statusCode != 201) {
					var code = response.statusCode == 401 || response.statusCode == 403 ? "relay_unauthorized"
						: response.statusCode == 429 ? "relay_rate_limited"
						: response.statusCode >= 500 ? "relay_unavailable" : "ticket_rejected";
					item.complete(null, code);
					return;
				}
				var ticket:Null<RelaySocketTicket> = null;
				try
					ticket = RelaySocketTicket.parse(response.body)
				catch (_:Dynamic) {
					item.complete(null, "invalid_relay_ticket");
					return;
				}
				item.complete(ticket, null);
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
