/**
 * @file src/platform/macos/ojd_protocol.h
 * @brief Lines of the OpenJoystickDriver SDK endpoint, which publishes a virtual gamepad on macOS.
 * @details OpenJoystickDriver is a separately installed app that holds Apple's virtual HID
 *          entitlement. A program it grants connects to a local socket and exchanges JSON objects,
 *          one per line: a Challenge, a Hello with a proof of its token, a Welcome, a FeedRequest,
 *          a FeedSession, then Frame lines one way and RumbleCommand lines the other. This file
 *          only builds and reads those lines; ojd_gamepad.cpp owns the socket.
 */
#pragma once

// standard includes
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace platf::ojd {
  constexpr std::string_view api_version = "openjoystickdriver/v1alpha2";

  /// What the user sets up once: the token from `ojd access grant --token NAME --scope control`.
  struct settings_t {
    std::string token;
    std::string token_name = "vibepollo";
    /// How games see the gamepad: GameControllerCompatible (an Xbox Wireless Controller, which
    /// Apple's Game Controller framework lists), SDLCompatible, or Generic.
    std::string persona = "GameControllerCompatible";
  };

  /**
   * @brief Read the settings file.
   * @details Either the token alone on a line, or `key = value` lines with the keys `token`,
   *          `token_name` and `persona`. Blank lines and lines starting with `#` are skipped.
   * @return The settings, or nothing without a token or with an unknown key or persona.
   */
  std::optional<settings_t> parse_settings(std::string_view text);

  /// A controller's state as Moonlight sends it; the fields of platf::gamepad_state_t.
  struct pad_state_t {
    std::uint32_t buttons = 0;
    std::uint8_t left_trigger = 0;
    std::uint8_t right_trigger = 0;
    std::int16_t left_x = 0;
    std::int16_t left_y = 0;  ///< Positive is up.
    std::int16_t right_x = 0;
    std::int16_t right_y = 0;

    bool operator==(const pad_state_t &) const = default;
  };

  // Moonlight's button flags (platf::DPAD_UP and so on).
  namespace button {
    constexpr std::uint32_t dpad_up = 0x0001;
    constexpr std::uint32_t dpad_down = 0x0002;
    constexpr std::uint32_t dpad_left = 0x0004;
    constexpr std::uint32_t dpad_right = 0x0008;
    constexpr std::uint32_t start = 0x0010;
    constexpr std::uint32_t back = 0x0020;
    constexpr std::uint32_t left_stick = 0x0040;
    constexpr std::uint32_t right_stick = 0x0080;
    constexpr std::uint32_t left_button = 0x0100;
    constexpr std::uint32_t right_button = 0x0200;
    constexpr std::uint32_t home = 0x0400;
    constexpr std::uint32_t a = 0x1000;
    constexpr std::uint32_t b = 0x2000;
    constexpr std::uint32_t x = 0x4000;
    constexpr std::uint32_t y = 0x8000;
  }  // namespace button

  /// The Hello's `proof`: HMAC-SHA256, keyed with the SHA-256 of the token, of the challenge text
  /// for a socket connection, in lowercase hex.
  std::string hello_proof(std::string_view token, std::string_view nonce);

  std::string hello_line(const settings_t &settings, std::string_view nonce);
  std::string feed_request_line(std::string_view persona);
  std::string keep_alive_line();

  /// One Frame. Buttons the endpoint has no name for are left out.
  std::string frame_line(const pad_state_t &state);

  /// A line the endpoint sends.
  struct service_line_t {
    enum class kind_e {
      challenge,
      welcome,
      feed_session,
      rumble,
      status,  ///< A failure; the endpoint closes the connection after it.
      other,
    };

    kind_e kind = kind_e::other;
    std::string nonce;  ///< challenge
    std::string code;  ///< status, such as E1002
    std::string message;  ///< status
    // rumble: all zero for StopRumble. Intensities run from 0 to 65535.
    std::uint16_t low_frequency = 0;
    std::uint16_t high_frequency = 0;
    std::uint16_t left_trigger = 0;
    std::uint16_t right_trigger = 0;
    int duration_ms = 0;  ///< rumble: 0 when the command gives no duration.
  };

  /// @return Nothing when the line is not a JSON object with a `kind`.
  std::optional<service_line_t> parse_service_line(std::string_view line);
}  // namespace platf::ojd
