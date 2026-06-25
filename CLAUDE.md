# SubSync — Neovim Subtitle Editor Plugin

A Neovim plugin (Lua) for editing `.srt` subtitle files, with encoding support and in-file timing annotations.

**Core capabilities:**
- Open/re-read `.srt` files with arbitrary encodings
- Edit subtitle text, add or delete entries (auto-renumbered on write)
- Annotate subtitle entries with timing directives and execute them as batch operations
- Save using the original or a specified encoding

The central design principle: timing instructions are written directly into the file as annotations on subtitle number lines. A small set of commands reads those annotations and applies them, leaving behind a clean, valid `.srt` file.

---

## Subtitle file format

Each subtitle entry looks like this:

```
15
00:02:29,166 --> 00:02:30,165
You don't think
there's a difference
```

Fields:
- **Sequence number** — `15` (renumbered automatically on every write/shift/interpolate)
- **Start time** — `00:02:29,166` (`HH:MM:SS,mmm`)
- **End time** — `00:02:30,165` (same format)
- **Text** — one or more lines

Entries are separated by a single blank line.

---

## Time specification (`timespec`)

Used wherever a duration or absolute time is needed.

**Format:** `[HH:][MM:]SS[,mmm]`

- Hours and minutes may be omitted (rightmost fields take precedence)
- Leading zeroes are allowed and ignored
- Milliseconds are optional

**Examples:**

| Input | Meaning |
|---|---|
| `5` | 5 seconds |
| `125,243` | 2 minutes 5 seconds 243 ms |
| `1:23,45` | 1 minute 23 seconds 45 ms |
| `74:23,552` | 1 hour 14 minutes 23 seconds 552 ms |
| `02:12:23,345` | 2 hours 12 minutes 23 seconds 345 ms |
| `1:0:0` | 1 hour |

---

## Annotations

Annotations are appended to the subtitle sequence number line, separated by a space:

```
15 <annotation>
00:02:29,166 --> 00:02:30,165
You don't think
there's a difference
```

All annotations are removed from the buffer after a `shift`, `interpolate`, or `clean` command runs.

### Shift annotations

These affect timing and cascade downward to subsequent subtitles until the next shift directive is encountered.

| Annotation | Effect |
|---|---|
| `+<timespec>` | Add `timespec` to this subtitle and all subsequent ones (until the next directive) |
| `-<timespec>` | Subtract `timespec` from this subtitle and all subsequent ones (until the next directive) |

Placing `+` or `-` on the very first subtitle is equivalent to a global shift.

### Single-subtitle annotations

These affect only the annotated subtitle; subsequent subtitles are unchanged.

| Annotation | Effect |
|---|---|
| `=<timespec>` | Set start time to `timespec`; preserve subtitle duration (end time shifts accordingly) |
| `+=<timespec>` | Increase both start and end times by `timespec` |
| `-=<timespec>` | Decrease both start and end times by `timespec` |

### Interpolation annotations

Used to define anchor points for linear interpolation. **At least two anchors are required.**

| Annotation | Effect |
|---|---|
| `@<timespec>` | Set this subtitle's start time to the absolute value `timespec` |
| `@+<timespec>` | Set this subtitle's start time to current + `timespec` |
| `@-<timespec>` | Set this subtitle's start time to current − `timespec` |

Both start and end times of every subtitle are interpolated (duration changes are small in practice).

**Interpolation segments:** anchors at subtitles #10, #20, #50, #80 define three segments: [10–20], [20–50], [50–80]. Subtitles within a segment are interpolated using the two bounding anchors. Subtitles outside all segments (#1–#9, #81+) are extrapolated using the slope of the nearest segment, unless `strict` mode is active.

---

## Configuration

All options have sensible defaults. Users can override them by passing a table to `setup`:

```lua
require('subsync').setup({
  default_encoding  = 'utf-8',
  default_gap       = 80,
  min_duration      = 1500,
  max_duration      = 6000,
  max_reading_speed = 17,
})
```

| Option | Default | Description |
|---|---|---|
| `default_encoding` | `'utf-8'` | Encoding used by `read`/`write`/`reload` when none is specified |
| `default_gap` | `80` ms | Minimum gap enforced by `SubSync gap` when called without an argument |
| `min_duration` | `1500` ms | Minimum subtitle duration used by `SubSync length` when called without arguments |
| `max_duration` | `6000` ms | Maximum subtitle duration used by `SubSync length` when called without arguments |
| `max_reading_speed` | `17` chars/sec | Threshold above which `SubSync info` flags a subtitle as hard to read |

---

## Commands

### `SubSync read <encoding>`

Re-reads the current buffer from disk using the specified encoding (e.g., `cp1250`, `latin1`). The encoding is remembered for use by `SubSync write`.

### `SubSync write [encoding]`

Writes the buffer to disk. Uses the provided encoding, or the one remembered from `SubSync read`, or UTF-8 if no encoding has been specified. Subtitles are renumbered before writing.

### `SubSync shift`

Applies all shift and single-subtitle annotations in the file. Interpolation annotations (`@`) are silently ignored and removed with a warning.

If no annotations are present, the buffer is left unchanged and the user is notified.

After execution: buffer contains a valid, annotation-free `.srt` file with renumbered subtitles.

### `SubSync shift <+/-><timespec>`

Applies a global time shift to all subtitles. All annotations (shift and interpolation) are removed with a warning.

### `SubSync interpolate`

Applies interpolation annotations. Requires at least two `@` anchor points — fails with an error if fewer than two are present. Shift and single-subtitle annotations are silently ignored and removed with a warning.

If no annotations are present, the buffer is left unchanged and the user is notified.

Subtitles outside the outermost anchors are extrapolated using the slope of the nearest segment.

After execution: buffer contains a valid, annotation-free `.srt` file with renumbered subtitles.

### `SubSync interpolate strict`

Same as `SubSync interpolate`, but subtitles outside the outermost anchor points retain their original timings unchanged.

### `SubSync length <min_timespec> <max_timespec>`

Enforces a visibility duration window on every subtitle by adjusting end times only (start times are never changed).

- **Too short** (`duration < min`): end time is extended to `start + min`. If the next subtitle starts before that point, end time is clamped to the next subtitle's start (no overlap is created).
- **Too long** (`duration > max`): end time is trimmed to `start + max`.
- Subtitles already within `[min, max]` are untouched.

After execution: buffer contains a valid, renumbered `.srt` file.

### `SubSync gap <timespec>`

Ensures a minimum gap between every consecutive pair of subtitles by trimming end times only (start times are never changed).

- If the gap between entry N's end and entry N+1's start is less than `timespec`, entry N's end time is trimmed to `next.start − timespec`.
- If trimming would reduce the subtitle's duration to zero or below, that entry is left unchanged and reported.
- `0` is valid — fixes overlaps without adding any extra space.

After execution: buffer contains a valid, renumbered `.srt` file.

### `SubSync reload`

Re-reads the current buffer from disk, discarding all unsaved changes. Uses the encoding remembered from the last `SubSync read`, or UTF-8 if none was set. Equivalent to `:e!` but encoding-aware.

### `SubSync jump <N>`

Moves the cursor to the sequence-number line of subtitle `N` in the current buffer. Useful for navigating directly to a subtitle flagged by `SubSync info`.

### `SubSync info`

Displays a summary of the current subtitle file in a scratch split. Reports the limits in use (from config) and counts of subtitles violating each one:

- Too short (duration < `min_duration`)
- Too long (duration > `max_duration`)
- Gap too small (gap to next subtitle < `default_gap`)
- Overlapping (entry ends after next entry starts)
- Too fast (characters per second > `max_reading_speed`; sequence numbers listed)
- Out of order (start time earlier than previous entry's start time; sequence numbers listed)

The buffer is read-only. Press `q` to close. Press `Enter` on any line containing a subtitle number (e.g. `#42`) to jump directly to that subtitle in the main buffer.

### `SubSync fixspeed [chars_per_sec]`

Extends end times of subtitles that exceed the reading speed threshold, making them readable at the given speed. If no argument is given, uses `max_reading_speed` from config.

- End time is extended to `start + char_count / chars_per_sec`.
- If that would overlap the next subtitle, end time is clamped to the next subtitle's start (zero gap is acceptable — readability takes priority).
- Start times are never changed.
- Subtitles already within the speed limit are untouched.

HTML-style tags (e.g. `<i>`) are excluded from the character count.

After execution: buffer contains a valid, renumbered `.srt` file.

### `SubSync sort`

Reorders subtitle entries by start time (ascending) and renumbers them. Useful after manually inserting entries out of order. If subtitles are already sorted, the buffer is left unchanged and the user is notified.

After execution: buffer contains a valid, renumbered `.srt` file.

### `SubSync merge`

Merges the subtitle under the cursor with the immediately following entry. The result keeps the current entry's start time and the next entry's end time; text lines are concatenated. The buffer is renumbered.

Errors if the cursor is not inside a subtitle entry, or if the current entry is the last one.

After execution: buffer contains a valid, renumbered `.srt` file.

### `SubSync clean`

Removes all annotations from the buffer without changing any timings or renumbering. Useful for discarding annotations without applying them.

---

## Editing notes

- Subtitle sequence numbers do not need to be correct while editing. A placeholder like `#` is acceptable.
- Renumbering happens automatically on every `shift`, `interpolate`, and `write` operation.
- All commands modify only the buffer; an explicit `SubSync write` is required to persist changes to disk.

---

## Ideas for future implementation

### Quality / correctness tools

~~**`SubSync sort`**~~ — implemented.

### Editing ergonomics

~~**`SubSync merge`**~~ — implemented.

**`SubSync split`** — split the current subtitle at the cursor line into two entries, dividing the duration evenly. Inverse of `merge`.

**`SubSync dup <N>`** — duplicate subtitle N as a new entry immediately after it (same timing, same text). Useful as a starting point when inserting a similar subtitle nearby.

### Format conversion

**`SubSync convert <format>`** — export to another subtitle format (`.vtt`, `.ass`, plain `.txt`). Read-only conversion; no import needed since `.srt` is the working format.

### Statistics / inspection

~~**`SubSync info`**~~ — implemented.

### Workflow

~~**`SubSync reload`**~~ — implemented.
