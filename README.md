# Jakob Gille Scripts (REAPER ReaPack Repository)

A ReaPack repository with REAPER ReaScripts.

## Packages

### Create Tracks Under Parent Folder (Per-Channel Routing)

Creates a new parent folder track at the end of the track list with N child
tracks underneath it (N is entered by the user). Every child track uses its
native parent send to reach its own parent channel:

- Child 1: channel 1 → parent channel 1
- Child 2: channel 1 → parent channel 2
- Child 3: channel 1 → parent channel 3
- ...

The parent track gets the user-selected channel count and forwards all of its
channels 1..N to the master channels 1..N through its own main send. Child
tracks are plain stereo (2-channel) tracks, independent of the project default
track channel count. Everything is wrapped in a single undo block, so one
Ctrl+Z removes the complete structure again.

## Installation

### Via ReaPack (recommended)

Import this repository in REAPER (Extensions → ReaPack → Manage repositories
→ Import…) with the URL:

    https://github.com/USERNAME/ReaPack/raw/master/index.xml

(Replace USERNAME with your GitHub user name before publishing.)

Then install the package "Create Tracks Under Parent Folder" from the
"Tracks" category in the package browser.

### Manually

1. Download `Tracks/CreateTracksUnderParentFolder.lua`
2. Copy it into REAPER's Scripts folder (Options → Show REAPER resource path
   in explorer/finder → Scripts)
3. Actions → Show action list → New action… → Load ReaScript…

## Requirements

- REAPER with ReaPack (for the ReaPack installation method)
- A recent REAPER version is recommended. On REAPER versions that do not
  accept multichannel/mono main sends, the script automatically falls back
  to explicit mono sends and prints a note to the console.

## License

MIT — see [LICENSE](LICENSE).
