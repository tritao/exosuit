#ifndef NOISEKIT_H
#define NOISEKIT_H

#include <stdint.h>

#if defined(_WIN32)
# if defined(NOISEKIT_BUILDING)
#  define NOISEKIT_API __declspec(dllexport)
# else
#  define NOISEKIT_API __declspec(dllimport)
# endif
#else
# define NOISEKIT_API __attribute__((visibility("default")))
#endif

#if defined(__clang__)
# define NKNOISE_OPAQUE __attribute__((annotate("hxi:opaque")))
# define NKNOISE_OUT __attribute__((annotate("hxi:out")))
# define NKNOISE_INOUT __attribute__((annotate("hxi:inout")))
# define NKNOISE_IN_ARRAY(count) __attribute__((annotate("hxi:in_array")))
# define NKNOISE_OUT_BUFFER(size) __attribute__((annotate("hxi:out_buffer")))
# define NKNOISE_NULLABLE _Nullable
# define NKNOISE_INITIAL_CAPACITY(size) __attribute__((annotate("hxi:initial_capacity=" #size)))
# define NKNOISE_BORROWED __attribute__((annotate("hxi:borrowed")))
#else
# define NKNOISE_OPAQUE
# define NKNOISE_OUT
# define NKNOISE_INOUT
# define NKNOISE_IN_ARRAY(count)
# define NKNOISE_OUT_BUFFER(size)
# define NKNOISE_NULLABLE
# define NKNOISE_INITIAL_CAPACITY(size)
# define NKNOISE_BORROWED
#endif

typedef struct noisekit_handshake noisekit_handshake NKNOISE_OPAQUE;

enum {
    NOISEKIT_INITIATOR = 0,
    NOISEKIT_RESPONDER = 1,
    NOISEKIT_KEY_BYTES = 32,
    NOISEKIT_HASH_BYTES = 32,
    /* Noise-C caps ciphertext at 65535 bytes, including its 16-byte tag. */
    NOISEKIT_MAX_MESSAGE_BYTES = 65519
};

/* Generates a Curve25519 static key pair using the OS/browser CSPRNG. */
NOISEKIT_API int noisekit_keypair_generate(
    uint8_t *private_key NKNOISE_OUT_BUFFER(private_size) NKNOISE_INITIAL_CAPACITY(32),
    uint32_t *private_size NKNOISE_INOUT,
    uint8_t *public_key NKNOISE_OUT_BUFFER(public_size) NKNOISE_INITIAL_CAPACITY(32),
    uint32_t *public_size NKNOISE_INOUT);
NOISEKIT_API int noisekit_public_key(
    const uint8_t *private_key NKNOISE_IN_ARRAY(private_size), uint32_t private_size,
    uint8_t *public_key NKNOISE_OUT_BUFFER(public_size) NKNOISE_INITIAL_CAPACITY(32),
    uint32_t *public_size NKNOISE_INOUT);

/* Prologue is hashed by Noise and must be byte-identical at both endpoints. */
NOISEKIT_API int noisekit_handshake_create(int role,
    const uint8_t *static_private_key NKNOISE_IN_ARRAY(static_private_key_size),
    uint32_t static_private_key_size,
    const uint8_t *prologue NKNOISE_IN_ARRAY(prologue_size), uint32_t prologue_size,
    noisekit_handshake * NKNOISE_NULLABLE *out_state NKNOISE_OUT
        NKNOISE_BORROWED);
NOISEKIT_API int noisekit_handshake_free(noisekit_handshake *state);
NOISEKIT_API int noisekit_handshake_action(const noisekit_handshake *state);
NOISEKIT_API int noisekit_handshake_write(noisekit_handshake *state,
    uint8_t *message NKNOISE_OUT_BUFFER(inout_size) NKNOISE_INITIAL_CAPACITY(1024),
    uint32_t *inout_size NKNOISE_INOUT);
NOISEKIT_API int noisekit_handshake_read(noisekit_handshake *state,
    const uint8_t *message NKNOISE_IN_ARRAY(message_size), uint32_t message_size);
NOISEKIT_API int noisekit_handshake_remote_static(const noisekit_handshake *state,
    uint8_t *public_key NKNOISE_OUT_BUFFER(public_size) NKNOISE_INITIAL_CAPACITY(32),
    uint32_t *public_size NKNOISE_INOUT);
NOISEKIT_API int noisekit_handshake_hash(const noisekit_handshake *state,
    uint8_t *hash NKNOISE_OUT_BUFFER(hash_size) NKNOISE_INITIAL_CAPACITY(32),
    uint32_t *hash_size NKNOISE_INOUT);

/* Available only after both sides complete the three-message XX handshake. */
NOISEKIT_API int noisekit_encrypt(noisekit_handshake *state,
    const uint8_t *plaintext NKNOISE_IN_ARRAY(plaintext_size), uint32_t plaintext_size,
    uint8_t *ciphertext NKNOISE_OUT_BUFFER(inout_size) NKNOISE_INITIAL_CAPACITY(65535),
    uint32_t *inout_size NKNOISE_INOUT);
NOISEKIT_API int noisekit_decrypt(noisekit_handshake *state,
    const uint8_t *ciphertext NKNOISE_IN_ARRAY(ciphertext_size), uint32_t ciphertext_size,
    uint8_t *plaintext NKNOISE_OUT_BUFFER(inout_size) NKNOISE_INITIAL_CAPACITY(65535),
    uint32_t *inout_size NKNOISE_INOUT);

#endif
