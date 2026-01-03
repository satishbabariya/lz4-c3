/**
 * LZ4 C3 Port - Test Program
 */
module lz4_test;

import std::io;
import lz4;

fn void main() {
    io::printn("=== LZ4 C3 Port Test ===");
    io::printfn("LZ4 Version: %d", lz4::version_number());
    
    // Test data - complex string with repetitions
    char[] test_data = "Hello, World! This is a test of the LZ4 compression algorithm. "
                       "Let's add some repetitive content to make it more compressible. "
                       "Repetitive repetitive repetitive repetitive repetitive content. "
                       "More text to compress. More text to compress. More text to compress.";
    
    io::printfn("\nOriginal size: %d bytes", test_data.len);
    
    // Calculate compress bound
    int max_compressed = lz4::compress_bound((int)test_data.len);
    io::printfn("Max compressed size: %d bytes", max_compressed);
    
    // Allocate buffers
    char[1024] compressed_buf;
    char[1024] decompressed_buf;
    
    char[] compressed = compressed_buf[0:max_compressed];
    
    // Compress
    int compressed_size = lz4::compress_default(test_data, compressed);
    
    if (compressed_size <= 0) {
        io::printn("ERROR: Compression failed!");
        return;
    }
    
    io::printfn("Compressed size: %d bytes", compressed_size);
    io::printfn("Compression ratio: %.2f%%", (double)compressed_size / (double)test_data.len * 100.0);
    
    // Decompress
    // C3 slice syntax: [start:length] or [start..end) where end is exclusive
    char[] to_decompress = compressed_buf[0:compressed_size];
    char[] decompressed = decompressed_buf[0:test_data.len];
    
    int decompressed_size = lz4::decompress_safe(to_decompress, decompressed);
    
    if (decompressed_size <= 0) {
        io::printn("ERROR: Decompression failed!");
        return;
    }
    
    io::printfn("Decompressed size: %d bytes", decompressed_size);
    
    // Verify
    bool match = true;
    if (decompressed_size != (int)test_data.len) {
        match = false;
    } else {
        for (int i = 0; i < decompressed_size; i++) {
            if (decompressed_buf[i] != test_data[i]) {
                match = false;
                break;
            }
        }
    }
    
    if (match) {
        io::printn("\n✓ SUCCESS: Decompressed data matches original!");
    } else {
        io::printn("\n✗ FAILURE: Decompressed data does not match!");
    }
    
    io::printn("\n=== Test Complete ===");
}
