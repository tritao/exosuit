cmake_minimum_required(VERSION 3.21)
project(noisekit LANGUAGES C)

set(NOISE_C_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/vendor/noise-c")

set(NOISE_C_SOURCES
    ${NOISE_C_ROOT}/src/protocol/cipherstate.c
    ${NOISE_C_ROOT}/src/protocol/dhstate.c
    ${NOISE_C_ROOT}/src/protocol/errors.c
    ${NOISE_C_ROOT}/src/protocol/handshakestate.c
    ${NOISE_C_ROOT}/src/protocol/hashstate.c
    ${NOISE_C_ROOT}/src/protocol/internal.c
    ${NOISE_C_ROOT}/src/protocol/names.c
    ${NOISE_C_ROOT}/src/protocol/patterns.c
    ${NOISE_C_ROOT}/src/protocol/randstate.c
    ${NOISE_C_ROOT}/src/protocol/signstate.c
    ${NOISE_C_ROOT}/src/protocol/symmetricstate.c
    ${NOISE_C_ROOT}/src/protocol/util.c
    ${NOISE_C_ROOT}/src/backend/ref/cipher-aesgcm.c
    ${NOISE_C_ROOT}/src/backend/ref/cipher-chachapoly.c
    ${NOISE_C_ROOT}/src/backend/ref/dh-curve25519.c
    ${NOISE_C_ROOT}/src/backend/ref/dh-curve448.c
    ${NOISE_C_ROOT}/src/backend/ref/dh-newhope.c
    ${NOISE_C_ROOT}/src/backend/ref/hash-blake2b.c
    ${NOISE_C_ROOT}/src/backend/ref/hash-blake2s.c
    ${NOISE_C_ROOT}/src/backend/ref/hash-sha256.c
    ${NOISE_C_ROOT}/src/backend/ref/hash-sha512.c
    ${NOISE_C_ROOT}/src/backend/ref/sign-ed25519.c
    ${NOISE_C_ROOT}/src/crypto/aes/rijndael-alg-fst.c
    ${NOISE_C_ROOT}/src/crypto/blake2/blake2b.c
    ${NOISE_C_ROOT}/src/crypto/blake2/blake2s.c
    ${NOISE_C_ROOT}/src/crypto/chacha/chacha.c
    ${NOISE_C_ROOT}/src/crypto/curve448/curve448.c
    ${NOISE_C_ROOT}/src/crypto/goldilocks/src/p448/arch_ref64/p448.c
    ${NOISE_C_ROOT}/src/crypto/newhope/batcher.c
    ${NOISE_C_ROOT}/src/crypto/newhope/crypto_stream_chacha20.c
    ${NOISE_C_ROOT}/src/crypto/newhope/error_correction.c
    ${NOISE_C_ROOT}/src/crypto/newhope/fips202.c
    ${NOISE_C_ROOT}/src/crypto/newhope/newhope.c
    ${NOISE_C_ROOT}/src/crypto/newhope/ntt.c
    ${NOISE_C_ROOT}/src/crypto/newhope/poly.c
    ${NOISE_C_ROOT}/src/crypto/newhope/precomp.c
    ${NOISE_C_ROOT}/src/crypto/newhope/reduce.c
    ${NOISE_C_ROOT}/src/crypto/donna/poly1305-donna.c
    ${NOISE_C_ROOT}/src/crypto/ghash/ghash.c
    ${NOISE_C_ROOT}/src/crypto/sha2/sha256.c
    ${NOISE_C_ROOT}/src/crypto/sha2/sha512.c
    ${NOISE_C_ROOT}/src/crypto/ed25519/ed25519.c)

# NoiseKit exposes only Noise_XX_25519_ChaChaPoly_SHA256. The vendored
# Curve448 and NewHope implementations use GCC vector extensions that MSVC
# cannot compile, and they are outside this package's fixed suite.
if(MSVC)
    list(REMOVE_ITEM NOISE_C_SOURCES
        ${NOISE_C_ROOT}/src/backend/ref/dh-curve448.c
        ${NOISE_C_ROOT}/src/backend/ref/dh-newhope.c
        ${NOISE_C_ROOT}/src/crypto/curve448/curve448.c
        ${NOISE_C_ROOT}/src/crypto/goldilocks/src/p448/arch_ref64/p448.c
        ${NOISE_C_ROOT}/src/crypto/newhope/batcher.c
        ${NOISE_C_ROOT}/src/crypto/newhope/crypto_stream_chacha20.c
        ${NOISE_C_ROOT}/src/crypto/newhope/error_correction.c
        ${NOISE_C_ROOT}/src/crypto/newhope/fips202.c
        ${NOISE_C_ROOT}/src/crypto/newhope/newhope.c
        ${NOISE_C_ROOT}/src/crypto/newhope/ntt.c
        ${NOISE_C_ROOT}/src/crypto/newhope/poly.c
        ${NOISE_C_ROOT}/src/crypto/newhope/precomp.c
        ${NOISE_C_ROOT}/src/crypto/newhope/reduce.c)
endif()

if(EMSCRIPTEN)
    list(APPEND NOISE_C_SOURCES src/random_wasm.c)
else()
    list(APPEND NOISE_C_SOURCES ${NOISE_C_ROOT}/src/protocol/rand_os.c)
endif()

if(EMSCRIPTEN)
    set(NOISEKIT_LIBRARY_TYPE STATIC)
else()
    set(NOISEKIT_LIBRARY_TYPE SHARED)
endif()
add_library(noisekit ${NOISEKIT_LIBRARY_TYPE} src/noisekit.c ${NOISE_C_SOURCES})
target_compile_features(noisekit PRIVATE c_std_11)
target_compile_definitions(noisekit PRIVATE
    NOISEKIT_BUILDING=1 USE_OPENSSL=0 USE_LIBSODIUM=0 HAVE_PTHREAD=0
    ED25519_CUSTOMHASH ED25519_CUSTOMRANDOM)
if(MSVC)
    target_compile_definitions(noisekit PRIVATE NOISEKIT_DH_CURVE25519_ONLY=1)
endif()
target_include_directories(noisekit PUBLIC include PRIVATE
    ${NOISE_C_ROOT}/include
    ${NOISE_C_ROOT}/src
    ${NOISE_C_ROOT}/src/protocol
    ${NOISE_C_ROOT}/src/crypto/goldilocks/src/include
    ${NOISE_C_ROOT}/src/crypto/goldilocks/src/p448
    ${NOISE_C_ROOT}/src/crypto/goldilocks/src/p448/arch_ref64)
set_target_properties(noisekit PROPERTIES C_VISIBILITY_PRESET hidden)
if(NOT EMSCRIPTEN AND UNIX)
    target_link_libraries(noisekit PRIVATE m)
endif()

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    include(CTest)
    if(BUILD_TESTING)
        add_executable(noisekit_contract tests/contract.c)
        target_link_libraries(noisekit_contract PRIVATE noisekit)
        add_test(NAME noisekit_contract COMMAND noisekit_contract)
    endif()
endif()
