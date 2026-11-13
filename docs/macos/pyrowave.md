# PyroWave on macOS

For PyroWave streaming with Vibepollo, use a client that supports it, such as Nonary's
[VRR Moonlight Client fork](https://github.com/Nonary/moonlight-qt). Select PyroWave
in the client's codec settings and connect over a fast wired LAN; stock Moonlight
does not support PyroWave.

Apple silicon builds enable `SUNSHINE_ENABLE_PYROWAVE` by default. Intel builds leave
it off: the encoder is upstream PyroWave's Metal port, which needs an Apple GPU. The
build needs nothing beyond the normal macOS dependencies, since the port's shaders are
checked-in Metal source compiled at runtime. No change to the PyroWave bitstream or
client protocol is required; see [the wire contract](../pyrowave-protocol.md).

The Metal port is vendored at the same commit as the Vulkan codec the clients decode
with, and emits the same bitstream, so `PYROWAVE_BITSTREAM_ID` is unchanged. Its local
patches live in `third-party/pyrowave/patches-metal/` and change buffer sizing, record
padding and input wrapping only.

As on Linux, the codec never sees the capture's own Y'CbCr. Each frame goes through
one Metal conversion pass that scales it to the stream's size, applies the negotiated
matrix and range, and writes 16-bit planes normalized as `code / (2^depth - 1)`. The
negotiated chroma subsampling and depth apply to both SDR and HDR sessions.

- SDR sessions capture BGRA.
- HDR sessions capture 10-bit RGB in BT.2020 PQ from ScreenCaptureKit, on macOS 15 or
  later and an HDR display. An 8-bit capture in an HDR session is converted to PQ at
  SDR white.
- A capture another session already switched to NV12 or P010 is resampled as it is; it
  is assumed to be in the stream's own matrix and range.
- A source of another shape is letterboxed or pillarboxed.

The existing `pyrowave` configuration switch controls advertisement. Startup probing
performs a real GPU conversion, encode, and readback. Session frames use the same
record/length-prefixed framing, bitrate budget, and critical FEC policy as Windows and
Linux. A passing probe does not verify client playback.
