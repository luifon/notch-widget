# Working on notch-widget

Rules for changes to this macOS notch and menu-bar widget. They come from
corrections during earlier work on it.

## Doing the work

- Do the requested change in the same turn. When an instruction cannot be
  done from code, say which part and why; do not answer with a tool
  recommendation instead of the change.
- Menu-bar icons belong to their own apps; macOS has no API to hide another
  app's icon. Some apps have their own setting for it.
- Private window APIs (for example the `CGSSpace` calls that place a window
  above the menu bar): copy the exact declarations from an open-source notch
  app's source and keep its license notice. Never write private signatures
  from memory; a wrong signature crashes the app.
- Calendar (EventKit) and similar permission prompts appear and persist only
  for a real `.app` bundle. An ad-hoc-signed rebuild can make macOS ask again;
  say so after a rebuild, and relaunch the bundle so the prompt appears.

## Notch geometry

Draw one solid bar across the whole area, the notch included. Do not leave a
transparent hole for the camera: the hole is wider than the physical cutout,
so the menu bar shows on both sides of it as stray pixels and a border.

## Checking a change

- After every build, take a screenshot of the region and look at it before
  reporting. Do not ask the operator to check a defect the screenshot already
  shows.
- A screenshot shows the pixels under the camera area as if there were no
  notch, so it cannot show how the bar meets the physical cutout. Say that
  this one point needs his check; do not claim the screenshot verifies it.
- When a fix does not change the reported defect, look for a structural cause
  (window layout, a gap, a layer) instead of another small adjustment.
- Before reporting a change as done, list each point of his feedback and
  check each one against the new screenshot.

## UI rules

- Every visual element carries a meaning. Remove any dot, icon or color that
  does not encode a state he can name.
- A color code maps to thresholds he agreed on (meetings: far, 15 minutes or
  less, 5 minutes or less or live). For a new state, propose specific colors
  and what each one means.
- Show a list where the data has several items (the next few meetings, not
  only the next one). Cards have a slightly lighter background and a border
  color that carries the state, and show the fields he named.
- Use the full width of the panel.
- Every clickable control has a visible hover state and a pointer cursor.
- Hover-to-open waits briefly before opening and before closing.
- The expanded view opens on the page the collapsed view was showing.
