# muzic

## TO 1.0 !!!!!!!!!!
- [ ] render highlight granular on typing find
- [ ] backspace on type
- [ ] utf handling 
    -lazily do utf8, albums on initial browser press
    -could even load the mpd response lazily
    ---TIME---
    songdata: 5
    searchable: 14
    songs: 14   -> init songdata, searchable on f, songs on b -> songs
    albums: 42
    artists: 43
- [ ] ROBUST NONBLOCK flag handling for mac
- [ ] don't break escape codes after quit
- [ ] return to original state, whatever was printed before running goes back to being visible

- [ ] space bar -> replace queue with selected
- [ ] shift arrow to seek faster

## Bugs/fixes
- [ ] render highlight granular on typing find
- [ ] escape codes stop working after quit - enter
- [ ] fix half up
- [ ] deliberate integer size choice
- [ ] More robust input debounce; I suspect, library size has an effect on mpd response speed.
- [ ] Input mode scope variables
- [ ] get rid of ALL UNNECESSARY public variables
- [ ] algorithm tweak, prioritize matches at the start of the string, for best match functions e.g. Tyler, The Creator
- [ ] algoirthm fix, EXETER failing best match
- [ ] display full album content, regardless of artist
- [ ] carefully track persistentallocator use
- [ ] Batch HOLD events on release - seeking, skipping through songs
- [ ] store only visible strings in queue
- [x] state save when return to first node
- [x] flashing could be due to unexpected flush - add empty character after content
    - A rendering layer could be added that keeps track of the lengths of the displaying to only clear what is needed.
- [x] outofbounds error in browser
- [x] next_col_ready reimplement
- [x] I think search strings has to be fixed
- [x] MEMORY LEAK suspected at 717 - input.zig
- [x] cursor on third column needs to reset
- [x] columns should be stored in an array, the same way nodes are, duh
- [x] cursor reset -- render function and save apex
- [x] scrolling horizontally works???? sometimes a bug but I can't reproduce
- [x] rewrite Browser - Describe in terms of prev, current, next
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
- [x] hold x from the top breaks
- [x] queue max_len could be runtime derived from column size in render
- [x] pause flickers the bar and timestamp
- [x] input debounce less
- [x] NUMBER FIX - program will crash if queue longer than 256
## Features 

- [ ] allow browse by files and directories - (no tags set)
- [ ] moving around in queue, visual mode?
- [x] lazy load strings
- [x] True color
- [x] X -> clear queue
- [x] browser typing
- [x] search in browser
- [x] permanent solution to queue length
- [x] queue scrolling
- [x] Browser
- [x] D -> clear from current pos to end queue
- [x] add album contents to queue
- [x] g, G top and bottom
- [x] ctrl-d , ctrl-u

- [ ] input independent of key + keymap customization
- [ ] cover art??
- [ ] get multiple of next strings in browser and cache, maybe like 10 - 20 ? 
- [ ] m to mark positio in Browser
- [ ] filter through "feat." in artist
- [ ] PLAYLIST MANIPULATION
