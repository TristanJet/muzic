# muzic

**A snappy, lightweight terminal client for MPD written in Zig with vim-keybindings and fuzzy-finding.**

## Features
 - Queue manipulation
 - Fuzzy find through entire song library
 - Music browser for manual browsing

## Installation and Usage
To build muzic you need **Zig 0.13** installed

```bash
zig build -Doptimize=ReleaseFast
```

muzic is requires NO external dependencies other than the Zig standard library, which comes with the Zig binary.

muzic's memory footprint will be directly correlated to the number of songs in your library but you can expect to be around 1MB per 1000 songs.
