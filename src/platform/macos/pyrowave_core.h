/**
 * @file src/platform/macos/pyrowave_core.h
 * @brief Metal PyroWave encoder, independent of capture and network lifetimes.
 */
#pragma once

// standard includes
#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

// platform includes
#include <CoreVideo/CoreVideo.h>

namespace pyrowave::macos_gpu {
  struct config_t {
    int width = 0;
    int height = 0;
    bool yuv444 = false;
    bool hdr = false;  ///< The stream is BT.2020 PQ.
    /// RGB to normalized Y'CbCr rows (y, u, v), each with its offset last:
    /// video::color_vectors_from_colorspace(colorspace, true).
    std::array<float, 12> matrix {};
  };

  /**
   * @brief One captured frame.
   * @details Either an IOSurface-backed pixel buffer in a format capture_format_supported() accepts,
   *          or packed BGRA pixels in memory.
   */
  struct source_t {
    CVPixelBufferRef pixel_buffer = nullptr;
    const std::uint8_t *pixels = nullptr;
    int width = 0;
    int height = 0;
    int stride = 0;
  };

  struct packet_t {
    std::size_t offset;
    std::size_t size;
  };

  /// Whether encode() can read pixel buffers of this CoreVideo format.
  bool capture_format_supported(OSType pixel_format);

  /// Whether this Mac's default GPU can run the encoder (Apple silicon only).
  bool device_supported(std::string &error);

  class core_t {
  public:
    static std::unique_ptr<core_t> create(const config_t &config, std::string &error);
    ~core_t();

    /**
     * @brief Convert the frame to the stream's Y'CbCr planes and encode it.
     * @param budget Largest bitstream size in bytes.
     * @param boundary Packet size the packetizer aims for; UINT32_MAX gives one packet.
     * @param bitstream Receives the packetized bitstream.
     * @param packets Receives the packets' positions in `bitstream`.
     */
    bool encode(const source_t &source, std::size_t budget, std::size_t boundary, std::vector<std::uint8_t> &bitstream, std::vector<packet_t> &packets, std::string &error);

  private:
    struct impl_t;
    core_t();
    std::unique_ptr<impl_t> impl;
  };
}  // namespace pyrowave::macos_gpu
