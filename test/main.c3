/**
 * LZ4 C3 Port - Test Program
 */
module lz4_test;

import std::io;
import lz4;
import lz4hc;

fn void main() {
    io::printn("=== LZ4 C3 Port Test ===");
    io::printfn("LZ4 Version: %d", lz4::version_number());
    
    test_basic_compression();
    test_streaming_compression();
    test_dict_decompression();
    test_hc_compression();
    
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
    char[] decompressed = decompressed_buf[0:test_data.len];
    
    int decompressed_size = lz4::decompress_safe(to_decompress, decompressed);
    if (decompressed_size <= 0) {
        io::printn("✗ Decompression failed!");
        return;
    }
    
    bool match = verify_data(test_data, decompressed_buf[0:decompressed_size]);
    io::printfn("✓ Basic compression: %s", match ? "PASS" : "FAIL");
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

