const std = @import("std");
const util = @import("util.zig");
const terminal = @import("terminal.zig");
const algoNRanked = &@import("algo.zig").nRanked;
const os = std.os;
const mem = std.mem;
const fs = std.fs;
const posix = std.posix;
const math = std.math;

const y_len_ptr: *usize = &@import("input.zig").y_len;

pub var window: Area = undefined;
pub var panels: Panels = undefined;

pub const Area = struct {
    xmin: usize,
    xmax: usize,
    ymin: usize,
    ymax: usize,
    xlen: usize,
    ylen: usize,
};

const PanelShape = struct {
    x_dim: Dim,
    y_dim: Dim,
};

const DimType = enum {
    fractional,
    absolute,
};

const Dim = union(DimType) {
    fractional: struct {
        totalfr: u8,
        startline: u8,
        endline: u8,
    },
    absolute: struct {
        min: usize,
        max: usize,
    },
};

pub fn init() !void {
    const tty = terminal.ttyFile();
    try getWindow(tty);
    panels.init(window);
    y_len_ptr.* = panels.find.validArea().ylen;
}

fn getWindow(tty: *const fs.File) !void {
    // Using posix.winsize which is platform-independent
    var win_size = mem.zeroes(posix.winsize);

    // TIOCGWINSZ is a standard terminal ioctl call, but might need to be used with the right numeric value
    // The value below is typically defined for both Linux and macOS
    const TIOCGWINSZ: u32 = 0x5413; // On macOS it's typically 0x40087468

    // For macOS compatibility, we'll use system.ioctl directly
    const is_macos = @import("builtin").os.tag == .macos;
    const ioctl_code = if (is_macos) 0x40087468 else TIOCGWINSZ;

    const err = std.os.linux.ioctl(tty.handle, ioctl_code, @intFromPtr(&win_size));
    if (err < 0) {
        return error.WindowSizeError;
    }

    window = .{
        .xmin = 0,
        .xmax = win_size.col - 1, // Columns (width) minus 1 for zero-based indexing
        .ymin = 0,
        .ymax = win_size.row - 1, // Rows (height) minus 1 for zero-based indexing
        .xlen = win_size.col,
        .ylen = win_size.row,
    };
}

pub const Panel = struct {
    borders: bool,
    area: Area,

    fn init(
        borders: bool,
        shape: PanelShape,
        fractionalBase: ?Area,
    ) Panel {
        const base = if (fractionalBase) |base| base else window;
        var x_min: usize = undefined;
        var x_max: usize = undefined;
        var y_min: usize = undefined;
        var y_max: usize = undefined;

        switch (shape.x_dim) {
            DimType.fractional => |fractional| divideFractional(&x_min, &x_max, base.xmin, base.xmax, fractional),
            DimType.absolute => |absolute| {
                x_min = absolute.min;
                x_max = absolute.max;
            },
        }

        switch (shape.y_dim) {
            DimType.fractional => |fractional| divideFractional(&y_min, &y_max, base.ymin, base.ymax, fractional),
            DimType.absolute => |absolute| {
                y_min = absolute.min;
                y_max = absolute.max;
            },
        }

        const x_len = x_max - x_min + 1;
        const y_len = y_max - y_min + 1;

        return .{
            .borders = borders,
            .area = .{
                .xmin = x_min,
                .xmax = x_max,
                .ymin = y_min,
                .ymax = y_max,
                .xlen = x_len,
                .ylen = y_len,
            },
        };
    }

    fn divideFractional(min: *usize, max: *usize, areamin: usize, areamax: usize, dimensions: anytype) void {
        const unit = (areamax - areamin + 1) / dimensions.totalfr;
        const remainder = (areamax + 1) % dimensions.totalfr;
        min.* = (unit * dimensions.startline) + @min(dimensions.startline, remainder) + areamin;
        max.* = areamin + (unit * dimensions.endline) + @min(dimensions.endline, remainder) - 1;
    }

    pub fn validArea(self: *const Panel) Area {
        if (self.borders) return .{
            .xmin = self.area.xmin + 1,
            .xmax = self.area.xmax - 1,
            .ymin = self.area.ymin + 1,
            .ymax = self.area.ymax - 1,
            .xlen = self.area.xlen - 2,
            .ylen = self.area.ylen - 2,
        };
        return self.area;
    }

    pub fn getYCentre(self: *const Panel) usize {
        return self.area.ymin + (self.area.ymax - self.area.ymin) / 2;
    }

    pub fn getXCentre(self: *const Panel) usize {
        return self.area.xmin + (self.area.xmax - self.area.xmin) / 2;
    }
};

pub const Panels = struct {
    curr_song: Panel,
    queue: Panel,
    find: Panel,
    browse1: Panel,
    browse2: Panel,
    browse3: Panel,

    fn init(self: *Panels, window_area: Area) void {
        self.curr_song = Panel.init(true, curr_song_shape(window_area), null);
        self.queue = Panel.init(true, queue_shape(window_area), null);
        self.find = Panel.init(true, find_shape(window_area), null);
        const find_valid = self.find.validArea();
        self.browse1 = Panel.init(false, browse1_shape(find_valid), find_valid);
        self.browse2 = Panel.init(false, browse2_shape(find_valid), find_valid);
        self.browse3 = Panel.init(false, browse3_shape(find_valid), find_valid);
    }
};

fn curr_song_shape(window_area: Area) PanelShape {
    return .{
        .x_dim = .{
            .absolute = .{
                .min = window_area.xmin,
                .max = window_area.xmax,
            },
        },
        .y_dim = .{
            .absolute = .{ .min = 0, .max = 6 },
        },
    };
}

fn queue_shape(window_area: Area) PanelShape {
    return .{
        .x_dim = .{
            .fractional = .{
                .totalfr = 7,
                .startline = 0,
                .endline = 4,
            },
        },
        .y_dim = .{
            .absolute = .{
                .min = 7,
                .max = window_area.ymax,
            },
        },
    };
}

fn find_shape(window_area: Area) PanelShape {
    return .{
        .x_dim = .{
            .fractional = .{
                .totalfr = 7,
                .startline = 4,
                .endline = 7,
            },
        },
        .y_dim = .{
            .absolute = .{
                .min = 7,
                .max = window_area.ymax,
            },
        },
    };
}

fn browse1_shape(find_area: Area) PanelShape {
    return .{
        .x_dim = .{
            .fractional = .{
                .totalfr = 8,
                .startline = 0,
                .endline = 2,
            },
        },
        .y_dim = .{
            .absolute = .{
                .min = find_area.ymin,
                .max = find_area.ymax,
            },
        },
    };
}

fn browse2_shape(find_area: Area) PanelShape {
    return .{
        .x_dim = .{
            .fractional = .{
                .totalfr = 8,
                .startline = 2,
                .endline = 5,
            },
        },
        .y_dim = .{
            .absolute = .{
                .min = find_area.ymin,
                .max = find_area.ymax,
            },
        },
    };
}

fn browse3_shape(find_area: Area) PanelShape {
    return .{
        .x_dim = .{
            .fractional = .{
                .totalfr = 8,
                .startline = 5,
                .endline = 8,
            },
        },
        .y_dim = .{
            .absolute = .{
                .min = find_area.ymin,
                .max = find_area.ymax,
            },
        },
    };
}
