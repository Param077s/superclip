# Superclip

A clipboard for macOS that knows where the paste is going.

The system clipboard has not meaningfully changed since 1983. It is a single
byte buffer with no memory of where content came from and no idea where it is
headed. Superclip fixes the second half of that: **copy captures meaning, and
paste is a rendering of that meaning for wherever it lands.**

Copy a table out of a PDF. Paste it into Numbers and you get real cells; into
Slack and you get readable lines; into a code editor and you get an array
literal. One copy, three correct outputs, and you never picked a format.

> **Status: early.** The app builds, runs, and holds all seven of its bindings.
> The parts that talk to the model, and the parts that need macOS permissions,
> are written but have not yet been exercised against real apps. See
> [Status](#status) before relying on any of it.

---

## What it does

| Binding | Does |
| --- | --- |
| `⇧⌘V` | **Smart paste.** Reshapes the clipboard for the destination app. |
| `⌥⇧⌘C` | **Copy from screen.** Drag any region; get its text. Works on locked PDFs, screenshots, error dialogs — anything you can see but not select. |
| `⌃⌘V` | **Pull.** You have not copied anything. The field under your cursor asks for what belongs in it. |
| `⌃⇧⌘V` | **Fill form.** Spread one copied record across an entire form, in any app. |
| `⌃⌥C` | **Collect.** Start or stop building a copy stack. |
| `⌃⌥V` | **Pop.** Paste the next item from the stack. Press once per field. |
| `⌃⌥⇧V` | **Merge.** Paste everything left on the stack as one block. |

**`⌘V` is never touched.** It stays byte-identical and instant, forever. No
feature is worth adding latency to the most-pressed shortcut in computing.

### Notes on the less obvious ones

**Copy from screen** runs Apple's Vision OCR on-device first, and that result is
what you see — instant, free, offline. The model is only spent when OCR comes
back empty or unsure, or when you ask for it with `⌘↩`. A column-gap heuristic
turns a screenshot of a table straight into tab-separated values with no model
call at all.

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

- **Clipboard history lives in memory only.** It is never written to disk and
  dies with the process. Persisting clipboard history is a genuinely dangerous
  thing to do casually.
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

---

## How it is built

Swift and SwiftUI, no dependencies, assembled with SwiftPM into a plain
`.app` bundle.

```
Sources/Superclip/
├── main.swift            NSApplication bootstrap
├── AppDelegate.swift     Menu bar, hotkey routing, all seven flows
├── Engine/
│   ├── Hotkey.swift          Carbon hotkeys — chosen over NSEvent monitors
│   │                         because Carbon *consumes* the keystroke
│   ├── ClipboardMonitor.swift Polls changeCount; provenance + history
│   ├── CopyStack.swift        Opt-in ordered collection, FIFO
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
│   ├── PasteEngine.swift      Pasteboard snapshot, synthesized ⌘V, restore
│   ├── Transformer.swift      Claude API — streaming and structured output
│   ├── Settings.swift         Keychain
│   ├── Permissions.swift      Accessibility + Screen Recording
│   └── Log.swift              ~/superclip-debug.log
└── UI/
    ├── PreviewPanel.swift     Non-activating floating preview
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

**Latency is the product.** The model calls stream so the preview fills token
by token, thinking is disabled at low effort, fast mode is on by default, and
the system prompts are frozen byte-for-byte so they cache server-side.

---

## Status

Honest accounting, because most of this has not run yet.

| Area | Builds | Logic tested | Run for real |
| --- | :-: | :-: | :-: |
| Clipboard monitor + provenance | ✅ | ✅ | ✅ |
| Retention / safety filter | ✅ | ✅ | ✅ |
| Copy stack | ✅ | ✅ | ❌ |
| Screen OCR | ✅ | ✅ | ❌ |
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

`~/superclip-debug.log` traces every flow. The two lines worth watching first
are `form: scanned N nodes, M writable field(s)` and `pull: field=… role=…`. If
those come back empty on a form that visibly has fields, the role filter or the
settability check is too strict.
