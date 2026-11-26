# Changelog

## Unreleased

- New icon, redrawn with the rest of the suite from one shared design (same glass parts, light, shadows and safe area on every icon).

## 1.2

- New icon: the suite's colour icons, TextHunter in teal.
- **Scratchpad**: a floating note for short-lived text, opened and closed with ⇧⌘T (changeable in Settings) or from the menu. Its text is saved as you type and kept across openings and restarts.
  - Pin to keep it open; unpinned, it closes at a click elsewhere. It takes the keyboard without making TextHunter the active app.
  - Formatting row (Markdown marks), formatted preview, copy all, export to a file, clear with undo, ⌘F search, lists that continue on Return.
- Settings has a second shortcut field, for the Scratchpad. Shortcuts are registered exclusively, so other apps using the same keys don't get them. Each shortcut shows its own messages, and the two can't be the same.

## 1.1

- **Label special text** (on by default, in Settings):
  - superscripts and subscripts are marked: `results[superscript: 17]`, `H[subscript: 2]O`;
  - text on a coloured bubble is marked, a whole badge or a tag inside a line: `[grey bubble: Source 1]`. Works in light and dark themes.
- The copied text keeps the page's hierarchy: titles, subtitles, captions and notes become paragraphs of their own, set apart by empty lines, and the main text stays as it is.
- Extra space on the page (around a heading, between spaced paragraphs) becomes an empty line.
- Bulleted items that wrap are joined correctly; a tag after the last word no longer breaks the paragraph.

## 1.0

- First release: copy the text in any area of the screen.
