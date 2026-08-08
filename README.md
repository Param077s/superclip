# Superclip

A clipboard for macOS that knows where the paste is going.

The system clipboard has not meaningfully changed since 1983. It is a single
byte buffer with no memory of where content came from and no idea where it is
headed. Superclip fixes the second half of that: **copy captures meaning, and
paste is a rendering of that meaning for wherever it lands.**

Copy a table out of a PDF. Paste it into Numbers and you get real cells; into
Slack and you get readable lines; into a code editor and you get an array
literal. One copy, three correct outputs, and you never picked a format.

> **Status: early.** The app builds, runs, and holds all nine of its bindings.
> The parts that talk to the model, and the parts that need macOS permissions,
> are written but have not yet been exercised against real apps. See
> [Status](#status) before relying on any of it.

---

## What it does

All of these are defaults — every one can be rebound from **Settings…** in the
menu bar item.

| Binding | Does |
| --- | --- |
| `⇧⌘V` | **Smart paste.** Reshapes the clipboard for the destination app. |
| `⌥⇧⌘C` | **Copy from screen.** Drag any region; get its text. Works on locked PDFs, screenshots, error dialogs — anything you can see but not select. |
| `⌃⌘V` | **Pull.** You have not copied anything. The field under your cursor asks for what belongs in it. |
| `⌃⇧⌘V` | **Fill form.** Spread one copied record across an entire form, in any app. |
| `⌃⌥C` | **Collect.** Start or stop building a copy stack. |
| `⌃⌥V` | **Pop.** Paste the next item from the stack. Press once per field. |
| `⌃⌥⇧V` | **Merge.** Paste everything left on the stack as one block. |
| `⌃⌥F` | **Search.** Ask for something you copied instead of scrolling for it. |
| `⌃⌥H` | **Browse.** See everything that has been kept, and delete any of it. |

**`⌘V` is never touched**, and cannot be bound to anything. It stays
byte-identical and instant, forever. No feature is worth adding latency to the
most-pressed shortcut in computing.

Rebinding is checked twice: against the other actions, so one shortcut cannot
silently shadow another, and against the system, so a combination macOS or
another app already owns is reported as unavailable rather than left as a dead
key. Bindings without ⌘, ⌃, or ⌥ are refused outright — a global hotkey of ⇧A
would swallow every capital A you type, everywhere.

### Notes on the less obvious ones

**Copy from screen** runs Apple's Vision OCR on-device first, and that result is
what you see — instant, free, offline. The model is only spent when OCR comes
back empty or unsure, or when you ask for it with `⌘↩`. A column-gap heuristic
turns a screenshot of a table straight into tab-separated values with no model
call at all.

**Handwriting** is routed separately. When OCR finds nothing but the region
clearly has marks on it — a scanned note, a photographed page, an annotated
PDF — it goes to a reading pass that thinks, runs at high effort, and returns
the words it is not sure of alongside the transcription. Those uncertain
readings are shown in the panel header, never mixed into what gets copied, so
you know which name or digit to check. This is the one place in the app where
accuracy is allowed to cost latency.

**Pull** inverts the forty-year-old model: the destination requests content
rather than the source pushing it. It reads the focused field's accessibility
role, placeholder and label, ranks your recent clips against it, and offers up
to three, `↑↓` to cycle.

**Fill form** is integration without integration. Every app on macOS publishes
its form controls over the accessibility API whether or not it has one, and
whether or not its vendor has ever heard of this. Copy a record, focus a form,
review the mapping, fill.

**The copy stack** does no model call and no network. That is the point: you
already decided what those values are, so one press equals one field, instantly
and for free.

**Search** turns history from a filing cabinet into memory. Instead of scrolling
a list of your last fifty clips, describe the thing — "the address from last
week", "that tracking number", "the SQL from yesterday" — and the matches come
back ranked, `↑↓` to cycle. A local text pass runs first, so literal queries
resolve instantly and the feature still works with no API key; the model handles
everything else, which is most of it. **The model returns item numbers, never
content**, so a search result cannot contain anything you did not actually copy.

History persists across launches, encrypted, which is what makes "last week" a
question worth asking rather than one the buffer cannot answer. See
[Privacy](#privacy) for what that costs and how to switch it off.

**Browsing** is the other half, and deliberately not the same thing. Search is
for when you can describe something but cannot find it; browsing is for seeing
what is actually there. So `⌃⌥H` filters by literal substring in strict recency
order — no ranking, no model, nothing rearranging under you as you read. It is
also the only place the stored history is visible, which makes it the right home
for deleting one specific clip with `⌘⌫`. **Forget everything** is the blunt
instrument; this is the scalpel.

---

## Setup

Requires macOS 26+, a Swift 6.2 toolchain, and an Anthropic API key.

```bash
git clone https://github.com/Param077s/superclip.git
cd superclip
./build.sh
open ./Superclip.app
```

Then, from the menu bar item:

1. **Set API Key…** — stored in your login keychain, never in a file.
2. **Accessibility** — needed to read where a paste is going, to synthesize the
   paste itself, and for pull and form fill to see fields at all.
3. **Screen Recording** — needed for copy-from-screen. macOS only applies this
   one on relaunch, so quit and reopen afterwards.
4. **Settings…** (`⌘,`) — rebind any shortcut. Click one, press the new
   combination, or Reset to put it back.

### Keep your permissions across rebuilds

`build.sh` signs with a stable self-signed identity so macOS does not revoke
the Accessibility grant every time you rebuild. Create it once:

Keychain Access → Certificate Assistant → Create a Certificate, named
`Superclip Dev Cert`, type **Code Signing**. Without it the build falls back to
ad-hoc signing, and you will be re-granting permissions after every build.

---

## Privacy

A clipboard tool earns trust or it gets deleted, so the rules are narrow and
explicit.

- **History is encrypted at rest and expires on its own.** The last 200 clips
  are stored in `~/Library/Application Support/Superclip/history.dat`, sealed
  with AES-GCM under a 256-bit key held in your login keychain as
  `ThisDeviceOnly` — so the key never reaches iCloud Keychain or an encrypted
  backup, and a copy of the file taken from a backup cannot be opened anywhere
  else. The file is `0600`, and nothing survives past the retention window
  (a week by default; **Keep history for** in the menu offers 1 day, 1 week,
  30 days, or not saving to disk at all).
- **Forget everything actually forgets.** The menu item deletes the file *and*
  destroys the key, so the stored bytes are unrecoverable even if the file
  itself is later undeleted from a backup or a disk image.
- **A damaged store loses history rather than inventing it.** Decryption is
  authenticated, so a wrong key, a truncated file, or a single flipped bit is
  detected and the store is discarded instead of decrypting to something
  plausible-looking.
- **Password-manager clips are never retained.** Superclip honors the
  `org.nspasteboard.ConcealedType` convention, and additionally drops
  credential-shaped tokens (`sk-`, `ghp_`, `AKIA`, PEM blocks, and similar).
- **Secure text fields are excluded at the scanner**, so a password field
  cannot reach the model or the form filler even by accident.
- **The copy stack never fills itself.** It collects only while you have
  switched it on, and the menu-bar icon changes and shows a live count the
  whole time.
- **Nothing is written into another app until you have seen it.** Form fill in
  particular is review-then-commit, always.

What leaves your machine: the clipboard content or screen region you are acting
on, plus the name of the destination app and its window title, sent to the
Anthropic API. The copy stack's pop path sends nothing at all.

What is written to disk is smaller than what is held in memory. A stored clip
keeps its text, the name and bundle id of the app it came from, and when it was
copied. Process ids are meaningless across launches and window titles routinely
carry document names, client names, and ticket subjects, so neither is
persisted.

---

## How it is built

Swift and SwiftUI, no dependencies, assembled with SwiftPM into a plain
`.app` bundle.

```
Sources/Superclip/
├── main.swift            NSApplication bootstrap
├── AppDelegate.swift     Menu bar, hotkey routing, all nine flows
├── Engine/
│   ├── Hotkey.swift           Carbon hotkeys — chosen over NSEvent monitors
│   │                          because Carbon *consumes* the keystroke
│   ├── HotkeyBinding.swift    Bindings, key names, conflict detection
│   ├── ClipboardMonitor.swift Polls changeCount; provenance + history
│   ├── HistoryStore.swift     AES-GCM store, keychain key, retention
│   ├── CopyStack.swift        Opt-in ordered collection, FIFO
│   ├── HistorySearch.swift    Local lexical ranking of history
│   ├── SensitiveContent.swift What is refused retention
│   ├── AppContext.swift       Which app, which window
│   ├── FieldIntent.swift      What the focused field is asking for
│   ├── FormScanner.swift      Walks the AX tree for writable fields
│   ├── FormFiller.swift       Writes values back, with verification
│   ├── ReadingOrder.swift     Top-to-bottom, left-to-right sorting
│   ├── AXKit.swift            Accessibility API wrappers
│   ├── Destination.swift      Bundle ID → format profile
│   ├── ScreenCapture.swift    ScreenCaptureKit region grab
│   ├── TextRecognizer.swift   Vision OCR + line assembly
│   ├── InkAnalysis.swift      Blank vs printed vs handwritten routing
│   ├── PasteEngine.swift      Pasteboard snapshot, synthesized ⌘V, restore
│   ├── Transformer.swift      Claude API — streaming and structured output
│   ├── Settings.swift         Keychain
│   ├── Permissions.swift      Accessibility + Screen Recording
│   └── Log.swift              ~/superclip-debug.log
└── UI/
    ├── PreviewPanel.swift     Non-activating floating preview
    ├── HistoryBrowser.swift   Browsable, filterable list of what is kept
    ├── QueryPanel.swift       Spotlight-style input bar
    ├── SettingsWindow.swift   Rebinding, with a key recorder
    └── RegionSelector.swift   Drag-to-select overlay
```

Two implementation notes worth knowing before changing anything:

**Writing into other apps takes two mechanisms.** Setting a value over the
accessibility API is instant and silent, but in web views and Electron apps it
routinely reports success while updating only the accessibility layer — the
app's own state, and therefore what gets submitted, never changes. So every
write is read back, and anything that did not take is redone with real
keystrokes. Before those keystrokes are sent, the target field's focus is
verified against the application's own idea of what is focused; otherwise they
would land somewhere else and overwrite it.

**Latency is the product — with one deliberate exception.** The model calls
stream so the preview fills token by token, thinking is disabled at low effort,
fast mode is on by default, and the system prompts are frozen byte-for-byte so
they cache server-side. Handwriting inverts all of that: it thinks, runs at high
effort, and does not stream, because a confidently wrong transcription is worse
than a slow one.

**Recording a shortcut has to stand the others down.** Carbon consumes a
registered hotkey before any local monitor can see it, so with the bindings live
you cannot capture ⌃⌥V as a new shortcut — pressing it fires the paste instead.
The recorder unregisters everything while capturing and re-registers afterwards.

**Nothing that can block runs before the bindings are live.** Registering the
hotkeys is the first thing that happens at launch, ahead of any keychain or disk
work, and the encrypted store is read on a background task. Reading it touches
the keychain, and the keychain can raise a modal authorization prompt that
blocks whoever asked — which on the main thread means an app that looks running
but whose shortcuts silently do nothing.

**Three paths return structure, not prose.** Pull, form fill, and search use
structured output rather than streaming. Search goes further and returns only
item *numbers*, which the caller pairs back with the original clipboard text —
so a search result cannot contain anything you did not copy, by construction
rather than by instruction.

---

## Status

Honest accounting, because most of this has not run yet.

| Area | Builds | Logic tested | Run for real |
| --- | :-: | :-: | :-: |
| Clipboard monitor + provenance | ✅ | ✅ | ✅ |
| Retention / safety filter | ✅ | ✅ | ✅ |
| Encrypted history store | ✅ | ✅ | ✅ |
| History browser | ✅ | ✅ | ❌ |
| Hotkey binding + conflicts | ✅ | ✅ | ❌ |
| Copy stack | ✅ | ✅ | ❌ |
| Screen OCR | ✅ | ✅ | ❌ |
| Handwriting routing | ✅ | ✅ | ❌ |
| Handwriting transcription | ✅ | ❌ | ❌ |
| Search — local text pass | ✅ | ✅ | ❌ |
| Search — semantic ranking | ✅ | ❌ | ❌ |
| Reading-order sorting | ✅ | ✅ (fuzzed) | ❌ |
| Smart paste | ✅ | ❌ | ❌ |
| Pull | ✅ | ❌ | ❌ |
| Fill form | ✅ | ❌ | ❌ |

The gaps are all one of three things: no API key was available in the
environment it was built in, Accessibility was never granted, or Screen
Recording was never granted.

Known unknowns, in the order they are likely to bite:

- **Screen capture coordinate math.** Converting `NSScreen`'s bottom-left global
  origin to ScreenCaptureKit's top-left display-relative `sourceRect` is the
  most likely thing to be wrong on a multi-monitor setup.
- **Which apps expose usable field labels.** Native AppKit forms should be
  fine. Electron and web views are the usual weak spots, and pull and form fill
  are only as good as the labels they can read.
- **Whether the accessibility write path ever succeeds** in practice, or whether
  everything falls through to the keystroke path. Both work; it is a speed
  difference.
- **Handwriting detection is deliberately crude.** It measures how much of a
  region differs from its own background, which cannot tell writing apart from a
  photograph or a screenshot of icons. Those are routed to the reading pass and
  come back empty, costing one wasted call. The opposite error — a small amount
  of writing inside a large selection reading as blank — is the one that would
  actually block you, so the blank verdict is offered rather than enforced:
  `⌘↩` reads it anyway.

`~/superclip-debug.log` traces every flow. The two lines worth watching first
are `form: scanned N nodes, M writable field(s)` and `pull: field=… role=…`. If
those come back empty on a form that visibly has fields, the role filter or the
settability check is too strict.

---

## License

[MIT](LICENSE) © 2026 Param077s
