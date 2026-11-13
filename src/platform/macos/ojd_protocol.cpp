/**
 * @file src/platform/macos/ojd_protocol.cpp
 * @brief Lines of the OpenJoystickDriver SDK endpoint.
 */
// standard includes
#include <algorithm>
#include <array>
#include <cstdio>

// platform includes
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonHMAC.h>

// lib includes
#include <nlohmann/json.hpp>

// local includes
#include "ojd_protocol.h"

namespace platf::ojd {
  namespace {
    std::string_view trim(std::string_view text) {
      const auto first = text.find_first_not_of(" \t\r");
      if (first == std::string_view::npos) {
        return {};
      }
      return text.substr(first, text.find_last_not_of(" \t\r") - first + 1);
    }

    bool known_persona(const std::string_view persona) {
      return persona == "GameControllerCompatible" || persona == "SDLCompatible" || persona == "Generic";
    }

    nlohmann::json header(const char *kind) {
      return {{"apiVersion", api_version}, {"kind", kind}};
    }

    std::uint16_t intensity(const nlohmann::json &intensities, const char *name) {
      const auto it = intensities.find(name);
      if (it == intensities.end() || !it->is_number()) {
        return 0;
      }
      return static_cast<std::uint16_t>(std::clamp(it->get<double>(), 0.0, 65535.0));
    }

    /// A stick axis from -1 to 1, rounded so equal states give equal lines.
    double axis(const std::int16_t value) {
      return std::max(-1.0, value / 32767.0);
    }
  }  // namespace

  std::optional<settings_t> parse_settings(const std::string_view text) {
    settings_t settings;
    std::size_t start = 0;
    while (start <= text.size()) {
      const auto end = std::min(text.find('\n', start), text.size());
      const auto line = trim(text.substr(start, end - start));
      start = end + 1;
      if (line.empty() || line.front() == '#') {
        continue;
      }
      const auto equals = line.find('=');
      if (equals == std::string_view::npos) {
        settings.token = line;
        continue;
      }
      const auto key = trim(line.substr(0, equals));
      const auto value = std::string {trim(line.substr(equals + 1))};
      if (key == "token") {
        settings.token = value;
      } else if (key == "token_name") {
        settings.token_name = value;
      } else if (key == "persona") {
        settings.persona = value;
      } else {
        return std::nullopt;
      }
    }
    if (settings.token.empty() || settings.token_name.empty() || !known_persona(settings.persona)) {
      return std::nullopt;
    }
    return settings;
  }

  std::string hello_proof(const std::string_view token, const std::string_view nonce) {
    std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> key {};
    CC_SHA256(token.data(), static_cast<CC_LONG>(token.size()), key.data());

    // Four lines: the purpose, the nonce, then the page's origin and the WebSocket's port, which
    // are both empty on the socket.
    std::string message = "OpenJoystickDriver endpoint hello 1\n";
    message.append(nonce).append("\n\n\n");

    std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> mac {};
    CCHmac(kCCHmacAlgSHA256, key.data(), key.size(), message.data(), message.size(), mac.data());

    std::string hex(mac.size() * 2, '0');
    for (std::size_t i = 0; i < mac.size(); ++i) {
      std::snprintf(hex.data() + i * 2, 3, "%02x", mac[i]);
    }
    return hex;
  }

  std::string hello_line(const settings_t &settings, const std::string_view nonce) {
    auto line = header("Hello");
    line["scopes"] = {"Control"};
    line["tokenName"] = settings.token_name;
    line["proof"] = hello_proof(settings.token, nonce);
    return line.dump() + '\n';
  }

  std::string feed_request_line(const std::string_view persona) {
    auto line = header("FeedRequest");
    line["as"] = persona;
    return line.dump() + '\n';
  }

  std::string keep_alive_line() {
    return header("KeepAlive").dump() + '\n';
  }

  std::string frame_line(const pad_state_t &state) {
    struct name_t {
      std::uint32_t flag;
      const char *name;
    };

    static constexpr name_t buttons[] = {
      {button::a, "South"},
      {button::b, "East"},
      {button::x, "West"},
      {button::y, "North"},
      {button::left_button, "LeftShoulder"},
      {button::right_button, "RightShoulder"},
      {button::back, "Back"},
      {button::start, "Start"},
      {button::left_stick, "LeftStickClick"},
      {button::right_stick, "RightStickClick"},
      {button::home, "Guide"},
    };
    static constexpr name_t dpad[] = {
      {button::dpad_up, "DpadUp"},
      {button::dpad_down, "DpadDown"},
      {button::dpad_left, "DpadLeft"},
      {button::dpad_right, "DpadRight"},
    };

    auto line = header("Frame");
    auto pressed = nlohmann::json::array();
    for (const auto &[flag, name] : buttons) {
      if (state.buttons & flag) {
        pressed.push_back(name);
      }
    }
    auto directions = nlohmann::json::array();
    for (const auto &[flag, name] : dpad) {
      if (state.buttons & flag) {
        directions.push_back(name);
      }
    }
    line["buttons"] = std::move(pressed);
    line["dpad"] = std::move(directions);
    // Moonlight's Y axes point up; the endpoint's point down.
    line["axes"] = {
      {"LeftStickX", axis(state.left_x)},
      {"LeftStickY", -axis(state.left_y)},
      {"RightStickX", axis(state.right_x)},
      {"RightStickY", -axis(state.right_y)},
      {"LeftTrigger", state.left_trigger / 255.0},
      {"RightTrigger", state.right_trigger / 255.0},
    };
    return line.dump() + '\n';
  }

  std::optional<service_line_t> parse_service_line(const std::string_view line) {
    const auto json = nlohmann::json::parse(line, nullptr, false);
    if (!json.is_object() || !json.contains("kind") || !json["kind"].is_string()) {
      return std::nullopt;
    }
    const auto kind = json["kind"].get<std::string>();

    service_line_t result;
    if (kind == "Challenge") {
      result.kind = service_line_t::kind_e::challenge;
      result.nonce = json.value("nonce", "");
    } else if (kind == "Welcome") {
      result.kind = service_line_t::kind_e::welcome;
    } else if (kind == "FeedSession") {
      result.kind = service_line_t::kind_e::feed_session;
    } else if (kind == "Status") {
      result.kind = service_line_t::kind_e::status;
      result.code = json.value("code", "");
      result.message = json.value("message", "");
    } else if (kind == "RumbleCommand") {
      result.kind = service_line_t::kind_e::rumble;
      const auto intensities = json.find("intensities");
      if (json.value("type", "") == "SetRumble" && intensities != json.end() && intensities->is_object()) {
        result.low_frequency = intensity(*intensities, "lowFrequency");
        result.high_frequency = intensity(*intensities, "highFrequency");
        result.left_trigger = intensity(*intensities, "leftTrigger");
        result.right_trigger = intensity(*intensities, "rightTrigger");
        if (const auto duration = json.find("durationMilliseconds"); duration != json.end() && duration->is_number()) {
          result.duration_ms = std::max(0, duration->get<int>());
        }
      }
    }
    return result;
  }
}  // namespace platf::ojd
