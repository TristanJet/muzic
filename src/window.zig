const std = @import("std");
const util = @import("util.zig");
const terminal = @import("terminal.zig");
const algoNRanked = &@import("algo.zig").nRanked;
const debug = std.debug;
const os = std.os;
const mem = std.mem;
const fs = std.fs;
const posix = std.posix;
const math = std.math;

// 12 for clock * 2 + 1 for borders
pub const MIN_WIN_WIDTH = 27;
pub const MIN_WIN_HEIGHT = 12;

const y_len_ptr: *usize = &@import("input.zig").y_len;

pub var window: Area = undefined;
pub var panels: Panels = undefined;

pub const WindowError = error{
    TooSmall,
    Ioctl,
};

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

pub fn init() WindowError!void {
    const tty = terminal.ttyFile();
    try getWindow(tty);
    panels.init(window);
    y_len_ptr.* = panels.find.validArea().ylen;
}

fn getWindow(tty: *const fs.File) WindowError!void {
    var win_size = posix.winsize{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };

    const err = posix.system.ioctl(tty.handle, posix.T.IOCGWINSZ, @intFromPtr(&win_size));
    if (posix.errno(err) == .SUCCESS) {
        if (win_size.col < MIN_WIN_WIDTH) return WindowError.TooSmall;
        if (win_size.row < MIN_WIN_HEIGHT) return WindowError.TooSmall;
        window = .{
            .xmin = 0,
            .xmax = win_size.col - 1, // Columns (width) minus 1 for zero-based indexing
            .ymin = 0,
            .ymax = win_size.row - 1, // Rows (height) minus 1 for zero-based indexing
            .xlen = win_size.col,
            .ylen = win_size.row,
        };
    } else {
        return WindowError.Ioctl;
    }
}

const Border = union(enum) {
    all: bool,
    which: WhichBorder,
};

const WhichBorder = struct {
    top: bool = false,
    right: bool = false,
    bottom: bool = false,
    left: bool = false,
};

pub const Panel = struct {
    borders: Border,
    area: Area,

    fn init(
        borders: Border,
        shape: PanelShape,
        fractionalBase: ?Area,
    ) Panel {
        var x_min: usize = undefined;
        var x_max: usize = undefined;
        var y_min: usize = undefined;
        var y_max: usize = undefined;

        switch (shape.x_dim) {
            DimType.fractional => |fractional| {
                const base = fractionalBase orelse window;
                divideFractional(&x_min, &x_max, base.xmin, base.xlen, fractional);
            },
            DimType.absolute => |absolute| {
                x_min = absolute.min;
                x_max = absolute.max;
            },
        }

        switch (shape.y_dim) {
            DimType.fractional => |fractional| {
                const base = fractionalBase orelse window;
                divideFractional(&y_min, &y_max, base.ymin, base.ylen, fractional);
            },
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

    fn divideFractional(min: *usize, max: *usize, areamin: usize, len: usize, dimensions: anytype) void {
        const unit = len / dimensions.totalfr;
        const remainder = len % dimensions.totalfr;
        min.* = (unit * dimensions.startline) + @min(dimensions.startline, remainder) + areamin;
        max.* = areamin + (unit * dimensions.endline) + @min(dimensions.endline, remainder) - 1;
        debug.assert(max.* <= areamin + len - 1);
        debug.assert(min.* >= areamin);
    }

    pub fn validArea(self: *const Panel) Area {
        var area: Area = self.area;
        switch (self.borders) {
            .all => |all| {
                if (all) {
                    area.xmin += 1;
                    area.ymax -= 1;
                    area.ymin += 1;
                    area.xmax -= 1;
                    area.xlen -= 2;
                    area.ylen -= 2;
                }
            },
            .which => |which| {
                if (which.top) {
                    area.ymin += 1;
                    area.ylen -= 1;
                }
                if (which.right) {
                    area.xmax -= 1;
                    area.xlen -= 1;
                }
                if (which.bottom) {
                    area.ymax -= 1;
                    area.ylen -= 1;
                }
                if (which.left) {
                    area.xmin += 1;
                    area.xlen -= 1;
                }
            },
        }
        return area;
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
        self.curr_song = Panel.init(.{ .all = true }, curr_song_shape(window_area), null);
        self.queue = Panel.init(.{ .all = true }, queue_shape(window_area), null);
        self.find = Panel.init(.{ .all = true }, find_shape(window_area), null);
        const find_valid = self.find.validArea();
        self.browse1 = Panel.init(.{ .which = .{ .right = true } }, browse1_shape(find_valid), find_valid);
        self.browse2 = Panel.init(.{ .which = .{ .right = true } }, browse2_shape(find_valid), find_valid);
        self.browse3 = Panel.init(.{ .all = false }, browse3_shape(find_valid), find_valid);
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
                .totalfr = 11,
                .startline = 0,
                .endline = 6,
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
                .totalfr = 11,
                .startline = 6,
                .endline = 11,
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
