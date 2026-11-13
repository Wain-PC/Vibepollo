# Gamepads on macOS

macOS lets only an app with Apple's virtual HID entitlement publish a game controller, and
Vibepollo has none. Controllers a client sends therefore go through
[OpenJoystickDriver](https://github.com/xsyetopz/OpenJoystickDriver), a separately installed app
that has the entitlement and offers a local endpoint for programs the user grants. SIP and AMFI
stay on. OpenJoystickDriver is under its own license (PolyForm Noncommercial); Vibepollo only
speaks its documented protocol.

Without this setup the host works as before and ignores controllers.

## Set up

1. Install OpenJoystickDriver, open it, and allow it in **Input Monitoring** and
   **Accessibility** under **System Settings** > **Privacy & Security**. Without Input Monitoring
   it cannot start a virtual gamepad.
2. Install its command-line tool from **Settings** > **Install Command-Line Tool**, then turn on
   the endpoint and create a token for Vibepollo:

   ```sh
   ojd access enable
   ojd access grant --token vibepollo --scope control
   ```

3. Save the token, which is shown once, as `~/.config/vibepollo/ojd_token`, readable only by
   you (`chmod 600`). The file is either the token alone, or `key = value` lines:

   ```
   token = ojd_...
   token_name = vibepollo
   persona = GameControllerCompatible
   ```

4. Restart Vibepollo.

OpenJoystickDriver can also grant a program by its code signature, but it refuses ad hoc and
self-signed builds, so Vibepollo always uses the token.

## What games see

`persona` picks how OpenJoystickDriver presents the gamepad:

| Persona | Shown as | Seen by |
| --- | --- | --- |
| `GameControllerCompatible` (default) | Xbox Wireless Controller | Apple's Game Controller framework, and apps that read HID gamepads |
| `SDLCompatible` | Xbox Adaptive Controller | SDL games, Steam and emulators; not the Game Controller framework |
| `Generic` | Generic HID gamepad | Apps that read HID gamepads; no rumble |

Whatever controller the client has, the game sees the persona. Buttons, the D-pad, both sticks,
both triggers and the Guide button are passed on, and rumble a game sends goes back to the client.
The touchpad, motion sensors, paddles, adaptive triggers and the light bar are not.

## Behaviour

- One virtual gamepad per client controller, up to OpenJoystickDriver's limit of four.
- OpenJoystickDriver plays each state for at least 8 ms, so Vibepollo sends the newest state at
  most every 8 ms rather than queueing older ones.
- If OpenJoystickDriver quits or revokes the token, Vibepollo logs why once and tries again every
  two seconds; the gamepad comes back when the endpoint does.
