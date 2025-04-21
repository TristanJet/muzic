const state = @import("state.zig");
const term = @import("terminal.zig");
const RenderState = @import("input.zig").RenderState;

pub fn handleNormalBrowse(char: u8, app: *state.State, render_state: *RenderState) !void {
    _ = render_state;
    switch (char) {
        'q' => app.quit = true,
        '\x1B' => {},
        'j' => {},
        'k' => {},
        // 'd' & '\x1F' => halfDown(app, render_state),
        // 'u' & '\x1F' => halfUp(app, render_state),
        // 'g' => goTop(app, render_state),
        // 'G' => goBottom(app, render_state),
        'h' => {},
        'l' => {},
        '/' => {},
        '\n', '\r' => {},
        else => return,
    }
}

fn nextNode() !void {}
