#include "noisekit.h"
#include <stdio.h>
#include <string.h>

#define REQUIRE(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "noisekit contract failed at %s:%d: %s\n", \
                __FILE__, __LINE__, #condition); \
        return 1; \
    } \
} while (0)

static int write_message(noisekit_handshake *state, uint8_t *output, uint32_t *size)
{
    *size = 512;
    return noisekit_handshake_write(state, output, size);
}

int main(void)
{
    uint8_t initiator_private[32], initiator_public[32];
    uint8_t responder_private[32], responder_public[32];
    uint8_t initiator_remote[32], responder_remote[32];
    uint8_t initiator_hash[32], responder_hash[32];
    uint8_t message[512], encrypted[128], plain[128];
    static uint8_t maximum_plain[NOISEKIT_MAX_MESSAGE_BYTES];
    static uint8_t maximum_cipher[NOISEKIT_MAX_MESSAGE_BYTES + 16];
    static uint8_t maximum_opened[NOISEKIT_MAX_MESSAGE_BYTES + 16];
    uint32_t key_size, public_size, message_size, encrypted_size, plain_size, remote_size, hash_size;
    const uint8_t prologue[] = "exosuit-remote-v1|machine=0123456789abcdef0123456789abcdef|device=fedcba9876543210fedcba9876543210";
    const uint8_t request[] = {0x81, 0xA1, 'x', 0x2A};
    noisekit_handshake *initiator = 0, *responder = 0;

    key_size = public_size = 32;
    REQUIRE(noisekit_keypair_generate(initiator_private, &key_size, initiator_public, &public_size) == 0);
    REQUIRE(key_size == 32 && public_size == 32);
    key_size = public_size = 32;
    REQUIRE(noisekit_keypair_generate(responder_private, &key_size, responder_public, &public_size) == 0);
    REQUIRE(key_size == 32 && public_size == 32);
    REQUIRE(noisekit_handshake_create(NOISEKIT_INITIATOR, initiator_private,
        sizeof(initiator_private), prologue, sizeof(prologue) - 1, &initiator) == 0);
    REQUIRE(noisekit_handshake_create(NOISEKIT_RESPONDER, responder_private,
        sizeof(responder_private), prologue, sizeof(prologue) - 1, &responder) == 0);

    REQUIRE(noisekit_handshake_action(initiator) == 0x4101);
    REQUIRE(write_message(initiator, message, &message_size) == 0);
    REQUIRE(noisekit_handshake_read(responder, message, message_size) == 0);
    REQUIRE(write_message(responder, message, &message_size) == 0);
    REQUIRE(noisekit_handshake_read(initiator, message, message_size) == 0);
    REQUIRE(write_message(initiator, message, &message_size) == 0);
    REQUIRE(noisekit_handshake_read(responder, message, message_size) == 0);

    REQUIRE(noisekit_handshake_action(initiator) == 0x4105);
    REQUIRE(noisekit_handshake_action(responder) == 0x4105);
    remote_size = 32;
    REQUIRE(noisekit_handshake_remote_static(initiator, initiator_remote, &remote_size) == 0);
    REQUIRE(remote_size == 32);
    remote_size = 32;
    REQUIRE(noisekit_handshake_remote_static(responder, responder_remote, &remote_size) == 0);
    REQUIRE(remote_size == 32);
    REQUIRE(memcmp(initiator_remote, responder_public, 32) == 0);
    REQUIRE(memcmp(responder_remote, initiator_public, 32) == 0);
    hash_size = 32;
    REQUIRE(noisekit_handshake_hash(initiator, initiator_hash, &hash_size) == 0);
    REQUIRE(hash_size == 32);
    hash_size = 32;
    REQUIRE(noisekit_handshake_hash(responder, responder_hash, &hash_size) == 0);
    REQUIRE(hash_size == 32);
    REQUIRE(memcmp(initiator_hash, responder_hash, 32) == 0);

    encrypted_size = sizeof(encrypted);
    REQUIRE(noisekit_encrypt(initiator, request, sizeof(request), encrypted, &encrypted_size) == 0);
    plain_size = sizeof(plain);
    REQUIRE(noisekit_decrypt(responder, encrypted, encrypted_size, plain, &plain_size) == 0);
    REQUIRE(plain_size == sizeof(request));
    REQUIRE(memcmp(plain, request, sizeof(request)) == 0);

    for (uint32_t index = 0; index < NOISEKIT_MAX_MESSAGE_BYTES; ++index)
        maximum_plain[index] = (uint8_t)(index * 17u + 29u);
    encrypted_size = sizeof(maximum_cipher);
    REQUIRE(noisekit_encrypt(initiator, maximum_plain, sizeof(maximum_plain),
        maximum_cipher, &encrypted_size) == 0);
    REQUIRE(encrypted_size == sizeof(maximum_cipher));
    plain_size = sizeof(maximum_opened);
    REQUIRE(noisekit_decrypt(responder, maximum_cipher, encrypted_size,
        maximum_opened, &plain_size) == 0);
    REQUIRE(plain_size == sizeof(maximum_plain));
    REQUIRE(memcmp(maximum_opened, maximum_plain, sizeof(maximum_plain)) == 0);

    encrypted_size = sizeof(encrypted);
    REQUIRE(noisekit_encrypt(responder, request, sizeof(request), encrypted, &encrypted_size) == 0);
    plain_size = sizeof(plain);
    REQUIRE(noisekit_decrypt(initiator, encrypted, encrypted_size, plain, &plain_size) == 0);
    REQUIRE(plain_size == sizeof(request));
    REQUIRE(memcmp(plain, request, sizeof(request)) == 0);

    noisekit_handshake_free(initiator);
    noisekit_handshake_free(responder);
    puts("PASS: fixed Noise XX suite, prologue binding, static identity, transcript and bidirectional encryption");
    return 0;
}
