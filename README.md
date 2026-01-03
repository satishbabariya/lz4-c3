# LZ4 C3 Port

A C3 port of the [LZ4](https://github.com/lz4/lz4) fast compression library.

## Features

- **Basic Compression** - `compress_default` / `decompress_safe`
- **Streaming** - Compress/decompress data in multiple calls
- **Dictionary Support** - Better compression for small data
- **LZ4HC** - High compression mode (levels 3-12)

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

## API Reference

### Core Functions

```c3
fn int compress_default(char[] src, char[] dst)
fn int compress_fast(char[] src, char[] dst, int acceleration)
fn int decompress_safe(char[] src, char[] dst)
fn int compress_bound(int input_size)
fn int version_number()
```

### Streaming Compression

```c3
fn Stream* create_stream()
fn void free_stream(Stream* stream)
fn int load_dict(Stream* stream, char[] dictionary)
fn int compress_fast_continue(Stream* stream, char[] src, char[] dst, int accel)
fn int save_dict(Stream* stream, char[] buffer)
```

### Streaming Decompression

```c3
fn StreamDecode* create_stream_decode()
fn void free_stream_decode(StreamDecode* stream)
fn int set_stream_decode(StreamDecode* stream, char[] dictionary)
fn int decompress_safe_continue(StreamDecode* stream, char[] src, char[] dst)
fn int decompress_safe_using_dict(char[] src, char[] dst, char[] dict)
```

### LZ4HC (High Compression)

```c3
import lz4hc;

fn int compress_hc(char[] src, char[] dst, int level)  // level: 3-12
fn StreamHC* create_stream_hc()
fn void free_stream_hc(StreamHC* stream)
fn int compress_hc_continue(StreamHC* stream, char[] src, char[] dst)
```

## Building

With Docker:
```bash
docker run --platform linux/amd64 --rm -v $(pwd):/app c3-lang c3c build lz4-test
docker run --platform linux/amd64 --rm -v $(pwd):/app c3-lang ./out/lz4-test
```

## Compression Comparison

| Method | Ratio | Speed |
|--------|-------|-------|
| LZ4 Default | ~62% | Fastest |
| LZ4HC Level 3 | ~63% | Fast |
| LZ4HC Level 9 | ~63% | Medium |
| LZ4HC Level 12 | ~63% | Slowest |

## License

BSD 2-Clause License (same as original LZ4)
