# Character Tracker — KOReader Plugin

Track characters, locations, factions, relationships, and notes while you read.
Never forget who's who in a long novel — or across an entire series — again.

---

## Features

### Objects
- **Add characters on the fly** from the highlight popup or the Tools menu.
- **Locations and factions** can also be created and managed with the same fields as characters.
- Each object type has its own icon: person, house, or shield.
- **Aliases** — track nicknames, titles, house names, alternate spellings.
- **Notes** — add evolving observations as the story progresses; edit or delete any time.
- **Rating** — rate objects from ★ to ★★★★★.
- **Role** — tag objects as Main, Secondary, Tertiary, Mentioned, Antagonist, or Narrator.
- **Per-book display settings** — hide ratings, roles, notes, or relationships without changing their data.
- **Rename** — safely rename an object (relationships pointing to it are updated automatically).

### Relationships
- Link characters with predefined types: **father, mother, son, daughter, brother, sister, spouse, ally, enemy, friend, mentor, servant, master, lover**.
- Link characters to their **origin location** and **factions**; nest locations and factions inside objects of the same type.
- **Custom relationships** for anything else (squire, rival, betrothed, ...).
- Relationship manager and detail view show both **outgoing** (→) and **incoming** (←) relationships.
- Tap a relationship to jump to that character's detail view.
- Invert a relationship to swap its two characters.
- Deleting an object cleans up dangling relationships automatically.

### Highlight integration
- Adds a **Character** button to the highlight popup.
- Selecting text and tapping **Character** offers to register the selection
  as a new character (or warns you if it's already known).

### Series support (shared objects across books)
- **Link a book to a series** to share one object database across multiple books.
- When linking, existing book characters are **merged** into the series
  (aliases and notes are deduplicated).
- **Unlink** at any time — the series file is preserved.
- Manage and **delete** series from the link dialog.
- Perfect for *A Song of Ice and Fire*, *The Wheel of Time*, *Discworld*, etc.

---

## Installation

Copy the `charactertracker.koplugin` folder to your KOReader plugins directory:

```
<koreader>/plugins/charactertracker.koplugin/
```

Then restart KOReader.

---

## Usage

### Adding a character

**From the highlight popup (recommended):**
1. Long-press and select a character's name in the text.
2. Tap **Character** in the popup.
3. Confirm name and add an optional first note.

**From the Tools menu:**
1. **Tools → Character Tracker → Add character**
2. Enter name and optional note.

Locations and factions can be added from their corresponding entries in the Tools menu.

### Viewing & editing objects

1. **Tools → Character Tracker → Object list**
2. Tap an object to open the detail view.
3. From there: rate, set role, manage notes, manage aliases, manage relationships, rename, or delete.

### Linking a book to a series

1. **Tools → Character Tracker → Link to series**
2. Pick an existing series or create a new one.
3. Existing objects in the current book are merged into the shared series file.

To unlink: open the same menu entry and choose **Unlink from series**.

---

## Data storage

- **Per-book mode** (default): objects are stored as
  `<book_path>.characters.json` next to the book file.
- **Series mode**: objects are stored in
  `<koreader-data>/character_tracker/<series_name>.json`
  and shared by every book linked to that series.

The format is plain JSON — easy to back up, version-control, or edit by hand.

---

## File structure

```
charactertracker.koplugin/
├── _meta.lua    # Plugin metadata
└── main.lua     # Plugin logic
```


---

Suggestions welcome — open an issue.

---

## License

GNU AGPL v3 — same as KOReader.
