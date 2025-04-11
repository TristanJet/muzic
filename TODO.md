# MUZIG

## CURRENT
- [ ] space bar -> replace queue with selected
- [ ] X -> clear queue
- [ ] ctrl-d , ctrl-u
- [ ] g, G top and bottom

## Bugs/Fixes
- [x] MAC BLOCK TERMINAL WRITES
- [x] key release event
- [x] get the uris for all_songs
- [x] handle column state based on type
- [x] alphabetical order all_songs
- [x] algorithm rewrite, take ITEMS as argument
- [x] NoSongs error, the find object probably being mishandled
- [x] don't let switch column before correct song item displaying
- [x] weird bug where highlight didn't update on normal queue
- [x] removing bugs on delete
- [ ] algorithm tweak, prioritize matches at the start of the string, for best match functions e.g. Tyler, The Creator
- [ ] algoirthm fix, EXETER failing best match
- [ ] display full album content, regardless of artist
- [ ] sometimes cursor doesn't display after switching horizontally
- [ ] const pointer retrieved at START of handle (should fix the weird cursor rendering issue)
- [ ] Batch HOLD events on release
- [ ] More robust input debounce; I suspect, library size has an effect on mpd response speed.
- [ ] hold x from the top breaks
- [ ] get rid of ALL UNNECESSARY public variables
- [ ] rewrite Browser - Describe in terms of prev, current, next
- [ ] MEMORY LEAK suspected at 717 - input.zig
- [ ] carefully track persistentallocator use
- [ ] NUMBER FIX - program will crash if queue longer than 256

- [x] queue max_len could be runtime derived from column size in render
- [ ] handle utf-16 when rendering highlight
- [ ] pause flickers the bar and timestamp
- [ ] Don't render if cursor doesn't move
- [ ] don't render queue on seek?

## Features 
**V1**
- [x] browser typing
- [x] search in browser
- [x] permanent solution to queue length
- [x] queue scrolling
- [x] Browser
- [x] D -> clear from current pos to end queue
- [x] add album contents to queue
- [ ] moving around in queue, visual mode?
- [ ] True color
- [ ] shift arrow to seek faster
- [ ] return to original state, whatever was printed before running goes back to being visible

- [ ] cover art??
- [ ] get multiple of next strings in browser and cache, maybe like 10 - 20 ? 
- [ ] m to mark positio in Browser
- [ ] filter through "feat." in artist
- [ ] PLAYLIST MANIPULATION
