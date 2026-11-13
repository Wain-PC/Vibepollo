/** macOS GPU integration test: real conversion, encoding, packetization and decoding. */
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "src/platform/macos/pyrowave_core.h"
#include "src/pyrowave_policy.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <pyrowave_metal.h>
#include <random>
#include <span>
#include <stdexcept>

using namespace pyrowave::macos_gpu;

static void require(bool ok, const char *message) {
  if (!ok) {
    throw std::runtime_error(message);
  }
}

// The same reference as the Linux test: sRGB to BT.2020 PQ at a given SDR white.
static std::array<float, 3> sdr_to_pq(std::array<float, 3> rgb, float white_nits) {
  for (auto &c : rgb) {
    c = c <= 0.04045f ? c / 12.92f : std::pow((c + 0.055f) / 1.055f, 2.4f);
  }
  std::array<float, 3> result = {
    0.627404f * rgb[0] + 0.329283f * rgb[1] + 0.043313f * rgb[2],
    0.069097f * rgb[0] + 0.919540f * rgb[1] + 0.011362f * rgb[2],
    0.016391f * rgb[0] + 0.088013f * rgb[1] + 0.895595f * rgb[2]
  };
  for (auto &c : result) {
    float x = std::pow(c * white_nits / 10000.0f, 2610.0f / 16384.0f);
    c = std::pow((3424.0f / 4096.0f + 2413.0f / 128.0f * x) / (1 + 2392.0f / 128.0f * x), 2523.0f / 32.0f);
  }
  return result;
}

enum class source_e {
  bgra_memory,
  bgra_surface,
  rgb10_surface,
  nv12_surface,
  p010_surface,
};

static const char *name(source_e kind) {
  switch (kind) {
    case source_e::bgra_memory:
      return "BGRA pixels";
    case source_e::bgra_surface:
      return "BGRA surface";
    case source_e::rgb10_surface:
      return "10-bit RGB surface";
    case source_e::nv12_surface:
      return "NV12 surface";
    case source_e::p010_surface:
      return "P010 surface";
  }
  return "";
}

struct frame_t {
  CVPixelBufferRef buffer = nullptr;
  std::vector<std::uint8_t> pixels;
  source_t source;

  frame_t() = default;
  frame_t(const frame_t &) = delete;

  ~frame_t() {
    if (buffer) {
      CVPixelBufferRelease(buffer);
    }
  }

  void surface(OSType format, int width, int height) {
    NSDictionary *attributes = @{(__bridge NSString *) kCVPixelBufferIOSurfacePropertiesKey: @{}};
    require(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, (__bridge CFDictionaryRef) attributes, &buffer) == kCVReturnSuccess, "pixel buffer allocation failed");
    source.pixel_buffer = buffer;
  }
};

/// A frame of one colour: 8-bit RGB for the RGB sources, 8-bit Y'CbCr codes for the biplanar ones.
static void fill(frame_t &frame, source_e kind, int width, int height, const std::array<int, 3> &colour) {
  if (kind == source_e::bgra_memory) {
    frame.pixels.resize(std::size_t(width) * height * 4);
    for (std::size_t i = 0; i < frame.pixels.size(); i += 4) {
      frame.pixels[i] = std::uint8_t(colour[2]);
      frame.pixels[i + 1] = std::uint8_t(colour[1]);
      frame.pixels[i + 2] = std::uint8_t(colour[0]);
      frame.pixels[i + 3] = 255;
    }
    frame.source.pixels = frame.pixels.data();
    frame.source.width = width;
    frame.source.height = height;
    frame.source.stride = width * 4;
    return;
  }

  const OSType format = kind == source_e::bgra_surface  ? kCVPixelFormatType_32BGRA :
                        kind == source_e::rgb10_surface ? kCVPixelFormatType_ARGB2101010LEPacked :
                        kind == source_e::nv12_surface  ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange :
                                                          kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
  frame.surface(format, width, height);
  CVPixelBufferLockBaseAddress(frame.buffer, 0);
  if (kind == source_e::bgra_surface || kind == source_e::rgb10_surface) {
    // 8-bit codes widen to 10 bits as code * 1023 / 255, so both formats hold the same colour.
    auto wide = [&](int i) {
      return std::uint32_t(std::lround(colour[i] * 1023.0 / 255.0));
    };
    const std::uint32_t pixel = kind == source_e::bgra_surface ?
                                  (0xFFu << 24) | (std::uint32_t(colour[0]) << 16) | (std::uint32_t(colour[1]) << 8) | std::uint32_t(colour[2]) :
                                  (3u << 30) | (wide(0) << 20) | (wide(1) << 10) | wide(2);
    auto *base = static_cast<std::uint8_t *>(CVPixelBufferGetBaseAddress(frame.buffer));
    const auto stride = CVPixelBufferGetBytesPerRow(frame.buffer);
    for (int y = 0; y < height; ++y) {
      auto *row = reinterpret_cast<std::uint32_t *>(base + y * stride);
      std::fill_n(row, width, pixel);
    }
  } else {
    const bool ten = kind == source_e::p010_surface;
    for (std::size_t plane = 0; plane < 2; ++plane) {
      auto *base = static_cast<std::uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(frame.buffer, plane));
      const auto stride = CVPixelBufferGetBytesPerRowOfPlane(frame.buffer, plane);
      const auto rows = CVPixelBufferGetHeightOfPlane(frame.buffer, plane);
      const auto columns = CVPixelBufferGetWidthOfPlane(frame.buffer, plane) * (plane ? 2 : 1);
      for (std::size_t y = 0; y < rows; ++y) {
        for (std::size_t x = 0; x < columns; ++x) {
          const int code = plane == 0 ? colour[0] : colour[1 + (x & 1)];
          if (ten) {
            // A 10-bit code (the 8-bit one times four) in the high bits.
            reinterpret_cast<std::uint16_t *>(base + y * stride)[x] = std::uint16_t((code * 4) << 6);
          } else {
            base[y * stride + x] = std::uint8_t(code);
          }
        }
      }
    }
  }
  CVPixelBufferUnlockBaseAddress(frame.buffer, 0);
}

struct decoder_t {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  id<MTLCommandQueue> queue = [device newCommandQueue];
  pyrowave_device codec = nullptr;

  decoder_t() {
    pyrowave_device_create_info info {};
    info.mtl_device = (__bridge void *) device;
    require(pyrowave_device_create(&info, &codec) == PYROWAVE_SUCCESS, "decoder device creation failed");
  }

  ~decoder_t() {
    pyrowave_device_destroy(codec);
  }

  /// Decodes one frame and returns its planes as normalized samples.
  std::array<std::vector<float>, 3> decode(const config_t &config, const std::vector<std::uint8_t> &bits, const std::vector<packet_t> &packets) {
    pyrowave_decoder_create_info info {};
    info.device = codec;
    info.width = config.width;
    info.height = config.height;
    info.chroma = config.yuv444 ? PYROWAVE_CHROMA_SUBSAMPLING_444 : PYROWAVE_CHROMA_SUBSAMPLING_420;
    pyrowave_decoder decoder = nullptr;
    require(pyrowave_decoder_create(&info, &decoder) == PYROWAVE_SUCCESS, "decoder creation failed");

    struct decoder_guard {
      pyrowave_decoder d;

      ~decoder_guard() {
        pyrowave_decoder_destroy(d);
      }
    } guard {decoder};

    for (auto &packet : packets) {
      require(pyrowave_decoder_push_packet(decoder, bits.data() + packet.offset, packet.size) == PYROWAVE_SUCCESS, "packet rejected");
    }
    require(pyrowave_decoder_decode_is_ready(decoder, false), "encoded frame is incomplete");

    id<MTLTexture> textures[3];
    pyrowave_gpu_buffers targets {};
    for (int i = 0; i < 3; ++i) {
      const bool half = i != 0 && !config.yuv444;
      auto *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Unorm
                                                                           width:NSUInteger(half ? config.width / 2 : config.width)
                                                                          height:NSUInteger(half ? config.height / 2 : config.height)
                                                                       mipmapped:NO];
      descriptor.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
      descriptor.storageMode = MTLStorageModeShared;
      textures[i] = [device newTextureWithDescriptor:descriptor];
      targets.planes[i] = (__bridge void *) textures[i];
    }

    id<MTLCommandBuffer> commands = [queue commandBuffer];
    require(pyrowave_decoder_decode_gpu_buffer(decoder, (__bridge void *) commands, &targets) == PYROWAVE_SUCCESS, "decode failed");
    [commands commit];
    [commands waitUntilCompleted];
    require(commands.status == MTLCommandBufferStatusCompleted, "decode command buffer failed");

    std::array<std::vector<float>, 3> planes;
    for (int i = 0; i < 3; ++i) {
      const NSUInteger width = textures[i].width;
      const NSUInteger height = textures[i].height;
      std::vector<std::uint16_t> raw(width * height);
      [textures[i] getBytes:raw.data() bytesPerRow:width * 2 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
      planes[i].resize(raw.size());
      for (std::size_t j = 0; j < raw.size(); ++j) {
        planes[i][j] = raw[j] / 65535.0f;
      }
    }
    return planes;
  }
};

/// The stream's RGB to normalized Y'CbCr rows, as video::color_vectors_from_colorspace() makes them.
static std::array<float, 12> matrix(unsigned depth, bool hdr) {
  const float max = float((1u << depth) - 1), scale = float(1u << (depth - 8));
  const float ym = 219 * scale / max, ya = 16 * scale / max;
  const float cm = 224 * scale / max, ca = float(1u << (depth - 1)) / max;
  const float kr = hdr ? 0.2627f : 0.2126f, kb = hdr ? 0.0593f : 0.0722f, kg = 1 - kr - kb;
  return {kr * ym, kg * ym, kb * ym, ya, -0.5f * kr / (1 - kb) * cm, -0.5f * kg / (1 - kb) * cm, 0.5f * cm, ca, 0.5f * cm, -0.5f * kg / (1 - kr) * cm, -0.5f * kb / (1 - kr) * cm, ca};
}

static float largest_error = 0;

static void expect_sample(const std::vector<float> &plane, std::size_t width, std::size_t x, std::size_t y, float expected, float tolerance, const char *what) {
  const float actual = plane[y * width + x];
  largest_error = std::max(largest_error, std::abs(actual - expected));
  if (std::abs(actual - expected) > tolerance) {
    std::cerr << what << ": expected " << expected << " got " << actual << '\n';
    throw std::runtime_error("decoded colour mismatch");
  }
}

int main() {
  @autoreleasepool {
    try {
      std::string error;
      if (!device_supported(error)) {
        std::cerr << "skipped: " << error << '\n';
        return 77;
      }

      decoder_t decoder;
      unsigned cases = 0;
      // A flat frame at this budget decodes to within half a 10-bit code. Three quarters of one
      // is tight enough to catch a P010 capture read at code * 64 / 65535 instead of code / 1023.
      const float tolerance = 0.75f / 1023.0f;

      for (bool chroma444 : {false, true}) {
        for (unsigned depth : {8u, 10u}) {
          for (bool hdr : {false, true}) {
            if (hdr && depth == 8) {
              continue;
            }
            config_t config;
            config.width = 128;
            config.height = 128;
            config.yuv444 = chroma444;
            config.hdr = hdr;
            config.matrix = matrix(depth, hdr);
            const auto &m = config.matrix;
            auto core = core_t::create(config, error);
            require(bool(core), error.c_str());
            const std::size_t chroma_dim = chroma444 ? 128 : 64;

            for (auto kind : {source_e::bgra_memory, source_e::bgra_surface, source_e::rgb10_surface, source_e::nv12_surface, source_e::p010_surface}) {
              const bool biplanar = kind == source_e::nv12_surface || kind == source_e::p010_surface;
              // A biplanar capture passes through, so it has to be in the stream's own depth.
              if ((kind == source_e::nv12_surface && depth != 8) || (kind == source_e::p010_surface && depth != 10)) {
                continue;
              }
              for (std::size_t boundary : {std::size_t(UINT32_MAX), std::size_t(1024)}) {
                for (int variant = 0; variant < 2; ++variant) {
                  const std::array<int, 3> colour = variant == 0 ? std::array<int, 3> {192, 96, 32} : std::array<int, 3> {40, 160, 220};
                  frame_t frame;
                  fill(frame, kind, 128, 128, colour);

                  std::vector<std::uint8_t> bits;
                  std::vector<packet_t> packets;
                  require(core->encode(frame.source, 65536, boundary, bits, packets, error), error.c_str());
                  require(!packets.empty(), "no packets");
                  if (boundary == UINT32_MAX) {
                    require(packets.size() == 1, "one packet expected without a boundary");
                  }
                  auto planes = decoder.decode(config, bits, packets);

                  std::array<float, 3> expected;
                  if (biplanar) {
                    // Codes pass through at the stream's normalization: code / 255, or (code * 4) / 1023.
                    for (int i = 0; i < 3; ++i) {
                      expected[i] = depth == 8 ? colour[i] / 255.0f : colour[i] * 4 / 1023.0f;
                    }
                  } else {
                    std::array<float, 3> rgb = {colour[0] / 255.0f, colour[1] / 255.0f, colour[2] / 255.0f};
                    // An 8-bit capture in an HDR stream is placed at SDR white; a 10-bit one is taken as it is.
                    if (hdr && kind != source_e::rgb10_surface) {
                      rgb = sdr_to_pq(rgb, 140.0f);
                    }
                    for (int i = 0; i < 3; ++i) {
                      expected[i] = m[i * 4] * rgb[0] + m[i * 4 + 1] * rgb[1] + m[i * 4 + 2] * rgb[2] + m[i * 4 + 3];
                    }
                  }

                  const std::string what = std::string(name(kind)) + (chroma444 ? " 4:4:4 " : " 4:2:0 ") + std::to_string(depth) + "-bit" + (hdr ? " HDR" : "");
                  expect_sample(planes[0], 128, 64, 96, expected[0], tolerance, (what + " Y").c_str());
                  expect_sample(planes[1], chroma_dim, chroma_dim / 2, chroma_dim * 3 / 4, expected[1], tolerance, (what + " Cb").c_str());
                  expect_sample(planes[2], chroma_dim, chroma_dim / 2, chroma_dim * 3 / 4, expected[2], tolerance, (what + " Cr").c_str());
                  ++cases;
                }
              }
            }
          }
        }
      }

      // A source of another shape is fitted into the picture with black bars.
      {
        config_t config;
        config.width = 128;
        config.height = 128;
        config.matrix = matrix(8, false);
        auto core = core_t::create(config, error);
        require(bool(core), error.c_str());
        frame_t frame;
        fill(frame, source_e::bgra_surface, 256, 64, {192, 96, 32});
        std::vector<std::uint8_t> bits;
        std::vector<packet_t> packets;
        require(core->encode(frame.source, 65536, UINT32_MAX, bits, packets, error), error.c_str());
        auto planes = decoder.decode(config, bits, packets);
        const auto &m = config.matrix;
        const float picture = m[0] * 192 / 255.0f + m[1] * 96 / 255.0f + m[2] * 32 / 255.0f + m[3];
        expect_sample(planes[0], 128, 64, 64, picture, tolerance, "letterbox picture");
        expect_sample(planes[0], 128, 64, 8, m[3], tolerance, "letterbox top bar");
        expect_sample(planes[0], 128, 64, 120, m[3], tolerance, "letterbox bottom bar");
        expect_sample(planes[1], 64, 32, 4, m[7], tolerance, "letterbox bar chroma");
        ++cases;
      }

      // A busy frame: the bitstream stays within its budget, splits at the packet boundary,
      // survives the host's record framing, and identical frames give identical records.
      {
        config_t config;
        config.width = 256;
        config.height = 256;
        config.yuv444 = true;
        config.matrix = matrix(8, false);
        auto core = core_t::create(config, error);
        require(bool(core), error.c_str());

        frame_t frame;
        frame.pixels.resize(256 * 256 * 4);
        std::mt19937 random {7};
        for (auto &byte : frame.pixels) {
          byte = std::uint8_t(random());
        }
        frame.source.pixels = frame.pixels.data();
        frame.source.width = frame.source.height = 256;
        frame.source.stride = 256 * 4;

        const std::size_t budget = 24000;
        std::vector<std::uint8_t> bits;
        std::vector<packet_t> packets;
        require(core->encode(frame.source, budget, 1024, bits, packets, error), error.c_str());
        require(packets.size() > 1, "a busy frame should need several packets");
        std::size_t total = 0;
        for (auto &packet : packets) {
          require(packet.offset + packet.size <= bits.size(), "packet outside the bitstream");
          total += packet.size;
        }
        require(total <= budget + 8 * packets.size(), "bitstream over budget");
        decoder.decode(config, bits, packets);

        std::vector<std::uint8_t> first_bits, second_bits;
        std::vector<packet_t> first, second;
        require(core->encode(frame.source, budget, UINT32_MAX, first_bits, first, error), error.c_str());
        require(core->encode(frame.source, budget, UINT32_MAX, second_bits, second, error), error.c_str());
        require(first.size() == 1 && second.size() == 1 && first[0].size == second[0].size, "identical frames should code to the same size");

        std::vector<std::uint8_t> framed;
        const std::span<const std::uint8_t> record_stream {first_bits.data() + first[0].offset, first[0].size};
        auto stats = pyrowave::policy::write_record_frame(record_stream, pyrowave::policy::shard_payload_bytes(1392), framed, budget);
        require(stats.has_value(), "record framing rejected the bitstream");
        require(stats->block_records > 0 && stats->critical_bytes > 0, "record framing found no records");

        // Every record starts with an 8-byte header whose second 16-bit word carries the 3-bit
        // sequence counter; everything else must match between the two encodes.
        std::size_t differing = 0;
        for (std::size_t i = 0; i < first[0].size; ++i) {
          differing += first_bits[first[0].offset + i] != second_bits[second[0].offset + i];
        }
        require(differing <= stats->block_records + 1, "identical frames gave different records");
        ++cases;
      }

      std::cout << cases << " macOS GPU encode/decode cases passed (largest sample error " << largest_error * 1023 << " 10-bit codes)\n";
      return 0;
    } catch (const std::exception &e) {
      std::cerr << "failed: " << e.what() << '\n';
      return 1;
    }
  }
}
