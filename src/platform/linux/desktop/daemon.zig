//! Tray daemon: owns the StatusNotifierItem and starts capture children
//! (detached, proc.spawnSelf: never the daemon's zombies, so SIGCHLD keeps
//! its default and children that wait for their own children work).
//! Detaches from the terminal (double fork + setsid) unless asked to stay
//! in the foreground; only one instance can own the bus name
//! io.github.midnattsol.Shotlet (its app id).

const std = @import("std");
const log = std.log.scoped(.daemon);
const dbus = @import("../dbus.zig");
const portal = @import("../portal.zig");
const sys = @import("../sys.zig");
const env_mod = @import("../../../app/env.zig");
const statefile = @import("../../../app/statefile.zig");
const proc = @import("../proc.zig");
const gnome = @import("../gnome.zig");
const shell1 = @import("../gnome/shell1.zig");
const Env = env_mod.Env;

const tray_mod = @import("tray.zig");

pub fn run(gpa: std.mem.Allocator, env: Env, foreground: bool) !void {
    if (!foreground) detach(env);

    var bus = try dbus.Connection.connectSession(gpa, env.session.bus);
    defer bus.deinit();

    // single instance: lose the name race -> another daemon already runs
    if (!(bus.requestName(@import("../../../app_id.zig").app_id) catch true)) {
        log.warn("already running", .{});
        return;
    }
    portal.registerApp(gpa, &bus);
    if (gnome.integrationActive(&bus)) gnome.finishPendingSetup(env);

    const icon22 = try tray_mod.drawIcon(gpa, 22);
    defer gpa.free(icon22);
    const icon44 = try tray_mod.drawIcon(gpa, 44);
    defer gpa.free(icon44);
    const icons = [_]tray_mod.Tray.IconPixmap{
        .{ .width = 22, .height = 22, .argb = icon22 },
        .{ .width = 44, .height = 44, .argb = icon44 },
    };
    var tray = try tray_mod.Tray.init(gpa, &bus, &icons);

    log.info("running", .{});
    var log_file = LogFile.init(env, foreground);
    try serve(gpa, env, &bus, &tray, &log_file);
}

/// Double fork + setsid: the shell gets control back and the daemon can
/// never reacquire a terminal.
fn detach(env: Env) void {
    // first fork: parent returns control to the shell immediately
    if ((sys.fork() catch 0) != 0) sys.exitProcess(0);
    sys.setsid(); // drop the controlling terminal
    // second fork: can never reacquire a tty
    if ((sys.fork() catch 0) != 0) sys.exitProcess(0);
    sys.chdirRoot();
    redirectStdio(env);
}

/// The bus loop: tray calls until Quit or the session bus goes away.
fn serve(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection, tray: *tray_mod.Tray, log_file: *LogFile) !void {
    while (true) {
        // wake up now and then to keep the log bounded: children write to
        // it through the stderr they inherit
        const maybe = bus.nextMessageDeadline(sys.monoMs() + 60_000) catch |err| {
            if (err == error.Disconnected) {
                log.warn("session bus closed; exiting", .{});
                return;
            }
            if (dbus.isFatal(err)) return err;
            // one malformed message must never take the tray down
            log.warn("dropped malformed bus message: {t}", .{err});
            continue;
        };
        log_file.check();
        var msg = maybe orelse continue;
        defer msg.deinit(gpa);

        const action = tray.handleMessage(&msg) catch |err| blk: {
            log.warn("tray message error: {t}", .{err});
            if (msg.type == .method_call) {
                bus.replyError(&msg, "org.freedesktop.DBus.Error.InvalidArgs", "malformed arguments") catch {};
            }
            break :blk .none;
        };
        if (action == .quit) return;
        perform(env, bus, action);
    }
}

/// Starts what a tray menu item asked for.
fn perform(env: Env, bus: *dbus.Connection, action: tray_mod.MenuAction) void {
    switch (action) {
        // the GNOME integration captures inside the shell (no prompt)
        // and starts the editor itself; else a capture child as usual
        .capture => {
            const how: shell1.CaptureRequest = if (gnome.integrationActive(bus)) shell1.capture(bus) else .unavailable;
            if (how == .unavailable) spawnChild(env, "shot");
        },
        // `shotlet record` stops the recording under way, if any
        .record => spawnChild(env, "record"),
        .history => spawnChild(env, "history"),
        .settings => spawnChild(env, "settings"),
        .quit, .none => {},
        else => if (action.modeCommand()) |cmd| spawnChild(env, cmd),
    }
}

/// Start a shotlet subcommand detached, so the daemon stays responsive
/// and a crash in the editor can't take down the tray. It gets the
/// daemon's own environment, so locale, XDG dirs, TZ, PATH and the rest
/// reach the editor unchanged.
fn spawnChild(env: Env, subcommand: [*:0]const u8) void {
    proc.spawnSelf(env.envp, &.{subcommand}, null);
}

/// stdin -> /dev/null; stdout/stderr -> append-only daemon log.
fn redirectStdio(env: Env) void {
    if (sys.openRw("/dev/null")) |null_fd| {
        sys.dup2(null_fd, 0);
        if (null_fd > 2) sys.close(null_fd);
    } else |_| {}
    var log_file = LogFile.init(env, false);
    log_file.rotateIfBig();
    log_file.reopen();
}

/// The daemon log in $XDG_STATE_HOME/shotlet (0600). Rotated past
/// `max_bytes` into a single .old file, checked at start and while running,
/// so it stays around 2 * max_bytes even with chatty children.
const LogFile = struct {
    path_buf: env_mod.PathBuf = undefined,
    path_len: usize = 0,
    enabled: bool = false,
    last_check_ms: i64 = 0,

    const max_bytes = 1024 * 1024;

    fn init(env: Env, foreground: bool) LogFile {
        var self = LogFile{};
        if (foreground) return self; // logging to the terminal
        const p = statefile.prepare(&self.path_buf, env.home, .state, "daemon.log") catch return self;
        self.path_len = p.len;
        self.enabled = true;
        return self;
    }

    fn path(self: *const LogFile) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// Point stdout/stderr at a fresh handle on the log file.
    fn reopen(self: *LogFile) void {
        if (!self.enabled) return;
        const log_fd = sys.openAppend(self.path()) catch return;
        sys.fchmod(log_fd, 0o600); // older versions created it 0644
        sys.dup2(log_fd, 1);
        sys.dup2(log_fd, 2);
        if (log_fd > 2) sys.close(log_fd);
    }

    fn rotateIfBig(self: *LogFile) void {
        if (!self.enabled) return;
        if ((sys.fileSize(self.path()) catch 0) <= max_bytes) return;
        var old_buf: env_mod.PathBuf = undefined;
        const old_path = std.fmt.bufPrint(&old_buf, "{s}.old", .{self.path()}) catch return;
        sys.rename(self.path(), old_path) catch {};
    }

    /// Called from the main loop; cheap, rate-limited to every few seconds.
    fn check(self: *LogFile) void {
        if (!self.enabled) return;
        const now = sys.monoMs();
        if (now - self.last_check_ms < 5_000) return;
        self.last_check_ms = now;
        const size = sys.fdSize(2) catch return;
        if (size <= max_bytes) return;
        self.rotateIfBig();
        self.reopen();
        // children started before the rotation keep appending to .old;
        // cut it if one of them is very chatty
        var old_buf: env_mod.PathBuf = undefined;
        const old_path = std.fmt.bufPrint(&old_buf, "{s}.old", .{self.path()}) catch return;
        if ((sys.fileSize(old_path) catch 0) > 4 * max_bytes) {
            if (sys.openRw(old_path)) |fd| {
                sys.ftruncate(fd, 0) catch {};
                sys.close(fd);
            } else |_| {}
        }
        log.info("daemon log rotated", .{});
    }
};
