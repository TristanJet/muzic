const std = @import("std");
const util = @import("util.zig");
const os = std.os;
const mem = std.mem;
const fs = std.fs;

pub var window: Area = undefined;

const Area = struct {
    xmin: usize,
    xmax: usize,
    ymin: usize,
    ymax: usize,
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

pub fn getWindow(tty: *fs.File) !void {
    var win_size = mem.zeroes(os.linux.winsize);
    const err = os.linux.ioctl(tty.handle, os.linux.T.IOCGWINSZ, @intFromPtr(&win_size));
    if (std.posix.errno(err) != .SUCCESS) {
        return std.posix.unexpectedErrno(os.linux.E.init(err));
    }
    window = .{
        .xmin = 0,
        .xmax = win_size.ws_col - 1, // Columns (width) minus 1 for zero-based indexing
        .ymin = 0,
        .ymax = win_size.ws_row - 1, // Rows (height) minus 1 for zero-based indexing
    };
}

pub const Panel = struct {
    borders: bool,
    xmin: usize,
    xmax: usize,
    ymin: usize,
    ymax: usize,
    xlen: usize,
    ylen: usize,

    pub fn init(borders: bool, x: Dim, y: Dim) Panel {
        var x_min: usize = undefined;
        var x_max: usize = undefined;
        var y_min: usize = undefined;
        var y_max: usize = undefined;

        switch (x) {
            DimType.fractional => |fractional| divideFractional(&x_min, &x_max, window.xmin, window.xmax, fractional),
            DimType.absolute => |absolute| {
                x_min = absolute.min;
                x_max = absolute.max;
            },
        }

        switch (y) {
            DimType.fractional => |fractional| divideFractional(&y_min, &y_max, window.ymin, window.ymax, fractional),
            DimType.absolute => |absolute| {
                y_min = absolute.min;
                y_max = absolute.max;
            },
        }

        const x_len = x_max - x_min + 1;
        const y_len = y_max - y_min + 1;
        util.log("xlen: {}", .{x_len});

        return .{
            .borders = borders,
            .xmin = x_min,
            .xmax = x_max,
            .ymin = y_min,
            .ymax = y_max,
            .xlen = x_len,
            .ylen = y_len,
        };
    }

    fn divideFractional(min: *usize, max: *usize, areamin: usize, areamax: usize, dimensions: anytype) void {
        const unit = (areamax - areamin + 1) / dimensions.totalfr;
        const remainder = (areamax + 1) % dimensions.totalfr;
        min.* = (unit * dimensions.startline) + @min(dimensions.startline, remainder) + areamin;
        max.* = (unit * dimensions.endline) + @min(dimensions.endline, remainder) - 1;
    }

    pub fn validArea(self: Panel) struct {
        xmin: usize,
        xmax: usize,
        xlen: usize,
        ymin: usize,
        ymax: usize,
        ylen: usize,
    } {
        if (self.borders) {
            return .{
                .xmin = self.xmin + 1,
                .xmax = self.xmax - 1,
                .ymin = self.ymin + 1,
                .ymax = self.ymax - 1,
                .xlen = self.xlen - 2,
                .ylen = self.ylen - 2,
            };
        } else {
            return .{
                .xmin = self.xmin,
                .xmax = self.xmax,
                .ymin = self.ymin,
                .ymax = self.ymax,
                .xlen = self.xlen,
                .ylen = self.ylen,
            };
        }
    }

    pub fn getYCentre(self: Panel) usize {
        return self.ymin + (self.ymax - self.ymin) / 2;
    }

    pub fn getXCentre(self: Panel) usize {
        return self.xmin + (self.xmax - self.xmin) / 2;
    }
};
