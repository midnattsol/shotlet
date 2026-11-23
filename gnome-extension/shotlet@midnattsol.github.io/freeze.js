// The frozen screen, shown by the shell itself the moment a capture is
// taken (extension.js _captureScreens): each monitor painted once at its
// own scale (Clutter.Stage.paint_to_content, the way GNOME's own
// screenshot UI shows its frozen frame), put on top of everything in an
// actor of the monitor's logical size, so its pixels land 1:1. It holds
// the pointer and the keyboard (a Clutter grab) so nothing reaches the
// live windows beneath, until the Shotlet started on the capture shows
// its own first frame of the same pixels and calls Unfreeze(id), or that
// Shotlet exits, or FREEZE_MAX_MS passes. What the pointer and keyboard
// did meanwhile (a press, its release, Escape) is Unfreeze's answer, for
// the editor to take up. No pixels leave the shell here.

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import Mtk from 'gi://Mtk';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {monotonicMs} from './util.js';

// a Shotlet that never takes over: the screen is given back anyway
const FREEZE_MAX_MS = 10 * 1000;

// Unfreeze's answer when nothing happened (or for another capture)
export const NO_INPUT = [false, 0, 0, false, 0, 0, false];

export class Freeze {
    constructor() {
        this._id = null;
        this._box = null;
        this._grab = null;
        this._timer = 0;
        this._painted = null;
        this._input = null;
    }

    // Paint every monitor now and show the frozen frame for capture
    // `id` (the key pressed at `t0`); false when it cannot (then nothing
    // is shown and the capture goes on without it).
    show(id, t0, monitors) {
        this.release();
        try {
            const x0 = Math.min(...monitors.map(m => m.x)), y0 = Math.min(...monitors.map(m => m.y));
            const x1 = Math.max(...monitors.map(m => m.x + m.w)), y1 = Math.max(...monitors.map(m => m.y + m.h));
            this._box = new Clutter.Actor({x: x0, y: y0, width: x1 - x0, height: y1 - y0, reactive: true});
            for (const m of monitors) {
                const rect = new Mtk.Rectangle({x: m.x, y: m.y, width: m.w, height: m.h});
                const content = global.stage.paint_to_content(rect, m.scale, Clutter.PaintFlag.NO_CURSORS);
                this._box.add_child(new Clutter.Actor({x: m.x - x0, y: m.y - y0, width: m.w, height: m.h, content}));
            }
            Main.layoutManager.uiGroup.add_child(this._box);
        } catch (e) {
            console.warn(`Shotlet: no frozen frame: ${e.message}`);
            this.release();
            return false;
        }
        this._id = id;
        this._at = monotonicMs();
        this._track();
        this._grab = global.stage.grab(this._box);
        this._timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, FREEZE_MAX_MS, () => {
            this._timer = 0;
            console.log('Shotlet: no editor took over the frozen screen');
            this.release();
            return GLib.SOURCE_REMOVE;
        });
        this._painted = new Promise(resolve => {
            const painted = global.stage.connect('after-paint', () => {
                global.stage.disconnect(painted);
                console.log(`Shotlet: frozen screen shown ${monotonicMs() - t0} ms after the key`);
                // what is painted next starts from that frame
                GLib.idle_add(GLib.PRIORITY_HIGH, () => resolve() ?? GLib.SOURCE_REMOVE);
            });
        });
        return true;
    }

    // Keep the first left press (and its release) and an Escape.
    _track() {
        const input = {pressed: false, x: 0, y: 0, released: false, rx: 0, ry: 0, escaped: false};
        this._input = input;
        this._box.connect('button-press-event', (_a, ev) => {
            if (ev.get_button() === Clutter.BUTTON_PRIMARY && !input.pressed)
                [input.pressed, input.x, input.y] = [true, ...ev.get_coords().map(Math.round)];
            return Clutter.EVENT_STOP;
        });
        this._box.connect('button-release-event', (_a, ev) => {
            if (ev.get_button() === Clutter.BUTTON_PRIMARY && input.pressed && !input.released)
                [input.released, input.rx, input.ry] = [true, ...ev.get_coords().map(Math.round)];
            return Clutter.EVENT_STOP;
        });
        this._box.connect('key-press-event', (_a, ev) => {
            if (ev.get_key_symbol() === Clutter.KEY_Escape)
                input.escaped = true;
            return Clutter.EVENT_STOP;
        });
    }

    // Resolves once the frozen frame shown last has been painted.
    painted() {
        return this._painted ?? Promise.resolve();
    }

    // Capture `id` is on screen in Shotlet (or never will be): the live
    // screen, with Shotlet's windows, comes back. The answer: what the
    // pointer and keyboard did meanwhile, as Unfreeze returns it
    // (pressed, x, y, released, rx, ry, escaped); NO_INPUT for another id.
    unfreeze(id) {
        if (id === null || id !== this._id)
            return NO_INPUT;
        const i = this._input;
        console.log(`Shotlet: frozen screen given back ${monotonicMs() - this._at} ms after it was taken`);
        this.release();
        return [i.pressed, i.x, i.y, i.released, i.rx, i.ry, i.escaped];
    }

    release() {
        if (this._timer)
            GLib.source_remove(this._timer);
        this._timer = 0;
        this._grab?.dismiss();
        this._grab = null;
        this._box?.destroy();
        this._box = null;
        this._id = null;
        this._painted = null;
        this._input = null;
    }
}
