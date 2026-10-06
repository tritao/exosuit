#include "noisekit.h"
#include <noise/protocol.h>
#include <string.h>

struct noisekit_handshake {
    NoiseHandshakeState *handshake;
    NoiseCipherState *send;
    NoiseCipherState *receive;
};

static int check_size(uint32_t size)
{
    return size <= NOISEKIT_MAX_MESSAGE_BYTES;
}

int noisekit_keypair_generate(uint8_t *private_key, uint32_t *private_size,
    uint8_t *public_key, uint32_t *public_size)
{
    NoiseDHState *dh = 0;
    int result;
    if (!private_key || !private_size || !public_key || !public_size)
        return NOISE_ERROR_INVALID_PARAM;
    if (*private_size < NOISEKIT_KEY_BYTES || *public_size < NOISEKIT_KEY_BYTES) {
        *private_size = NOISEKIT_KEY_BYTES;
        *public_size = NOISEKIT_KEY_BYTES;
        return NOISE_ERROR_INVALID_LENGTH;
    }
    result = noise_dhstate_new_by_id(&dh, NOISE_DH_CURVE25519);
    if (result != NOISE_ERROR_NONE)
        return result;
    result = noise_dhstate_generate_keypair(dh);
    if (result == NOISE_ERROR_NONE)
        result = noise_dhstate_get_keypair(dh, private_key, NOISEKIT_KEY_BYTES,
                                           public_key, NOISEKIT_KEY_BYTES);
    noise_dhstate_free(dh);
    if (result != NOISE_ERROR_NONE) {
        noise_clean(private_key, NOISEKIT_KEY_BYTES);
        noise_clean(public_key, NOISEKIT_KEY_BYTES);
    }
    if (result == NOISE_ERROR_NONE) {
        *private_size = NOISEKIT_KEY_BYTES;
        *public_size = NOISEKIT_KEY_BYTES;
    }
    return result;
}

int noisekit_public_key(const uint8_t *private_key, uint32_t private_size,
    uint8_t *public_key, uint32_t *public_size)
{
    NoiseDHState *dh = 0;
    int result;
    if (!private_key || private_size != NOISEKIT_KEY_BYTES || !public_key || !public_size)
        return NOISE_ERROR_INVALID_PARAM;
    if (*public_size < NOISEKIT_KEY_BYTES) {
        *public_size = NOISEKIT_KEY_BYTES;
        return NOISE_ERROR_INVALID_LENGTH;
    }
    result = noise_dhstate_new_by_id(&dh, NOISE_DH_CURVE25519);
    if (result != NOISE_ERROR_NONE)
        return result;
    result = noise_dhstate_set_keypair_private(dh, private_key, NOISEKIT_KEY_BYTES);
    if (result == NOISE_ERROR_NONE)
        result = noise_dhstate_get_public_key(dh, public_key, NOISEKIT_KEY_BYTES);
    noise_dhstate_free(dh);
    if (result != NOISE_ERROR_NONE)
        noise_clean(public_key, NOISEKIT_KEY_BYTES);
    else
        *public_size = NOISEKIT_KEY_BYTES;
    return result;
}

int noisekit_handshake_create(int role, const uint8_t *static_private_key,
    uint32_t static_private_key_size, const uint8_t *prologue, uint32_t prologue_size,
    noisekit_handshake **out_state)
{
    struct noisekit_handshake *state;
    NoiseDHState *local;
    int noise_role, result;
    if (!static_private_key || static_private_key_size != NOISEKIT_KEY_BYTES || !out_state || (!prologue && prologue_size) ||
        prologue_size > 1024 || (role != NOISEKIT_INITIATOR && role != NOISEKIT_RESPONDER))
        return NOISE_ERROR_INVALID_PARAM;
    *out_state = 0;
    state = (struct noisekit_handshake *)noise_new(struct noisekit_handshake);
    if (!state)
        return NOISE_ERROR_NO_MEMORY;
    memset(state, 0, sizeof(*state));
    noise_role = role == NOISEKIT_INITIATOR ? NOISE_ROLE_INITIATOR : NOISE_ROLE_RESPONDER;
    result = noise_handshakestate_new_by_name(&state->handshake,
        "Noise_XX_25519_ChaChaPoly_SHA256", noise_role);
    if (result != NOISE_ERROR_NONE)
        goto fail;
    result = noise_handshakestate_set_prologue(state->handshake, prologue, prologue_size);
    if (result != NOISE_ERROR_NONE)
        goto fail;
    local = noise_handshakestate_get_local_keypair_dh(state->handshake);
    if (!local) {
        result = NOISE_ERROR_INVALID_STATE;
        goto fail;
    }
    result = noise_dhstate_set_keypair_private(local, static_private_key, NOISEKIT_KEY_BYTES);
    if (result != NOISE_ERROR_NONE)
        goto fail;
    result = noise_handshakestate_start(state->handshake);
    if (result != NOISE_ERROR_NONE)
        goto fail;
    *out_state = state;
    return NOISE_ERROR_NONE;
fail:
    noisekit_handshake_free(state);
    return result;
}

int noisekit_handshake_free(noisekit_handshake *state)
{
    if (!state)
        return NOISE_ERROR_INVALID_PARAM;
    if (state->send)
        noise_cipherstate_free(state->send);
    if (state->receive)
        noise_cipherstate_free(state->receive);
    if (state->handshake)
        noise_handshakestate_free(state->handshake);
    noise_free(state, sizeof(*state));
    return NOISE_ERROR_NONE;
}

static int split_if_ready(noisekit_handshake *state)
{
    if (state->send && state->receive)
        return NOISE_ERROR_NONE;
    if (noise_handshakestate_get_action(state->handshake) != NOISE_ACTION_SPLIT &&
        noise_handshakestate_get_action(state->handshake) != NOISE_ACTION_COMPLETE)
        return NOISE_ERROR_INVALID_STATE;
    return noise_handshakestate_split(state->handshake, &state->send, &state->receive);
}

int noisekit_handshake_action(const noisekit_handshake *state)
{
    if (!state || !state->handshake)
        return NOISE_ACTION_FAILED;
    return noise_handshakestate_get_action(state->handshake);
}

int noisekit_handshake_write(noisekit_handshake *state, uint8_t *message, uint32_t *inout_size)
{
    NoiseBuffer msg, payload;
    uint8_t empty_payload = 0;
    int result;
    if (!state || !state->handshake || !message || !inout_size || !check_size(*inout_size))
        return NOISE_ERROR_INVALID_PARAM;
    if (noise_handshakestate_get_action(state->handshake) != NOISE_ACTION_WRITE_MESSAGE)
        return NOISE_ERROR_INVALID_STATE;
    noise_buffer_set_output(msg, message, *inout_size);
    noise_buffer_set_input(payload, &empty_payload, 0);
    result = noise_handshakestate_write_message(state->handshake, &msg, &payload);
    if (result != NOISE_ERROR_NONE) {
        *inout_size = 0;
        return result;
    }
    *inout_size = (uint32_t)msg.size;
    if (noise_handshakestate_get_action(state->handshake) == NOISE_ACTION_SPLIT)
        return split_if_ready(state);
    return NOISE_ERROR_NONE;
}

int noisekit_handshake_read(noisekit_handshake *state, const uint8_t *message, uint32_t message_size)
{
    NoiseBuffer msg, payload;
    uint8_t empty_payload = 0;
    int result;
    if (!state || !state->handshake || !message || message_size == 0 || !check_size(message_size))
        return NOISE_ERROR_INVALID_PARAM;
    if (noise_handshakestate_get_action(state->handshake) != NOISE_ACTION_READ_MESSAGE)
        return NOISE_ERROR_INVALID_STATE;
    noise_buffer_set_input(msg, (uint8_t *)message, message_size);
    noise_buffer_set_output(payload, &empty_payload, 0);
    result = noise_handshakestate_read_message(state->handshake, &msg, &payload);
    if (result != NOISE_ERROR_NONE)
        return result;
    if (noise_handshakestate_get_action(state->handshake) == NOISE_ACTION_SPLIT)
        return split_if_ready(state);
    return NOISE_ERROR_NONE;
}

int noisekit_handshake_remote_static(const noisekit_handshake *state, uint8_t *public_key,
    uint32_t *public_size)
{
    NoiseDHState *remote;
    if (!state || !state->handshake || !public_key || !public_size || !state->send || !state->receive)
        return NOISE_ERROR_INVALID_STATE;
    if (*public_size < NOISEKIT_KEY_BYTES) {
        *public_size = NOISEKIT_KEY_BYTES;
        return NOISE_ERROR_INVALID_LENGTH;
    }
    remote = noise_handshakestate_get_remote_public_key_dh(state->handshake);
    if (!remote)
        return NOISE_ERROR_INVALID_STATE;
    int result = noise_dhstate_get_public_key(remote, public_key, NOISEKIT_KEY_BYTES);
    if (result == NOISE_ERROR_NONE)
        *public_size = NOISEKIT_KEY_BYTES;
    return result;
}

int noisekit_handshake_hash(const noisekit_handshake *state, uint8_t *hash, uint32_t *hash_size)
{
    if (!state || !state->handshake || !hash || !hash_size || !state->send || !state->receive)
        return NOISE_ERROR_INVALID_STATE;
    if (*hash_size < NOISEKIT_HASH_BYTES) {
        *hash_size = NOISEKIT_HASH_BYTES;
        return NOISE_ERROR_INVALID_LENGTH;
    }
    int result = noise_handshakestate_get_handshake_hash(state->handshake, hash, NOISEKIT_HASH_BYTES);
    if (result == NOISE_ERROR_NONE)
        *hash_size = NOISEKIT_HASH_BYTES;
    return result;
}

int noisekit_encrypt(noisekit_handshake *state, const uint8_t *plaintext,
    uint32_t plaintext_size, uint8_t *ciphertext, uint32_t *inout_size)
{
    NoiseBuffer buffer;
    uint32_t capacity;
    int result;
    if (!state || !state->send || !state->receive || (!plaintext && plaintext_size) ||
        !ciphertext || !inout_size || plaintext_size > NOISEKIT_MAX_MESSAGE_BYTES)
        return NOISE_ERROR_INVALID_PARAM;
    capacity = *inout_size;
    if (capacity < plaintext_size || capacity > NOISEKIT_MAX_MESSAGE_BYTES + 16)
        return NOISE_ERROR_INVALID_LENGTH;
    if (plaintext_size)
        memmove(ciphertext, plaintext, plaintext_size);
    noise_buffer_set_inout(buffer, ciphertext, plaintext_size, capacity);
    result = noise_cipherstate_encrypt(state->send, &buffer);
    *inout_size = result == NOISE_ERROR_NONE ? (uint32_t)buffer.size : 0;
    return result;
}

int noisekit_decrypt(noisekit_handshake *state, const uint8_t *ciphertext,
    uint32_t ciphertext_size, uint8_t *plaintext, uint32_t *inout_size)
{
    NoiseBuffer buffer;
    int result;
    if (!state || !state->send || !state->receive || !ciphertext || !plaintext ||
        !inout_size || ciphertext_size < 16 ||
        ciphertext_size > NOISEKIT_MAX_MESSAGE_BYTES + 16 ||
        *inout_size < ciphertext_size ||
        *inout_size > NOISEKIT_MAX_MESSAGE_BYTES + 16)
        return NOISE_ERROR_INVALID_PARAM;
    memmove(plaintext, ciphertext, ciphertext_size);
    noise_buffer_set_inout(buffer, plaintext, ciphertext_size, *inout_size);
    result = noise_cipherstate_decrypt(state->receive, &buffer);
    *inout_size = result == NOISE_ERROR_NONE ? (uint32_t)buffer.size : 0;
    return result;
}
