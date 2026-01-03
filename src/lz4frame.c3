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
    
    Preferences local_prefs;
    if (prefs != null) {
        local_prefs = *prefs;
    } else {
        local_prefs.frame_info.block_size_id = BLOCK_MAX64KB;
        local_prefs.frame_info.block_mode = MODE_INDEPENDENT;
        local_prefs.frame_info.content_checksum = CHECKSUM_ENABLED;
        local_prefs.frame_info.block_checksum = CHECKSUM_DISABLED;
        local_prefs.frame_info.content_size = 0;
        local_prefs.frame_info.dict_id = 0;
        local_prefs.compression_level = 0;
        local_prefs.auto_flush = true;
    }
    
    char* op = dst.ptr;
    char* op_end = dst.ptr + dst.len;
    
    // Write header
    usz header_size = write_frame_header(op, op_end, &local_prefs, src.len);
    if (header_size == 0) return 0;
    op += header_size;
    
    // Initialize content checksum
    xxhash::State32 content_xxh;
    xxhash::reset32(&content_xxh, 0);
    if (local_prefs.frame_info.content_checksum == CHECKSUM_ENABLED) {
        xxhash::update32(&content_xxh, src);
    }
    
    // Compress blocks
    usz block_size = get_block_size(local_prefs.frame_info.block_size_id);
    char* ip = src.ptr;
    char* ip_end = src.ptr + src.len;
    
    while (ip < ip_end) {
        usz remaining = (usz)(ip_end - ip);
        usz this_block = remaining < block_size ? remaining : block_size;
        
        // Compress block
        char[] block_src = ip[0:this_block];
        usz max_dst = lz4::compress_bound((int)this_block);
        
        if (op + BLOCK_HEADER_SIZE + max_dst > op_end) return 0;
        
        int compressed_size;
        if (local_prefs.compression_level >= 3) {
            compressed_size = lz4hc::compress_hc(block_src, op[BLOCK_HEADER_SIZE:max_dst], local_prefs.compression_level);
        } else {
            compressed_size = lz4::compress_default(block_src, op[BLOCK_HEADER_SIZE:max_dst]);
        }
        
        // Check if compression was effective
        if (compressed_size > 0 && (usz)compressed_size < this_block) {
            // Write compressed block
            write_le32(op, (uint)compressed_size);
            op += (usz)BLOCK_HEADER_SIZE + (usz)compressed_size;
        } else {
            // Store uncompressed
            write_le32(op, (uint)this_block | BLOCK_UNCOMPRESSED_FLAG);
            op += BLOCK_HEADER_SIZE;
            for (usz i = 0; i < this_block; i++) {
                *op++ = ip[i];
            }
        }
        
        // Block checksum (optional)
        if (local_prefs.frame_info.block_checksum == CHECKSUM_ENABLED) {
            uint block_crc = xxhash::xxh32(op[-compressed_size:compressed_size], 0);
            write_le32(op, block_crc);
            op += BLOCK_CHECKSUM_SIZE;
        }
        
        ip += this_block;
    }
    
    // Write end mark (0x00000000)
    write_le32(op, 0);
    op += BLOCK_HEADER_SIZE;
    
    // Write content checksum
    if (local_prefs.frame_info.content_checksum == CHECKSUM_ENABLED) {
        uint content_crc = xxhash::digest32(&content_xxh);
        write_le32(op, content_crc);
        op += BLOCK_CHECKSUM_SIZE;
    }
    
    return (usz)(op - dst.ptr);
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
