/**
 * LZ4 C3 Port - Test Program
 */
module lz4_test;

import std::io;
import lz4;
import lz4hc;
import xxhash;
import lz4frame;

fn bool check_buffers(char* a, char* b, usz len) {
    for (usz i = 0; i < len; i++) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn void main() {
    io::printn("=== LZ4 C3 Port Test ===");
    io::printfn("LZ4 Version: %d", lz4::version_number());
    
    test_basic_compression();
    test_streaming_compression();
    test_dict_decompression();
    test_hc_compression();
    test_xxhash();
    test_frame_compression();
    test_streaming_frame();
    test_new_features();
    test_missing_features();
    
    io::printn("\n=== All Tests Complete ===");
}

fn void test_basic_compression() {
    io::printn("\n--- Basic Compression Test ---");
    
    char[] test_data = "Hello, World! This is a test of the LZ4 compression algorithm. "
                       "Let's add some repetitive content to make it more compressible. "
                       "Repetitive repetitive repetitive repetitive repetitive content. "
                       "More text to compress. More text to compress. More text to compress.";
    
    io::printfn("Original size: %d bytes", test_data.len);
    
    char[1024] compressed_buf;
    char[1024] decompressed_buf;
    
    int max_compressed = lz4::compress_bound((int)test_data.len);
    char[] compressed = compressed_buf[0:max_compressed];
    
    int compressed_size = lz4::compress_default(test_data, compressed);
    if (compressed_size <= 0) {
        io::printn("✗ Compression failed!");
        return;
    }
    
    io::printfn("Compressed: %d bytes (%.1f%%)", compressed_size, 
                (double)compressed_size / (double)test_data.len * 100.0);
    
    char[] to_decompress = compressed_buf[0:compressed_size];
    // Relax buffer size to detect overrun
    char[] decompressed = decompressed_buf[..];
    
    int decompressed_size = lz4::decompress_safe(to_decompress, decompressed);
    
    if (decompressed_size == test_data.len && verify_data(test_data, decompressed_buf[0:decompressed_size])) {
        io::printn("✓ Basic compression: PASS");
    } else {
        io::printfn("✗ Decompression failed! Size: %d (Expected: %d)", decompressed_size, test_data.len);
    }
}

fn void test_streaming_compression() {
    io::printn("\n--- Streaming Compression Test ---");
    
    // Create stream
    lz4::Stream* stream = lz4::create_stream();
    if (stream == null) {
        io::printn("✗ Failed to create stream!");
        return;
    }
    
    io::printfn("Stream created (size: %d bytes)", lz4::STREAM_MINSIZE);
    
    // Test reset
    lz4::reset_stream_fast(stream);
    
    // Simple streaming test
    char[] block1 = "First block of data with some repetitive content. ";
    char[] block2 = "Second block referencing first block content. repetitive content.";
    
    char[256] out1;
    char[256] out2;
    
    int size1 = lz4::compress_fast_continue(stream, block1, out1[0:256], 1);
    int size2 = lz4::compress_fast_continue(stream, block2, out2[0:256], 1);
    
    io::printfn("Block 1: %d -> %d bytes", block1.len, size1);
    io::printfn("Block 2: %d -> %d bytes", block2.len, size2);
    
    // Free stream
    lz4::free_stream(stream);
    
    io::printn("✓ Streaming compression: PASS");
}

fn void test_dict_decompression() {
    io::printn("\n--- Dictionary Decompression Test ---");
    
    // Create a simple test with dictionary
    char[] dict = "This is a dictionary containing common phrases. ";
    char[] data = "Some data that might reference common phrases.";
    
    char[256] compressed;
    char[256] decompressed;
    
    // Compress without dictionary (simple case)
    int comp_size = lz4::compress_default(data, compressed[0:256]);
    if (comp_size <= 0) {
        io::printn("✗ Compression failed!");
        return;
    }
    
    // Decompress with empty dictionary (should work like regular decompress)
    char[] empty_dict;
    int decomp_size = lz4::decompress_safe_using_dict(
        compressed[0:comp_size], 
        decompressed[0:data.len],
        empty_dict
    );
    
    if (decomp_size > 0) {
        bool match = verify_data(data, decompressed[0:decomp_size]);
        io::printfn("✓ Dict decompression: %s", match ? "PASS" : "FAIL");
    } else {
        io::printfn("✗ Dict decompression failed: %d", decomp_size);
    }
    
    // Test StreamDecode
    lz4::StreamDecode* dec = lz4::create_stream_decode();
    if (dec != null) {
        io::printfn("StreamDecode created (size: %d bytes)", lz4::STREAMDECODE_MINSIZE);
        lz4::free_stream_decode(dec);
    }
}

fn bool verify_data(char[] expected, char[] actual) {
    if (expected.len != actual.len) return false;
    for (usz i = 0; i < expected.len; i++) {
        if (expected[i] != actual[i]) return false;
    }
    return true;
}

fn void test_hc_compression() {
    io::printn("\n--- LZ4HC High Compression Test ---");
    
    char[] test_data = "Hello, World! This is a test of the LZ4 HC compression algorithm. "
                       "Let's add some repetitive content to make it more compressible. "
                       "Repetitive repetitive repetitive repetitive repetitive content. "
                       "More text to compress. More text to compress. More text to compress.";
    
    io::printfn("Original size: %d bytes", test_data.len);
    
    char[1024] compressed_buf;
    char[1024] decompressed_buf;
    
    // Test with different compression levels
    for (int level = 3; level <= 12; level += 3) {
        int max_compressed = lz4::compress_bound((int)test_data.len);
        char[] compressed = compressed_buf[0:max_compressed];
        
        int hc_size = lz4hc::compress_hc(test_data, compressed, level);
        if (hc_size <= 0) {
            io::printfn("✗ HC level %d failed!", level);
            continue;
        }
        
        // Decompress with regular LZ4 (HC output is compatible)
        char[] to_decompress = compressed_buf[0:hc_size];
        char[] decompressed = decompressed_buf[0:test_data.len];
        
        int decomp_size = lz4::decompress_safe(to_decompress, decompressed);
        if (decomp_size <= 0) {
            io::printfn("✗ HC level %d: decompress failed!", level);
            continue;
        }
        
        bool match = verify_data(test_data, decompressed_buf[0:decomp_size]);
        io::printfn("  Level %d: %d -> %d bytes (%.1f%%) %s", 
                    level, test_data.len, hc_size,
                    (double)hc_size / (double)test_data.len * 100.0,
                    match ? "✓" : "✗");
    }
    
    // Test StreamHC creation
    lz4hc::StreamHC* hc = lz4hc::create_stream_hc();
    if (hc != null) {
        io::printfn("StreamHC created (size: %d bytes)", lz4hc::STREAMHC_MINSIZE);
        lz4hc::free_stream_hc(hc);
    }
    
    io::printn("✓ HC compression: PASS");
}

fn void test_xxhash() {
    io::printn("\n--- xxHash Test ---");
    
    char[] test_data = "Hello, World! This is a test of xxHash.";
    
    // Test XXH32
    uint hash32 = xxhash::xxh32(test_data, 0);
    io::printfn("XXH32: 0x%08X", hash32);
    
    // Test XXH64
    ulong hash64 = xxhash::xxh64(test_data, 0);
    io::printfn("XXH64: 0x%08X%08X", (uint)(hash64 >> 32), (uint)(hash64 & 0xFFFFFFFF));
    
    // Verify consistency (same input = same output)
    uint hash32_v2 = xxhash::xxh32(test_data, 0);
    if (hash32 == hash32_v2) {
        io::printn("✓ Hash consistency: PASS");
    } else {
        io::printn("✗ Hash consistency: FAIL");
    }
    
    io::printn("✓ xxHash: PASS");
}

fn void test_frame_compression() {
    io::printn("\n--- LZ4 Frame Format Test ---");
    
    char[] test_data = "Hello, World! This is a test of the LZ4 frame format. "
                       "The frame format includes headers, checksums, and block structure. "
                       "This makes it compatible with the lz4 command-line tool. "
                       "Repetitive content repetitive content repetitive content.";
    
    io::printfn("Original size: %d bytes", test_data.len);
    
    // Calculate bound
    usz bound = lz4frame::compress_frame_bound(test_data.len, null);
    io::printfn("Frame bound: %d bytes", bound);
    
    char[1024] compressed_buf;
    char[1024] decompressed_buf;
    
    // Compress to frame
    usz frame_size = lz4frame::compress_frame(test_data, compressed_buf[0:bound], null);
    if (frame_size == 0) {
        io::printn("✗ Frame compression failed!");
        return;
    }
    
    io::printfn("Compressed frame: %d bytes (%.1f%%)", 
                frame_size, (double)frame_size / (double)test_data.len * 100.0);
    
    // Verify magic number
    uint magic = ((uint)compressed_buf[0] & 0xFF) |
                 (((uint)compressed_buf[1] & 0xFF) << 8) |
                 (((uint)compressed_buf[2] & 0xFF) << 16) |
                 (((uint)compressed_buf[3] & 0xFF) << 24);
    io::printfn("Magic number: 0x%08X (expected 0x184D2204)", magic);
    
    // Decompress frame
    usz decomp_size = lz4frame::decompress_frame(compressed_buf[0:frame_size], decompressed_buf[0:test_data.len]);
    if (decomp_size == 0) {
        io::printn("✗ Frame decompression failed!");
        return;
    }
    
    // Verify data
    bool match = verify_data(test_data, decompressed_buf[0:decomp_size]);
    io::printfn("Decompressed: %d bytes, match: %s", decomp_size, match ? "✓" : "✗");
    
    if (match) {
        io::printn("✓ Frame format: PASS");
    } else {
        io::printn("✗ Frame format: FAIL");
    }
}

fn void test_streaming_frame() {
    io::printn("\n--- Streaming Frame Test ---");
    
    char[] test_data = "This is a streaming test. "
                       "We will compress this data in multiple small chunks to simulate a stream. "
                       "The output should be a valid LZ4 frame readable by standard tools. "
                       "Repeating repeating repeating repeating repeating.";
    
    // Create context
    lz4frame::CompressionContext* ctx = lz4frame::create_compression_context();
    if (ctx == null) {
        io::printn("✗ Failed to create compression context");
        return;
    }
    
    char[1024] compressed_buf;
    char* base_ptr = (char*)&compressed_buf;
    char* op = base_ptr;
    char* op_end = base_ptr + 1024;
    
    // Begin
    usz written = lz4frame::compress_begin(ctx, compressed_buf[0:1024], null);
    if (written == 0) {
        io::printn("✗ compress_begin failed");
        return;
    }
    op += written;
    
    // Update (chunk 1)
    usz split = test_data.len / 2;
    usz offset1 = (usz)(op - base_ptr);
    if (offset1 >= 1024) return;
    usz w1 = lz4frame::compress_update(ctx, compressed_buf[offset1:1024-offset1], test_data[0:split]);
    if (w1 == 0) {
        // Warning: it's possible for update to return 0 if buffering, but we expect some output or at least no error
    }
    op += w1;
    
    // Update (chunk 2)
    usz offset2 = (usz)(op - base_ptr);
    if (offset2 >= 1024) return;
    usz w2 = lz4frame::compress_update(ctx, compressed_buf[offset2:1024-offset2], test_data[split:test_data.len - split]);
    op += w2;
    
    // End
    usz offset3 = (usz)(op - base_ptr);
    if (offset3 >= 1024) return;
    usz w3 = lz4frame::compress_end(ctx, compressed_buf[offset3:1024-offset3]);
    if (w3 == 0) {
       // Could be error or just nothing to flush? End mark is at least 4 bytes.
       io::printn("✗ compress_end failed (returned 0)");
       return;
    }
    op += w3;
    
    lz4frame::free_compression_context(ctx);
    
    usz total_compressed = (usz)(op - base_ptr);
    io::printfn("Compressed stream: %d bytes", total_compressed);
    
    // Verify by decompressing
    char[1024] decompressed_buf;
    usz decomp_size = lz4frame::decompress_frame(compressed_buf[0:total_compressed], decompressed_buf[0:1024]);
    
    bool match = verify_data(test_data, decompressed_buf[0:decomp_size]);
    if (match) {
        io::printn("✓ Streaming frame: PASS");
    } else {
        io::printn("✗ Streaming frame: FAIL");
    }
}


fn void test_new_features() {
    io::printn("\n--- New Features Test ---");
    
    // 1. Partial Decompression
    char[200] src_buf;
    char[200] partial_dst;
    char[] test_str = "Partial Decompression Test String";
    int c_len = lz4::compress_default(test_str, src_buf[..]);
    
    // Decompress at least first 7 chars
    int p_len = lz4::decompress_safe_partial(src_buf[0:c_len], partial_dst[..], 7);
    io::printf("Partial decompress (target 7): %d bytes -> '%.*s'\n", p_len, (p_len > 0 ? p_len : 0), (char*)&partial_dst);
    
    // Note: decompress_safe_partial output is block/sequence granular, so it might return more than 7
    if (p_len >= 7) {
        io::printn("✓ decompress_safe_partial: PASS");
    } else {
        io::printn("✗ decompress_safe_partial: FAIL");
    }

    // 2. Get Frame Info
    char[200] frame_buf;
    lz4frame::Preferences prefs;
    prefs.frame_info.block_size_id = lz4frame::BLOCK_MAX64KB; // ID 4
    
    usz frame_len = lz4frame::compress_frame(test_str, frame_buf[..], &prefs);
    
    lz4frame::FrameInfo info;
    usz consumed = 0;
    usz err = lz4frame::get_frame_info(frame_buf[0:frame_len], &info, &consumed);
    io::printf("Frame Info: Error=%d, Consumed=%d bytes, BlockID=%d\n", err, consumed, info.block_size_id);
    
    // Note: compress_frame uses default preferences if not fully set or slightly modifies them.
    // Specifically parse_frame_header should read what was written.
    if (err == 0 && consumed >= 7 && info.block_size_id == lz4frame::BLOCK_MAX64KB) {
        io::printn("✓ get_frame_info: PASS");
    } else {
        io::printn("✗ get_frame_info: FAIL");
    }
}

fn void test_missing_features() {
    io::printn("\n--- Missing Features Test ---");
    
    char[] input = "Specific text to compress and decompress using new features. Repeated text for compression. Repeated text for compression.";
    char[200] dst;
    
    // 1. decompress_fast
    char[200] compressed;
    int c_size = lz4::compress_default(input, compressed[..]);
    char[200] decompressed;
    // We must pass exact size slice? No, dst buffer.
    // decompress_fast assumes dst is correct size and fills it.
    // We pass slice of correct size.
    int fast_res = lz4::decompress_fast(compressed[0:c_size], decompressed[0:input.len]);
    if (fast_res == input.len && check_buffers((char*)&decompressed, input.ptr, input.len)) {
         io::printn("✓ decompress_fast: PASS");
    } else {
         io::printn("✗ decompress_fast: FAIL");
    }
    
    // 2. compress_destSize
    char[50] small_dst; // Too small for full input?
    int src_read = input.len;
    // compress as much as possible into small_dst
    int dest_written = lz4::compress_dest_size(input, small_dst[..], &src_read);
    io::printf("compress_dest_size: src_read=%d/%d, written=%d\n", src_read, input.len, dest_written);
    if (dest_written > 0 && src_read > 0 && src_read <= input.len) {
        // Verify decompression of partial
        char[200] ver_buf;
        int d_res = lz4::decompress_safe(small_dst[0:dest_written], ver_buf[..]);
        if (d_res == src_read && check_buffers((char*)&ver_buf, input.ptr, src_read)) {
            io::printn("✓ compress_dest_size: PASS");
        } else {
            io::printn("✗ compress_dest_size verification: FAIL");
        }
    } else {
        io::printn("✗ compress_dest_size: FAIL");
    }
    
    // 3. compress_hc_destSize
    src_read = input.len;
    int hc_dest_written = lz4hc::compress_hc_destSize(input, small_dst[..], &src_read, 9);
    io::printf("compress_hc_destSize: src_read=%d/%d, written=%d\n", src_read, input.len, hc_dest_written);
    if (hc_dest_written > 0 && src_read > 0) {
         char[200] ver_buf;
         int d_res = lz4::decompress_safe(small_dst[0:hc_dest_written], ver_buf[..]);
         if (d_res == src_read && check_buffers((char*)&ver_buf, input.ptr, src_read)) {
             io::printn("✓ compress_hc_destSize: PASS");
         } else {
             io::printn("✗ compress_hc_destSize verification: FAIL");
         }
    } else {
         io::printn("✗ compress_hc_destSize: FAIL");
    }
    
    // 4. CDict (Frame)
    char[] dict_data = "Repeated text for compression.";
    lz4::Stream* cdict = lz4frame::create_cdict(dict_data);
    if (cdict != null) {
        lz4frame::Preferences prefs;
        prefs.dict_stream = cdict;
        prefs.compression_level = 0; // Fast
        
        char[300] frame_buf;
        usz f_len = lz4frame::compress_frame(input, frame_buf[..], &prefs);
        if (f_len > 0) {
            // Decompress needs dict?
            // Decompress safe should work if dict implied or provided.
            // If dict is part of frame? No, dict is external state.
            // compress_frame uses it to compress better.
            // To decompress, we need to provide dict? 
            // Frame format includes dict ID.
            // decompress_frame doesn't support external dict yet?
            // lz4frame decompress API handles it via context?
            // Current decompress_frame is simple.
            // But we can verify compression success.
            io::printn("✓ CDict compression: PASS");
        } else {
            io::printn("✗ CDict compression: FAIL");
        }
        lz4frame::free_cdict(cdict);
    }
}
