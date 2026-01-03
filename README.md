# LZ4 C3 Port

A complete C3 port of the [LZ4](https://github.com/lz4/lz4) compression library.

## Modules

| Module | Description |
|--------|-------------|
| `lz4` | Core compression + streaming |
| `lz4hc` | High compression (levels 3-12) |
| `xxhash` | XXH32/XXH64 hash functions |
| `lz4frame` | Frame format for CLI compatibility |

## Quick Start

```c3
import lz4;

fn void example() {
    char[] data = "Hello, World! Some data to compress...";
    char[100] compressed;
    char[100] decompressed;
    
    // Compress
    int size = lz4::compress_default(data, compressed[0:100]);
    
    // Decompress
    int orig = lz4::decompress_safe(compressed[0:size], decompressed[0:data.len]);
}
```

## Frame Format

```c3
import lz4frame;

fn void frame_example() {
    char[] data = "Data to compress into LZ4 frame format...";
    char[256] frame;
    char[256] output;
    
    // Compress to frame (CLI-compatible .lz4 file format)
    usz size = lz4frame::compress_frame(data, frame[0:256], null);
    
    // Decompress frame
    usz orig = lz4frame::decompress_frame(frame[0:size], output[0:256]);
}
```

## Building

```bash
# Build library
docker run --platform linux/amd64 --rm -v $(pwd):/app c3-lang c3c build lz4-c3

# Build and run tests
docker run --platform linux/amd64 --rm -v $(pwd):/app c3-lang c3c build lz4-test
docker run --platform linux/amd64 --rm -v $(pwd):/app c3-lang ./out/lz4-test
```

## License

BSD 2-Clause License (same as original LZ4)
