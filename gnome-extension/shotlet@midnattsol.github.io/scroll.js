// Scrolling captures for the Shotlet extension: Shotlet picks a region,
// then asks for one frame of it after each scroll step and stitches them.
//
//   ScrollBegin(x, y, w, h, auto) -> session, pieces   (logical region;
//                                    the strips every frame comes in)
//   ScrollStep(session, clicks)   -> capture id (a PNG a piece, shoot.js)
//   ScrollEnd(session)
//
// How it stays safe:
// - only the shotlet binary may begin a session (the same caller check as
//   Capture), one session at a time, never on the lock screen; only the
//   bus connection that began it may step or end it, and it ends by
//   itself when that connection goes away, after 30 s without a step, or
//   after 5 minutes;
// - a step is honoured only while Shotlet's scrolling control (a window
//   of the Shotlet app titled "shotlet:scroll") is on screen;
// - frames are only ever of the region given at the start, written like
//   every capture: fresh 0600 files in the private capture directory;
//   the control is left out of them (hidden for the grab), else it
//   would be a changing part of every frame it sits over;
// - with `auto`, a virtual pointer exists for the session only: it puts
//   the pointer in the middle of the region and turns the wheel there
//   (at most 10 notches a step, at most 25 steps a second); the pointer
//   goes back where it was at the end. Nothing else is injected.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import System from 'system';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {discard, layout, shoot, strips} from './shoot.js';
import {CallError, monotonicMs} from './util.js';

const IDLE_MS = 30 * 1000;
const MAX_MS = 5 * 60 * 1000;
const MIN_STEP_MS = 40;
const MAX_CLICKS = 10;
// time for the app to scroll and paint before the frame is taken
const SETTLE_MS = 160;
// strips of the region: about this many pixels each (shoot.js): a region
// is the one thing encoding, so finer than a capture of every monitor
const PIXELS_PER_PIECE = 400 * 1000;

function wait(ms) {
    return new Promise(resolve => GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => resolve() ?? GLib.SOURCE_REMOVE));
}

export class ScrollSessions {
    // checkCaller(sender) throws unless it is shotlet; captureDir() is the
    // private directory; hudShown() says whether the control is up,
    // hudWindows() which windows it is
    constructor(checkCaller, captureDir, hudShown, hudWindows) {
        this._checkCaller = checkCaller;
        this._captureDir = captureDir;
        this._hudShown = hudShown;
        this._hudWindows = hudWindows;
        this._session = null;
    }

    destroy() {
        this._end();
    }

    _monitorOf(x, y, w, h) {
        return Main.layoutManager.monitors.find(m =>
            x >= m.x && y >= m.y && x + w <= m.x + m.width && y + h <= m.y + m.height);
    }

    async begin(sender, x, y, w, h, auto) {
        await this._checkCaller(sender);
        if (Main.sessionMode.isLocked)
            throw new CallError('Locked', 'the screen is locked');
        if (this._session)
            throw new CallError('Busy', 'a scrolling capture is under way');
        const monitor = this._monitorOf(x, y, w, h);
        if (w < 16 || h < 16 || !monitor)
            throw new CallError('Failed', 'the region must lie on one monitor');
        const id = GLib.uuid_string_random().replace(/-/g, '').slice(0, 16);
        const scale = global.display.get_monitor_scale(monitor.index);
        const pieces = strips({x, y, w, h, scale}, PIXELS_PER_PIECE);
        const s = {id, sender, x, y, w, h, pieces, n: 0, last: 0, dev: null, pointer: null, born: monotonicMs()};
        if (auto) {
            const seat = Clutter.get_default_backend().get_default_seat();
            s.dev = seat.create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
            s.pointer = global.get_pointer().slice(0, 2);
        }
        s.watch = Gio.bus_watch_name_on_connection(Gio.DBus.session, sender,
            Gio.BusNameWatcherFlags.NONE, null, () => this._end());
        s.timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1000, () => {
            const now = monotonicMs();
            if (now - s.born > MAX_MS || now - (s.last || s.born) > IDLE_MS || Main.sessionMode.isLocked) {
                s.timer = 0;
                this._end();
                return GLib.SOURCE_REMOVE;
            }
            return GLib.SOURCE_CONTINUE;
        });
        this._session = s;
        console.log(`Shotlet: scrolling capture of ${w}x${h} at ${x},${y}${auto ? ', scrolling for the person' : ''}`);
        return [id, layout(pieces)];
    }

    _own(sender, id) {
        const s = this._session;
        if (!s || s.id !== id || s.sender !== sender)
            throw new CallError('AccessDenied', 'not this caller\'s scrolling capture');
        return s;
    }

    async step(sender, id, clicks) {
        const s = this._own(sender, id);
        if (!this._hudShown())
            throw new CallError('AccessDenied', 'Shotlet\'s scrolling control is not on screen');
        // too soon after the last one: it waits its turn
        const now = monotonicMs();
        const at = Math.max(now, s.last + MIN_STEP_MS);
        s.last = at;
        if (at > now)
            await wait(at - now);
        if (this._session !== s)
            throw new CallError('Failed', 'the scrolling capture ended');
        if (clicks > 0 && s.dev) {
            this._wheel(s, Math.min(clicks, MAX_CLICKS));
            await wait(SETTLE_MS);
        }
        if (this._session !== s)
            throw new CallError('Failed', 'the scrolling capture ended');
        return this._grab(s);
    }

    _wheel(s, clicks) {
        const t = GLib.get_monotonic_time();
        s.dev.notify_absolute_motion(t, s.x + s.w / 2, s.y + s.h / 2);
        for (let i = 0; i < clicks; i++)
            s.dev.notify_discrete_scroll(t + i + 1, Clutter.ScrollDirection.DOWN, Clutter.ScrollSource.WHEEL);
    }

    // The control's window actors, made invisible (for the grab: just
    // moved, one is still painted where it was); give each back its
    // opacity after.
    _hideHud() {
        const hidden = [];
        for (const w of this._hudWindows()) {
            const actor = w.get_compositor_private();
            if (!actor || actor.opacity === 0)
                continue;
            hidden.push([actor, actor.opacity]);
            actor.opacity = 0;
        }
        return hidden;
    }

    // One frame, in the session's pieces: the pixels are painted at once
    // (the control hidden only meanwhile), the PNGs follow.
    async _grab(s) {
        const id = `${s.id}s${s.n++}`;
        const files = [];
        const hidden = this._hideHud();
        try {
            let shots;
            try {
                shots = shoot(s.pieces, this._captureDir(), id, files);
            } finally {
                for (const [actor, opacity] of hidden)
                    actor.opacity = opacity;
            }
            await Promise.all(shots);
        } catch (e) {
            discard(files);
            throw e;
        }
        return id;
    }

    end(sender, id) {
        this._own(sender, id);
        this._end();
    }

    _end() {
        const s = this._session;
        if (!s)
            return;
        this._session = null;
        if (s.timer)
            GLib.source_remove(s.timer);
        Gio.bus_unwatch_name(s.watch);
        if (s.dev) {
            if (s.pointer)
                s.dev.notify_absolute_motion(GLib.get_monotonic_time(), ...s.pointer);
            // the last reference: the device goes when it is collected
            s.dev = null;
            System.gc();
        }
        console.log(`Shotlet: scrolling capture ended after ${s.n} frames`);
    }
}
