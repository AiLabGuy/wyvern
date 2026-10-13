<!--
SPDX-FileCopyrightText: 2026 Wyvern Contributors
SPDX-License-Identifier: MIT
-->

# Network health (core)

This folder is the data source for the concept 3 vitals badge. It does not draw anything.
The product name, when the interface needs it, comes from `AppInfo.displayName`.

The service watches **one host**: the host of the visible tab. It does not contact any other
address, it does not write samples to disk, and it does not send measurements anywhere.
`protocolName` stays nil until the tab that owns the connection sets it.

## What the interface reads

Own one `NetworkHealthService`. Settings binds its `enabled` flag (`netHealthEnabled`,
default on). `onSnapshot` runs on the main queue.

Call `start(host:scheme:)` when the visible tab has an `http` or `https` host, and `stop()`
for a new tab or any page that is not a remote host. Call `visibilityChanged(visible:)`
when the window gains or loses focus. After the window is hidden, probing continues for
30 seconds and then stops. Showing the window again resumes the same host.

Each `NetworkHealthSnapshot` carries:

| Field | Badge and panel |
|---|---|
| `state` and `presentation` | Glyph, label, colors, BPM, beat width, sweep speed, beat-shape id |
| `stats.medianRTT` | The large latency figure. Multiply seconds by 1000 for milliseconds |
| `stats.meanRTT`, `jitter`, `lossPercent` | The jitter and loss rows |
| `samples` | The 60 second sparkline. A nil `rtt` is a gap, not a zero |
| `probeKind.displayName` | "ICMP echo" or "TCP connect :443" / "TCP connect :80", shown in the panel |
| `resolvedIP` | From `getaddrinfo`. A dash when nil |
| `protocolName` | A dash while nil. The tab sets "HTTP/3", "HTTP/2", or "HTTP/1.1" later |
| `hopCount` | A dash until Trace returns hops |
| `accessibilityLabel` | VoiceOver string, for example "Network health: Fair, 164 ms" |
| `announcePolitely` | Post this label only when the state just became poor or offline |

## Badge

Concept 3 puts a 24px-high pill at the right end of the toolbar.
Radius 12, 1px border, trace 28×14 at 1.3px stroke. The pill shows the glyph, the trace,
and the state label (`GOOD`, `FAIR`, `POOR`, `OFFLINE`). `IDLE` is the unknown state
before two samples agree; the bar can hide the pill while the state is unknown.

Color is not the only cue. The glyph, the label, and the beat shape differ per state:

| State | Glyph | Beat shape | BPM | Badge sweep | Panel sweep |
|---|---|---|---|---|---|
| Good | circle | `sharp-qrs` | 60 | 25 pt/s | 50 pt/s |
| Fair | triangle | `wide-stretched` (1.5× width) | 40 | 25 pt/s | 50 pt/s |
| Poor | cross | `jagged-spike` (±30% interval and height) | 150 | 40 pt/s | 40 pt/s |
| Offline | dash | `flatline` | none | 10 pt/s | 10 pt/s |

Light and dark hex values are on `presentation`. Cross-fade the color over
`HealthLimits.colorCrossfade` (200 ms). Change the waveform on the next beat.

The trace sweeps left to right. The newest point is the head dot; older points leave
on the left. Offline has no beats: the dashes drift and the head dot pulses at 0.5 Hz.

Reduced motion is an interface concern (`NSWorkspace.accessibilityDisplayShouldReduceMotion`).
This library does not link AppKit. When reduced motion is on, do not sweep. Draw the
static waveform for the state and replace it only when the state changes. Poor does not flash.
Pause the sweep when the window is unfocused or occluded.

The badge is keyboard-focusable. Enter or Space opens the panel. Esc closes it.

## Panel

A click, not a hover, opens the 300px panel (14px padding, 10px radius, 12px text,
mono values). The monitor trace is 270×64 at 1.8px stroke on an 8px grid. Under it:

- latency from `stats.medianMilliseconds`, with a 120×26 sparkline of `samples`
- Host, resolved IP, protocol, jitter, packet loss
- Hops: `hopCount`, or a dash when it is nil
- The probe kind from `probeKind.displayName`
- A Trace button

Trace calls `service.trace`. The result is `.hops([ttl, ip, rtt])`, `.cancelled`, or
`.unavailable` with `TraceError.message`. Unavailable means the unprivileged ICMP
socket could not be opened, so time-exceeded messages cannot be read. The button does
not start a trace by itself. Cancel with `cancelTrace()`.

## How a state is chosen

The window is the last 60 seconds, not a fixed count of 10. Median RTT, mean RTT,
jitter (mean absolute successive difference of replies), and loss percent all come
from that window.

- Good: median under 80 ms, loss at or under 2%, jitter at or under 100 ms
- Fair: median from 80 ms through 250 ms, with the same loss and jitter limits
- Poor: median over 250 ms, or loss over 2%, or jitter over 100 ms
- Offline: no successful reply for 3 seconds, or the path reports no route

Good, fair, and poor publish only after two consecutive samples agree, so one spike
does not flicker the badge. Offline publishes as soon as the 3 second silence elapses.
Two agreeing samples are required again to leave offline.

Probes run about once a second. ICMP echo is first (`SOCK_DGRAM` / `IPPROTO_ICMP`).
If that socket cannot be opened, or three ICMP sends fail in a row and a TCP handshake
to port 443 (port 80 for `http`) reaches ready, later probes use TCP. The handshake is
cancelled as soon as it is ready. No request body is sent.
