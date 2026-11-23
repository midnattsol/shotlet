//! Minimal PipeWire screen-capture client. Loads libpipewire-0.3 at runtime
//! (dlopen) so shotlet keeps building with zero dependencies and falls back
//! to the Screenshot portal when PipeWire is unavailable. Uses the stable
//! pw_stream C API; the SPA format pod is built by hand.
//!
//! Facade over pw/: abi (constants, struct mirrors, the pw_* table), pod
//! (format pods and the pod walker), stream (what every stream client
//! shares: format, valid area, callbacks), capture (the screenshot
//! stream's callbacks and frame copy) and grab (connection and one-shot
//! grab). pwstream.zig, the recording client, builds on the same parts.
//! The loaded library and its function table live here, shared by all.

const std = @import("std");
const abi = @import("pw/abi.zig");
const pod = @import("pw/pod.zig");
const stream = @import("pw/stream.zig");
const capture = @import("pw/capture.zig");
const grab = @import("pw/grab.zig");
const optlib = @import("../../optlib.zig");

pub const SPA_PARAM_Format = abi.SPA_PARAM_Format;
pub const VideoFormat = abi.VideoFormat;
pub const PW_DIRECTION_INPUT = abi.PW_DIRECTION_INPUT;
pub const PW_STREAM_FLAG_AUTOCONNECT = abi.PW_STREAM_FLAG_AUTOCONNECT;
pub const PW_STREAM_FLAG_MAP_BUFFERS = abi.PW_STREAM_FLAG_MAP_BUFFERS;
pub const SpaHook = abi.SpaHook;
pub const StreamEvents = abi.StreamEvents;
pub const Api = abi.Api;

pub const buildFormatPod = pod.buildFormatPod;
pub const buildAudioFormatPod = pod.buildAudioFormatPod;

pub const Format = stream.Format;
pub const onFormat = stream.onFormat;
pub const onState = stream.onState;
pub const chunkOf = stream.chunkOf;
pub const validArea = stream.validArea;

pub const Frame = capture.Frame;

pub const Pre = grab.Pre;
pub const preconnect = grab.preconnect;
pub const connectDaemon = grab.connectDaemon;
pub const teardown = grab.teardown;
pub const max_nodes = grab.max_nodes;
pub const grabNodes = grab.grabNodes;
pub const grabFrames = grab.grabFrames;

/// The resolved entry points; valid once `available` returned true.
pub var api: Api = undefined;

const Lib = optlib.Once(optlib.Table(Api), struct {
    fn load(why: *[]const u8) anyerror!optlib.Table(Api) {
        const t = optlib.bindPrefixed(Api, "pipewire-0.3", "pw_", &.{"0"}, why) catch |err| {
            if (err == error.NotFound)
                std.log.info("{s}; using the Screenshot portal", .{why.*})
            else
                std.log.warn("{s}; using the Screenshot portal", .{why.*});
            return err;
        };
        api = t.api;
        api.init(null, null);
        return t;
    }
}.load);

/// Try to load libpipewire, once. False (logged once) when unavailable.
pub fn available() bool {
    return Lib.available();
}

comptime {
    _ = abi;
    _ = pod;
    _ = stream;
    _ = capture;
    _ = grab;
}
