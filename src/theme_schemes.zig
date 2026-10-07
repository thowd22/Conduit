//! The colour schemes Conduit ships, as compile-time data.
//!
//! Every value is copied exactly from the scheme's Ghostty theme file in the
//! iTerm2-Color-Schemes collection (MIT, Mark Badolato), the collection Ghostty
//! itself bundles; each entry names that file and the scheme's own project.
//! `assets/themes/README.md` records the licences. `conduit-dark` is Conduit's
//! own default and is first so an empty `theme` setting resolves to it.

const theme = @import("theme.zig");

const Bundled = theme.Bundled;
const hex = theme.Color.hex;

/// Conduit's built-in default: the palette every release before TASK-38 drew
/// with, unchanged.
pub const conduit_dark: theme.Scheme = .{
    .ansi = .{
        hex(0x1a1c24), hex(0xcc5555), hex(0x7fb874), hex(0xd6b055),
        hex(0x617fd4), hex(0xb47ad0), hex(0x56b6c2), hex(0xc8c8d2),
        hex(0x4a4f5c), hex(0xe06c6c), hex(0x9ad08c), hex(0xecc86a),
        hex(0x7c9ce8), hex(0xd092e4), hex(0x6cccd6), hex(0xf0f0f6),
    },
    .foreground = hex(0xd8d8e0),
    .background = hex(0x161a22),
    .cursor = hex(0xd8d8e0),
    .selection_background = hex(0x2c3a4d),
};

/// Every bundled scheme, in the order the picker lists them before sorting.
pub const all = [_]Bundled{
    .{ .id = "conduit-dark", .label = "Conduit Dark", .scheme = conduit_dark },
    // Gruvbox Dark: https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/ghostty/Gruvbox%20Dark
    // Scheme project: https://github.com/morhetz/gruvbox (MIT/X11).
    .{ .id = "gruvbox-dark", .label = "Gruvbox Dark", .scheme = .{
        .ansi = .{
            hex(0x282828), hex(0xcc241d), hex(0x98971a), hex(0xd79921),
            hex(0x458588), hex(0xb16286), hex(0x689d6a), hex(0xa89984),
            hex(0x928374), hex(0xfb4934), hex(0xb8bb26), hex(0xfabd2f),
            hex(0x83a598), hex(0xd3869b), hex(0x8ec07c), hex(0xebdbb2),
        },
        .foreground = hex(0xebdbb2),
        .background = hex(0x282828),
        .cursor = hex(0xebdbb2),
        .cursor_text = hex(0x282828),
        .selection_background = hex(0x665c54),
        .selection_foreground = hex(0xebdbb2),
    } },
    // Gruvbox Light: https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/ghostty/Gruvbox%20Light
    // Scheme project: https://github.com/morhetz/gruvbox (MIT/X11).
    .{ .id = "gruvbox-light", .label = "Gruvbox Light", .scheme = .{
        .ansi = .{
            hex(0xfbf1c7), hex(0xcc241d), hex(0x98971a), hex(0xd79921),
            hex(0x458588), hex(0xb16286), hex(0x689d6a), hex(0x7c6f64),
            hex(0x928374), hex(0x9d0006), hex(0x79740e), hex(0xb57614),
            hex(0x076678), hex(0x8f3f71), hex(0x427b58), hex(0x3c3836),
        },
        .foreground = hex(0x3c3836),
        .background = hex(0xfbf1c7),
        .cursor = hex(0x3c3836),
        .cursor_text = hex(0xfbf1c7),
        .selection_background = hex(0x3c3836),
        .selection_foreground = hex(0xfbf1c7),
    } },
    // Catppuccin Mocha: https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/ghostty/Catppuccin%20Mocha
    // Scheme project: https://github.com/catppuccin/catppuccin (MIT).
    .{ .id = "catppuccin-mocha", .label = "Catppuccin Mocha", .scheme = .{
        .ansi = .{
            hex(0x45475a), hex(0xf38ba8), hex(0xa6e3a1), hex(0xf9e2af),
            hex(0x89b4fa), hex(0xf5c2e7), hex(0x94e2d5), hex(0xbac2de),
            hex(0x585b70), hex(0xf7aec2), hex(0xc2ecbf), hex(0xfcd682),
            hex(0xaeccfc), hex(0xf398da), hex(0xb1eae1), hex(0xa6adc8),
        },
        .foreground = hex(0xcdd6f4),
        .background = hex(0x1e1e2e),
        .cursor = hex(0xf5e0dc),
        .cursor_text = hex(0x1e1e2e),
        .selection_background = hex(0xf5e0dc),
        .selection_foreground = hex(0x1e1e2e),
    } },
    // Catppuccin Latte: https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/ghostty/Catppuccin%20Latte
    // Scheme project: https://github.com/catppuccin/catppuccin (MIT).
    .{ .id = "catppuccin-latte", .label = "Catppuccin Latte", .scheme = .{
        .ansi = .{
            hex(0xbcc0cc), hex(0xd20f39), hex(0x40a02b), hex(0xdf8e1d),
            hex(0x1e66f5), hex(0xea76cb), hex(0x179299), hex(0x5c5f77),
            hex(0xacb0be), hex(0xe7103f), hex(0x46b02f), hex(0xe49931),
            hex(0x3878f6), hex(0xef95d7), hex(0x19a1a8), hex(0x6c6f85),
        },
        .foreground = hex(0x4c4f69),
        .background = hex(0xeff1f5),
        .cursor = hex(0xdc8a78),
        .cursor_text = hex(0xeff1f5),
        .selection_background = hex(0xdc8a78),
        .selection_foreground = hex(0xeff1f5),
    } },
    // Dracula: https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/ghostty/Dracula
    // Scheme project: https://github.com/dracula/dracula-theme (MIT).
    .{ .id = "dracula", .label = "Dracula", .scheme = .{
        .ansi = .{
            hex(0x21222c), hex(0xff5555), hex(0x50fa7b), hex(0xf1fa8c),
            hex(0xbd93f9), hex(0xff79c6), hex(0x8be9fd), hex(0xf8f8f2),
            hex(0x6272a4), hex(0xff6e6e), hex(0x69ff94), hex(0xffffa5),
            hex(0xd6acff), hex(0xff92df), hex(0xa4ffff), hex(0xffffff),
        },
        .foreground = hex(0xf8f8f2),
        .background = hex(0x282a36),
        .cursor = hex(0xf8f8f2),
        .cursor_text = hex(0x282a36),
        .selection_background = hex(0x44475a),
        .selection_foreground = hex(0xffffff),
    } },
    // Nord: https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/ghostty/Nord
    // Scheme project: https://github.com/nordtheme/nord (MIT).
    .{ .id = "nord", .label = "Nord", .scheme = .{
        .ansi = .{
            hex(0x3b4252), hex(0xbf616a), hex(0xa3be8c), hex(0xebcb8b),
            hex(0x81a1c1), hex(0xb48ead), hex(0x88c0d0), hex(0xe5e9f0),
            hex(0x596377), hex(0xbf616a), hex(0xa3be8c), hex(0xebcb8b),
            hex(0x81a1c1), hex(0xb48ead), hex(0x8fbcbb), hex(0xeceff4),
        },
        .foreground = hex(0xd8dee9),
        .background = hex(0x2e3440),
        .cursor = hex(0xeceff4),
        .cursor_text = hex(0x282828),
        .selection_background = hex(0xeceff4),
        .selection_foreground = hex(0x4c566a),
    } },
    // Tokyo Night: https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/ghostty/TokyoNight
    // Scheme project: https://github.com/folke/tokyonight.nvim (Apache-2.0).
    .{ .id = "tokyo-night", .label = "Tokyo Night", .scheme = .{
        .ansi = .{
            hex(0x15161e), hex(0xf7768e), hex(0x9ece6a), hex(0xe0af68),
            hex(0x7aa2f7), hex(0xbb9af7), hex(0x7dcfff), hex(0xa9b1d6),
            hex(0x414868), hex(0xf7768e), hex(0x9ece6a), hex(0xe0af68),
            hex(0x7aa2f7), hex(0xbb9af7), hex(0x7dcfff), hex(0xc0caf5),
        },
        .foreground = hex(0xc0caf5),
        .background = hex(0x1a1b26),
        .cursor = hex(0xc0caf5),
        .cursor_text = hex(0x15161e),
        .selection_background = hex(0x33467c),
        .selection_foreground = hex(0xc0caf5),
    } },
    // Solarized Dark: https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/ghostty/iTerm2%20Solarized%20Dark
    // Scheme project: https://github.com/altercation/solarized (MIT).
    .{ .id = "solarized-dark", .label = "Solarized Dark", .scheme = .{
        .ansi = .{
            hex(0x073642), hex(0xdc322f), hex(0x859900), hex(0xb58900),
            hex(0x268bd2), hex(0xd33682), hex(0x2aa198), hex(0xeee8d5),
            hex(0x335e69), hex(0xcb4b16), hex(0x586e75), hex(0x657b83),
            hex(0x839496), hex(0x6c71c4), hex(0x93a1a1), hex(0xfdf6e3),
        },
        .foreground = hex(0x839496),
        .background = hex(0x002b36),
        .cursor = hex(0x839496),
        .cursor_text = hex(0x073642),
        .selection_background = hex(0x073642),
        .selection_foreground = hex(0x93a1a1),
    } },
    // Solarized Light: https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/ghostty/iTerm2%20Solarized%20Light
    // Scheme project: https://github.com/altercation/solarized (MIT).
    .{ .id = "solarized-light", .label = "Solarized Light", .scheme = .{
        .ansi = .{
            hex(0x073642), hex(0xdc322f), hex(0x859900), hex(0xb58900),
            hex(0x268bd2), hex(0xd33682), hex(0x2aa198), hex(0xbbb5a2),
            hex(0x002b36), hex(0xcb4b16), hex(0x586e75), hex(0x657b83),
            hex(0x839496), hex(0x6c71c4), hex(0x93a1a1), hex(0xfdf6e3),
        },
        .foreground = hex(0x657b83),
        .background = hex(0xfdf6e3),
        .cursor = hex(0x657b83),
        .cursor_text = hex(0xeee8d5),
        .selection_background = hex(0xeee8d5),
        .selection_foreground = hex(0x586e75),
    } },
    // One Dark: https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/ghostty/Atom%20One%20Dark
    // Scheme project: https://github.com/atom/one-dark-syntax (MIT).
    .{ .id = "one-dark", .label = "One Dark", .scheme = .{
        .ansi = .{
            hex(0x21252b), hex(0xe06c75), hex(0x98c379), hex(0xe5c07b),
            hex(0x61afef), hex(0xc678dd), hex(0x56b6c2), hex(0xabb2bf),
            hex(0x767676), hex(0xe06c75), hex(0x98c379), hex(0xe5c07b),
            hex(0x61afef), hex(0xc678dd), hex(0x56b6c2), hex(0xabb2bf),
        },
        .foreground = hex(0xabb2bf),
        .background = hex(0x21252b),
        .cursor = hex(0xabb2bf),
        .cursor_text = hex(0x21252b),
        .selection_background = hex(0x323844),
        .selection_foreground = hex(0xabb2bf),
    } },
    // Kanagawa Wave: https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/ghostty/Kanagawa%20Wave
    // Scheme project: https://github.com/rebelot/kanagawa.nvim (MIT).
    .{ .id = "kanagawa-wave", .label = "Kanagawa Wave", .scheme = .{
        .ansi = .{
            hex(0x090618), hex(0xc34043), hex(0x76946a), hex(0xc0a36e),
            hex(0x7e9cd8), hex(0x957fb8), hex(0x6a9589), hex(0xc8c093),
            hex(0x727169), hex(0xe82424), hex(0x98bb6c), hex(0xe6c384),
            hex(0x7fb4ca), hex(0x938aa9), hex(0x7aa89f), hex(0xdcd7ba),
        },
        .foreground = hex(0xdcd7ba),
        .background = hex(0x1f1f28),
        .cursor = hex(0xdcd7ba),
        .cursor_text = hex(0x1f1f28),
        .selection_background = hex(0xdcd7ba),
        .selection_foreground = hex(0x1f1f28),
    } },
    // Everforest Dark: https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/ghostty/Everforest%20Dark%20Med
    // Scheme project: https://github.com/sainnhe/everforest (MIT).
    .{ .id = "everforest-dark", .label = "Everforest Dark", .scheme = .{
        .ansi = .{
            hex(0x7a8478), hex(0xe67e80), hex(0xa7c080), hex(0xdbbc7f),
            hex(0x7fbbb3), hex(0xd699b6), hex(0x83c092), hex(0xf2efdf),
            hex(0xa6b0a0), hex(0xf85552), hex(0x8da101), hex(0xdfa000),
            hex(0x3a94c5), hex(0xdf69ba), hex(0x35a77c), hex(0xfffbef),
        },
        .foreground = hex(0xd3c6aa),
        .background = hex(0x232a2e),
        .cursor = hex(0xe69875),
        .cursor_text = hex(0x543a48),
        .selection_background = hex(0x543a48),
        .selection_foreground = hex(0xd3c6aa),
    } },
    // Rosé Pine: https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/ghostty/Rose%20Pine
    // Scheme project: https://github.com/rose-pine/rose-pine-theme (MIT).
    .{ .id = "rose-pine", .label = "Rosé Pine", .scheme = .{
        .ansi = .{
            hex(0x26233a), hex(0xeb6f92), hex(0x31748f), hex(0xf6c177),
            hex(0x9ccfd8), hex(0xc4a7e7), hex(0xebbcba), hex(0xe0def4),
            hex(0x6e6a86), hex(0xeb6f92), hex(0x31748f), hex(0xf6c177),
            hex(0x9ccfd8), hex(0xc4a7e7), hex(0xebbcba), hex(0xe0def4),
        },
        .foreground = hex(0xe0def4),
        .background = hex(0x191724),
        .cursor = hex(0xe0def4),
        .cursor_text = hex(0x191724),
        .selection_background = hex(0x403d52),
        .selection_foreground = hex(0xe0def4),
    } },
};
