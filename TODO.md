# muzic

## TO 1.0 !!!!!!!!!!
---I, Tristan Lay, will not sleep tomorrow until 1.0 is shipped!---

I, Tristan Lay will ship 1.0 on the 5th of August or else I am a **faggot** and a *loser* and I will never become a great man and I will never marry a gorgeous woman.

7th. Today is the day.

- [x] fix search
    - [x] browser search
    - [x] capitalisation in browser search
    - [x] rewrite algorithm - no longer uses allocator
- [ ] remove indefinite dynamic allocation in queue (memory leak)
    - [ ] circular buffer
- [ ] typing in higher column should have same effect as scroll, resetting later nodes

## Semi important
- [ ] return exact matches, this can be done inside the smithwaterman function
- [ ] convert all apostrophes to same, this can be done inside the smithwaterman function
- [ ] implement strict max string size at MPD level
- [ ] ROBUST NONBLOCK flag handling for mac
- [ ] set max size for memory
- [ ] fallback if TTY mode
- [ ] ROBUST check for terminal features
    - [ ] terminfo
    - [ ] return to original state, whatever was printed before running goes back to being visible
- [ ] Kitty input protocol?
- [ ] handle no mp3 tags?

## Bugs/fixes
- [ ] better error handling, I should only run the search algorithms IF there is a valid search set right, so its not the responsibility of algorithm to return error over that
- [ ] flashing in queue
- [ ] check reading terminal input, why do I read one byte at a time??
- [ ] render highlight granular on typing find
- [ ] escape codes stop working after quit - enter
- [ ] fix half up
- [ ] deliberate integer size choice
- [ ] More robust input debounce; I suspect, library size has an effect on mpd response speed.
- [ ] Input mode scope variables
- [ ] get rid of ALL UNNECESSARY public variables
- [ ] algorithm tweak, prioritize matches at the start of the string, for best match functions e.g. Tyler, The Creator
- [ ] display full album content, regardless of artist
- [ ] carefully track persistentallocator use
- [ ] Batch HOLD events on release - seeking, skipping through songs
- [ ] store only visible strings in queue
- [ ] unset apex problem on col switch l 768 in input
- [x] add a EMPTY QUEUE screen
- [x] print error message if fails to connect to MPD
- [x] invalid argument error message
- [x] parse address before mpd
- [x] render highlight granular on typing find
- [x] g, and G rendereffect only
- [x] utf handling
    - [x] fitting bytes function
    - [x] fitting the text
    - [x] highlight correctly browser
    - [x] data structure implementation
- [x] unset apex error on col switch [PATCHED]
- [x] migrate to zig 0.14
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

- [ ] infinite play without filling queue?
- [ ] allow browse by files and directories - (no tags set)
- [ ] moving around in queue, visual mode?
- [x] back takes you to beginning of song
- [x] backspace on type
- [x] shift arrow to seek faster
- [x] play all of an artists catalogue
- [x] space bar -> replace queue with selected
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
