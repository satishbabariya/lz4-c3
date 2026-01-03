/**
 * LZ4 Frame Format
 * C3 Port
 *
 * Original Copyright (c) Yann Collet. All rights reserved.
 * BSD 2-Clause License
 *
 * Implements LZ4 frame format v1.6.1 for CLI-compatible compressed files.
 */
module lz4frame;

import lz4;
import lz4hc;
import xxhash;

// ============================================================================
// Constants
// ============================================================================

const uint VERSION = 100;
const uint MAGIC_NUMBER = 0x184D2204;
const uint MAGIC_SKIPPABLE_START = 0x184D2A50;

const int HEADER_SIZE_MIN = 7;
const int HEADER_SIZE_MAX = 19;
const int BLOCK_HEADER_SIZE = 4;
const int BLOCK_CHECKSUM_SIZE = 4;

const uint BLOCK_UNCOMPRESSED_FLAG = 0x80000000;

// Block size IDs
const int BLOCK_DEFAULT = 0;
const int BLOCK_MAX64KB = 4;
const int BLOCK_MAX256KB = 5;
const int BLOCK_MAX1MB = 6;
const int BLOCK_MAX4MB = 7;

// Block modes
const int MODE_LINKED = 0;
const int MODE_INDEPENDENT = 1;

// Checksum options
const int CHECKSUM_DISABLED = 0;
const int CHECKSUM_ENABLED = 1;

// ============================================================================
// Types
// ============================================================================

/**
 * Frame information structure.
 */
struct FrameInfo {
    int block_size_id;
    int block_mode;
    int content_checksum;
    int block_checksum;
    ulong content_size;
    uint dict_id;
}

/**
 * Compression preferences.
 */
struct Preferences {
    FrameInfo frame_info;
    int compression_level;  // 0=fast, 1-12=HC levels
    bool auto_flush;
    lz4::Stream* dict_stream;    // pre-digested dictionary (fast mode)
    lz4hc::StreamHC* dict_stream_hc; // pre-digested dictionary (HC mode)
}

/**
 * Compression context.
 */
struct CompressionContext {
    Preferences prefs;
    uint version_num;
    uint c_stage;
    usz max_block_size;
    usz max_buffer_size;
    char* tmp_buff;
    char* tmp_in;
    usz tmp_in_size;
    ulong total_in_size;
    xxhash::State32 xxh;
    lz4::Stream* lz4_ctx;
    lz4hc::StreamHC* lz4hc_ctx;
}

/**
 * Decompression context.
 */
struct DecompressionContext {
    FrameInfo frame_info;
    uint version_num;
    uint d_stage;
    usz max_block_size;
    char* tmp_buff;
    usz tmp_buff_size;
    usz tmp_in_target;
    usz tmp_in_size;
    xxhash::State32 xxh;
    ulong content_size;
    uint dict_id;
}

// ============================================================================
// Public API - Frame Compression
// ============================================================================

/**
 * Calculate maximum compressed frame size.
 */
fn usz compress_frame_bound(usz src_size, Preferences* prefs) {
    usz block_size = get_block_size(prefs != null ? prefs.frame_info.block_size_id : BLOCK_DEFAULT);
    usz nb_blocks = (src_size + block_size - 1) / block_size;
    usz header_size = (usz)HEADER_SIZE_MAX;
    usz block_headers = nb_blocks * (BLOCK_HEADER_SIZE + BLOCK_CHECKSUM_SIZE);
    usz end_mark = BLOCK_HEADER_SIZE;
    usz content_checksum = BLOCK_CHECKSUM_SIZE;
    
    return header_size + src_size + block_headers + end_mark + content_checksum;
}

/**
 * Compress entire buffer into a valid LZ4 frame.
 * @return : number of bytes written, or 0 on error
 */
fn usz compress_frame(char[] src, char[] dst, Preferences* prefs) {
    if (src.len == 0) return 0;
    if (dst.len < compress_frame_bound(src.len, prefs)) return 0;
    
    // Use streaming API for simplicity and code reuse
    CompressionContext* ctx = create_compression_context();
    if (ctx == null) return 0;
    
    usz total_written = 0;
    
    // 1. Begin
    usz w1 = compress_begin(ctx, dst, prefs);
    if (w1 == 0) {
        free_compression_context(ctx);
        return 0;
    }
    total_written += w1;
    
    // 2. Update
    if (src.len > 0) {
        usz w2 = compress_update(ctx, dst[total_written:dst.len-total_written], src);
        // Note: w2 can be 0 if data is buffered
        total_written += w2;
    }
    
    // 3. End
    usz w3 = compress_end(ctx, dst[total_written:dst.len-total_written]);
    if (w3 == 0) {
        free_compression_context(ctx);
        return 0;
    }
    total_written += w3;
    
    free_compression_context(ctx);
    return total_written;
}

/**
 * Extract frame parameters from a frame header.
 * 
 * @param src : source buffer pointing to the start of the frame
 * @param info : pointer to FrameInfo structure to fill
 * @param src_size_consumed : out parameter, set to number of bytes consumed (header size)
 * @return : 0 on success, or non-zero error code/0 on failure if header is incomplete
 */
fn usz get_frame_info(char[] src, FrameInfo* info, usz* src_size_consumed) {
    if (src.len < HEADER_SIZE_MIN) return 1; // Error
    
    // We reuse parse_frame_header which returns bytes read
    usz header_size = parse_frame_header(src.ptr, src.ptr + src.len, info);
    
    if (header_size == 0) return 1; // Error
    
    if (src_size_consumed != null) {
        *src_size_consumed = header_size;
    }
    
    return 0; // Success
}

/**
 * Decompress an LZ4 frame.
 * @return : number of bytes decompressed, or 0 on error
 */
fn usz decompress_frame(char[] src, char[] dst) {
    if (src.len < HEADER_SIZE_MIN) return 0;
    
    char* ip = src.ptr;
    char* ip_end = src.ptr + src.len;
    char* op = dst.ptr;
    char* op_end = dst.ptr + dst.len;
    
    // Parse header
    FrameInfo info;
    usz header_size = parse_frame_header(ip, ip_end, &info);
    if (header_size == 0) return 0;
    ip += header_size;
    
    // Initialize content checksum
    xxhash::State32 content_xxh;
    xxhash::reset32(&content_xxh, 0);
    
    // Decompress blocks
    while (ip + BLOCK_HEADER_SIZE <= ip_end) {
        uint block_header = read_le32(ip);
        ip += BLOCK_HEADER_SIZE;
        
        // End mark
        if (block_header == 0) break;
        
        bool is_compressed = (block_header & BLOCK_UNCOMPRESSED_FLAG) == 0;
        usz block_size = (usz)(block_header & ~BLOCK_UNCOMPRESSED_FLAG);
        
        if (block_size > 4 * 1024 * 1024) return 0;  // Invalid block size
        if (ip + block_size > ip_end) return 0;
        
        if (is_compressed) {
            // Decompress block
            usz remaining_out = (usz)(op_end - op);
            int decompressed = lz4::decompress_safe(ip[0:block_size], op[0:remaining_out]);
            if (decompressed <= 0) return 0;
            
            // Update content checksum
            if (info.content_checksum == CHECKSUM_ENABLED) {
                xxhash::update32(&content_xxh, op[0:decompressed]);
            }
            
            op += decompressed;
        } else {
            // Copy uncompressed block
            if (op + block_size > op_end) return 0;
            
            for (usz i = 0; i < block_size; i++) {
                *op++ = ip[i];
            }
            
            if (info.content_checksum == CHECKSUM_ENABLED) {
                xxhash::update32(&content_xxh, ip[0:block_size]);
            }
        }
        
        ip += block_size;
        
        // Skip block checksum if present
        if (info.block_checksum == CHECKSUM_ENABLED) {
            if (ip + BLOCK_CHECKSUM_SIZE > ip_end) return 0;
            ip += BLOCK_CHECKSUM_SIZE;
        }
    }
    
    // Verify content checksum
    if (info.content_checksum == CHECKSUM_ENABLED) {
        if (ip + BLOCK_CHECKSUM_SIZE > ip_end) return 0;
        uint expected_crc = read_le32(ip);
        uint actual_crc = xxhash::digest32(&content_xxh);
        if (expected_crc != actual_crc) return 0;
    }
    
    return (usz)(op - dst.ptr);
}

/**
 * Get block size for a block size ID.
 */
fn usz get_block_size(int id) {
    switch (id) {
        case BLOCK_MAX64KB: return 64 * 1024;
        case BLOCK_MAX256KB: return 256 * 1024;
        case BLOCK_MAX1MB: return 1024 * 1024;
        case BLOCK_MAX4MB: return 4 * 1024 * 1024;
        default: return 64 * 1024;
    }
}

// ============================================================================
// Streaming Frame Compression
// ============================================================================

/**
 * Create a frame compression context.
 * @return : pointer to context, or null on error
 */
fn CompressionContext* create_compression_context() {
    CompressionContext* ctx = mem::new(CompressionContext);
    if (ctx == null) return null;
    
    ctx.version_num = VERSION;
    ctx.c_stage = 0;
    ctx.max_block_size = 0;
    ctx.max_buffer_size = 0;
    ctx.tmp_buff = null;
    ctx.tmp_in = null;
    ctx.tmp_in_size = 0;
    ctx.total_in_size = 0;
    ctx.lz4_ctx = null;
    ctx.lz4hc_ctx = null;
    xxhash::reset32(&ctx.xxh, 0);
    
    return ctx;
}

/**
 * Free a frame compression context.
 */
fn void free_compression_context(CompressionContext* ctx) {
    if (ctx == null) return;
    
    if (ctx.tmp_buff != null) {
        mem::free(ctx.tmp_buff);
    }
    if (ctx.lz4_ctx != null) {
        lz4::free_stream(ctx.lz4_ctx);
    }
    if (ctx.lz4hc_ctx != null) {
        lz4hc::free_stream_hc(ctx.lz4hc_ctx);
    }
    
    mem::free(ctx);
}

/**
 * Begin a frame compression.
 * Writes the frame header to dst.
 *
 * @return : number of bytes written (header size), or 0 on error
 */
fn usz compress_begin(CompressionContext* ctx, char[] dst, Preferences* prefs) {
    if (ctx == null || dst.len < HEADER_SIZE_MAX) return 0;
    
    // Copy preferences
    if (prefs != null) {
        ctx.prefs = *prefs;
    } else {
        ctx.prefs.frame_info.block_size_id = BLOCK_MAX64KB;
        ctx.prefs.frame_info.block_mode = MODE_INDEPENDENT;
        ctx.prefs.frame_info.content_checksum = CHECKSUM_ENABLED;
        ctx.prefs.frame_info.block_checksum = CHECKSUM_DISABLED;
        ctx.prefs.frame_info.content_size = 0;
        ctx.prefs.frame_info.dict_id = 0;
        ctx.prefs.compression_level = 0;
        ctx.prefs.auto_flush = true;
    }
    
    ctx.max_block_size = get_block_size(ctx.prefs.frame_info.block_size_id);
    ctx.c_stage = 1;
    ctx.total_in_size = 0;
    xxhash::reset32(&ctx.xxh, 0);
    
    // Allocate internal buffer if needed
    if (ctx.tmp_buff == null) {
        ctx.max_buffer_size = ctx.max_block_size;
        ctx.tmp_buff = mem::alloc_array(char, ctx.max_buffer_size);
        if (ctx.tmp_buff == null) return 0;
    }
    ctx.tmp_in = ctx.tmp_buff;
    ctx.tmp_in_size = 0;
    
    // Create compression context
    if (ctx.prefs.compression_level >= 3) {
        if (ctx.lz4hc_ctx == null) {
            ctx.lz4hc_ctx = lz4hc::create_stream_hc();
        }
        if (ctx.prefs.dict_stream_hc != null) {
            lz4hc::attach_HC_dictionary(ctx.lz4hc_ctx, ctx.prefs.dict_stream_hc);
        }
    } else {
        if (ctx.lz4_ctx == null) {
            ctx.lz4_ctx = lz4::create_stream();
        }
        if (ctx.prefs.dict_stream != null) {
            lz4::attach_dictionary(ctx.lz4_ctx, ctx.prefs.dict_stream);
        }
    }
    
    // Write header
    return write_frame_header(dst.ptr, dst.ptr + dst.len, &ctx.prefs, 0);
}

/**
 * Compress data chunk. May buffer data internally.
 *
 * @return : number of bytes written to dst, or 0 on error
 */
fn usz compress_update(CompressionContext* ctx, char[] dst, char[] src) {
    if (ctx == null || ctx.c_stage == 0) return 0;
    if (src.len == 0) return 0;
    
    char* op = dst.ptr;
    char* op_end = dst.ptr + dst.len;
    char* ip = src.ptr;
    usz remaining = src.len;
    
    // Update content checksum
    if (ctx.prefs.frame_info.content_checksum == CHECKSUM_ENABLED) {
        xxhash::update32(&ctx.xxh, src);
    }
    ctx.total_in_size += src.len;
    
    // Process input
    while (remaining > 0) {
        usz to_buffer = ctx.max_block_size - ctx.tmp_in_size;
        if (to_buffer > remaining) to_buffer = remaining;
        
        // Copy to internal buffer
        for (usz i = 0; i < to_buffer; i++) {
            ctx.tmp_in[ctx.tmp_in_size + i] = ip[i];
        }
        ctx.tmp_in_size += to_buffer;
        ip += to_buffer;
        remaining -= to_buffer;
        
        // Flush block if full
        if (ctx.tmp_in_size == ctx.max_block_size) {
            usz written = flush_block(ctx, op, op_end);
            if (written == 0) return 0;
            op += written;
            ctx.tmp_in_size = 0;
        }
    }
    
    return (usz)(op - dst.ptr);
}

/**
 * Finish frame compression. Writes any remaining data and end mark.
 *
 * @return : number of bytes written, or 0 on error
 */
fn usz compress_end(CompressionContext* ctx, char[] dst) {
    if (ctx == null || ctx.c_stage == 0) return 0;
    
    char* op = dst.ptr;
    char* op_end = dst.ptr + dst.len;
    
    // Flush any remaining data
    if (ctx.tmp_in_size > 0) {
        usz written = flush_block(ctx, op, op_end);
        if (written == 0) return 0;
        op += written;
    }
    
    // Write end mark (0x00000000)
    if (op + BLOCK_HEADER_SIZE > op_end) return 0;
    write_le32(op, 0);
    op += BLOCK_HEADER_SIZE;
    
    // Write content checksum
    if (ctx.prefs.frame_info.content_checksum == CHECKSUM_ENABLED) {
        if (op + BLOCK_CHECKSUM_SIZE > op_end) return 0;
        uint content_crc = xxhash::digest32(&ctx.xxh);
        write_le32(op, content_crc);
        op += BLOCK_CHECKSUM_SIZE;
    }
    
    ctx.c_stage = 0;
    return (usz)(op - dst.ptr);
}

/**
 * Get compressed bound for update operations.
 */
fn usz compress_bound(usz src_size, Preferences* prefs) {
    usz block_size = get_block_size(prefs != null ? prefs.frame_info.block_size_id : BLOCK_DEFAULT);
    usz nb_blocks = (src_size + block_size - 1) / block_size;
    return src_size + nb_blocks * (BLOCK_HEADER_SIZE + BLOCK_CHECKSUM_SIZE);
}

fn usz flush_block(CompressionContext* ctx, char* op, char* op_end) @private {
    if (ctx.tmp_in_size == 0) return 0;
    
    usz max_compressed = lz4::compress_bound((int)ctx.tmp_in_size);
    if (op + BLOCK_HEADER_SIZE + max_compressed > op_end) return 0;
    
    char[] block_src = ctx.tmp_buff[0:ctx.tmp_in_size];
    
    int compressed_size;
    if (ctx.prefs.compression_level >= 3) {
        compressed_size = lz4hc::compress_hc(block_src, op[BLOCK_HEADER_SIZE:max_compressed], ctx.prefs.compression_level);
    } else {
        compressed_size = lz4::compress_default(block_src, op[BLOCK_HEADER_SIZE:max_compressed]);
    }
    
    usz written;
    if (compressed_size > 0 && (usz)compressed_size < ctx.tmp_in_size) {
        // Write compressed block
        write_le32(op, (uint)compressed_size);
        written = (usz)BLOCK_HEADER_SIZE + (usz)compressed_size;
    } else {
        // Store uncompressed
        write_le32(op, (uint)ctx.tmp_in_size | BLOCK_UNCOMPRESSED_FLAG);
        char* dst = op + BLOCK_HEADER_SIZE;
        for (usz i = 0; i < ctx.tmp_in_size; i++) {
            dst[i] = ctx.tmp_buff[i];
        }
        written = (usz)BLOCK_HEADER_SIZE + ctx.tmp_in_size;
    }
    
    return written;
}

// ============================================================================
// Internal Functions
// ============================================================================

fn usz write_frame_header(char* dst, char* dst_end, Preferences* prefs, usz content_size) @private {
    if (dst + HEADER_SIZE_MAX > dst_end) return 0;
    
    char* op = dst;
    
    // Magic number (4 bytes)
    write_le32(op, MAGIC_NUMBER);
    op += 4;
    
    char* header_start = op;
    
    // FLG byte
    char flg = 0;
    flg |= (1 & 0x03) << 6;  // Version = 01
    flg |= ((char)prefs.frame_info.block_mode & 0x01) << 5;
    flg |= ((char)prefs.frame_info.block_checksum & 0x01) << 4;
    if (prefs.frame_info.content_size > 0 || content_size > 0) flg |= 1 << 3;
    flg |= ((char)prefs.frame_info.content_checksum & 0x01) << 2;
    if (prefs.frame_info.dict_id > 0) flg |= 1;
    *op++ = flg;
    
    // BD byte
    char bd = ((char)prefs.frame_info.block_size_id & 0x07) << 4;
    *op++ = bd;
    
    // Optional content size (8 bytes)
    if ((flg & 0x08) != 0) {
        ulong size = prefs.frame_info.content_size > 0 ? prefs.frame_info.content_size : content_size;
        write_le64(op, size);
        op += 8;
    }
    
    // Optional dictionary ID (4 bytes)
    if ((flg & 0x01) != 0) {
        write_le32(op, prefs.frame_info.dict_id);
        op += 4;
    }
    
    // Header checksum (1 byte)
    uint hc = xxhash::xxh32(header_start[0:(usz)(op - header_start)], 0);
    *op++ = (char)((hc >> 8) & 0xFF);
    
    return (usz)(op - dst);
}

fn usz parse_frame_header(char* src, char* src_end, FrameInfo* info) @private {
    if (src + HEADER_SIZE_MIN > src_end) return 0;
    
    char* ip = src;
    
    // Magic number
    uint magic = read_le32(ip);
    if (magic != MAGIC_NUMBER) return 0;
    ip += 4;
    
    char* header_start = ip;
    
    // FLG byte
    char flg = *ip++;
    int version = (flg >> 6) & 0x03;
    if (version != 1) return 0;  // Only version 01 supported
    
    info.block_mode = (flg >> 5) & 0x01;
    info.block_checksum = (flg >> 4) & 0x01;
    bool has_content_size = ((flg >> 3) & 0x01) != 0;
    info.content_checksum = (flg >> 2) & 0x01;
    bool has_dict_id = (flg & 0x01) != 0;
    
    // BD byte
    char bd = *ip++;
    info.block_size_id = (bd >> 4) & 0x07;
    
    // Optional content size
    if (has_content_size) {
        if (ip + 8 > src_end) return 0;
        info.content_size = read_le64(ip);
        ip += 8;
    } else {
        info.content_size = 0;
    }
    
    // Optional dictionary ID
    if (has_dict_id) {
        if (ip + 4 > src_end) return 0;
        info.dict_id = read_le32(ip);
        ip += 4;
    } else {
        info.dict_id = 0;
    }
    
    // Header checksum
    uint expected_hc = xxhash::xxh32(header_start[0:(usz)(ip - header_start)], 0);
    char actual_hc = *ip++;
    if (actual_hc != (char)((expected_hc >> 8) & 0xFF)) return 0;
    
    return (usz)(ip - src);
}

fn void write_le32(char* dst, uint val) @private {
    dst[0] = (char)(val & 0xFF);
    dst[1] = (char)((val >> 8) & 0xFF);
    dst[2] = (char)((val >> 16) & 0xFF);
    dst[3] = (char)((val >> 24) & 0xFF);
}

fn void write_le64(char* dst, ulong val) @private {
    dst[0] = (char)(val & 0xFF);
    dst[1] = (char)((val >> 8) & 0xFF);
    dst[2] = (char)((val >> 16) & 0xFF);
    dst[3] = (char)((val >> 24) & 0xFF);
    dst[4] = (char)((val >> 32) & 0xFF);
    dst[5] = (char)((val >> 40) & 0xFF);
    dst[6] = (char)((val >> 48) & 0xFF);
    dst[7] = (char)((val >> 56) & 0xFF);
}

fn uint read_le32(char* src) @private {
    return ((uint)src[0] & 0xFF) |
           (((uint)src[1] & 0xFF) << 8) |
           (((uint)src[2] & 0xFF) << 16) |
           (((uint)src[3] & 0xFF) << 24);
}

fn ulong read_le64(char* src) @private {
    return ((ulong)src[0] & 0xFF) |
           (((ulong)src[1] & 0xFF) << 8) |
           (((ulong)src[2] & 0xFF) << 16) |
           (((ulong)src[3] & 0xFF) << 24) |
           (((ulong)src[4] & 0xFF) << 32) |
           (((ulong)src[5] & 0xFF) << 40) |
           (((ulong)src[6] & 0xFF) << 48) |
           (((ulong)src[7] & 0xFF) << 56);
}

// ============================================================================
// Dictionary Helpers (CDict)
// ============================================================================

/**
 * Create a digested dictionary for fast compression.
 */
fn lz4::Stream* create_cdict(char[] dict_buffer) {
    lz4::Stream* cdict = lz4::create_stream();
    if (cdict == null) return null;
    lz4::load_dict(cdict, dict_buffer);
    return cdict;
}

/**
 * Create a digested dictionary for HC compression.
 */
fn lz4hc::StreamHC* create_cdict_hc(char[] dict_buffer, int compression_level) {
    lz4hc::StreamHC* cdict = lz4hc::create_stream_hc();
    if (cdict == null) return null;
    cdict.compression_level = compression_level;
    lz4hc::load_dict_hc(cdict, dict_buffer);
    return cdict;
}

fn void free_cdict(lz4::Stream* cdict) {
    lz4::free_stream(cdict);
}

fn void free_cdict_hc(lz4hc::StreamHC* cdict) {
    lz4hc::free_stream_hc(cdict);
}
