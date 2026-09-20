# Rooms — pick a room from a list, see where every plant stands

**Date:** 2026-09-20
**Status:** Approved (mockups: https://claude.ai/artifact/UUEh1aqaCbBgRfXQy4qtPs, version 3), not yet implemented
**Builds on:** `2026-09-14-sensor-health-design.md` (the `location` field and the peer-witness rule)

## Problem

The sensor-health work added `FlowerDevice.location` with a free-text field and
small suggestion chips (`LocationField`). The user's verdict: not good enough.
Typing a room name per plant is tedious, the chips are easy to miss, and the
overview barely shows where a plant stands or how many plants share a room.

## Decisions

- **The UI says "Room".** The stored field stays `location: String?`; no schema
  change, no `Room` entity. A room exists for as long as a plant uses it.
- **Rooms apply to every plant**, not only sensors. The peer-witness rule keeps
  ignoring non-sensor peers, so nothing changes for sensor health.
- **Room icons come from keywords in the name** ("Balkon" → sun, "Küche" →
  fork and knife, …) with a neutral pin as fallback. German and English
  keywords; no stored icon.
- **The overview keeps its structure.** "Environment Overview" and "My Plants"
  stay; rooms appear as one slim, horizontally scrolling filter bar under the
  "My Plants" header. The first mockup's large room tiles and grouped list were
  rejected.

## Screens

### 1. Overview — room filter bar

Under the "My Plants" header: chips `All 6`, one per room with its plant count,
and `No room N` when any plant is unassigned. The active chip is filled green.
A red dot on a room chip means a sensor there is `.unreachable`. Tapping a chip
filters the flat list; the list stays flat, no group headers. The bar is hidden
while no plant has a room (nothing to filter). If the filtered room disappears
(last plant moved away), the filter falls back to `All`.

Each plant card names its room in the clock line (`🕐 12 min ago · 📍 Balkon`)
instead of next to the name. While at least one room exists, plants without one
show `No room` there.

Swipe-to-delete keeps working on a filtered list: offsets are translated back
to the unfiltered device array before deletion.

### 2. Details — one room row

Below the header card: a single card with the room icon, the caption "Room",
the room name, and a companion line ("Together with Basilikum", "Together with
Basilikum and 2 more", "Only plant here"). Without a room the name reads
"Choose a room" in green. Tapping opens the room picker as a sheet; a choice is
persisted immediately through `modifyDevice` (only `location`). The
sensor-health banner's link ("Tell the app which room this sensor is in") opens
the same sheet instead of the settings sheet.

### 3. Room picker

A page with a search field that doubles as the input for a new name:

- "Your rooms": every existing room with icon, "N plants · M sensors", and a
  checkmark on the current one. Search is case- and diacritic-insensitive.
- "No room" clears the assignment (shown while the search field is empty).
- "Create “X”" appears when the trimmed query matches no existing room exactly
  (case-insensitively). An exact match never offers "Create" — the existing
  spelling wins, which is what prevents "Balkon"/"balkon" duplicates.
- "Suggestions": common room names (localized strings) that are not rooms yet,
  filtered by the query.

Picking anything sets the selection and closes the page. Reached from three
places: the details room row (sheet, saves immediately), the device settings
form and the add-device form (pushed; the value is saved with the form as
before). `LocationField` is deleted.

## Architecture

```
[FlowerDeviceDTO] ──► RoomCatalog(devices:now:) ──► RoomFilterBar      (overview)
                          │  rooms, unassigned,   ──► RoomPickerView    (3 entry points)
                          │  search/create/        ──► RoomRowCard      (details)
                          │  suggestions, symbol
                          └── uses SensorHealth.evaluate for the red dot
```

`RoomCatalog` (`GrowGuard/Core/`) is pure: DTOs in, value types out. It owns
counting, sorting (`localizedStandardCompare`), folding for search, the
create rule, suggestions, keyword → SF Symbol mapping, companions, and
`RoomFilter.includes(_:)`. Views hold no room logic.

## Testing

`RoomCatalogTests` (pure): counts and sorting; unassigned bucket present/absent;
silent flag from an unreachable sensor; folded search ("kuche" finds "Küche");
exact match suppresses "Create"; create normalizes whitespace; suggestions
exclude existing rooms and follow the query; symbol mapping incl. fallback and
nil; companions (none / one / more, self excluded, other rooms excluded);
`RoomFilter.includes`. Views stay untested (project convention) and get one
manual look with seeded devices.

## Editing rooms (added 2026-09-20)

Rooms can be renamed, given an icon, and deleted — still without a `Room`
entity or a schema change.

- **Entry points.** In the room picker every room row has a trailing "…" menu
  and swipe actions with **Edit** and **Delete**. Tapping the row itself still
  picks the room. Edit opens a sheet (`RoomEditView`); a sheet rather than a
  push because the picker is hosted in a legacy `NavigationView` (settings),
  a path-driven `NavigationStack` (add flow) and a sheet (details), and a
  sheet behaves the same in all three.
- **Rename** rewrites `location` on every plant of the room (`RoomEditor`,
  one `modifyDevice` per plant, only `location`). If the new name folds to an
  existing *other* room, the user is asked to merge; the existing spelling
  wins. When several existing spellings fold alike (legacy duplicates), the
  target is the room spelled exactly as the user typed, otherwise the spelling
  the most plants use (ties by name), and the confirmed target is handed back
  to `rename(_:to:mergingInto:)` so the alert and the write cannot disagree.
  A case-only change is a plain rename only while no other spelling exists —
  a "balkon" next to a "Balkon" is a second room and is confirmed as a merge.
  Empty names are rejected. Because all members move together, peer-witness
  groups are unchanged.
- **Delete** sets `location = nil` on every plant of the room after a
  confirmation that names the number of affected plants. Plants are never
  deleted.
- **Icon.** `RoomIconStore` (UserDefaults, key `rooms.customIcons`, keyed by
  the folded room name, `@Observable` so views refresh) holds an optional
  custom SF Symbol per room. "Automatic" removes the entry and falls back to
  the keyword mapping. `RoomCatalog.symbolName(for:icons:)` asks the store
  first. Rename moves the entry; a merge leaves the target room's look
  untouched (its own icon, or automatic) and drops the dissolved room's
  entry; delete removes it. Not synced and not part of the Core Data store — an
  accepted trade-off for avoiding model version 3.
- **Refresh.** After an edit the picker reloads its devices from the
  repository, moves the current selection along (renamed → new name, deleted
  → none) and calls `onRoomsChanged` so the host refreshes its own copy
  (details: peers + own location; settings/add: device list).

Testing: `RoomIconStore` and `RoomEditor` are TDD with an in-memory repository
and an isolated `UserDefaults` suite; `RoomCatalogTests.symbols` injects an
empty store so a developer's custom icons cannot leak in. Views untested, one
visual pass with seeded devices.

## Out of scope

- A `Room` entity (empty rooms, fixed order, synced icons).
- Grouping the overview list by room.
- Changing sensor-health semantics.
