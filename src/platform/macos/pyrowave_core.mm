/**
 * @file src/platform/macos/pyrowave_core.mm
 * @brief Metal PyroWave encoder: colour conversion and the vendored Metal port of the codec.
 * @details Built with ARC. As on Linux, the codec never sees the capture's own Y'CbCr: every
 *          frame goes through one conversion pass that writes the stream's planes as 16-bit
 *          normalized samples (code / (2^depth - 1)), which is what clients decode against.
 */
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

// standard includes
#include <algorithm>
#include <cmath>
#include <cstring>

// local includes
#include "pyrowave_core.h"

// lib includes
#include <pyrowave_metal.h>

namespace pyrowave::macos_gpu {
  namespace {
    // SDR white of an SDR capture placed into an HDR stream, matching what ScreenCaptureKit's HDR
    // frames use for SDR content (see sdr_white_nits in display.mm).
    constexpr float sdr_white_nits = 140.0f;

    // A P010 sample is a 10-bit code in the high bits: code * 64 / 65535 as UNORM16. The stream's
    // convention is code / 1023.
    constexpr float p010_to_unorm10 = 65535.0f / (1023.0f * 64.0f);

    enum source_kind_e : std::int32_t {
      source_rgb = 0,
      source_biplanar = 1,
    };

    enum transfer_e : std::int32_t {
      transfer_native = 0,
      transfer_sdr_to_pq = 3,  // The same number as the Linux conversion shader.
    };

    // Matches Params in the shader below.
    struct params_t {
      float y[4];
      float u[4];
      float v[4];
      float fit[2];
      float output_size[2];
      float ycbcr_scale;
      float white_nits;
      std::int32_t source_kind;
      std::int32_t subsampled;
      std::int32_t transfer;
      std::int32_t padding[3];
    };
    static_assert(sizeof(params_t) == 96, "params_t must match the shader's Params");

    // Compiled at runtime, like the codec's own shaders, so the build needs no Metal toolchain.
    const char *const conversion_shader = R"MSL(
#include <metal_stdlib>
using namespace metal;

struct Params {
  float4 y;
  float4 u;
  float4 v;
  float2 fit;
  float2 output_size;
  float ycbcr_scale;
  float white_nits;
  int source_kind;
  int subsampled;
  int transfer;
};

constexpr sampler linear_clamp(coord::normalized, address::clamp_to_edge, filter::linear);

static float3 srgb_to_linear(float3 c) {
  return select(pow(max((c + 0.055) / 1.055, 0.0), float3(2.4)), c / 12.92, c <= float3(0.04045));
}

static float3 pq(float3 nits) {
  float3 x = pow(max(nits / 10000.0, 0.0), float3(2610.0 / 16384.0));
  return pow((3424.0 / 4096.0 + 2413.0 / 128.0 * x) / (1.0 + 2392.0 / 128.0 * x), float3(2523.0 / 32.0));
}

static float3 to_2020(float3 c) {
  return float3(dot(c, float3(0.627404, 0.329283, 0.043313)),
                dot(c, float3(0.069097, 0.919540, 0.011362)),
                dot(c, float3(0.016391, 0.088013, 0.895595)));
}

// Fits the source into the output, centred, keeping its aspect ratio.
static bool map_uv(float2 pos, constant Params &p, thread float2 &uv) {
  uv = (pos / p.output_size - 0.5) * p.fit + 0.5;
  return all(uv >= float2(0.0)) && all(uv <= float2(1.0));
}

static float3 sample_rgb(float2 pos, texture2d<float, access::sample> source, constant Params &p) {
  float2 uv;
  if (!map_uv(pos, p, uv)) {
    return float3(0.0);
  }
  float3 rgb = source.sample(linear_clamp, uv).rgb;
  if (p.transfer == 3) {
    rgb = pq(to_2020(srgb_to_linear(rgb)) * p.white_nits);
  }
  return rgb;
}

kernel void pyrowave_convert(texture2d<float, access::sample> source [[texture(0)]],
                             texture2d<float, access::sample> source_chroma [[texture(1)]],
                             texture2d<float, access::write> y_plane [[texture(2)]],
                             texture2d<float, access::write> u_plane [[texture(3)]],
                             texture2d<float, access::write> v_plane [[texture(4)]],
                             constant Params &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= uint(p.output_size.x) || gid.y >= uint(p.output_size.y)) {
    return;
  }

  const float2 pos = float2(gid) + 0.5;
  const bool chroma_site = p.subsampled == 0 || ((gid.x & 1u) == 0u && (gid.y & 1u) == 0u);
  const uint2 chroma_pos = p.subsampled != 0 ? gid >> 1 : gid;

  if (p.source_kind == 1) {
    // The capture is already video range Y'CbCr: rescale and resample it. Outside the picture,
    // the matrix offsets are black.
    float2 uv;
    const bool inside = map_uv(pos, p, uv);
    y_plane.write(float4(inside ? source.sample(linear_clamp, uv).r * p.ycbcr_scale : p.y.w), gid);
    if (chroma_site) {
      // A subsampled chroma sample sits in the middle of its 2x2 luma block.
      float2 chroma_uv;
      const bool chroma_inside = map_uv(p.subsampled != 0 ? pos + 0.5 : pos, p, chroma_uv);
      const float2 chroma = chroma_inside ? source_chroma.sample(linear_clamp, chroma_uv).rg * p.ycbcr_scale : float2(p.u.w, p.v.w);
      u_plane.write(float4(chroma.x), chroma_pos);
      v_plane.write(float4(chroma.y), chroma_pos);
    }
    return;
  }

  float3 rgb = sample_rgb(pos, source, p);
  y_plane.write(float4(dot(p.y, float4(rgb, 1.0))), gid);
  if (!chroma_site) {
    return;
  }
  if (p.subsampled != 0) {
    rgb = (rgb + sample_rgb(pos + float2(1.0, 0.0), source, p) + sample_rgb(pos + float2(0.0, 1.0), source, p) +
           sample_rgb(pos + float2(1.0, 1.0), source, p)) * 0.25;
  }
  u_plane.write(float4(dot(p.u, float4(rgb, 1.0))), chroma_pos);
  v_plane.write(float4(dot(p.v, float4(rgb, 1.0))), chroma_pos);
}
)MSL";

    std::string describe(NSError *error) {
      return error && error.localizedDescription ? error.localizedDescription.UTF8String : "unknown error";
    }

    id<MTLTexture> wrap_surface(id<MTLDevice> device, IOSurfaceRef surface, NSUInteger plane, MTLPixelFormat format, MTLTextureUsage usage) {
      auto *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                           width:IOSurfaceGetWidthOfPlane(surface, plane)
                                                                          height:IOSurfaceGetHeightOfPlane(surface, plane)
                                                                       mipmapped:NO];
      descriptor.usage = usage;
      descriptor.storageMode = MTLStorageModeShared;
      return [device newTextureWithDescriptor:descriptor iosurface:surface plane:plane];
    }
  }  // namespace

  bool capture_format_supported(const OSType pixel_format) {
    switch (pixel_format) {
      case kCVPixelFormatType_32BGRA:
      case kCVPixelFormatType_ARGB2101010LEPacked:
      case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
      case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        return true;
      default:
        return false;
    }
  }

  bool device_supported(std::string &error) {
    @autoreleasepool {
      id<MTLDevice> device = MTLCreateSystemDefaultDevice();
      if (!device) {
        error = "no Metal device";
        return false;
      }
      if (!pyrowave_device_is_supported((__bridge void *) device)) {
        error = "the GPU is not Apple silicon, which the Metal PyroWave port requires";
        return false;
      }
      return true;
    }
  }

  struct core_t::impl_t {
    config_t config;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> conversion;
    id<MTLTexture> upload;  // For frames that arrive as pixels in memory.
    id<MTLTexture> plane_textures[3];
    IOSurfaceRef planes[3] {};
    pyrowave_device codec_device = nullptr;
    pyrowave_encoder encoder = nullptr;
    std::string codec_messages;

    ~impl_t() {
      if (encoder) {
        pyrowave_encoder_destroy(encoder);
      }
      if (codec_device) {
        pyrowave_device_destroy(codec_device);
      }
      for (auto *plane : planes) {
        if (plane) {
          CFRelease(plane);
        }
      }
    }

    static void on_codec_message(void *userdata, const char *message) {
      auto &messages = static_cast<impl_t *>(userdata)->codec_messages;
      if (!messages.empty()) {
        messages += "; ";
      }
      messages += message;
    }

    /// `what`, with whatever the codec logged since the last call.
    std::string codec_error(const char *what, const pyrowave_result result) {
      std::string error = std::string(what) + ": " + pyrowave_result_to_string(result);
      if (!codec_messages.empty()) {
        error += " (" + codec_messages + ")";
        codec_messages.clear();
      }
      return error;
    }

    bool init(std::string &error) {
      device = MTLCreateSystemDefaultDevice();
      if (!device) {
        error = "no Metal device";
        return false;
      }
      queue = [device newCommandQueue];

      NSError *ns_error = nil;
      id<MTLLibrary> library = [device newLibraryWithSource:@(conversion_shader) options:nil error:&ns_error];
      if (!library) {
        error = "conversion shader: " + describe(ns_error);
        return false;
      }
      conversion = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"pyrowave_convert"] error:&ns_error];
      if (!conversion) {
        error = "conversion pipeline: " + describe(ns_error);
        return false;
      }

      // The planes are IOSurfaces because that is the codec's GPU input. 16 bits a sample holds
      // 8-bit and 10-bit streams alike.
      for (int i = 0; i < 3; ++i) {
        const bool half = i != 0 && !config.yuv444;
        NSDictionary *properties = @{
          (__bridge NSString *) kIOSurfaceWidth: @(half ? config.width / 2 : config.width),
          (__bridge NSString *) kIOSurfaceHeight: @(half ? config.height / 2 : config.height),
          (__bridge NSString *) kIOSurfaceBytesPerElement: @2,
          (__bridge NSString *) kIOSurfacePixelFormat: @(kCVPixelFormatType_OneComponent16),
        };
        planes[i] = IOSurfaceCreate((__bridge CFDictionaryRef) properties);
        if (planes[i]) {
          plane_textures[i] = wrap_surface(device, planes[i], 0, MTLPixelFormatR16Unorm, MTLTextureUsageShaderWrite);
        }
        if (!plane_textures[i]) {
          error = "could not allocate the Y'CbCr planes";
          return false;
        }
      }

      pyrowave_device_create_info device_info {};
      device_info.mtl_device = (__bridge void *) device;
      device_info.message_callback = on_codec_message;
      device_info.message_userdata = this;
      if (const auto result = pyrowave_device_create(&device_info, &codec_device); result != PYROWAVE_SUCCESS) {
        error = codec_error("codec device", result);
        return false;
      }

      pyrowave_encoder_create_info encoder_info {};
      encoder_info.device = codec_device;
      encoder_info.width = config.width;
      encoder_info.height = config.height;
      encoder_info.chroma = config.yuv444 ? PYROWAVE_CHROMA_SUBSAMPLING_444 : PYROWAVE_CHROMA_SUBSAMPLING_420;
      if (const auto result = pyrowave_encoder_create(&encoder_info, &encoder); result != PYROWAVE_SUCCESS) {
        error = codec_error("encoder", result);
        return false;
      }
      return true;
    }

    /// The frame as textures: RGB in `source`, or luma in `source` and CbCr in `chroma`.
    bool source_textures(const source_t &frame, id<MTLTexture> __strong &source, id<MTLTexture> __strong &chroma, params_t &params, std::string &error) {
      params.source_kind = source_rgb;
      params.ycbcr_scale = 1.0f;
      params.transfer = transfer_native;

      IOSurfaceRef surface = frame.pixel_buffer ? CVPixelBufferGetIOSurface(frame.pixel_buffer) : nullptr;
      const OSType format = frame.pixel_buffer ? CVPixelBufferGetPixelFormatType(frame.pixel_buffer) : kCVPixelFormatType_32BGRA;

      if (surface) {
        switch (format) {
          case kCVPixelFormatType_32BGRA:
            source = wrap_surface(device, surface, 0, MTLPixelFormatBGRA8Unorm, MTLTextureUsageShaderRead);
            // An SDR capture in an HDR stream: place it at SDR white.
            params.transfer = config.hdr ? transfer_sdr_to_pq : transfer_native;
            break;
          case kCVPixelFormatType_ARGB2101010LEPacked:
            source = wrap_surface(device, surface, 0, MTLPixelFormatBGR10A2Unorm, MTLTextureUsageShaderRead);
            break;
          case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            source = wrap_surface(device, surface, 0, MTLPixelFormatR8Unorm, MTLTextureUsageShaderRead);
            chroma = wrap_surface(device, surface, 1, MTLPixelFormatRG8Unorm, MTLTextureUsageShaderRead);
            params.source_kind = source_biplanar;
            break;
          case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            source = wrap_surface(device, surface, 0, MTLPixelFormatR16Unorm, MTLTextureUsageShaderRead);
            chroma = wrap_surface(device, surface, 1, MTLPixelFormatRG16Unorm, MTLTextureUsageShaderRead);
            params.source_kind = source_biplanar;
            params.ycbcr_scale = p010_to_unorm10;
            break;
          default:
            error = "unsupported capture pixel format";
            return false;
        }
        if (!source || (params.source_kind == source_biplanar && !chroma)) {
          error = "could not wrap the captured surface";
          return false;
        }
        return true;
      }

      if (!frame.pixels || format != kCVPixelFormatType_32BGRA || frame.width <= 0 || frame.height <= 0 || frame.stride < frame.width * 4) {
        error = "the captured frame is neither an IOSurface nor BGRA pixels";
        return false;
      }
      if (!upload || upload.width != NSUInteger(frame.width) || upload.height != NSUInteger(frame.height)) {
        auto *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                             width:NSUInteger(frame.width)
                                                                            height:NSUInteger(frame.height)
                                                                         mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;
        upload = [device newTextureWithDescriptor:descriptor];
        if (!upload) {
          error = "could not allocate the upload texture";
          return false;
        }
      }
      [upload replaceRegion:MTLRegionMake2D(0, 0, NSUInteger(frame.width), NSUInteger(frame.height))
                mipmapLevel:0
                  withBytes:frame.pixels
                bytesPerRow:NSUInteger(frame.stride)];
      source = upload;
      params.transfer = config.hdr ? transfer_sdr_to_pq : transfer_native;
      return true;
    }

    bool convert(const source_t &frame, std::string &error) {
      params_t params {};
      id<MTLTexture> source;
      id<MTLTexture> chroma;
      if (!source_textures(frame, source, chroma, params, error)) {
        return false;
      }

      std::memcpy(params.y, config.matrix.data(), sizeof(float) * 12);
      params.output_size[0] = float(config.width);
      params.output_size[1] = float(config.height);
      params.white_nits = sdr_white_nits;
      params.subsampled = config.yuv444 ? 0 : 1;

      // Letterbox or pillarbox a source of another shape. Shapes within 1% count as equal, so
      // rounding in a scaled mode doesn't add a one pixel bar.
      const double source_aspect = double(source.width) / double(source.height);
      const double output_aspect = double(config.width) / double(config.height);
      params.fit[0] = params.fit[1] = 1.0f;
      if (std::abs(output_aspect / source_aspect - 1.0) > 0.01) {
        if (output_aspect > source_aspect) {
          params.fit[0] = float(output_aspect / source_aspect);
        } else {
          params.fit[1] = float(source_aspect / output_aspect);
        }
      }

      id<MTLCommandBuffer> commands = [queue commandBuffer];
      id<MTLComputeCommandEncoder> pass = [commands computeCommandEncoder];
      [pass setComputePipelineState:conversion];
      [pass setTexture:source atIndex:0];
      [pass setTexture:chroma ?: source atIndex:1];
      for (NSUInteger i = 0; i < 3; ++i) {
        [pass setTexture:plane_textures[i] atIndex:2 + i];
      }
      [pass setBytes:&params length:sizeof(params) atIndex:0];
      [pass dispatchThreadgroups:MTLSizeMake((NSUInteger(config.width) + 15) / 16, (NSUInteger(config.height) + 15) / 16, 1)
           threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
      [pass endEncoding];
      [commands commit];
      // The codec reads the planes on its own queue, so they have to be complete first.
      [commands waitUntilCompleted];
      if (commands.status != MTLCommandBufferStatusCompleted) {
        error = "colour conversion failed: " + describe(commands.error);
        return false;
      }
      return true;
    }
  };

  core_t::core_t():
      impl(std::make_unique<impl_t>()) {}

  core_t::~core_t() = default;

  std::unique_ptr<core_t> core_t::create(const config_t &config, std::string &error) {
    if (config.width <= 0 || config.height <= 0 || (!config.yuv444 && ((config.width | config.height) & 1))) {
      error = "invalid frame dimensions";
      return nullptr;
    }
    @autoreleasepool {
      std::unique_ptr<core_t> core {new core_t()};
      core->impl->config = config;
      if (!core->impl->init(error)) {
        return nullptr;
      }
      return core;
    }
  }

  bool core_t::encode(const source_t &source, std::size_t budget, const std::size_t boundary, std::vector<std::uint8_t> &bitstream, std::vector<packet_t> &packets, std::string &error) {
    packets.clear();
    budget = std::min<std::size_t>(budget, UINT32_MAX) & ~std::size_t(3);
    if (!budget || !boundary) {
      error = "invalid budget";
      return false;
    }

    @autoreleasepool {
      auto &d = *impl;
      if (!d.convert(source, error)) {
        return false;
      }

      pyrowave_gpu_input input {};
      for (int i = 0; i < 3; ++i) {
        input.planes[i] = d.planes[i];
      }
      const pyrowave_rate_control rate_control {budget};
      if (const auto result = pyrowave_encoder_encode_gpu_synchronous(d.encoder, &input, &rate_control); result != PYROWAVE_SUCCESS) {
        error = d.codec_error("encode", result);
        return false;
      }

      std::size_t packet_count = 0;
      if (const auto result = pyrowave_encoder_compute_num_packets(d.encoder, boundary, &packet_count); result != PYROWAVE_SUCCESS) {
        error = d.codec_error("packet count", result);
        return false;
      }

      // Each packet starts with its own 8-byte header on top of the coded records.
      std::vector<pyrowave_packet> native(packet_count);
      bitstream.resize(budget + 8 * (packet_count + 1) + 4096);
      std::size_t written = 0;
      const auto result = pyrowave_encoder_packetize(d.encoder, native.data(), boundary, &written, bitstream.data(), bitstream.size());
      if (result != PYROWAVE_SUCCESS || written == 0 || written > packet_count) {
        error = d.codec_error("packetization", result);
        return false;
      }

      packets.reserve(written);
      for (std::size_t i = 0; i < written; ++i) {
        packets.push_back({native[i].offset, native[i].size});
      }
      return true;
    }
  }
}  // namespace pyrowave::macos_gpu
