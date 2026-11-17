# Relay identity: relay ids, the invitation fingerprint and proven registration

How a machine names itself to a relay, and how a phone knows it reached the right machine. Code:
`src/workspace/transport/MachineKeys.hx` (the derived values), `suit/src/suit/remote/MachineRelayIds.hx` (which id a
relay gets), `src/workspace/client/PairingLink.hx` (the invitation link), `relay/worker/src/index.ts` (the Worker).

## Why

The relay (`relay/worker`) addresses a machine by a 16-byte id in the URL path and registers ids first come, first
served: the first bearer to `POST /register` an id owns it. suit used to register the hex of its catalog id on every
relay. That id is in every invitation URL, so anyone who had seen an old invitation could register it on a relay the
machine had not used yet, and the machine got `machine_identity_conflict` there for good. No access is gained (Noise
pins the machine key, and devices are registered by the machine), but the machine is locked out of that relay.

Separately, the phone learned the machine's key only from the Noise handshake. A relay that answered the pairing with
its own key was caught only if the user compared the six-digit code.

## Values derived from the machine key

The machine key is the Noise static public key (32 bytes, X25519) suit uses with a relay.

| Name | Value | Where |
| --- | --- | --- |
| fingerprint | first 16 bytes of SHA-256(key), 32 hex digits | the invitation URL's `#mk=` fragment |
| relay id | first 16 bytes of SHA-256(`"exosuit-relay-id/1"` + key), 32 hex digits | the relay URL path, `/v1/machines/<relay id>/` |
| registration proof | HMAC-SHA256(key = X25519(machine private key, challenge key); message = `"exosuit-relay-register/1"` + relay id (16 bytes) + challenge key (32 bytes) + SHA-256(bearer as its 64 hex characters)), 64 hex digits | proven registration |

Vectors (key = bytes 0..31): fingerprint `630dcd2966c4336691125448bbb25b4f`, relay id
`5ff11fa2bc5136b8ccf63b6c679d6f8d`; with shared secret 32 x `11`, challenge bytes 32..63 and bearer `ab` x 32 the
proof is `bd14af04eba3b85dbfb2bca787b9a64bcf63070ec15a5e2de9170096057b1598`. `relay/worker/test/identity.test.ts` checks them.

## Relay ids (suit)

Turning remote access on with a relay picks its relay id (`MachineRelayIds.choose`):

1. the id remembered for that relay origin in `machine-relay-ids.json` (suit's home);
2. else the catalog id's hex, when suit already holds a bearer for the relay under it: a relay used before relay ids
   were separate keeps that id, so its devices stay paired;
3. else a new id: suit makes a Noise key for this relay, stores it as the relay identity's key
   (`noise-static:<relay id>` in the credential store) and derives the relay id from it.

`machine-relay.json` keeps its version 1 shape (`origin`, `machineId` = the relay id). Turning remote access off deletes
it but keeps `machine-relay-ids.json`, the bearer and the key, so on again with the same relay keeps the id.

The machine directory names the relay id in its optional field 5, `relay` (RPC-VECTORS.md, method 180). The phone
accepts a directory that names its relay id under any machine id. A machine that sends no `relay` must answer with the
relay id, or `machine-` and the relay id, as its machine id (the old rule).

## The invitation fingerprint

`PairingInvitation` field 7, `invitationUrl`, is `pairingSocketUrl` + `#mk=<fingerprint>`. The Remote Access panel
shows and copies it. The phone (`PairingLink`) connects to the URL without the fragment, so the relay never sees it.
After the Noise handshake:

- the key reached does not match: the pairing ends with "The machine that answered is not the one that made this
  invitation: its key does not match the invitation. Nothing was paired.";
- it matches: under the code, "The machine's key matches the invitation.";
- the link has no fragment (an older desktop): the phone pairs as before and shows "This invitation carries no machine
  key (it comes from an older desktop), so comparing the code is the only check."

The phone logs `exosuit-pairing: machine key matches the invitation` or `exosuit-pairing: the invitation has no machine
key` for the acceptance scripts, in test runs only (the rig's `EXOSUIT_AUTOMATION_DIR`). The code comparison stays in both cases.

## Proven registration (Worker)

Plain registration is unchanged: `POST /v1/machines/<id>/register` with `Authorization: Bearer <token>` and no body or a
JSON body without `proof`. The first bearer gets 201, the same bearer 204, another 409.

Proven registration:

1. `POST /v1/machines/<id>/register/challenge` (no credential) returns 201 `{"challenge": "<64 hex>",
   "expiresInSeconds": 60}`: the public half of a one-use X25519 key the Durable Object keeps for 60 s (at most 8 at
   once). A challenge younger than 10 s is never evicted: when all 8 slots are that young the answer is 429 with
   `Retry-After` (seconds until the oldest may go), otherwise the oldest older challenge makes room. One client
   address (`CF-Connecting-IP`) also gets a token bucket per machine id (6 at once, one more every 2 s, stored in
   `challenge_bucket`): beyond it, 429 with `Retry-After`. So a flood neither evicts the challenge the machine is about to
   register with nor, from one address, keeps the table full; suit waits the `Retry-After` and dials again.
2. `POST /v1/machines/<id>/register`, the bearer, JSON `{"publicKey": "<64 hex>", "challenge": "<64 hex>", "proof":
   "<64 hex>"}`. The Worker checks that `<id>` is the relay id of `publicKey` (else 400 `machine_id_not_derived`), uses
   the challenge up (unknown or expired: 401 `invalid_challenge`), and recomputes the proof (mismatch, or an all-zero
   X25519 result: 401 `invalid_proof`). Then:
   - no credential yet: 201, the bearer owns the id;
   - the same bearer: 204;
   - another bearer: 201 `{"registered": true, "reclaimed": true}`. The bearer is replaced and everything the previous
     one set up goes: pending invitations, devices, tickets, and every open socket (closed with 1008).
   The key is stored (`machine_key`) either way.

suit registers plainly, as before. Only when that gives 409 and its relay id is derived from its key
(`RelayRegistrationProver.forKey`) does it ask for a challenge and register with a proof. A Worker without proven
registration answers the challenge with 404; suit then reports the original `machine_identity_conflict`.

What it does not cover:

- Relays whose id is the catalog id (step 2 above) cannot prove it. They keep first-come registration and the
  explanation in the Remote Access status. Turning remote access off and choosing another relay gives a new, derived id.
- Someone who registers a derived id first (before the machine) can hold it only until the machine connects to a
  Worker with proven registration. A derived id is not in any invitation before the machine registered it.
- Many addresses together can still keep all 8 slots young (the machine then gets 429 and retries, and gets a slot as soon
  as the oldest challenge passes 10 s). Stateless challenges would close that; not done.

## Compatibility

| Pairing | Deployed Worker (no proofs) | Worker with proofs |
| --- | --- | --- |
| New suit, new phone | works; a squatted derived id stays a conflict | works; a squatted id is taken back |
| New suit, older phone | the older phone refuses a link with `#mk=`; without the fragment it pairs (no key check). Then it works with a relay set up before (catalog id) and refuses the directory of a relay set up now ("answered for another machine id"): update the phone | same |
| Older suit, new phone | works; the link has no fingerprint, the phone says so | works |
