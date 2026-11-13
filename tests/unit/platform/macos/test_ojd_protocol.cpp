/**
 * @file tests/unit/platform/macos/test_ojd_protocol.cpp
 * @brief Tests for the OpenJoystickDriver endpoint lines behind the macOS virtual gamepad.
 */
#include "../../../tests_common.h"

#include <nlohmann/json.hpp>
#include <src/platform/macos/ojd_protocol.h>

using namespace platf::ojd;

TEST(MacosOjdSettings, ABareTokenUsesTheDefaults) {
  const auto settings = parse_settings("ojd_abc\n");
  ASSERT_TRUE(settings);
  EXPECT_EQ(settings->token, "ojd_abc");
  EXPECT_EQ(settings->token_name, "vibepollo");
  EXPECT_EQ(settings->persona, "GameControllerCompatible");
}

TEST(MacosOjdSettings, ReadsKeysCommentsAndSpacing) {
  const auto settings = parse_settings("# from ojd access grant\n\n  token = ojd_abc  \r\ntoken_name=couch\npersona = SDLCompatible\n");
  ASSERT_TRUE(settings);
  EXPECT_EQ(settings->token, "ojd_abc");
  EXPECT_EQ(settings->token_name, "couch");
  EXPECT_EQ(settings->persona, "SDLCompatible");
}

TEST(MacosOjdSettings, RefusesWhatItCannotUse) {
  EXPECT_FALSE(parse_settings(""));
  EXPECT_FALSE(parse_settings("persona = Generic\n"));
  EXPECT_FALSE(parse_settings("token = ojd_abc\npersona = DualSense\n"));
  EXPECT_FALSE(parse_settings("token = ojd_abc\nport = 1\n"));
}

TEST(MacosOjdHello, ProofIsTheHmacOfTheSocketChallenge) {
  // HMAC-SHA256, keyed with SHA-256("ojd_test-token"), of the four challenge lines for a socket;
  // computed independently with Python's hmac and hashlib.
  EXPECT_EQ(hello_proof("ojd_test-token", "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"), "464068ba6ab7e24d713b8d2ca30c1947c626d8d2aeb78bf5803a5c3e8416fcee");
}

TEST(MacosOjdHello, AsksForControlWithTheTokenName) {
  settings_t settings;
  settings.token = "ojd_test-token";
  const auto line = hello_line(settings, "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8");
  ASSERT_EQ(line.back(), '\n');
  const auto json = nlohmann::json::parse(line);
  EXPECT_EQ(json["apiVersion"], "openjoystickdriver/v1alpha2");
  EXPECT_EQ(json["kind"], "Hello");
  EXPECT_EQ(json["scopes"], nlohmann::json::array({"Control"}));
  EXPECT_EQ(json["tokenName"], "vibepollo");
  EXPECT_EQ(json["proof"], "464068ba6ab7e24d713b8d2ca30c1947c626d8d2aeb78bf5803a5c3e8416fcee");
  // The token itself never goes over the socket.
  EXPECT_EQ(line.find("ojd_test-token"), std::string::npos);
}

TEST(MacosOjdFrame, NeutralStateHasNoButtonsAndCenteredAxes) {
  const auto json = nlohmann::json::parse(frame_line({}));
  EXPECT_EQ(json["kind"], "Frame");
  EXPECT_TRUE(json["buttons"].empty());
  EXPECT_TRUE(json["dpad"].empty());
  for (const auto *axis : {"LeftStickX", "LeftStickY", "RightStickX", "RightStickY", "LeftTrigger", "RightTrigger"}) {
    EXPECT_EQ(json["axes"][axis].get<double>(), 0.0) << axis;
  }
}

TEST(MacosOjdFrame, MapsButtonsByPositionAndTheDpadSeparately) {
  pad_state_t state;
  state.buttons = button::a | button::y | button::left_button | button::home | button::dpad_up | button::dpad_right | button::right_stick;
  const auto json = nlohmann::json::parse(frame_line(state));
  EXPECT_EQ(json["buttons"], nlohmann::json::array({"South", "North", "LeftShoulder", "RightStickClick", "Guide"}));
  EXPECT_EQ(json["dpad"], nlohmann::json::array({"DpadUp", "DpadRight"}));
}

TEST(MacosOjdFrame, FlipsYAndScalesSticksAndTriggers) {
  pad_state_t state;
  state.left_x = 32767;
  state.left_y = 32767;  // Up in Moonlight, which is negative for the endpoint.
  state.right_x = -32768;
  state.right_y = -16384;
  state.left_trigger = 255;
  state.right_trigger = 51;
  const auto axes = nlohmann::json::parse(frame_line(state))["axes"];
  EXPECT_DOUBLE_EQ(axes["LeftStickX"].get<double>(), 1.0);
  EXPECT_DOUBLE_EQ(axes["LeftStickY"].get<double>(), -1.0);
  EXPECT_DOUBLE_EQ(axes["RightStickX"].get<double>(), -1.0);
  EXPECT_NEAR(axes["RightStickY"].get<double>(), 0.5, 0.001);
  EXPECT_DOUBLE_EQ(axes["LeftTrigger"].get<double>(), 1.0);
  EXPECT_DOUBLE_EQ(axes["RightTrigger"].get<double>(), 0.2);
}

TEST(MacosOjdFrame, LeavesOutButtonsTheEndpointHasNoNameFor) {
  pad_state_t state;
  state.buttons = 0x100000 | 0x010000 | button::b;  // The touchpad button and a paddle.
  EXPECT_EQ(nlohmann::json::parse(frame_line(state))["buttons"], nlohmann::json::array({"East"}));
}

TEST(MacosOjdLines, FeedRequestAndKeepAlive) {
  const auto request = nlohmann::json::parse(feed_request_line("SDLCompatible"));
  EXPECT_EQ(request["kind"], "FeedRequest");
  EXPECT_EQ(request["as"], "SDLCompatible");
  const auto keep_alive = nlohmann::json::parse(keep_alive_line());
  EXPECT_EQ(keep_alive["kind"], "KeepAlive");
  // A KeepAlive with another member is refused.
  EXPECT_EQ(keep_alive.size(), 2u);
}

TEST(MacosOjdService, ReadsTheHandshakeLines) {
  using kind_e = service_line_t::kind_e;
  const auto challenge = parse_service_line(R"({"apiVersion":"openjoystickdriver/v1alpha2","kind":"Challenge","nonce":"abc"})");
  ASSERT_TRUE(challenge);
  EXPECT_EQ(challenge->kind, kind_e::challenge);
  EXPECT_EQ(challenge->nonce, "abc");
  EXPECT_EQ(parse_service_line(R"({"apiVersion":"openjoystickdriver/v1alpha2","kind":"Welcome","version":"0.6.0","scopes":["Control"]})")->kind, kind_e::welcome);
  EXPECT_EQ(parse_service_line(R"({"apiVersion":"openjoystickdriver/v1alpha2","kind":"FeedSession","as":"Generic"})")->kind, kind_e::feed_session);
}

TEST(MacosOjdService, ReadsAFailure) {
  const auto status = parse_service_line(R"({"apiVersion":"openjoystickdriver/v1alpha2","kind":"Status","status":"Failure","code":"E1002","message":"Not granted."})");
  ASSERT_TRUE(status);
  EXPECT_EQ(status->kind, service_line_t::kind_e::status);
  EXPECT_EQ(status->code, "E1002");
  EXPECT_EQ(status->message, "Not granted.");
}

TEST(MacosOjdService, ReadsRumbleAndItsStop) {
  const auto rumble = parse_service_line(R"({"apiVersion":"openjoystickdriver/v1alpha2","kind":"RumbleCommand","type":"SetRumble","intensities":{"lowFrequency":65535,"highFrequency":1000,"leftTrigger":0,"rightTrigger":7,"leftHaptic":0,"rightHaptic":0},"durationMilliseconds":200})");
  ASSERT_TRUE(rumble);
  EXPECT_EQ(rumble->kind, service_line_t::kind_e::rumble);
  EXPECT_EQ(rumble->low_frequency, 65535);
  EXPECT_EQ(rumble->high_frequency, 1000);
  EXPECT_EQ(rumble->right_trigger, 7);
  EXPECT_EQ(rumble->duration_ms, 200);

  const auto stop = parse_service_line(R"({"apiVersion":"openjoystickdriver/v1alpha2","kind":"RumbleCommand","type":"StopRumble"})");
  ASSERT_TRUE(stop);
  EXPECT_EQ(stop->kind, service_line_t::kind_e::rumble);
  EXPECT_EQ(stop->low_frequency, 0);
  EXPECT_EQ(stop->high_frequency, 0);
  EXPECT_EQ(stop->duration_ms, 0);
}

TEST(MacosOjdService, IgnoresWhatIsNotALine) {
  EXPECT_FALSE(parse_service_line("not json"));
  EXPECT_FALSE(parse_service_line("[1,2]"));
  EXPECT_FALSE(parse_service_line(R"({"type":"ADDED","object":{}})"));
  EXPECT_EQ(parse_service_line(R"({"apiVersion":"openjoystickdriver/v1alpha2","kind":"Drained"})")->kind, service_line_t::kind_e::other);
}
