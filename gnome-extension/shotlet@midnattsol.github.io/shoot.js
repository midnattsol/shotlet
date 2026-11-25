// The screenshot of an area, for Shotlet's captures (extension.js) and
// its scrolling captures (scroll.js): Shell.Screenshot.screenshot_area in
// a few horizontal strips, so the PNG encoding (on a worker thread per
// call) runs in parallel. Every strip is painted when shoot() is called,
// in one main loop iteration: the same frame.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';

// the shell encodes on a pool of 10 threads: two monitors in 8 strips
// each measured fastest on two 4K monitors
const MAX_STRIPS = 8;

// The smallest number of logical pixels that is a whole number of
// physical pixels at `scale` (2 at 1.5, 4 at 1.25, 3 at 4/3), as
// geom.pixelStep in Shotlet; 0 when there is none up to 16.
function stripStep(scale) {
    for (let n = 1; n <= 16; n++) {
        if (Math.abs(n * scale - Math.round(n * scale)) < 1e-3)
            return n;
    }
    return 0;
}

// Area `m` ({x, y, w, h, scale}, logical, on whole physical pixels) in
// strips of about `pixels` physical pixels, at most MAX_STRIPS, their
// edges on whole physical pixels (else it stays whole).
export function strips(m, pixels) {
    const step = stripStep(m.scale);
    const px = m.w * m.h * m.scale * m.scale;
    const rows = step ? Math.floor(m.h / step) : 0;
    const n = Math.min(MAX_STRIPS, rows, Math.max(1, Math.ceil(px / pixels)));
    if (n <= 1)
        return [{...m}];
    const out = [];
    for (let i = 0; i < n; i++) {
        const y0 = m.y + Math.floor(i * rows / n) * step;
        const y1 = i === n - 1 ? m.y + m.h : m.y + Math.floor((i + 1) * rows / n) * step;
        out.push({x: m.x, y: y0, w: m.w, h: y1 - y0, scale: m.scale});
    }
    return out;
}

// "x,y,w,h,scale;..." as Shotlet's shellcap.zig reads it
export function layout(list) {
    return list.map(r => [r.x, r.y, r.w, r.h, r.scale].join(',')).join(';');
}

// Paint `pieces` now and write each as a PNG to a new file shot-ID-K.part
// in `dir`, renamed to .png once complete (both added to `files`); one
// promise a piece, resolved once renamed.
export function shoot(pieces, dir, id, files) {
    return pieces.map((p, k) => shootOne(p, dir, `shot-${id}-${k}`, files));
}

function shootOne(p, dir, name, files) {
    const part = Gio.File.new_for_path(GLib.build_filenamev([dir, `${name}.part`]));
    const done = Gio.File.new_for_path(GLib.build_filenamev([dir, `${name}.png`]));
    // O_EXCL, mode 0600
    const stream = part.create(Gio.FileCreateFlags.PRIVATE, null);
    files.push(part, done);
    return new Promise((resolve, reject) => {
        new Shell.Screenshot().screenshot_area(p.x, p.y, p.w, p.h, stream, (obj, res) => {
            try {
                obj.screenshot_area_finish(res);
                stream.close(null);
                part.move(done, Gio.FileCopyFlags.NOFOLLOW_SYMLINKS, null, null);
                resolve();
            } catch (e) {
                reject(e);
            }
        });
    });
}

// Delete what is left of a capture's files.
export function discard(files) {
    for (const f of files) {
        try {
            f.delete(null);
        } catch {}
    }
}
