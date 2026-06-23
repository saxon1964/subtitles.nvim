# subtitles.nvim

Neovim plugin for editing `.srt` subtitle files. Supports arbitrary encodings and
in-file timing annotations — write timing adjustments directly in the file, then
apply them all at once with a single command.

---

## Installation

**[lazy.nvim](https://github.com/folke/lazy.nvim)**
```lua
{ 'saxon1964/subtitles.nvim' }
```

**[packer.nvim](https://github.com/wbthomason/packer.nvim)**
```lua
use 'saxon1964/subtitles.nvim'
```

**[vim-plug](https://github.com/junegunn/vim-plug)**
```vim
Plug 'saxon1964/subtitles.nvim'
```

No configuration is required. The `:SubSync` command is available as soon as the
plugin loads.

---

## Commands

### `SubSync read <encoding>`

Re-reads the current buffer from disk using the specified encoding, converting to
UTF-8 for editing. The encoding is remembered and reused by `SubSync write`.

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
