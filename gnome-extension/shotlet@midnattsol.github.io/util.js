// Small helpers of the Shotlet extension (extension.js).

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

export const APP_ID = 'io.github.midnattsol.Shotlet';

// "<Ctrl><Shift>s", "<Shift><Control>S": the same key
export function normalizeAccel(accel) {
    const mods = [];
    const key = accel.replace(/<([^>]+)>/g, (_m, mod) => {
        mod = mod.toLowerCase();
        mods.push({ctrl: 'control', primary: 'control', ctl: 'control'}[mod] ?? mod);
        return '';
    }).toLowerCase();
    return [...mods.sort(), key].join('+');
}

// an error a D-Bus call answers with: dev.shotlet.Shell1.Error.<name>
export class CallError extends Error {
    constructor(name, message) {
        super(message);
        this.dbusName = `dev.shotlet.Shell1.Error.${name}`;
    }
}

// answer a call with the values `fn` gives, of these D-Bus types ('ss';
// null: no values), or with the error it throws
export async function reply(invocation, types, fn) {
    try {
        const values = await fn();
        invocation.return_value(types ? new GLib.Variant(`(${types})`, values) : null);
    } catch (e) {
        invocation.return_dbus_error(e.dbusName ?? 'dev.shotlet.Shell1.Error.Failed', e.message);
    }
}

export function monotonicMs() {
    return Math.floor(GLib.get_monotonic_time() / 1000);
}

// device and inode of what a path finally names (symlinks followed)
export function fileId(path) {
    try {
        const info = Gio.File.new_for_path(path).query_info(
            'unix::device,unix::inode', Gio.FileQueryInfoFlags.NONE, null);
        return `${info.get_attribute_uint32('unix::device')}:${info.get_attribute_uint64('unix::inode')}`;
    } catch {
        return null;
    }
}

export function roleOf(win) {
    if (!win || win.get_wm_class() !== APP_ID)
        return null;
    const title = win.get_title() ?? '';
    if (!title.startsWith('shotlet:'))
        return null;
    return title.split(':')[1] || null;
}
