/**
 * @file src/platform/macos/ojd_gamepad.h
 * @brief A virtual gamepad on macOS, published through OpenJoystickDriver's SDK endpoint.
 */
#pragma once

// standard includes
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>

// local includes
#include "ojd_protocol.h"

namespace platf::ojd {
  /// The settings in `<config directory>/ojd_token`, if the file is there and valid.
  std::optional<settings_t> load_settings();

  /**
   * @brief One virtual gamepad, for as long as the object lives.
   * @details A worker thread keeps a connection to the endpoint: it connects again after an
   *          error, sends the newest state no more often than the endpoint plays frames, and keeps
   *          the feed open while nothing changes.
   */
  class feed_t {
  public:
    /// Rumble a game asked for; all zero stops it. Called on the worker thread.
    using rumble_fn = std::function<void(std::uint16_t low_frequency, std::uint16_t high_frequency, std::uint16_t left_trigger, std::uint16_t right_trigger)>;

    feed_t(settings_t settings, rumble_fn on_rumble);
    ~feed_t();

    feed_t(const feed_t &) = delete;
    feed_t &operator=(const feed_t &) = delete;

    void update(const pad_state_t &state);

  private:
    struct impl_t;
    std::unique_ptr<impl_t> impl;
  };
}  // namespace platf::ojd
