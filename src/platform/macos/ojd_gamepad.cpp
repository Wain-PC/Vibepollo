/**
 * @file src/platform/macos/ojd_gamepad.cpp
 * @brief A virtual gamepad on macOS, published through OpenJoystickDriver's SDK endpoint.
 */
// standard includes
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <fstream>
#include <mutex>
#include <sstream>
#include <thread>

// platform includes
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

// local includes
#include "ojd_gamepad.h"
#include "src/logging.h"
#include "src/platform/common.h"

using namespace std::literals;

namespace platf::ojd {
  namespace {
    using clock = std::chrono::steady_clock;

    // The endpoint plays each frame for at least 8 ms and queues what arrives sooner, so sending
    // faster only adds delay.
    constexpr auto frame_interval = 8ms;
    // The endpoint closes a feed that sends nothing for 2 seconds.
    constexpr auto keep_alive_interval = 500ms;
    constexpr auto handshake_timeout = 5s;
    constexpr auto reconnect_delay = 2s;

    /// The endpoint's socket: OpenJoystickDriver puts it in the user's temporary directory.
    std::string socket_path() {
      char directory[PATH_MAX] {};
      if (confstr(_CS_DARWIN_USER_TEMP_DIR, directory, sizeof(directory)) == 0) {
        return {};
      }
      std::string path {directory};
      if (!path.empty() && path.back() != '/') {
        path += '/';
      }
      return path + "com.openjoystickdriver.endpoint.sock";
    }

    int connect_endpoint() {
      const auto path = socket_path();
      sockaddr_un address {};
      if (path.empty() || path.size() >= sizeof(address.sun_path)) {
        return -1;
      }
      const int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
      if (fd < 0) {
        return -1;
      }
      address.sun_family = AF_UNIX;
      std::strncpy(address.sun_path, path.c_str(), sizeof(address.sun_path) - 1);
      const int set = 1;
      ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &set, sizeof(set));
      if (::connect(fd, reinterpret_cast<const sockaddr *>(&address), sizeof(address)) != 0) {
        ::close(fd);
        return -1;
      }
      return fd;
    }

    bool send_all(const int fd, const std::string &line) {
      std::size_t sent = 0;
      while (sent < line.size()) {
        const auto result = ::send(fd, line.data() + sent, line.size() - sent, 0);
        if (result < 0 && errno == EINTR) {
          continue;
        }
        if (result <= 0) {
          return false;
        }
        sent += static_cast<std::size_t>(result);
      }
      return true;
    }
  }  // namespace

  std::optional<settings_t> load_settings() {
    const auto path = platf::appdata() / "ojd_token";
    std::ifstream file {path};
    if (!file) {
      return std::nullopt;
    }
    std::stringstream text;
    text << file.rdbuf();
    auto settings = parse_settings(text.str());
    if (!settings) {
      BOOST_LOG(warning) << "Gamepad: "sv << path.string() << " has no token, or an unknown key or persona"sv;
    }
    return settings;
  }

  struct feed_t::impl_t {
    settings_t settings;
    rumble_fn on_rumble;

    std::mutex mutex;
    pad_state_t state;
    bool dirty = true;  // The first frame publishes the neutral state.

    int wake_pipe[2] {-1, -1};
    std::atomic_bool stopping {false};
    std::thread worker;

    std::string last_problem;  // So a repeating failure is logged once.
    std::string received;  // Bytes of a line that has not ended yet.
    bool rumbling = false;
    std::optional<clock::time_point> rumble_until;

    void wake() const {
      const char byte = 0;
      (void) ::write(wake_pipe[1], &byte, 1);
    }

    void report(const std::string &problem) {
      if (problem != last_problem) {
        BOOST_LOG(warning) << "Gamepad: "sv << problem;
        last_problem = problem;
      }
    }

    void stop_rumble() {
      rumble_until.reset();
      if (rumbling) {
        rumbling = false;
        on_rumble(0, 0, 0, 0);
      }
    }

    /// Wait for the socket (if there is one) or a wake-up. @return false once the feed is stopping.
    bool wait(const int fd, const clock::duration timeout, bool &readable) {
      pollfd fds[2] {{wake_pipe[0], POLLIN, 0}, {fd, POLLIN, 0}};
      const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(timeout).count();
      // Round up, so a wait that is due in under a millisecond doesn't spin.
      const int result = ::poll(fds, fd >= 0 ? 2 : 1, static_cast<int>(std::clamp<long long>(ms + 1, 1, 60'000)));
      if (result > 0 && (fds[0].revents & POLLIN)) {
        char drained[64];
        (void) ::read(wake_pipe[0], drained, sizeof(drained));
      }
      readable = fd >= 0 && result > 0 && (fds[1].revents & (POLLIN | POLLHUP | POLLERR));
      return !stopping;
    }

    /// Read what the socket has. @return false when the endpoint closed the connection.
    bool receive(const int fd) {
      char buffer[4096];
      const auto count = ::recv(fd, buffer, sizeof(buffer), 0);
      if (count < 0 && errno == EINTR) {
        return true;
      }
      if (count <= 0) {
        return false;
      }
      received.append(buffer, static_cast<std::size_t>(count));
      // The endpoint's lines are at most 64 KiB.
      return received.size() <= 128 * 1024;
    }

    std::optional<std::string> take_line() {
      const auto end = received.find('\n');
      if (end == std::string::npos) {
        return std::nullopt;
      }
      auto line = received.substr(0, end);
      received.erase(0, end + 1);
      return line;
    }

    /// The next line within the handshake's time limit.
    std::optional<service_line_t> expect_line(const int fd, const clock::time_point deadline) {
      for (;;) {
        if (auto line = take_line()) {
          return parse_service_line(*line);
        }
        bool readable = false;
        if (clock::now() >= deadline || !wait(fd, deadline - clock::now(), readable)) {
          return std::nullopt;
        }
        if (readable && !receive(fd)) {
          return std::nullopt;
        }
      }
    }

    /// Challenge, Hello, Welcome, FeedRequest, FeedSession.
    bool handshake(const int fd) {
      using kind_e = service_line_t::kind_e;
      const auto deadline = clock::now() + handshake_timeout;

      const auto fail = [this](const std::optional<service_line_t> &line, const char *step) {
        if (line && line->kind == kind_e::status) {
          report("OpenJoystickDriver refused the "s + step + ": " + line->code + ' ' + line->message);
        } else if (!stopping) {
          report("OpenJoystickDriver did not answer the "s + step);
        }
        return false;
      };

      const auto challenge = expect_line(fd, deadline);
      if (!challenge || challenge->kind != kind_e::challenge) {
        return fail(challenge, "connection");
      }
      if (!send_all(fd, hello_line(settings, challenge->nonce))) {
        return fail(std::nullopt, "hello");
      }
      const auto welcome = expect_line(fd, deadline);
      if (!welcome || welcome->kind != kind_e::welcome) {
        return fail(welcome, "hello");
      }
      if (!send_all(fd, feed_request_line(settings.persona))) {
        return fail(std::nullopt, "feed request");
      }
      const auto session = expect_line(fd, deadline);
      if (!session || session->kind != kind_e::feed_session) {
        return fail(session, "feed request");
      }
      return true;
    }

    /// Drive one connection until it fails or the feed stops.
    void serve(const int fd) {
      using kind_e = service_line_t::kind_e;
      auto next_frame = clock::now();
      auto last_sent = clock::now();
      {
        std::lock_guard lock {mutex};
        dirty = true;  // A new virtual gamepad starts neutral: give it the current state.
      }

      while (!stopping) {
        const auto now = clock::now();
        if (rumble_until && now >= *rumble_until) {
          stop_rumble();
        }

        std::optional<pad_state_t> to_send;
        {
          std::lock_guard lock {mutex};
          if (dirty && now >= next_frame) {
            to_send = state;
            dirty = false;
          }
        }
        if (to_send) {
          if (!send_all(fd, frame_line(*to_send))) {
            return;
          }
          last_sent = now;
          next_frame = now + frame_interval;
        } else if (now - last_sent >= keep_alive_interval) {
          if (!send_all(fd, keep_alive_line())) {
            return;
          }
          last_sent = now;
        }

        auto wake_at = last_sent + keep_alive_interval;
        {
          std::lock_guard lock {mutex};
          if (dirty) {
            wake_at = std::min(wake_at, next_frame);
          }
        }
        if (rumble_until) {
          wake_at = std::min(wake_at, *rumble_until);
        }

        bool readable = false;
        if (!wait(fd, wake_at - clock::now(), readable)) {
          return;
        }
        if (readable && !receive(fd)) {
          report("OpenJoystickDriver closed the virtual gamepad");
          return;
        }
        while (auto line = take_line()) {
          const auto parsed = parse_service_line(*line);
          if (!parsed) {
            continue;
          }
          if (parsed->kind == kind_e::status) {
            report("OpenJoystickDriver closed the virtual gamepad: "s + parsed->code + ' ' + parsed->message);
            return;
          }
          if (parsed->kind == kind_e::rumble) {
            rumbling = parsed->low_frequency || parsed->high_frequency || parsed->left_trigger || parsed->right_trigger;
            rumble_until = rumbling && parsed->duration_ms > 0 ? std::optional {clock::now() + std::chrono::milliseconds(parsed->duration_ms)} : std::nullopt;
            on_rumble(parsed->low_frequency, parsed->high_frequency, parsed->left_trigger, parsed->right_trigger);
          }
        }
      }
    }

    void run() {
      while (!stopping) {
        received.clear();
        const int fd = connect_endpoint();
        if (fd < 0) {
          report("OpenJoystickDriver's endpoint is not available: open the app and run 'ojd access enable'");
        } else {
          if (handshake(fd)) {
            BOOST_LOG(info) << "Gamepad: virtual gamepad published through OpenJoystickDriver as "sv << settings.persona;
            last_problem.clear();
            serve(fd);
          }
          ::close(fd);
          stop_rumble();
        }

        // Try again after a pause, which a stop request ends early.
        const auto retry_at = clock::now() + reconnect_delay;
        bool readable = false;
        while (!stopping && clock::now() < retry_at && wait(-1, retry_at - clock::now(), readable)) {}
      }
    }
  };

  feed_t::feed_t(settings_t settings, rumble_fn on_rumble):
      impl(std::make_unique<impl_t>()) {
    impl->settings = std::move(settings);
    impl->on_rumble = std::move(on_rumble);
    if (::pipe(impl->wake_pipe) == 0) {
      for (const int fd : impl->wake_pipe) {
        ::fcntl(fd, F_SETFL, ::fcntl(fd, F_GETFL) | O_NONBLOCK);
        ::fcntl(fd, F_SETFD, FD_CLOEXEC);
      }
    }
    impl->worker = std::thread {[state = impl.get()]() {
      state->run();
    }};
  }

  feed_t::~feed_t() {
    impl->stopping = true;
    impl->wake();
    if (impl->worker.joinable()) {
      impl->worker.join();
    }
    for (const int fd : impl->wake_pipe) {
      if (fd >= 0) {
        ::close(fd);
      }
    }
  }

  void feed_t::update(const pad_state_t &state) {
    {
      std::lock_guard lock {impl->mutex};
      if (impl->state == state) {
        return;
      }
      impl->state = state;
      impl->dirty = true;
    }
    impl->wake();
  }
}  // namespace platf::ojd
