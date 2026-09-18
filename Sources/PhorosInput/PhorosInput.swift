/// Game controller forwarding for Phoros.
///
/// The wire contract for controller input is one packet type, `.input`, whose
/// payload is a fourteen-byte `ControllerReport`. This module carries the two
/// ends that every app on the contract had to write by hand:
///
/// - `ControllerSampler` (client): watches the GameController framework for
///   an extended gamepad, snapshots it into `ControllerReport`s, and applies
///   the send-on-change plus keepalive policy so the host gets at most one
///   report per tick and never loses the last state.
/// - `VirtualGamepad` (host, macOS 13+): replays `ControllerReport`s into a
///   virtual HID gamepad through `IOHIDUserDevice`, so any game on the host
///   sees a real controller with full analog sticks and triggers.
/// - `GamepadReport`: the HID report descriptor and the pure mapping from a
///   `ControllerReport` to the nine HID report bytes. Shared by
///   `VirtualGamepad` and its tests.
/// - `InputReplay` (host, macOS): posts the keyboard, text, media-key and
///   mouse events that `ControlMessage.mediaKey` asks for. Needs the
///   Accessibility permission, no entitlement.
/// - `FrameMapping`: pure geometry from a tap or viewport lock in the frame
///   the client shows to a point or rect on the source the host captures,
///   with letterbox and viewport lock undone.
///
/// Creating a virtual HID device needs the `com.apple.developer.hid.virtual.device`
/// entitlement, which Apple grants per team on request. A host without it
/// should not advertise `HostCapabilities.supportsControllerInput`, and a
/// client should not sample a controller for a host that did not advertise it.
public enum PhorosInput {}
