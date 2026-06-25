# subtitles.nvim

![subtitles.nvim](images/logo-big.jpg)

Neovim plugin for editing subtitle files. Supports arbitrary encodings and
in-file timing annotations — write timing adjustments directly in the file, then
apply them all at once with a single command.

> **Format support:** currently `.srt` only. Support for additional formats
> (`.vtt`, `.ass`, `.ssa`) is planned.

---

## Installation

**[lazy.nvim](https://github.com/folke/lazy.nvim)**
```lua
{ 'saxon1964/subtitles.nvim', version = '*' }
```

**[packer.nvim](https://github.com/wbthomason/packer.nvim)**
```lua
use { 'saxon1964/subtitles.nvim', branch = 'master' }
```

**[vim-plug](https://github.com/junegunn/vim-plug)**
```vim
Plug 'saxon1964/subtitles.nvim', { 'branch': 'master', 'tag': 'v*' }
```

No configuration is required. The `:SubSync` command is available as soon as the
plugin loads.

---

## Configuration

All options have sensible defaults. Override any of them by passing a table to
`setup`:

```lua
require('subsync').setup({
  default_encoding        = 'utf-8',  -- fallback encoding for read/write/reload
  default_gap             = 80,       -- ms, used by SubSync gap when no arg given
  min_duration            = 1500,     -- ms, used by SubSync duration when no arg given
  max_duration            = 6000,     -- ms, used by SubSync duration when no arg given
  max_reading_speed       = 17,       -- chars/sec, used by SubSync info and fixspeed
  recommended_line_length = 40,       -- chars, used by SubSync wrap and info
})
```

| Option | Default | Description |
|---|---|---|
| `default_encoding` | `'utf-8'` | Encoding used by `read`/`write`/`reload` when none is specified |
| `default_gap` | `80` | Minimum gap in ms enforced by `SubSync gap` when called without an argument |
| `min_duration` | `1500` | Minimum subtitle duration in ms used by `SubSync duration` when called without arguments |
| `max_duration` | `6000` | Maximum subtitle duration in ms used by `SubSync duration` when called without arguments |
| `max_reading_speed` | `17` | Characters per second threshold above which `SubSync info` flags a subtitle as hard to read |
| `recommended_line_length` | `40` | Maximum line length used by `SubSync wrap` and reported by `SubSync info` |

---

## Commands

### `SubSync read [encoding]`

Re-reads the current buffer from disk using the specified encoding (default:
`default_encoding`), converting to UTF-8 for editing. The encoding is remembered
and reused by `SubSync write`.

```vim
:SubSync read cp1250
:SubSync read latin1
```

### `SubSync write [encoding]`

Writes the buffer to disk. Renumbers subtitle entries before saving. Uses, in order:
the encoding given here, the one remembered from `SubSync read`, or UTF-8.

```vim
:SubSync write          " uses remembered or UTF-8
:SubSync write cp1250   " explicit encoding
```

### `SubSync shift`

Applies all shift and single-subtitle annotations in the buffer, then removes them.
Interpolation annotations (`@`) are ignored and removed with a warning. Leaves a
clean, renumbered `.srt` file in the buffer.

### `SubSync shift <+/-><timespec>`

Applies a global time shift to every subtitle, ignoring and removing all annotations.

```vim
:SubSync shift +1,500    " delay everything by 1.5 s
:SubSync shift -30       " advance everything by 30 s
```

### `SubSync interpolate`

Applies interpolation annotations. Requires at least two `@` anchor points. Subtitles
between anchors are adjusted by linear interpolation; subtitles outside the outermost
anchors are extrapolated using the slope of the nearest segment.

### `SubSync interpolate strict`

Same as `SubSync interpolate`, but subtitles outside the outermost anchor points are
left unchanged.

### `SubSync duration [min_timespec] [max_timespec]`

Enforces a visibility duration window on every subtitle by adjusting end times only
— start times are never changed. Omitting either argument uses `min_duration` or
`max_duration` from config.

- If a subtitle is **shorter** than `min_timespec`, its end time is extended. If
  the next subtitle starts too soon to allow the full minimum, the end time is
  clamped to the next subtitle's start (no overlap).
- If a subtitle is **longer** than `max_timespec`, its end time is trimmed.
- Subtitles already within the window are left unchanged.

```vim
:SubSync duration 2 5        " min 2 s, max 5 s
:SubSync duration 1,500 4    " min 1.5 s, max 4 s
```

### `SubSync gap [timespec]`

Ensures a minimum gap between every consecutive pair of subtitles by trimming end
times only — start times are never changed. Omitting the argument uses
`default_gap` from config.

- If the gap between entry N's end and entry N+1's start is smaller than `timespec`,
  entry N's end time is trimmed to `next.start − timespec`.
- If trimming would reduce the subtitle's duration to zero or below, that entry is
  left unchanged and reported.
- Use `0` to fix overlaps without adding any extra space.

```vim
:SubSync gap 0,080     " enforce 80 ms minimum gap
:SubSync gap 0         " fix overlaps only
```

### `SubSync reload`

Re-reads the current buffer from disk, discarding all unsaved changes. Uses the
encoding remembered from the last `SubSync read`, or UTF-8 if none was set.
Equivalent to `:e!` but encoding-aware.

### `SubSync fixspeed [chars_per_sec]`

Extends end times of subtitles that exceed the reading speed threshold. Uses
`max_reading_speed` from config if no argument is given.

- End time is set to `start + char_count / chars_per_sec`.
- If that would overlap the next subtitle, end time is clamped to the next
  subtitle's start (zero gap — readability takes priority over spacing).
- Start times are never changed. HTML tags are excluded from the character count.

```vim
:SubSync fixspeed        " uses max_reading_speed from config
:SubSync fixspeed 20     " override to 20 chars/sec
```

### `SubSync jump <N>`

Moves the cursor to the sequence-number line of subtitle `N`. Useful for
navigating directly to a subtitle flagged by `SubSync info`.

```vim
:SubSync jump 42
```

### `SubSync info`

Opens a read-only scratch split summarising the current file. Shows the active
limits and a count of subtitles violating each one:

- Too short / too long (vs. `min_duration` / `max_duration`)
- Gap too small / overlapping (vs. `default_gap`)
- Too fast to read (vs. `max_reading_speed`) — sequence numbers listed
- Out of order — sequence numbers listed
- Line too long (vs. `recommended_line_length`) — sequence numbers listed

Press `q` to close the info window. Press `Enter` on any line containing a
subtitle number (e.g. `#42`) to jump directly to that subtitle in the main
buffer.

### `SubSync sort`

Reorders subtitle entries by start time (ascending) and renumbers them. Useful
after manually inserting entries out of order. No-op if already sorted.

### `SubSync merge [N]`

Merges subtitle `N` (or the subtitle under the cursor) with the immediately
following entry. Keeps the current entry's start time and the next entry's end
time; text lines are concatenated.

```vim
:SubSync merge      " merge subtitle under cursor with the next
:SubSync merge 42   " merge subtitle #42 with #43
```

### `SubSync split [N]`

Splits subtitle `N` (or the subtitle under the cursor) into two consecutive
entries, dividing the duration at the midpoint. When using the cursor, text is
split at the cursor line; otherwise text is divided in half.

```vim
:SubSync split      " split subtitle under cursor at cursor line
:SubSync split 42   " split subtitle #42 at text midpoint
```

### `SubSync dup [N]`

Inserts a copy of subtitle `N` immediately after it with identical timing and
text. If `N` is omitted, duplicates the subtitle under the cursor. Useful as a
starting point when adding a nearby subtitle with similar content.

```vim
:SubSync dup      " duplicate subtitle under cursor
:SubSync dup 42   " duplicate subtitle #42
```

### `SubSync wrap [N]`

Rebalances over-long text lines in subtitle `N`, or the subtitle under the cursor
if `N` is omitted.

Text is split into paragraphs at lines whose first non-space character is `-` or
`—`. Each paragraph is handled independently:

- A paragraph where all lines are within `recommended_line_length` is left
  **exactly as-is** — intentional line breaks are preserved.
- A paragraph with at least one long line has its words rejoined and re-wrapped
  greedily to fit within `recommended_line_length`. A leading `-`/`—` on the
  first line of a paragraph is preserved.

Use `SubSync info` to find which subtitles need attention.

```vim
:SubSync wrap      " rebalance subtitle under cursor
:SubSync wrap 42   " rebalance subtitle #42
```

### `SubSync clean`

Removes all annotations without changing any timings or renumbering.

---

## Time specification

Used wherever a duration or absolute time is needed.

**Format:** `[HH:][MM:]SS[,mmm]`

Hours and minutes may be omitted (rightmost fields take precedence). Leading zeroes
are allowed. Milliseconds are optional.

| Input | Meaning |
|---|---|
| `5` | 5 seconds |
| `125,243` | 2 min 5 s 243 ms |
| `1:23,45` | 1 min 23 s 45 ms |
| `74:23,552` | 1 h 14 min 23 s 552 ms |
| `02:12:23,345` | 2 h 12 min 23 s 345 ms |
| `1:0:0` | 1 hour |

---

## Annotations

Annotations are written directly on the subtitle number line, separated by a space:

```
15 +2,500
00:02:29,166 --> 00:02:30,165
You don't think
there's a difference
```

All annotations are removed after `shift`, `interpolate`, or `clean` runs.

Subtitle sequence numbers do not need to be correct while editing — a placeholder
like `#` is fine. Renumbering happens automatically on every `shift`, `interpolate`,
and `write`.

### Cascading shift

Affects the annotated subtitle and all subsequent ones, until the next directive.
Placing `+` or `-` on the very first subtitle is equivalent to a global shift.

| Annotation | Effect |
|---|---|
| `+<timespec>` | Add `timespec` from here onward |
| `-<timespec>` | Subtract `timespec` from here onward |

### Single-subtitle

Affects only the annotated subtitle.

| Annotation | Effect |
|---|---|
| `=<timespec>` | Set start time; preserve duration |
| `+=<timespec>` | Add `timespec` to both start and end |
| `-=<timespec>` | Subtract `timespec` from both start and end |

### Interpolation anchors

Define fixed points for `SubSync interpolate`. At least two are required.

| Annotation | Effect |
|---|---|
| `@<timespec>` | Set start time to absolute `timespec` |
| `@+<timespec>` | Set start time to current + `timespec` |
| `@-<timespec>` | Set start time to current − `timespec` |

**Example:** anchors at entries #10, #20, and #80 define two segments. Entries
between them are interpolated; entries outside are extrapolated (or left alone in
`strict` mode).

---

## Encoding support

`SubSync read` and `SubSync write` accept any encoding name recognised by the
system's `iconv` library. Common values:

| Encoding | Use case |
|---|---|
| `utf-8` | Default |
| `cp1250` | Windows Central European (Croatian, Polish, Czech…) |
| `cp1251` | Windows Cyrillic |
| `cp1252` | Windows Western European |
| `latin1` | ISO-8859-1 |
| `latin2` | ISO-8859-2 |

To check available encodings on your system: `iconv -l`

---

## Typical workflow

```vim
" 1. Open a mis-encoded file
:e Pressure.srt
:SubSync read cp1250        " re-read and decode properly

" 2. Check timings — subtitles are ~2 s behind from entry 40 onward
" Add annotations in the buffer:
"   40 +2,000
"   (everything from #40 on gets +2 s)

" 3. Apply
:SubSync shift

" 4. Save back in the original encoding
:SubSync write cp1250
```

---

## License

MIT
