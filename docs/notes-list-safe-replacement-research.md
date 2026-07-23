# Notes list-safe replacement research

## Problem

Papuga previously deleted the detected text together with its trailing boundary and then recreated
both with synthetic key events. In Apple Notes, deleting Return can merge or remove the numbered
paragraph. Inserting a Unicode newline afterward is not equivalent to asking Notes to execute its
native Return command, so list numbering and indentation can be lost.

## Implemented approach

Papuga now anchors a correction to the focused Accessibility element and its UTF-16 text range.
Before changing text it verifies the process, focused-element identity, collapsed caret, and exact
source substring. It then selects and replaces only the source range; the following space, Return,
or Tab is never selected, deleted, or recreated. Unsupported or changed targets fail without
mutation.

Undo and retry use the resulting replacement range and repeat the same validation. Escape, ×, and
proposal timeout are reversible. Only the explicitly labelled `Ніколи не замінювати “…”` action
adds the source to Papuga's allowlist.

## Primary sources

- Apple defines `kAXStringForRangeParameterizedAttribute` as the substring for a supplied character
  range: [Apple Developer Documentation](https://developer.apple.com/documentation/applicationservices/kaxstringforrangeparameterizedattribute).
- Accessibility clients must check whether an attribute can be set with
  `AXUIElementIsAttributeSettable`: [Apple Developer Documentation](https://developer.apple.com/documentation/applicationservices/1459972-axuielementisattributesettable).
- `kAXSelectedTextRangeAttribute` represents the editable element's selected character range:
  [Apple Developer Documentation](https://developer.apple.com/documentation/applicationservices/kaxselectedtextrangeattribute).
- `kAXValueAttribute` represents the whole editable value, so Papuga does not use it for a local
  replacement: [Apple Developer Documentation](https://developer.apple.com/documentation/applicationservices/kaxvalueattribute).
- AppKit's text system applies surrounding typing attributes to inserted plain text, supporting a
  range-only edit that leaves paragraph structure untouched:
  [Text System User Interface Layer Programming Guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/TextUILayer/Tasks/SetTextAttributes.html).

## Verification matrix

- Numbered, bulleted, and checklist items in Notes, including first, middle, and last items.
- Space and Return boundaries; numbering, indentation, following empty item, and Cmd-Z must remain.
- Proposal accept after Return, dismissal/reopen, undo/reapply, and the configured undo shortcut.
- TextEdit rich text and a plain text field.
- Caret movement, note switch, and app switch before acceptance must abort safely.
