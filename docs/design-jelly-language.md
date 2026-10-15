# Proposal: the jelly as Squircle's design language

**Status: proposal (2026-10-15), not built.** The user asked for it on
2026-10-15: "In the task UI it's not so obvious that the little pill things
are running agents. Can we make them look more alive, like agents. Maybe we
should be aligning around these blobby dudes as our design language. Across
the board." Nothing here changes product code yet; open questions are at the
end.

Visuals are in `attachments/jelly-language/`. Every jelly in them was drawn by
the overlay's real shader (`JellyRenderer.source` in
`app/Squircle/Overlay/GlassJelly.swift`), compiled on the Mac and rendered
offscreen. Two prototype knobs were patched into the scratch copy only (eye
spacing and cube aspect for identities, a no-face flag for direction C); the
surrounding screens are HTML mockups of the current UI (Clay palette, design A
chat), not app screenshots. Scripts: `attachments/jelly-language/prototype/`.

- `tasks-{light,dark}.jpg`: the Tasks sheet in A, B and C.
- `chat-{light,dark}.jpg`: the app's agent conversation with worker lines, the
  agent's live line and the counts capsule, in A, B and C.
- `capsules.jpg`: the counts capsule close up, A/B/C, light and dark.
- `home-{light,dark}.jpg`: Home with an app working and one needing you.
- `live-activity.jpg`: the Live Activity, Dynamic Island and notifications.
- `crew.jpg`: states × identities, sizes, and C's eyeless drops.
- `states-motion.mp4`: the five states moving (real shader, frame by frame).

## The rule

**A jelly always means an agent: one T3 thread, live.** Never decoration,
never a task, never a build. Where a jelly shows, something is (or was just)
acting on your behalf, and its face says how it is doing. Everything you touch
stays glass; everything that acts is jelly.

- The app's agent is the big one (34–40 pt, the overlay's creature). Workers
  are small ones (16–22 pt).
- **Colour means state, shape means who.** Body tint is the state (Clay's
  terracotta / ochre / olive / crimson, as the overlay and Live Activity
  already use). A worker's identity is in its proportions and eyes, never its
  hue, so the two never fight.
- A task row shows a jelly only while a worker is linked and alive. Queued
  tasks and "Ready to try" rows have none: the worker is gone, the build is
  what is left.

## States

| State | Colour | Face | Motion (live) | Still frame |
| --- | --- | --- | --- | --- |
| Working | terracotta | open eyes, reading along a line a word at a time | slow breath, saccades, timed blinks | eyes looking down-right |
| Needs you | ochre | worried tilt, looking up at you | a hop every ~3 s (the overlay's) | worried, raised |
| Done | olive | happy arcs | one gulp (squash ring-down), then still | happy |
| Idle / waiting | terracotta at half strength | heavy lids | very slow breath, rare slow blink | sleepy |
| Failed | crimson | `> <` squint | slumped (squashed, tilted), one shudder on arrival, then still | slumped squint |
| Stopped / offline | greyed, faint | heavy lids | none | the overlay's doze |

Done is a moment, not a state to hold: after the gulp a finished worker leaves
the Tasks row (its build stays) and, in the chat, its line keeps a still
happy face. All of these exist in today's shader except failed's slump (a
fixed squash and roll, already uniforms) and the reading saccades at small
sizes.

## Where they appear

- **Tasks rows** (the user's ask): the grey pill with a dot becomes the worker
  itself: a 22 pt jelly, its title, and under it the step it is on ("Reading
  TasksViewController"; "Asks: restart the service now?" in ochre when it
  needs you). Tapping it opens the worker, as the pill does today.
- **Counts capsule** above the field: dots become jellies. In B the working
  count shows the actual crew (up to three overlapping, then "+n").
- **Threads tab**: each thread's row leads with its jelly (agent big, workers
  small); finished threads show none.
- **Worker lines in the chat** ("Started worker · …", "From · …"): the person
  and message symbols become the worker's jelly in its current state, so the
  same little character you see in Tasks is the one that started, asked and
  finished here. Lines in old turns hold a still frame.
- **The agent conversation**: the app's agent sits just above the field at the
  left, with its live step beside it (replacing the plain live line of design
  A). Pushed into a worker's thread, that worker sits there instead. This is
  the overlay's creature, so the app and the overlay finally look like one
  product.
- **Home**: while an app's agent works, it peeks over its device's top edge,
  eyes down at the screen; needing you, it is ochre and worried. Idle apps
  show nothing (today's green dot goes).
- **Sim deck / PiP**: the jelly of the thread using a simulator peeks over the
  picture's top edge (replacing the text label in the fanned row), so you see
  which agent is driving it.
- **Live Activity / Dynamic Island**: the existing SwiftUI cube is replaced by
  the real jelly rendered to images: the agent large on the lock screen with
  its step, the crew small at the trailing edge; in the island, the agent
  leading and the crew trailing.
- **Notifications**: a notification from a worker shows that worker's jelly
  as the sender's avatar (Communication Notifications). Researched, not
  tested: it needs the communication-notifications entitlement and Push,
  which are blocked on the same Xcode account as Push today.

## Distinct identities

A worker's look is derived from its thread ID (a stable hash), so it is the
same jelly in Tasks, Threads, the chat, the PiP and the island:

- **Proportions**: three cube aspects (square, a little wide and squat, a
  little tall).
- **Eyes**: three spacings (close, normal, wide-set).
- **Temperament**: blink interval and glance tempo, so two working jellies
  side by side never blink in unison.

That gives nine looks. They are deliberately subtle (`crew.jpg`): enough to
tell "the one in this row is the one in the chat", not enough to be a cast of
cartoon characters. The agent is always the plain shape at full size.

Not proposed: hue per worker (it would collide with state), names or faces
with mouths, hats or props (cartoonish at 16 pt; see the open questions if
you want one tiny accessory). **Codex vs Claude**: no difference by default;
the provider is a detail of the thread, not of who is doing your work. If you
want them told apart, the least noisy option is eye shape (Claude round
beads, Codex short vertical bars).

## Directions

**A: Quiet glyphs.** Small still jellies replace the dots and symbols
(16 pt, face showing state, no motion). Only the app's agent is live, in the
conversation and the overlay. Cheapest and calmest; reads as "status with a
face" more than "agents at work". Rows keep today's pills.

**B: Little crew (recommended).** Every agent is a character: workers are 22 pt
jellies with their current step, live while visible and working, still
otherwise. The agent is the hero by the field. It answers the ask directly
(you can see who is working and on what) and makes Tasks, the chat and the
island tell one story. Budgeted as below so it never becomes a screen of
wobbling sweets.

**C: One creature, jelly drops.** Only the app's agent has a face. Workers
are small eyeless jelly drops that bud off it (its liquid bridge pinching,
the physics already in the overlay) and merge back when they finish; in the
conversation the counts capsule itself becomes jelly with the agent's head on
its end, exactly the overlay's docked form. Most coherent as one creature and
the strongest "material" story, but workers stay abstract dots, the thing the
user found unclear; and a capsule made of jelly blurs the glass-for-controls
rule.

A hybrid worth considering: B's crew everywhere, with C's capsule-with-head
as the agent's spot by the field.

## Restraint and performance

- **One live body, the rest flipbooks.** Only the hero (the app's agent in
  its conversation, the overlay creature) runs the full live Metal body with
  physics (`GlassJelly`). Every small jelly is a flipbook: short loops (about
  24 frames per state: breath, reading, hop, gulp, blink) rendered once by the
  same shader offscreen on the phone, cached by (state, look, size, appearance),
  and played as layer contents at 15–24 fps. A list never runs a shader per
  row.
- **At most four animate at once** besides the hero. Needs-you first, then
  working ones nearest the top; the rest hold their still frame. Off screen,
  covered, scrolled away or in the background: nothing plays.
- **Still by default**: old chat lines, Ready rows, Home tiles without work,
  notifications and the Live Activity are stills. ActivityKit can't animate
  anyway; state changes there are the motion.
- **Reduce Motion / Low Power Mode**: stills everywhere (faces still change
  with state); the hero keeps glances at touches as it does today.
- **Cost estimate (not measured)**: a 22 pt frame at 3x is about 50 KB
  cropped; the handful of combinations on screen at once is a few MB. The
  hero's cost is today's overlay creature (0.10 ms Mac GPU for a full-screen
  panel; the creature alone less).
- **Small sizes are denser.** At 16–22 pt the translucent material reads pale
  on cream, so small jellies draw at about 1.3× tint strength (as in the
  mockups); the hero keeps the overlay's material.

## One material, not two

Glass and jelly are the same physical idea: clear material under one light.
Glass is untinted and empty (controls: buttons, the field, the segmented
control, the capsule); jelly is the same material filled with colour and
something alive. To keep them one language:

- one light direction (upper left), one soft rim and one highlight for both;
  the jelly's streak highlight is the glass edge's highlight;
- jelly colours are only Clay's four status colours, so every jelly already
  matches the accent, the "Needs you" headings and the "finished" words;
- no jelly behind text (its body is never a card or a container, except in C);
- glass stays reserved for controls, jelly for agents; the user's bubbles stay
  tinted glass (they are yours, not an agent's).

## Rollout

0. **Shared jelly component.** Today the shader and creature live in
   `Overlay/GlassJelly.swift` behind `#if SQUIRCLE_OVERLAY || DEBUG`. Split it
   into: the shader and a `JellyLook` value (state, look, size, appearance,
   face pose) compiled into the app, overlay and stress modes; `JellySprite`
   (offscreen render to an image, the flipbook cache, a small `UIView` that
   plays one); and the creature body (`GlassJelly`, physics, hero only). Swift
   concurrency only (the flipbook clock is the display link the hero already
   uses). The widget extension can't run Metal: its images are pre-rendered
   on the Mac at build time by the same shader into the widget's asset
   catalog (the prototype renderer, made a build script).
1. **Tasks rows, counts capsule, worker lines** (the original ask), with the
   four-at-once budget and the stills rules. Extend the stress audit: no
   flipbook playing off screen or above the budget.
2. **The hero by the field** in the agent and worker conversations; the
   Threads tab.
3. **Home peeking and the sim deck.**
4. **Live Activity, island and notification avatars** (needs the signing
   fixes Push already waits on).

Each phase is checked in the simulator frame by frame in light and dark,
under Reduce Motion, and on the phone for battery and hitches.

## Open questions for the user

1. A, B or C (or B with C's capsule-with-head)? Recommended: B.
2. Should workers have faces (B), or only your app's agent (C)?
3. Are subtle identities (proportions, eye spacing) enough, or do you want
   workers more distinct (a tiny accessory, or a colour per worker at the cost
   of colour meaning state)? Tell Codex and Claude workers apart?
4. Home: agent peeking over its device while it works, yes or too cute?
5. Failed as a crimson, slumped `> <`: right, or just the sleepy grey?
