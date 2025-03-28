# MUZIG

## CURRENT
- [ ] rewrite Browser

## Bugs/Fixes
- [x] MAC BLOCK TERMINAL WRITES
- [x] key release event
- [x] get the uris for all_songs
- [ ] handle utf-16 when rendering cursor
- [ ] display full album content, regardless of artist
- [ ] sometimes cursor doesn't display after switching horizontally
- [ ] don't let switch column before correct song item displaying
- [x] alphabetical order all_songs
- [ ] const pointer retrieved at START of handle (should fix the weird cursor rendering issue)
- [ ] Batch HOLD events on release
- [ ] More robust input debounce; I suspect, library size has an effect on mpd response speed.
- [ ] hold x from the top breaks
- [ ] pause flickers the bar and timestamp
- [ ] Don't render if cursor doesn't move
- [ ] don't render queue on seek?

## Features 
- [ ] search in browser
- [ ] Browser
- [ ] m to mark positio in Browser
- [ ] filter through "feat." in artist
- [ ] dd -> clear queue
- [ ] D -> clear from current pos to end queue
- [ ] True color
- [ ] shift arrow to seek faster
- [ ] return to original state, whatever was printed before running goes back to being visible
- [ ] cover art??
