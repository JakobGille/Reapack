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

### Auto Mute Invisible Tracks (CPU Saver)

Automatically mutes tracks that are scrolled out of the visible arrangement
area and switches off the FX chain of muted tracks (the real CPU lever, since
REAPER keeps processing FX of muted tracks). When a track becomes visible
again, its original mute state is restored after a short debounce. Requires
the js_ReaScriptAPI extension for full functionality (visibility detection);
without it, only the "FX follows mute" rule stays active.

### Project Time Tracker (Scalable UI, Edit Mode & Monthly Heatmap)

Tracks active project working time based on audio playback, recording, mouse
movement (strictly restricted to REAPER foreground/windows), and project state
changes. Features a scalable UI, manual time editing, per-plugin time
tracking, and a GitHub-style monthly activity heatmap with day inspector.
All data is stored in the project (.rpp), so it travels with the project.

## Installation

### Via ReaPack (recommended)

Import this repository in REAPER (Extensions → ReaPack → Manage repositories
→ Import…) with the URL:

    https://github.com/JakobGille/ReaPack/raw/master/index.xml

Then install the packages from the "Tracks" and "Utility" categories in the
package browser.

### Manually

1. Download `Tracks/CreateTracksUnderParentFolder.lua`
2. Copy it into REAPER's Scripts folder (Options → Show REAPER resource path
   in explorer/finder → Scripts)
3. Actions → Show action list → New action… → Load ReaScript…

## Requirements

- REAPER with ReaPack (for the ReaPack installation method)
- [js_ReaScriptAPI](https://github.com/ReaTeam/Extensions) is required for
  "Auto Mute Invisible Tracks" (visibility detection) and recommended for
  "Project Time Tracker" (foreground window detection). Installable via
  ReaPack from the "ReaTeam Extensions" repository.

## License

MIT — see [LICENSE](LICENSE).
