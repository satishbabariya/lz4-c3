/**
 * LZ4 - Fast LZ compression algorithm
 * C3 Port
 *
 * Original Copyright (c) Yann Collet. All rights reserved.
 * BSD 2-Clause License
 *
 * C3 Port maintains the same algorithm and produces compatible output.
 */
module lz4;

// ============================================================================
// Version Information
// ============================================================================
const int VERSION_MAJOR = 1;
const int VERSION_MINOR = 10;
const int VERSION_RELEASE = 0;
const int VERSION_NUMBER = VERSION_MAJOR * 100 * 100 + VERSION_MINOR * 100 + VERSION_RELEASE;

// ============================================================================
// Constants
// ============================================================================
const int MAX_INPUT_SIZE = 0x7E000000;  // 2,113,929,216 bytes

// Internal constants
const int MINMATCH = 4;
const int WILDCOPYLENGTH = 8;
const int LASTLITERALS = 5;
const int MFLIMIT = 12;
const int MATCH_SAFEGUARD_DISTANCE = 2 * WILDCOPYLENGTH - MINMATCH;

const int ML_BITS = 4;
const uint ML_MASK = (1 << ML_BITS) - 1;
const int RUN_BITS = 8 - ML_BITS;
const uint RUN_MASK = (1 << RUN_BITS) - 1;

const int HASHLOG = 12;  // For 16KB hash table (default memory usage 14 -> 2^14 = 16KB, hashlog = 14-2 = 12)
const int HASHTABLESIZE = 1 << (HASHLOG + 2);
const int HASH_SIZE_U32 = 1 << HASHLOG;

const int DISTANCE_MAX = 65535;
const int ACCELERATION_DEFAULT = 1;
const int ACCELERATION_MAX = 65537;

const uint SKIP_TRIGGER = 6;

// ============================================================================
// Public API
// ============================================================================

/**
 * Returns the library version number.
 */
fn int version_number() {
    return VERSION_NUMBER;
}

/**
 * Provides the maximum size that LZ4 compression may output in a "worst case" scenario.
 * This function is primarily useful for memory allocation purposes (destination buffer size).
 *
 * @param input_size : max supported value is MAX_INPUT_SIZE
 * @return : maximum output size in a "worst case" scenario
 *           or 0, if input size is incorrect (too large or negative)
 */
fn int compress_bound(int input_size) {
    if (input_size < 0 || input_size > MAX_INPUT_SIZE) {
        return 0;
    }
    return input_size + input_size / 255 + 16;
}

/**
 * Compresses 'src_size' bytes from buffer 'src' into already allocated 'dst' buffer.
 *
 * Compression is guaranteed to succeed if 'dst.len' >= compress_bound(src_size).
 *
 * @param src : source buffer to compress
 * @param dst : destination buffer (must be pre-allocated)
 * @return : the number of bytes written into buffer 'dst' (necessarily <= dst.len)
 *           or 0 if compression fails
 */
fn int compress_default(char[] src, char[] dst) {
    return compress_fast(src, dst, ACCELERATION_DEFAULT);
}

/**
 * Same as compress_default(), but allows selection of "acceleration" factor.
 * The larger the acceleration value, the faster the algorithm, but also the lesser the compression.
 *
 * @param acceleration : acceleration factor (1 = default, higher = faster but less compression)
 * @return : the number of bytes written into buffer 'dst', or 0 if compression fails
 */
fn int compress_fast(char[] src, char[] dst, int acceleration) {
    if (src.len == 0) {
        return 0;
    }
    if (src.len > MAX_INPUT_SIZE) {
        return 0;
    }
    
    // Clamp acceleration
    int accel = acceleration;
    if (accel < 1) accel = ACCELERATION_DEFAULT;
    if (accel > ACCELERATION_MAX) accel = ACCELERATION_MAX;
    
    return compress_generic(src, dst, accel);
}

/**
 * Decompresses 'compressed_size' bytes from buffer 'src' into buffer 'dst'.
 *
 * @param src : compressed source buffer
 * @param dst : destination buffer (must be pre-allocated with enough space)
 * @return : the number of bytes decompressed into destination buffer (necessarily <= dst.len)
 *           If destination buffer is not large enough, decoding will stop and return a negative value.
 *           If the source stream is malformed, returns a negative result.
 */
fn int decompress_safe(char[] src, char[] dst) {
    if (src.len == 0 || dst.len == 0) {
        return -1;
    }
    return decompress_generic(src, dst, dst.len);
}

/**
 * Decompresses 'src' into 'dst', stopping when 'target_output_size' is reached.
 * useful for parsing headers or partial data.
 *
 * @param src : compressed source buffer
 * @param dst : destination buffer
 * @param target_output_size : stop decoding after this many bytes
 * @return : number of bytes decoded, or negative on error
 */
fn int decompress_safe_partial(char[] src, char[] dst, int target_output_size) {
    if (src.len == 0 || dst.len == 0) return -1;
    if (target_output_size > dst.len) target_output_size = dst.len;
    return decompress_generic(src, dst, target_output_size);
}

// ============================================================================
// Internal Implementation
// ============================================================================

fn uint read16(char* ptr) @private {
    // Little-endian read with unsigned masking
    return ((uint)ptr[0] & 0xFF) | (((uint)ptr[1] & 0xFF) << 8);
}

fn uint read32(char* ptr) @private {
    // Little-endian read with unsigned masking
    return ((uint)ptr[0] & 0xFF) | 
           (((uint)ptr[1] & 0xFF) << 8) | 
           (((uint)ptr[2] & 0xFF) << 16) | 
           (((uint)ptr[3] & 0xFF) << 24);
}

fn void write16(char* ptr, ushort value) @private {
    ptr[0] = (char)(value & 0xFF);
    ptr[1] = (char)((value >> 8) & 0xFF);
}

fn uint hash4(uint sequence) @private {
    // Multiply by prime and shift, then mask to table size
    uint hash = (sequence * 2654435761) >> (MINMATCH * 8 - HASHLOG);
    return hash & (HASH_SIZE_U32 - 1);  // Mask to ensure valid index
}

fn uint hash_position(char* p) @private {
    return hash4(read32(p));
}

fn void put_position(char* p, char* base, uint[HASH_SIZE_U32]* hash_table) @private {
    uint h = hash_position(p);
    (*hash_table)[h] = (uint)(p - base);
}

fn char* get_position(char* p, char* base, uint[HASH_SIZE_U32]* hash_table) @private {
    uint h = hash_position(p);
    return base + (*hash_table)[h];
}

fn uint count_match(char* p_in, char* p_match, char* p_in_limit) @private {
    char* p_start = p_in;
    
    while (p_in < p_in_limit - 7) {
        uint diff = read32(p_match) ^ read32(p_in);
        if (diff != 0) {
            // Count trailing zeros / 8 to get matching bytes
            uint match_bytes = count_trailing_zeros(diff) / 8;
            return (uint)(p_in - p_start) + match_bytes;
        }
        p_in += 4;
        p_match += 4;
    }
    
    // Byte-by-byte for remainder
    while (p_in < p_in_limit && *p_match == *p_in) {
        p_in++;
        p_match++;
    }
    
    return (uint)(p_in - p_start);
}

fn uint count_trailing_zeros(uint val) @private {
    if (val == 0) return 32;
    uint count = 0;
    while ((val & 1) == 0) {
        count++;
        val >>= 1;
    }
    return count;
}

fn void wild_copy8(char* dst, char* src, char* dst_end) @private {
    while (dst < dst_end) {
        // Copy 8 bytes at a time
        for (int i = 0; i < 8 && dst < dst_end; i++) {
            *dst++ = *src++;
        }
    }
}

fn int compress_generic(char[] src, char[] dst, int acceleration) @private {
    char* ip = src.ptr;
    char* base = src.ptr;
    char* anchor = ip;
    char* iend = src.ptr + src.len;
    char* mflimit_p = iend - MFLIMIT;
    char* match_limit = iend - LASTLITERALS;
    
    char* op = dst.ptr;
    char* olimit = dst.ptr + dst.len;
    
    // Hash table on stack
    uint[HASH_SIZE_U32] hash_table;
    for (int i = 0; i < HASH_SIZE_U32; i++) {
        hash_table[i] = 0;
    }
    
    // Minimum input size check
    if (src.len < MFLIMIT + 1) {
        // Too small, just output literals
        return output_last_literals(anchor, iend, op, olimit, dst.ptr);
    }
    
    // First byte
    put_position(ip, base, &hash_table);
    ip++;
    uint forwardH = hash_position(ip);
    
    // Main compression loop
    while (true) {
        char* match;
        char* token;
        
        // Find a match
        {
            char* forward_ip = ip;
            uint step = 1;
            uint search_match_nb = acceleration << SKIP_TRIGGER;
            
            while (true) {
                uint h = forwardH;
                ip = forward_ip;
                forward_ip += step;
                step = search_match_nb >> SKIP_TRIGGER;
                search_match_nb++;
                
                if (forward_ip > mflimit_p) {
                    return output_last_literals(anchor, iend, op, olimit, dst.ptr);
                }
                
                match = base + hash_table[h];
                forwardH = hash_position(forward_ip);
                hash_table[h] = (uint)(ip - base);
                
                // Check match validity - must be different position and within range
                if (read32(match) == read32(ip) && match != ip) {
                    if (ip - match <= DISTANCE_MAX) {
                        break;  // Found valid match
                    }
                }
            }
        }
        
        // Catch up: extend match backwards
        while (ip > anchor && match > base && ip[-1] == match[-1]) {
            ip--;
            match--;
        }
        
        // Encode literals
        {
            uint lit_length = (uint)(ip - anchor);
            token = op++;
            
            if (op + lit_length + (lit_length / 255) + 2 > olimit) {
                return 0;  // Output buffer too small
            }
            
            if (lit_length >= RUN_MASK) {
                *token = (char)(RUN_MASK << ML_BITS);
                uint len = lit_length - RUN_MASK;
                while (len >= 255) {
                    *op++ = (char)255;
                    len -= 255;
                }
                *op++ = (char)len;
            } else {
                *token = (char)(lit_length << ML_BITS);
            }
            
            // Copy literals
            char* lit_end = anchor + lit_length;
            while (anchor < lit_end) {
                *op++ = *anchor++;
            }
        }
        
        // Encode offset
        {
            ushort offset = (ushort)(ip - match);
            write16(op, offset);
            op += 2;
        }
        
        // Encode match length
        {
            ip += MINMATCH;
            match += MINMATCH;
            anchor = ip;
            
            uint match_length = count_match(ip, match, match_limit);
            ip += match_length;
            
            if (match_length >= ML_MASK) {
                *token += (char)ML_MASK;
                match_length -= ML_MASK;
                while (match_length >= 255) {
                    if (op >= olimit) return 0;
                    *op++ = (char)255;
                    match_length -= 255;
                }
                if (op >= olimit) return 0;
                *op++ = (char)match_length;
            } else {
                *token += (char)match_length;
            }
        }
        
        anchor = ip;
        
        // Check if we can continue
        if (ip > mflimit_p) {
            break;
        }
        
        // Fill hash table
        put_position(ip - 2, base, &hash_table);
        
        // Test next position
        uint h = hash_position(ip);
        match = base + hash_table[h];
        
        if (read32(match) == read32(ip) && ip - match <= DISTANCE_MAX && match != ip) {
            // Update hash table before processing this match
            hash_table[h] = (uint)(ip - base);
            
            // Another match at current position
            token = op++;
            *token = 0;
            ushort offset = (ushort)(ip - match);
            write16(op, offset);
            op += 2;
            
            ip += MINMATCH;
            match += MINMATCH;
            anchor = ip;
            
            uint match_length = count_match(ip, match, match_limit);
            ip += match_length;
            
            if (match_length >= ML_MASK) {
                *token = (char)ML_MASK;
                match_length -= ML_MASK;
                while (match_length >= 255) {
                    if (op >= olimit) return 0;
                    *op++ = (char)255;
                    match_length -= 255;
                }
                if (op >= olimit) return 0;
                *op++ = (char)match_length;
            } else {
                *token = (char)match_length;
            }
            
            anchor = ip;
            
            if (ip > mflimit_p) break;
            
            put_position(ip - 2, base, &hash_table);
        } else {
            // Update hash table even if no match found
            hash_table[h] = (uint)(ip - base);
        }
        
        forwardH = hash_position(ip);
    }
    
    // Output last literals
    return output_last_literals(anchor, iend, op, olimit, dst.ptr);
}

fn int output_last_literals(char* anchor, char* iend, char* op, char* olimit, char* dst_start) @private {
    usz last_run = (usz)(iend - anchor);
    
    if (op + 1 + last_run + (last_run / 255) > olimit) {
        return 0;  // Not enough space
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
    
    // Copy last literals
    while (anchor < iend) {
        *op++ = *anchor++;
    }
    
    return (int)(op - dst_start);  // Calculate written bytes from start
}

fn int decompress_generic(char[] src, char[] dst, int target_size) @private {
    char* ip = src.ptr;
    char* iend = src.ptr + src.len;
    
    char* op = dst.ptr;
    char* oend = dst.ptr + dst.len;
    char* oexit = dst.ptr + target_size;
    
    while (ip < iend) {
        // Get the token
        uint token = (uint)(*ip++) & 0xFF;
        
        // Decode literal length
        usz literal_len = (usz)(token >> ML_BITS);
        if (literal_len == RUN_MASK) {
            uint s;
            do {
                if (ip >= iend) return -10;  // Malformed literal length
                s = (uint)(*ip++) & 0xFF;
                literal_len += s;
            } while (s == 255);
        }
        
        // Copy literals
        if (op + literal_len > oend) {
            return -20;  // Output buffer too small for literals
        }
        if (ip + literal_len > iend) {
            return -21;  // Malformed input - literal length exceeds input
        }
        
        for (usz i = 0; i < literal_len; i++) {
            *op++ = *ip++;
        }
        
        // Check if this was the last sequence
        if (ip >= iend || op >= oexit) {
            break;
        }
        
        // Decode offset
        if (ip + 2 > iend) return -30;  // Not enough bytes for offset
        uint offset = read16(ip);
        ip += 2;
        
        if (offset == 0) return -31;  // Invalid zero offset
        
        char* match = op - offset;
        if (match < dst.ptr) return -32;  // Offset points before output buffer
        
        // Decode match length
        usz match_len = (usz)(token & ML_MASK);
        if (match_len == ML_MASK) {
            uint s;
            do {
                if (ip >= iend) return -40;  // Malformed match length
                s = (uint)(*ip++) & 0xFF;
                match_len += s;
            } while (s == 255);
        }
        match_len += MINMATCH;
        
        // Copy match
        if (op + match_len > oend) {
            return -50;  // Output buffer too small for match
        }
        
        // Handle overlapping copy
        for (usz i = 0; i < match_len; i++) {
            *op++ = *match++;
        }
    }
    
    return (int)(op - dst.ptr);
}

// ============================================================================
// Streaming Compression
// ============================================================================

/**
 * Streaming compression context.
 * Allows compressing data in multiple calls while maintaining context.
 */
struct Stream {
    uint[HASH_SIZE_U32] hash_table;
    char* dictionary;
    Stream* dict_ctx;
    uint current_offset;
    uint table_type;
    uint dict_size;
}

const usz STREAM_MINSIZE = Stream.sizeof;

/**
 * Allocate and initialize a streaming compression context.
 * @return : pointer to newly created Stream, or null if allocation fails
 */
fn Stream* create_stream() {
    // Use C3's allocator
    Stream* stream = mem::new(Stream);
    if (stream != null) {
        init_stream(stream);
    }
    return stream;
}

/**
 * Free a streaming compression context.
 * @return : 0 on success
 */
fn int free_stream(Stream* stream) {
    if (stream == null) return 0;
    mem::free(stream);
    return 0;
}

/**
 * Initialize a Stream structure.
 * Can be used with stack-allocated or externally managed Stream.
 * @return : pointer to initialized stream, or null if invalid
 */
fn Stream* init_stream(void* buffer) {
    if (buffer == null) return null;
    Stream* stream = (Stream*)buffer;
    
    // Zero the hash table
    for (int i = 0; i < HASH_SIZE_U32; i++) {
        stream.hash_table[i] = 0;
    }
    stream.dictionary = null;
    stream.dict_ctx = null;
    stream.current_offset = 0;
    stream.table_type = 0;
    stream.dict_size = 0;
    
    return stream;
}

/**
 * Reset stream for a new compression session.
 * Faster than init_stream() but requires stream to be properly initialized.
 */
fn void reset_stream_fast(Stream* stream) {
    if (stream == null) return;
    stream.current_offset = 0;
    stream.dict_size = 0;
    stream.dictionary = null;
    stream.dict_ctx = null;
    // Note: hash table is NOT cleared - caller must ensure clean state
}

/**
 * Load a dictionary into the stream for better compression.
 * Dictionary must remain accessible during compression.
 * @return : loaded dictionary size (max 64KB)
 */
fn int load_dict(Stream* stream, char[] dictionary) {
    if (stream == null) return 0;
    
    // Reset stream
    for (int i = 0; i < HASH_SIZE_U32; i++) {
        stream.hash_table[i] = 0;
    }
    stream.current_offset = 0;
    
    if (dictionary.len == 0) {
        stream.dictionary = null;
        stream.dict_size = 0;
        return 0;
    }
    
    // Only use last 64KB of dictionary
    usz dict_size = dictionary.len;
    char* dict_start = dictionary.ptr;
    if (dict_size > 64 * 1024) {
        dict_start = dictionary.ptr + dictionary.len - 64 * 1024;
        dict_size = 64 * 1024;
    }
    
    stream.dictionary = dict_start;
    stream.dict_size = (uint)dict_size;
    
    // Fill hash table with dictionary entries
    if (dict_size >= MINMATCH) {
        char* p = dict_start;
        char* dict_end = dict_start + dict_size - MINMATCH;
        while (p <= dict_end) {
            uint h = hash_position(p) & (HASH_SIZE_U32 - 1);
            stream.hash_table[h] = (uint)(p - dict_start);
            p++;
        }
    }
    
    stream.current_offset = (uint)dict_size;
    return (int)dict_size;
}

/**
 * Compress data using the stream context, for streaming compression.
 * Previous blocks must remain accessible in memory.
 *
 * @return : number of bytes written to dst, or 0 on error
 */
fn int compress_fast_continue(Stream* stream, char[] src, char[] dst, int acceleration) {
    if (stream == null || src.len == 0) return 0;
    if (src.len > MAX_INPUT_SIZE) return 0;
    
    // For now, fall back to stateless compression
    // Full streaming implementation would maintain state across calls
    return compress_fast(src, dst, acceleration);
}

/**
 * Save the last 64KB of compressed data as dictionary for future use.
 * @return : saved dictionary size, or 0 on error
 */
fn int save_dict(Stream* stream, char[] safe_buffer) {
    if (stream == null) return 0;
    if (safe_buffer.len == 0) return 0;
    
    // Copy last dict_size bytes if available
    uint to_save = stream.dict_size;
    if (to_save > safe_buffer.len) {
        to_save = (uint)safe_buffer.len;
    }
    
    if (to_save > 0 && stream.dictionary != null) {
        char* src = stream.dictionary + stream.dict_size - to_save;
        for (uint i = 0; i < to_save; i++) {
            safe_buffer.ptr[i] = src[i];
        }
    }
    
    return (int)to_save;
}

/**
 * Load dictionary using slower but more thorough method.
 * Processes every position in dictionary, not just sampled positions.
 * Better compression for small dictionaries at cost of slower loading.
 *
 * @return : loaded dictionary size (max 64KB)
 */
fn int load_dict_slow(Stream* stream, char[] dictionary) {
    if (stream == null) return 0;
    
    // Reset stream completely
    for (int i = 0; i < HASH_SIZE_U32; i++) {
        stream.hash_table[i] = 0;
    }
    stream.current_offset = 0;
    stream.dict_ctx = null;
    
    if (dictionary.len == 0) {
        stream.dictionary = null;
        stream.dict_size = 0;
        return 0;
    }
    
    // Only use last 64KB of dictionary
    usz dict_size = dictionary.len;
    char* dict_start = dictionary.ptr;
    if (dict_size > 64 * 1024) {
        dict_start = dictionary.ptr + dictionary.len - 64 * 1024;
        dict_size = 64 * 1024;
    }
    
    stream.dictionary = dict_start;
    stream.dict_size = (uint)dict_size;
    
    // Fill hash table with EVERY position (slower, better compression)
    if (dict_size >= MINMATCH) {
        char* p = dict_start;
        char* dict_end = dict_start + dict_size - MINMATCH + 1;
        uint idx = 0;
        while (p < dict_end) {
            uint h = hash_position(p) & (HASH_SIZE_U32 - 1);
            stream.hash_table[h] = idx;
            p++;
            idx++;
        }
    }
    
    stream.current_offset = (uint)dict_size;
    return (int)dict_size;
}

/**
 * Attach a pre-filled dictionary Stream to a working Stream.
 * The dictionary stream must remain valid during compression.
 * This allows reusing a pre-computed dictionary across multiple compressions.
 *
 * @param working_stream : stream to attach dictionary to
 * @param dict_stream : pre-filled dictionary stream (from load_dict)
 */
fn void attach_dictionary(Stream* working_stream, Stream* dict_stream) {
    if (working_stream == null) return;
    
    // Reset working stream
    reset_stream_fast(working_stream);
    
    // Clear hash table
    for (int i = 0; i < HASH_SIZE_U32; i++) {
        working_stream.hash_table[i] = 0;
    }
    
    // Attach dictionary reference
    working_stream.dict_ctx = dict_stream;
    
    if (dict_stream != null) {
        working_stream.dictionary = dict_stream.dictionary;
        working_stream.dict_size = dict_stream.dict_size;
    }
}

// ============================================================================
// Streaming Decompression
// ============================================================================

/**
 * Streaming decompression context.
 */
struct StreamDecode {
    char* external_dict;
    char* prefix_end;
    usz ext_dict_size;
    usz prefix_size;
}

const usz STREAMDECODE_MINSIZE = StreamDecode.sizeof;

/**
 * Allocate and initialize streaming decompression context.
 */
fn StreamDecode* create_stream_decode() {
    StreamDecode* stream = mem::new(StreamDecode);
    if (stream != null) {
        stream.external_dict = null;
        stream.prefix_end = null;
        stream.ext_dict_size = 0;
        stream.prefix_size = 0;
    }
    return stream;
}

/**
 * Free streaming decompression context.
 */
fn int free_stream_decode(StreamDecode* stream) {
    if (stream == null) return 0;
    mem::free(stream);
    return 0;
}

/**
 * Set dictionary for streaming decompression.
 * @return : 1 on success, 0 on error
 */
fn int set_stream_decode(StreamDecode* stream, char[] dictionary) {
    if (stream == null) return 0;
    
    stream.external_dict = dictionary.ptr;
    stream.ext_dict_size = dictionary.len;
    stream.prefix_end = null;
    stream.prefix_size = 0;
    
    return 1;
}

/**
 * Decompress with dictionary support.
 * Dictionary must contain the last 64KB of previously decompressed data.
 */
fn int decompress_safe_using_dict(char[] src, char[] dst, char[] dict) {
    if (src.len == 0 || dst.len == 0) return -1;
    
    // If no dictionary, use regular decompression
    if (dict.len == 0) {
        return decompress_safe(src, dst);
    }
    
    return decompress_with_dict_generic(src, dst, dict);
}

/**
 * Streaming decompression - decompress blocks that reference previous output.
 */
fn int decompress_safe_continue(StreamDecode* stream, char[] src, char[] dst) {
    if (stream == null) return -1;
    
    int result;
    
    // Use external dict if set
    if (stream.ext_dict_size > 0) {
        char[] dict = stream.external_dict[0:stream.ext_dict_size];
        result = decompress_with_dict_generic(src, dst, dict);
    } else {
        result = decompress_safe(src, dst);
    }
    
    if (result > 0) {
        // Update stream state for next block
        stream.prefix_end = dst.ptr + result;
        stream.prefix_size = (usz)result;
    }
    
    return result;
}

/**
 * Get minimum ring buffer size for streaming decompression.
 */
fn int decoder_ring_buffer_size(int max_block_size) {
    if (max_block_size < 0) return 0;
    return 65536 + 14 + max_block_size;
}

// ============================================================================
// Internal: Decompression with Dictionary
// ============================================================================

fn int decompress_with_dict_generic(char[] src, char[] dst, char[] dict) @private {
    char* ip = src.ptr;
    char* iend = src.ptr + src.len;
    
    char* op = dst.ptr;
    char* oend = dst.ptr + dst.len;
    
    char* dict_start = dict.ptr;
    char* dict_end = dict.ptr + dict.len;
    
    while (ip < iend) {
        uint token = (uint)(*ip++) & 0xFF;
        
        // Decode literal length
        usz literal_len = (usz)(token >> ML_BITS);
        if (literal_len == RUN_MASK) {
            uint s;
            do {
                if (ip >= iend) return -10;
                s = (uint)(*ip++) & 0xFF;
                literal_len += s;
            } while (s == 255);
        }
        
        // Copy literals
        if (op + literal_len > oend) return -20;
        if (ip + literal_len > iend) return -21;
        
        for (usz i = 0; i < literal_len; i++) {
            *op++ = *ip++;
        }
        
        if (ip >= iend) break;
        
        // Decode offset
        if (ip + 2 > iend) return -30;
        uint offset = read16(ip);
        ip += 2;
        
        if (offset == 0) return -31;
        
        // Determine match source (output buffer or dictionary)
        char* match;
        usz match_in_dict = 0;
        
        if ((usz)(op - dst.ptr) < offset) {
            // Match is in dictionary
            usz offset_in_dict = offset - (usz)(op - dst.ptr);
            if (offset_in_dict > dict.len) return -32;
            match = dict_end - offset_in_dict;
            match_in_dict = offset_in_dict;
        } else {
            match = op - offset;
        }
        
        // Decode match length
        usz match_len = (usz)(token & ML_MASK);
        if (match_len == ML_MASK) {
            uint s;
            do {
                if (ip >= iend) return -40;
                s = (uint)(*ip++) & 0xFF;
                match_len += s;
            } while (s == 255);
        }
        match_len += MINMATCH;
        
        if (op + match_len > oend) return -50;
        
        // Copy match (may span dictionary and output buffer)
        if (match_in_dict > 0) {
            // Copy from dictionary first
            usz from_dict = match_in_dict;
            if (from_dict > match_len) from_dict = match_len;
            
            for (usz i = 0; i < from_dict; i++) {
                *op++ = *match++;
            }
            match_len -= from_dict;
            
            // Continue from output buffer if needed
            if (match_len > 0) {
                match = dst.ptr;
                for (usz i = 0; i < match_len; i++) {
                    *op++ = *match++;
                }
            }
        } else {
            for (usz i = 0; i < match_len; i++) {
                *op++ = *match++;
            }
        }
    }
    
    return (int)(op - dst.ptr);
}
