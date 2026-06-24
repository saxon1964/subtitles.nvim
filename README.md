# subtitles.nvim

Neovim plugin for editing `.srt` subtitle files. Supports arbitrary encodings and
in-file timing annotations — write timing adjustments directly in the file, then
apply them all at once with a single command.

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
  default_encoding  = 'utf-8',  -- fallback encoding for read/write/reload
  default_gap       = 80,       -- ms, used by SubSync gap when no arg given
  min_duration      = 1500,     -- ms, used by SubSync length when no arg given
  max_duration      = 6000,     -- ms, used by SubSync length when no arg given
  max_reading_speed = 17,       -- chars/sec, used by SubSync info
})
```

| Option | Default | Description |
|---|---|---|
| `default_encoding` | `'utf-8'` | Encoding used by `read`/`write`/`reload` when none is specified |
| `default_gap` | `80` | Minimum gap in ms enforced by `SubSync gap` when called without an argument |
| `min_duration` | `1500` | Minimum subtitle duration in ms used by `SubSync length` when called without arguments |
| `max_duration` | `6000` | Maximum subtitle duration in ms used by `SubSync length` when called without arguments |
| `max_reading_speed` | `17` | Characters per second threshold above which `SubSync info` flags a subtitle as hard to read |

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

### `SubSync length [min_timespec] [max_timespec]`

Enforces a visibility duration window on every subtitle by adjusting end times only
— start times are never changed. Omitting either argument uses `min_duration` or
`max_duration` from config.

- If a subtitle is **shorter** than `min_timespec`, its end time is extended. If
  the next subtitle starts too soon to allow the full minimum, the end time is
  clamped to the next subtitle's start (no overlap).
- If a subtitle is **longer** than `max_timespec`, its end time is trimmed.
- Subtitles already within the window are left unchanged.

```vim
:SubSync length 2 5        " min 2 s, max 5 s
:SubSync length 1,500 4    " min 1.5 s, max 4 s
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

### `SubSync info`

Opens a read-only scratch split summarising the current file. Shows the active
limits and a count of subtitles violating each one:

- Too short / too long (vs. `min_duration` / `max_duration`)
- Gap too small / overlapping (vs. `default_gap`)
- Too fast to read (vs. `max_reading_speed`) — sequence numbers listed
- Out of order — sequence numbers listed

Press `q` to close the info window.

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
