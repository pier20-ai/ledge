# Ledge design principles

Sixteen rules. Every surface, mockup, and app follows all of them.

## A. Proportion — it's a notch, not a window

1. **Notch-scale, not app-scale.** Nothing here is a shrunken desktop app. Every
   element defaults one step lighter than desktop instinct: hairline over stroke,
   ghost over filled, tint over color.
2. **The shell owns chrome; apps own almost none.** Navigation, app switching,
   settings, close, expand — shell, drawn once, identical everywhere. An app gets
   its content well, its rows, and at most two controls.
3. **Color is quiet until it means something.** Semantic hues only, each with a
   fixed meaning. A panel at rest is ink, hairlines, and at most one hue doing a
   job. Bold fills mark the one moment that warrants them, never decoration.
4. **Words are the scarcest resource.** Numerals, glyphs, labels of a word or two.
   A sentence is a design failure everywhere except an empty state's single line.
5. **Show the datum, not UI about the datum.** Before an element exists, ask
   whether it needs to. When it does, use the simplest honest display: a score
   is a number — not a labeled box around a number.

## B. Continuity — every surface is the notch

6. **One material, one body.** Panel, mini, wings, the torn-off window: the same
   black glass as the notch, swelling, stretching, or detaching whole — never a
   window that appeared nearby.
7. **The swell is the notch growing, not a panel dropping.** Notifications and
   hover summaries deform the notch itself — downward and outward, with the
   silhouette visibly continuous. The physical notch is an exclusion zone:
   nothing ever renders behind the cutout; content wraps around it.
8. **Persistent controls are notch-anchored, never panel-anchored.** The panel
   may take any size, centered under the notch, because no control depends on
   its frame. A hover earns only a glance surface — the swell, the summary;
   the visit opens by click and closes by click, Esc, or a walk-away timeout
   that never fires mid-interaction. A heavy visit owes a hover summary; a
   light one is its own summary.
9. **Wings have a fixed vocabulary and one owner at a time.** Below the visit
   state, apps choose from an enumerated set (glyph, ticker, meter, fixed-slot
   canvas) and the shell arbitrates who holds each surface; in a visit, the
   wings are Ledge's own controls. Click is the only gesture, save two: a
   horizontal swipe walks the session strip, and dragging the panel off the
   notch parks it.
10. **Motion is the personality.** The fun comes from how surfaces move — swell,
    zoom, split, fly home — never from adding color or copy. Every state change
    is animated on the house springs; Reduce Motion swaps motion for fades.

## C. Hierarchy — what the product is

11. **The agent conversation is the foundational interface.** It is designed
    first and held to the highest standard; its idioms set the tone for
    everything else. The transcript reads like iMessage, never like a terminal.
12. **Chrome is universal; content is the identity.** Apps are indistinguishable
    in chrome and distinguishable only inside their content well plus one accent.
    The flat-vector sprite style is a content style; it never touches chrome.
13. **An app is a job, not a demo.** A recurring job, a reason to live on the
    notch, and a quiet default state — or it doesn't ship. Theatre never costs
    the job. Fixtures stay fixtures; showcase apps are few; nothing is retired
    by a mockup.

## D. Discipline — the rules that keep it true

14. **The protocol is the design system.** Mockups use only what the renderer can
    express; anything else is an explicitly labeled platform proposal.
15. **One token source, copied whole, never forked.** One palette, one type ramp,
    one radius rule (concentric: child = parent − inset), one shadow ramp, one
    control ramp. An inline literal is a defect even when its value is correct.
16. **Fix ugliness at the platform level.** A defect shared by several apps gets
    a platform fix, never per-app patches. Mockups are contracts, reviewed at
    real size on the real notch.
