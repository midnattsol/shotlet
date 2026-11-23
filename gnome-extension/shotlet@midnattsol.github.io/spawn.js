// Starting a program and hearing when it exits: GNOME Shell's own
// Util.trySpawn (the app launch environment, a systemd scope of its own,
// no double fork) with the exit reported, which trySpawn keeps to itself.

import GLib from 'gi://GLib';
import GnomeDesktop from 'gi://GnomeDesktop';
import Shell from 'gi://Shell';

// Start `argv`; `onExit()` runs once it has exited. Throws when it could
// not start.
export function spawnWatched(argv, onExit) {
    const launchContext = global.create_app_launch_context(0, -1);
    const pid = Shell.util_spawn_async(null, argv, launchContext.get_environment(),
        GLib.SpawnFlags.SEARCH_PATH | GLib.SpawnFlags.DO_NOT_REAP_CHILD);
    GnomeDesktop.start_systemd_scope(argv[0], pid, null, null, null, () => {});
    GLib.child_watch_add(GLib.PRIORITY_DEFAULT, pid, () => {
        GLib.spawn_close_pid(pid);
        onExit();
    });
}
