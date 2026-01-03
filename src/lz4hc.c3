/**
 * LZ4 HC - High Compression Mode
 * C3 Port
 *
 * Original Copyright (c) Yann Collet. All rights reserved.
 * BSD 2-Clause License
 *
 * HC mode trades compression speed for better compression ratio.
 * Uses chain tables for finding better matches.
 */
module lz4hc;

import lz4;

// ============================================================================
// Constants
// ============================================================================

const int CLEVEL_MIN = 3;
const int CLEVEL_DEFAULT = 9;
const int CLEVEL_OPT_MIN = 10;
const int CLEVEL_MAX = 12;

const int HC_HASHLOG = 15;  // 32KB hash table
const int HC_HASHTABLESIZE = 1 << HC_HASHLOG;
const int HC_HASH_MASK = HC_HASHTABLESIZE - 1;

const int MAXD = 1 << 16;  // 64KB window
const int MAXD_MASK = MAXD - 1;

const int OPTIMAL_ML = 18;  // ((15-1) + 4) for optimal match length

// From lz4
const int MINMATCH = 4;
const int LASTLITERALS = 5;
const int MFLIMIT = 12;
const int ML_BITS = 4;
const uint ML_MASK = (1 << ML_BITS) - 1;
const int RUN_BITS = 8 - ML_BITS;
const uint RUN_MASK = (1 << RUN_BITS) - 1;
const int DISTANCE_MAX = 65535;
const int MAX_INPUT_SIZE = 0x7E000000;

// ============================================================================
// Types
// ============================================================================

/**
 * HC compression context with chain table for better match finding.
 */
struct StreamHC {
    uint[HC_HASHTABLESIZE] hash_table;
    ushort[MAXD] chain_table;
    char* prefix_start;
    char* end;
    char* dict_start;
    uint dict_limit;
    uint low_limit;
    uint next_to_update;
    int compression_level;
    StreamHC* dict_ctx;
}

const usz STREAMHC_MINSIZE = StreamHC.sizeof;

// ============================================================================
// Public API
// ============================================================================

/**
 * Compress using High Compression mode.
 * Slower but achieves better compression ratio than compress_default.
 *
 * @param src : source buffer
 * @param dst : destination buffer (must be pre-allocated)
 * @param level : compression level (3-12), higher = slower but better compression
 * @return : number of bytes written, or 0 on failure
 */
fn int compress_hc(char[] src, char[] dst, int level) {
    if (src.len == 0 || src.len > MAX_INPUT_SIZE) return 0;
    if (dst.len == 0) return 0;
    
    // Clamp level
    int clevel = level;
    if (clevel < CLEVEL_MIN) clevel = CLEVEL_DEFAULT;
    if (clevel > CLEVEL_MAX) clevel = CLEVEL_MAX;
    
    // Use heap-allocated context (StreamHC is too large for stack)
    StreamHC* ctx = create_stream_hc();
    if (ctx == null) return 0;
    
    ctx.compression_level = clevel;
    int result = compress_hc_generic(ctx, src, dst, clevel);
    
    free_stream_hc(ctx);
    return result;
}

/**
 * Compress using HC mode with fixed destination size.
 * Compresses as much src as possible into dst.
 * output src_read indicates how much src was consumed.
 */
fn int compress_hc_destSize(char[] src, char[] dst, int* src_read, int level) {
    if (src.len == 0 || dst.len == 0) return 0;
    
    int clevel = level;
    if (clevel < CLEVEL_MIN) clevel = CLEVEL_DEFAULT;
    if (clevel > CLEVEL_MAX) clevel = CLEVEL_MAX;
    
    StreamHC* ctx = create_stream_hc();
    if (ctx == null) return 0;
    
    ctx.compression_level = clevel;
    int result = compress_hc_generic_dest(ctx, src, dst, clevel, src_read);
    
    free_stream_hc(ctx);
    return result;
}

/**
 * Create streaming HC compression context.
 */
fn StreamHC* create_stream_hc() {
    StreamHC* stream = mem::new(StreamHC);
    if (stream != null) {
        init_stream_hc(stream, CLEVEL_DEFAULT);
    }
    return stream;
}

/**
 * Free streaming HC compression context.
 */
fn int free_stream_hc(StreamHC* stream) {
    if (stream == null) return 0;
    mem::free(stream);
    return 0;
}

/**
 * Initialize HC stream with specified compression level.
 */
fn void init_stream_hc(StreamHC* stream, int level) {
    if (stream == null) return;
    
    // Clear hash table
    for (int i = 0; i < HC_HASHTABLESIZE; i++) {
        stream.hash_table[i] = 0;
    }
    
    // Initialize chain table to 0xFFFF (no chain)
    for (int i = 0; i < MAXD; i++) {
        stream.chain_table[i] = 0xFFFF;
    }
    
    stream.prefix_start = null;
    stream.end = null;
    stream.dict_start = null;
    stream.dict_limit = 0;
    stream.low_limit = 0;
    stream.next_to_update = 0;
    stream.compression_level = level;
    stream.dict_ctx = null;
}

/**
 * Reset HC stream for new compression.
 */
fn void reset_stream_hc_fast(StreamHC* stream, int level) {
    if (stream == null) return;
    stream.compression_level = level;
    stream.next_to_update = stream.dict_limit;
    stream.dict_ctx = null;
}

/**
 * Load dictionary into HC stream.
 */
fn int load_dict_hc(StreamHC* stream, char[] dictionary) {
    if (stream == null) return 0;
    
    init_stream_hc(stream, stream.compression_level);
    
    if (dictionary.len == 0) return 0;
    
    // Limit to last 64KB
    usz dict_size = dictionary.len;
    char* dict_start = dictionary.ptr;
    if (dict_size > 64 * 1024) {
        dict_start = dictionary.ptr + dictionary.len - 64 * 1024;
        dict_size = 64 * 1024;
    }
    
    stream.prefix_start = dict_start;
    stream.end = dict_start + dict_size;
    stream.dict_start = dict_start;
    stream.dict_limit = 64 * 1024;  // Offset to handle negative offsets
    stream.low_limit = stream.dict_limit;
    stream.next_to_update = stream.dict_limit;
    
    // Fill hash and chain tables with dictionary content
    if (dict_size >= MINMATCH) {
        fill_hc_tables(stream, dict_start, dict_size);
    }
    
    return (int)dict_size;
}

/**
 * Attach a pre-filled dictionary StreamHC to a working StreamHC.
 * The dictionary stream must remain valid during compression.
 * This allows reusing a pre-computed dictionary across multiple compressions.
 *
 * @param working_stream : stream to attach dictionary to
 * @param dict_stream : pre-filled dictionary stream (from load_dict_hc)
 */
fn void attach_HC_dictionary(StreamHC* working_stream, StreamHC* dict_stream) {
    if (working_stream == null) return;
    
    // Reset working stream
    reset_stream_hc_fast(working_stream, working_stream.compression_level);
    
    // Clear hash table (must be cleared because we don't copy it)
    for (int i = 0; i < HC_HASHTABLESIZE; i++) {
        working_stream.hash_table[i] = 0;
    }
    
    // Attach dictionary reference
    working_stream.dict_ctx = dict_stream;
    
    // Initialize limits from dictionary
    if (dict_stream != null) {
        working_stream.dict_start = dict_stream.dict_start;
        working_stream.dict_limit = dict_stream.dict_limit;
        working_stream.low_limit = dict_stream.low_limit;
    }
}

/**
 * Streaming HC compression.
 */
fn int compress_hc_continue(StreamHC* stream, char[] src, char[] dst) {
    if (stream == null || src.len == 0) return 0;
    
    return compress_hc_generic(stream, src, dst, stream.compression_level);
}

/**
 * Save dictionary for future compression sessions.
 */
fn int save_dict_hc(StreamHC* stream, char[] safe_buffer) {
    if (stream == null) return 0;
    if (stream.prefix_start == null) return 0;
    
    usz dict_size = (usz)(stream.end - stream.prefix_start);
    if (dict_size > 64 * 1024) dict_size = 64 * 1024;
    if (dict_size > safe_buffer.len) dict_size = safe_buffer.len;
    
    if (dict_size > 0) {
        char* src = stream.end - dict_size;
        for (usz i = 0; i < dict_size; i++) {
            safe_buffer.ptr[i] = src[i];
        }
    }
    
    return (int)dict_size;
}

// ============================================================================
// Internal Implementation
// ============================================================================

fn uint hash_hc(char* ptr) @private {
    uint val = ((uint)ptr[0] & 0xFF) | 
               (((uint)ptr[1] & 0xFF) << 8) | 
               (((uint)ptr[2] & 0xFF) << 16) | 
               (((uint)ptr[3] & 0xFF) << 24);
    return ((val * 2654435761) >> (32 - HC_HASHLOG)) & HC_HASH_MASK;
}

fn void fill_hc_tables(StreamHC* ctx, char* start, usz size) @private {
    if (size < MINMATCH) return;
    
    char* p = start;
    char* end = start + size - MINMATCH + 1;
    uint idx = ctx.dict_limit;
    
    while (p < end) {
        uint h = hash_hc(p);
        ctx.chain_table[idx & MAXD_MASK] = (ushort)(idx - ctx.hash_table[h]);
        ctx.hash_table[h] = idx;
        p++;
        idx++;
    }
    
    ctx.next_to_update = idx;
}

fn void insert_hc(StreamHC* ctx, char* ip, char* base, uint ip_idx) @private {
    uint h = hash_hc(ip);
    uint match_idx = ctx.hash_table[h];
    
    // Chain current position to previous
    if (ip_idx > match_idx && ip_idx - match_idx <= MAXD) {
        ctx.chain_table[ip_idx & MAXD_MASK] = (ushort)(ip_idx - match_idx);
    } else {
        ctx.chain_table[ip_idx & MAXD_MASK] = 0xFFFF;
    }
    
    ctx.hash_table[h] = ip_idx;
}

// Get number of search attempts based on compression level
fn int get_search_attempts(int level) @private {
    if (level <= 3) return 4;
    if (level <= 5) return 16;
    if (level <= 7) return 64;
    if (level <= 9) return 256;
    return 1024;  // levels 10-12
}

fn int compress_hc_generic(StreamHC* ctx, char[] src, char[] dst, int level) @private {
    char* ip = src.ptr;
    char* base = src.ptr;
    char* anchor = ip;
    char* iend = src.ptr + src.len;
    char* mflimit_p = iend - MFLIMIT;
    char* match_limit = iend - LASTLITERALS;
    
    char* op = dst.ptr;
    char* olimit = dst.ptr + dst.len;
    
    int nb_searches = get_search_attempts(level);
    
    // Minimum input check
    if (src.len < MFLIMIT + 1) {
        return output_last_literals_hc(anchor, iend, op, olimit, dst.ptr);
    }
    
    // Main compression loop
    while (ip < mflimit_p) {
        // Insert all positions up to current
        uint ip_idx = (uint)(ip - base);
        insert_hc(ctx, ip, base, ip_idx);
        
        // Search for best match using chain
        int best_len = 0;
        int best_off = 0;
        
        uint h = hash_hc(ip);
        uint match_idx = ctx.hash_table[h];
        int attempts = nb_searches;
        
        while (match_idx > 0 && attempts-- > 0 && ip_idx - match_idx <= DISTANCE_MAX) {
            char* match = base + match_idx;
            
            if (match >= base && match < ip) {
                // Count match length
                int len = count_match_hc(ip, match, match_limit);
                if (len > best_len) {
                    best_len = len;
                    best_off = (int)(ip - match);
                }
            }
            
            // Follow chain
            ushort delta = ctx.chain_table[match_idx & MAXD_MASK];
            if (delta == 0xFFFF || delta == 0) break;
            if (match_idx < delta) break;
            match_idx -= delta;
        }
        
        // No good match found
        if (best_len < MINMATCH) {
            ip++;
            continue;
        }
        
        // Extend match backwards
        while (ip > anchor && ip - best_off > base && ip[-1] == ip[-1 - best_off]) {
            ip--;
            best_len++;
        }
        
        // Encode sequence
        int lit_len = (int)(ip - anchor);
        
        // Check output space
        if (op + 1 + lit_len + (lit_len / 255) + 2 + (best_len / 255) > olimit) {
            return 0;  // Output buffer too small
        }
        
        // Write token
        char* token = op++;
        
        // Encode literal length
        if (lit_len >= (int)RUN_MASK) {
            *token = (char)(RUN_MASK << ML_BITS);
            int remaining = lit_len - (int)RUN_MASK;
            while (remaining >= 255) {
                *op++ = (char)255;
                remaining -= 255;
            }
            *op++ = (char)remaining;
        } else {
            *token = (char)(lit_len << ML_BITS);
        }
        
        // Copy literals
        for (int i = 0; i < lit_len; i++) {
            *op++ = anchor[i];
        }
        
        // Write offset (little-endian)
        *op++ = (char)(best_off & 0xFF);
        *op++ = (char)((best_off >> 8) & 0xFF);
        
        // Encode match length
        int ml_minus_min = best_len - MINMATCH;
        if (ml_minus_min >= (int)ML_MASK) {
            *token += (char)ML_MASK;
            ml_minus_min -= (int)ML_MASK;
            while (ml_minus_min >= 255) {
                *op++ = (char)255;
                ml_minus_min -= 255;
            }
            *op++ = (char)ml_minus_min;
        } else {
            *token += (char)ml_minus_min;
        }
        
        // Advance
        ip += best_len;
        anchor = ip;
    }
    
    return output_last_literals_hc(anchor, iend, op, olimit, dst.ptr);
}

fn int count_match_hc(char* p_in, char* p_match, char* limit) @private {
    char* start = p_in;
    
    while (p_in < limit - 3) {
        uint v1 = ((uint)p_in[0] & 0xFF) | (((uint)p_in[1] & 0xFF) << 8) |
                  (((uint)p_in[2] & 0xFF) << 16) | (((uint)p_in[3] & 0xFF) << 24);
        uint v2 = ((uint)p_match[0] & 0xFF) | (((uint)p_match[1] & 0xFF) << 8) |
                  (((uint)p_match[2] & 0xFF) << 16) | (((uint)p_match[3] & 0xFF) << 24);
        
        if (v1 != v2) {
            // Count matching bytes in first differing word
            uint diff = v1 ^ v2;
            int bytes = 0;
            while ((diff & 0xFF) == 0) {
                bytes++;
                diff >>= 8;
            }
            return (int)(p_in - start) + bytes;
        }
        p_in += 4;
        p_match += 4;
    }
    
    // Byte-by-byte for remainder
    while (p_in < limit && *p_in == *p_match) {
        p_in++;
        p_match++;
    }
    
    return (int)(p_in - start);
}

fn int output_last_literals_hc(char* anchor, char* iend, char* op, char* olimit, char* dst_start) @private {
    usz last_run = (usz)(iend - anchor);
    
    if (op + 1 + last_run + (last_run / 255) > olimit) {
        return 0;
    }
    
    if (last_run >= RUN_MASK) {
        *op++ = (char)(RUN_MASK << ML_BITS);
        usz remaining = last_run - RUN_MASK;
        while (remaining >= 255) {
            *op++ = (char)255;
            remaining -= 255;
        }
        *op++ = (char)remaining;
    } else {
        *op++ = (char)(last_run << ML_BITS);
    }
    
    while (anchor < iend) {
        *op++ = *anchor++;
    }
    
    return (int)(op - dst_start);
}

fn int compress_hc_generic_dest(StreamHC* ctx, char[] src, char[] dst, int level, int* src_read) @private {
    char* ip = src.ptr;
    char* base = src.ptr;
    char* anchor = ip;
    char* iend = src.ptr + src.len;
    char* mflimit_p = iend - MFLIMIT;
    char* match_limit = iend - LASTLITERALS;
    
    char* op = dst.ptr;
    char* olimit = dst.ptr + dst.len;
    char* op_bottom = olimit - 1 - LASTLITERALS - RUN_MASK;
    char* op_threshold = olimit - (1 + LASTLITERALS);
    
    int nb_searches = get_search_attempts(level);
    
    if (src.len < MFLIMIT + 1) {
        return output_last_literals_hc_dest(anchor, iend, op, olimit, dst.ptr, src_read, base);
    }
    
    while (ip < mflimit_p) {
        uint ip_idx = (uint)(ip - base);
        insert_hc(ctx, ip, base, ip_idx);
        
        int best_len = 0;
        int best_off = 0;
        
        uint h = hash_hc(ip);
        uint match_idx = ctx.hash_table[h];
        int attempts = nb_searches;
        
        while (match_idx > 0 && attempts-- > 0 && ip_idx - match_idx <= DISTANCE_MAX) {
            char* match = base + match_idx;
            if (match >= base && match < ip) {
                int len = count_match_hc(ip, match, match_limit);
                if (len > best_len) {
                    best_len = len;
                    best_off = (int)(ip - match);
                }
            }
            ushort delta = ctx.chain_table[match_idx & MAXD_MASK];
            if (delta == 0xFFFF || delta == 0) break;
            if (match_idx < delta) break;
            match_idx -= delta;
        }
        
        if (best_len < MINMATCH) {
            ip++; continue;
        }
        
        while (ip > anchor && ip - best_off > base && ip[-1] == ip[-1 - best_off]) {
            ip--; best_len++;
        }
        
        // Check output space aggressively
        int lit_len = (int)(ip - anchor);
        char* op_check = op + 1 + lit_len + (lit_len >> 8);
        if (op_check > op_threshold) {
             return output_last_literals_hc_dest(anchor, iend, op, olimit, dst.ptr, src_read, base);
        }
        
        // Write token
        char* token = op++;
        
        if (lit_len >= (int)RUN_MASK) {
            *token = (char)(RUN_MASK << ML_BITS);
            int remaining = lit_len - (int)RUN_MASK;
            while (remaining >= 255) {
                *op++ = (char)255; remaining -= 255;
            }
            *op++ = (char)remaining;
        } else {
            *token = (char)(lit_len << ML_BITS);
        }
        
        for (int i = 0; i < lit_len; i++) *op++ = anchor[i];
        
        *op++ = (char)(best_off & 0xFF);
        *op++ = (char)((best_off >> 8) & 0xFF);
        
        int ml_minus_min = best_len - MINMATCH;
        if (ml_minus_min >= (int)ML_MASK) {
            *token += (char)ML_MASK;
            ml_minus_min -= (int)ML_MASK;
            while (ml_minus_min >= 255) {
                if (op >= olimit) return output_last_literals_hc_dest(anchor, iend, op - 1, olimit, dst.ptr, src_read, base);
                *op++ = (char)255; ml_minus_min -= 255;
            }
            if (op >= olimit) return output_last_literals_hc_dest(anchor, iend, op - 1, olimit, dst.ptr, src_read, base);
            *op++ = (char)ml_minus_min;
        } else {
            *token += (char)ml_minus_min;
        }
        
        ip += best_len;
        anchor = ip;
        
        if (op > op_bottom) {
             return output_last_literals_hc_dest(anchor, iend, op, olimit, dst.ptr, src_read, base);
        }
    }
    
    return output_last_literals_hc_dest(anchor, iend, op, olimit, dst.ptr, src_read, base);
}


fn int output_last_literals_hc_dest(char* anchor, char* iend, char* op, char* olimit, char* dst_start, int* src_read, char* base) @private {
    usz avail = (usz)(olimit - op);
    if (avail < 1) return 0;
    
    usz max_lit = avail - 1;
    usz lit_len = (usz)(iend - anchor);
    if (lit_len > max_lit) {
        lit_len = max_lit;
        while (lit_len > 0) {
             usz overhead = 1 + (lit_len >= 15 ? (lit_len - 15)/255 + 1 : 0);
             if (overhead + lit_len <= avail) break;
             lit_len--;
        }
    }
    
    if (src_read != null) *src_read = (int)((anchor + lit_len) - base);
    
    return output_last_literals_hc(anchor, anchor + lit_len, op, olimit, dst_start);
}
