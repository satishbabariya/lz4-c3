/**
 * xxHash - Extremely Fast Hash algorithm
 * C3 Port
 *
 * Original Copyright (C) 2012-2016, Yann Collet.
 * BSD 2-Clause License
 *
 * This is a port of xxHash for use with LZ4 frame format checksums.
 */
module xxhash;

// ============================================================================
// Constants
// ============================================================================

const uint VERSION_MAJOR = 0;
const uint VERSION_MINOR = 6;
const uint VERSION_RELEASE = 5;
const uint VERSION_NUMBER = VERSION_MAJOR * 100 * 100 + VERSION_MINOR * 100 + VERSION_RELEASE;

// XXH32 primes
const uint PRIME32_1 = 2654435761;
const uint PRIME32_2 = 2246822519;
const uint PRIME32_3 = 3266489917;
const uint PRIME32_4 = 668265263;
const uint PRIME32_5 = 374761393;

// XXH64 primes
const ulong PRIME64_1 = 11400714785074694791;
const ulong PRIME64_2 = 14029467366897019727;
const ulong PRIME64_3 = 1609587929392839161;
const ulong PRIME64_4 = 9650029242287828579;
const ulong PRIME64_5 = 2870177450012600261;

// ============================================================================
// Types
// ============================================================================

/**
 * Streaming state for XXH32.
 */
struct State32 {
    uint total_len_32;
    uint large_len;
    uint v1;
    uint v2;
    uint v3;
    uint v4;
    uint[4] mem32;
    uint memsize;
}

/**
 * Streaming state for XXH64.
 */
struct State64 {
    ulong total_len;
    ulong v1;
    ulong v2;
    ulong v3;
    ulong v4;
    ulong[4] mem64;
    uint memsize;
}

// ============================================================================
// XXH32 - 32-bit Hash
// ============================================================================

/**
 * Calculate the 32-bit hash of input data.
 * @param input : data to hash
 * @param seed : seed value to alter result
 * @return : 32-bit hash value
 */
fn uint xxh32(char[] input, uint seed) {
    if (input.len == 0) {
        return xxh32_avalanche(seed + PRIME32_5);
    }
    
    char* p = input.ptr;
    char* end = input.ptr + input.len;
    uint h32;
    
    if (input.len >= 16) {
        char* limit = end - 15;
        uint v1 = seed + PRIME32_1 + PRIME32_2;
        uint v2 = seed + PRIME32_2;
        uint v3 = seed;
        uint v4 = seed - PRIME32_1;
        
        while (p < limit) {
            v1 = xxh32_round(v1, read32_le(p)); p += 4;
            v2 = xxh32_round(v2, read32_le(p)); p += 4;
            v3 = xxh32_round(v3, read32_le(p)); p += 4;
            v4 = xxh32_round(v4, read32_le(p)); p += 4;
        }
        
        h32 = rotl32(v1, 1) + rotl32(v2, 7) + rotl32(v3, 12) + rotl32(v4, 18);
    } else {
        h32 = seed + PRIME32_5;
    }
    
    h32 += (uint)input.len;
    
    // Process remaining 4-byte chunks
    while (p + 4 <= end) {
        h32 += read32_le(p) * PRIME32_3;
        h32 = rotl32(h32, 17) * PRIME32_4;
        p += 4;
    }
    
    // Process remaining bytes
    while (p < end) {
        h32 += ((uint)(*p++) & 0xFF) * PRIME32_5;
        h32 = rotl32(h32, 11) * PRIME32_1;
    }
    
    return xxh32_avalanche(h32);
}

/**
 * Create streaming hash state.
 */
fn State32* create_state32() {
    State32* state = mem::new(State32);
    if (state != null) {
        reset32(state, 0);
    }
    return state;
}

/**
 * Free streaming hash state.
 */
fn void free_state32(State32* state) {
    if (state != null) {
        mem::free(state);
    }
}

/**
 * Reset streaming state with seed.
 */
fn void reset32(State32* state, uint seed) {
    if (state == null) return;
    
    state.total_len_32 = 0;
    state.large_len = 0;
    state.v1 = seed + PRIME32_1 + PRIME32_2;
    state.v2 = seed + PRIME32_2;
    state.v3 = seed;
    state.v4 = seed - PRIME32_1;
    state.memsize = 0;
    
    for (int i = 0; i < 4; i++) {
        state.mem32[i] = 0;
    }
}

/**
 * Update hash with more data.
 */
fn void update32(State32* state, char[] input) {
    if (state == null || input.len == 0) return;
    
    char* p = input.ptr;
    char* end = input.ptr + input.len;
    
    state.total_len_32 += (uint)input.len;
    if (input.len >= 16) state.large_len = 1;
    
    // Fill buffer if partially full
    if (state.memsize > 0) {
        uint fill = 16 - state.memsize;
        if (fill > input.len) fill = (uint)input.len;
        
        char* mem = (char*)&state.mem32[0];
        for (uint i = 0; i < fill; i++) {
            mem[state.memsize + i] = p[i];
        }
        p += fill;
        state.memsize += fill;
        
        if (state.memsize == 16) {
            state.v1 = xxh32_round(state.v1, state.mem32[0]);
            state.v2 = xxh32_round(state.v2, state.mem32[1]);
            state.v3 = xxh32_round(state.v3, state.mem32[2]);
            state.v4 = xxh32_round(state.v4, state.mem32[3]);
            state.memsize = 0;
        }
    }
    
    // Process 16-byte blocks
    if (p + 16 <= end) {
        char* limit = end - 16;
        uint v1 = state.v1;
        uint v2 = state.v2;
        uint v3 = state.v3;
        uint v4 = state.v4;
        
        while (p <= limit) {
            v1 = xxh32_round(v1, read32_le(p)); p += 4;
            v2 = xxh32_round(v2, read32_le(p)); p += 4;
            v3 = xxh32_round(v3, read32_le(p)); p += 4;
            v4 = xxh32_round(v4, read32_le(p)); p += 4;
        }
        
        state.v1 = v1;
        state.v2 = v2;
        state.v3 = v3;
        state.v4 = v4;
    }
    
    // Save remaining bytes
    if (p < end) {
        char* mem = (char*)&state.mem32[0];
        while (p < end) {
            mem[state.memsize++] = *p++;
        }
    }
}

/**
 * Finalize and return hash value.
 */
fn uint digest32(State32* state) {
    if (state == null) return 0;
    
    uint h32;
    
    if (state.large_len != 0) {
        h32 = rotl32(state.v1, 1) + rotl32(state.v2, 7) +
              rotl32(state.v3, 12) + rotl32(state.v4, 18);
    } else {
        h32 = state.v3 + PRIME32_5;  // v3 == seed
    }
    
    h32 += state.total_len_32;
    
    // Process remaining bytes in buffer
    char* p = (char*)&state.mem32[0];
    char* end = p + state.memsize;
    
    while (p + 4 <= end) {
        h32 += read32_le(p) * PRIME32_3;
        h32 = rotl32(h32, 17) * PRIME32_4;
        p += 4;
    }
    
    while (p < end) {
        h32 += ((uint)(*p++) & 0xFF) * PRIME32_5;
        h32 = rotl32(h32, 11) * PRIME32_1;
    }
    
    return xxh32_avalanche(h32);
}

// ============================================================================
// XXH64 - 64-bit Hash
// ============================================================================

/**
 * Calculate the 64-bit hash of input data.
 * Faster on 64-bit systems.
 */
fn ulong xxh64(char[] input, ulong seed) {
    if (input.len == 0) {
        return xxh64_avalanche(seed + PRIME64_5);
    }
    
    char* p = input.ptr;
    char* end = input.ptr + input.len;
    ulong h64;
    
    if (input.len >= 32) {
        char* limit = end - 31;
        ulong v1 = seed + PRIME64_1 + PRIME64_2;
        ulong v2 = seed + PRIME64_2;
        ulong v3 = seed;
        ulong v4 = seed - PRIME64_1;
        
        while (p < limit) {
            v1 = xxh64_round(v1, read64_le(p)); p += 8;
            v2 = xxh64_round(v2, read64_le(p)); p += 8;
            v3 = xxh64_round(v3, read64_le(p)); p += 8;
            v4 = xxh64_round(v4, read64_le(p)); p += 8;
        }
        
        h64 = rotl64(v1, 1) + rotl64(v2, 7) + rotl64(v3, 12) + rotl64(v4, 18);
        h64 = xxh64_merge_round(h64, v1);
        h64 = xxh64_merge_round(h64, v2);
        h64 = xxh64_merge_round(h64, v3);
        h64 = xxh64_merge_round(h64, v4);
    } else {
        h64 = seed + PRIME64_5;
    }
    
    h64 += (ulong)input.len;
    
    // Process 8-byte chunks
    while (p + 8 <= end) {
        ulong k1 = xxh64_round(0, read64_le(p));
        p += 8;
        h64 ^= k1;
        h64 = rotl64(h64, 27) * PRIME64_1 + PRIME64_4;
    }
    
    // Process 4-byte chunk
    if (p + 4 <= end) {
        h64 ^= (ulong)read32_le(p) * PRIME64_1;
        h64 = rotl64(h64, 23) * PRIME64_2 + PRIME64_3;
        p += 4;
    }
    
    // Process remaining bytes
    while (p < end) {
        h64 ^= ((ulong)(*p++) & 0xFF) * PRIME64_5;
        h64 = rotl64(h64, 11) * PRIME64_1;
    }
    
    return xxh64_avalanche(h64);
}

// ============================================================================
// Internal Helpers
// ============================================================================

fn uint rotl32(uint x, int r) @private @inline {
    return (x << r) | (x >> (32 - r));
}

fn ulong rotl64(ulong x, int r) @private @inline {
    return (x << r) | (x >> (64 - r));
}

fn uint read32_le(char* ptr) @private {
    return ((uint)ptr[0] & 0xFF) |
           (((uint)ptr[1] & 0xFF) << 8) |
           (((uint)ptr[2] & 0xFF) << 16) |
           (((uint)ptr[3] & 0xFF) << 24);
}

fn ulong read64_le(char* ptr) @private {
    return ((ulong)ptr[0] & 0xFF) |
           (((ulong)ptr[1] & 0xFF) << 8) |
           (((ulong)ptr[2] & 0xFF) << 16) |
           (((ulong)ptr[3] & 0xFF) << 24) |
           (((ulong)ptr[4] & 0xFF) << 32) |
           (((ulong)ptr[5] & 0xFF) << 40) |
           (((ulong)ptr[6] & 0xFF) << 48) |
           (((ulong)ptr[7] & 0xFF) << 56);
}

fn uint xxh32_round(uint acc, uint input) @private @inline {
    acc += input * PRIME32_2;
    acc = rotl32(acc, 13);
    acc *= PRIME32_1;
    return acc;
}

fn uint xxh32_avalanche(uint h32) @private {
    h32 ^= h32 >> 15;
    h32 *= PRIME32_2;
    h32 ^= h32 >> 13;
    h32 *= PRIME32_3;
    h32 ^= h32 >> 16;
    return h32;
}

fn ulong xxh64_round(ulong acc, ulong input) @private @inline {
    acc += input * PRIME64_2;
    acc = rotl64(acc, 31);
    acc *= PRIME64_1;
    return acc;
}

fn ulong xxh64_merge_round(ulong acc, ulong val) @private {
    val = xxh64_round(0, val);
    acc ^= val;
    acc = acc * PRIME64_1 + PRIME64_4;
    return acc;
}

fn ulong xxh64_avalanche(ulong h64) @private {
    h64 ^= h64 >> 33;
    h64 *= PRIME64_2;
    h64 ^= h64 >> 29;
    h64 *= PRIME64_3;
    h64 ^= h64 >> 32;
    return h64;
}
