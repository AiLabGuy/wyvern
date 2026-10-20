# Backlog

Ideas that are wanted but not scheduled. Nothing here is implemented yet.

## Browser-based KVM mode (JetKVM and similar)

**Why.** Web KVMs such as JetKVM are hard to use in most browsers. On iPad Safari the KVM
view is treated as a media window (a video to play) instead of an interactive screen, which
makes it nearly unusable. The goal is to make Wyvern the best browser for browser-based KVMs.

**What JetKVM uses (checked Oct 2026).** WebRTC for both video and input:

- The project README lists "1080p@60FPS video with 30-60ms latency using H.264 encoding" and
  remote access "using WebRTC" ([jetkvm/kvm README](https://github.com/jetkvm/kvm#features)).
- The device firmware is built on Pion WebRTC (`github.com/pion/webrtc/v4` in
  [go.mod](https://github.com/jetkvm/kvm/blob/dev/go.mod)). Keyboard and mouse travel over
  WebRTC data channels (control, RPC and HID channels in
  [webrtc.go](https://github.com/jetkvm/kvm/blob/dev/webrtc.go)); the video track is H.264,
  with an H.265 option in the same file.

**Likely work areas.**

- WebRTC and hardware H.264 decode performance in WKWebView; measure frame pacing and latency.
- Keyboard capture: send Command, Option and Control combinations and app shortcuts (Command-W,
  Command-Tab where possible, Command-Q) to the remote side instead of Wyvern, with a clear,
  documented escape key to get the shortcuts back.
- Pointer lock (relative mouse) and correct absolute-pointer mapping when the view is scaled.
- Do not treat the KVM view as media: no picture-in-picture offer, no Now Playing / media-key
  hijack, no autoplay or power-saving pauses on the video track.
- Element fullscreen and window fullscreen that keep keyboard capture.
- Clipboard: paste-as-keystrokes and copy back, only on a user gesture.
- Low-latency settings: no throttling of background/occluded KVM tabs, no timer coalescing.
- A per-site "KVM mode" that turns the above on for one origin (for example
  `https://kvm.example.lan`), shown in the address bar while active.

## RDP tab type

**What.** A new tab kind next to terminal (CLI) tabs. The new-tab right-click menu offers
**CLI** or **RDP**. An RDP tab connects to a saved, named machine (for example `my-desktop`)
and tiles like any other tab, so an RDP session can sit next to a CLI tab.

**Possible approaches.**

- Embed a native client built on FreeRDP (Apache-2.0) rendering into an `NSView` pane, the
  same way terminal tabs host SwiftTerm.
- Or a WebSocket gateway such as Apache Guacamole (Apache-2.0) rendered in a web view; simpler
  UI, but it needs a server to run and adds a hop.

**Licensing and security.**

- Check that every linked library is Apache-2.0/MIT/BSD compatible; no GPL code in the app.
- Credentials live only in the macOS Keychain, never in plain text, settings files or session
  snapshots. Saved machines store host, port, user name and a Keychain reference.
- Verify server certificates (TOFU with a visible fingerprint prompt), offer NLA, and keep
  clipboard and drive redirection off by default.
