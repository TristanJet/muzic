# muzic

**A snappy, lightweight terminal client for MPD written in Zig with vim-keybindings and fuzzy-finding.**

## Features
 - Queue manipulation
 - Fuzzy find through entire song library
 - Music browser for manual browsing

## Installation and Usage
Muzig currently only works on linux.

To build muzic you need **Zig 0.13** installed

```bash
zig build -Doptimize=ReleaseFast
```

A running [mpd](https://github.com/MusicPlayerDaemon/MPD) instance will be required. The default host and port are 127.0.0.1:6600. The port and host can be specified as so:

```bash
muzic -H "127.0.0.1" -p 6600
```

muzic is requires NO external dependencies other than the Zig standard library, which comes with the Zig binary.

muzic's memory footprint will be directly correlated to the number of songs in your library but you can expect to be around 1MB per 1000 songs.

## Keybinds

**normal queue**
| key   | action    |
|---    |---        |
| q     | quit      |
| k     | cursor up        |
| j     | cursor down      |
| Ctrl+U     | cursor up half queue      |
| Ctrl+D     | cursor down half queue      |
| g     | go top      |
| G     | go bottom      |
| h     | prev song      |
| l     | next song      |
| ENTER     | play selected song      |
| x     | delete from queue      |
| X     | clear queue      |
| D     | clear till end      |
| p     | pause/play      |
| left     | seek -5      |
| right     | seek +5      |
| up     | increase volume      |
| up     | decrease volume      |
| f     | switch to fuzzy find      |
| b     | switch to browser      |

**fuzzy find**
| key   | action    |
|---    |---        |
| ESC     | return to normal queue      |
| Ctrl+U     | cursor up      |
| Ctrl+D     | cursor down      |
| ENTER     | add song to queue      |
| *rest*     |  type      |

**browser**
| key   | action    |
|---    |---        |
| ESC     | return to normal queue      |
| k     | cursor up        |
| j     | cursor down      |
| Ctrl+U     | cursor up half queue      |
| Ctrl+D     | cursor down half queue      |
| g     | go top      |
| G     | go bottom      |
| h     | prev column      |
| l     | next column      |
| ENTER     | add song/album to queue      |
| /     | search in column      |
| ENTER *while searching    | exit search |
| ESC *while searching   | exit search |
