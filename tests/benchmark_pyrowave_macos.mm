/** Manual macOS benchmark: conversion plus encode time per frame. Not part of CTest. */
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include "src/platform/macos/pyrowave_core.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <random>
#include <vector>

using namespace pyrowave::macos_gpu;

int main() {
  @autoreleasepool {
    std::string error;
    if (!device_supported(error)) {
      std::fprintf(stderr, "skipped: %s\n", error.c_str());
      return 77;
    }

    struct mode_t {
      int width, height, fps, mbps;
    };

    for (const mode_t mode : {mode_t {1920, 1080, 120, 300}, mode_t {2560, 1440, 120, 500}, mode_t {3840, 2160, 60, 600}, mode_t {3840, 2160, 120, 1000}}) {
      // A BGRA surface as the capture delivers it: half noise, half flat, so the rate
      // control has both busy and idle blocks.
      NSDictionary *attributes = @{(__bridge NSString *) kCVPixelBufferIOSurfacePropertiesKey: @{}};
      CVPixelBufferRef buffer = nullptr;
      CVPixelBufferCreate(kCFAllocatorDefault, mode.width, mode.height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef) attributes, &buffer);
      CVPixelBufferLockBaseAddress(buffer, 0);
      auto *base = static_cast<std::uint8_t *>(CVPixelBufferGetBaseAddress(buffer));
      const auto stride = CVPixelBufferGetBytesPerRow(buffer);
      std::mt19937 random {7};
      for (int y = 0; y < mode.height; ++y) {
        for (int x = 0; x < mode.width * 4; ++x) {
          base[y * stride + x] = y < mode.height / 2 ? std::uint8_t(random()) : std::uint8_t(96);
        }
      }
      CVPixelBufferUnlockBaseAddress(buffer, 0);

      for (bool yuv444 : {false, true}) {
        config_t config;
        config.width = mode.width;
        config.height = mode.height;
        config.yuv444 = yuv444;
        // Limited range BT.709, 8-bit.
        config.matrix = {0.1826f, 0.6142f, 0.0620f, 0.0627f, -0.1006f, -0.3386f, 0.4392f, 0.5020f, 0.4392f, -0.3989f, -0.0403f, 0.5020f};
        auto core = core_t::create(config, error);
        if (!core) {
          std::fprintf(stderr, "failed: %s\n", error.c_str());
          return 1;
        }

        source_t source;
        source.pixel_buffer = buffer;
        const std::size_t budget = std::size_t(mode.mbps) * 1000 * 1000 / 8 / mode.fps;
        std::vector<std::uint8_t> bits;
        std::vector<packet_t> packets;
        std::vector<double> times;
        for (int i = 0; i < 70; ++i) {
          const auto started = std::chrono::steady_clock::now();
          if (!core->encode(source, budget, UINT32_MAX, bits, packets, error)) {
            std::fprintf(stderr, "failed: %s\n", error.c_str());
            return 1;
          }
          if (i >= 10) {  // Skip warm-up.
            times.push_back(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count());
          }
        }
        std::sort(times.begin(), times.end());
        std::printf("%dx%d %s, %d Mbit/s at %d fps (%zu kB a frame): median %.2f ms, p95 %.2f ms, frame budget %.2f ms\n",
                    mode.width, mode.height, yuv444 ? "4:4:4" : "4:2:0", mode.mbps, mode.fps, packets.front().size / 1000,
                    times[times.size() / 2], times[times.size() * 95 / 100], 1000.0 / mode.fps);
      }
      CVPixelBufferRelease(buffer);
    }
    return 0;
  }
}
