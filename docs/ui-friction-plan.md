# UI: fewer steps to the first images

Today, reaching the first image takes about 8 taps, 5 separate AI waits and 3
long scrolls. Along the way you must approve three AI outputs, even when you
change nothing. This plan cuts that to one tap and one progress screen for
the common case, and keeps every editor one tap away. It comes from the UI
audit of the current app.

**The checks don't change.** What stops a hallucinated image is enforced by
the server, not by the approval screens:

- every model reply is checked against a schema;
- the image checker answers yes/no questions, and "unsure" counts as a fail;
- images that didn't pass are hidden unless the server's inspection switch is
  on;
- the server alone decides what goes into a set.

Nothing in this plan loosens these, and each stage below has tests that pin
them (see Verification).

The work is split into five stages. Each can ship on its own, in order.

## Build checklist

- [ ] Stage A: quick wins in the app only (no server changes)
- [ ] Stage B: one-tap **Auto** run, driven by the app
- [ ] Stage C: Auto runs on the server, with progress you can leave and
      resume
- [ ] Stage D: lighter fixes: **Try with a note** for one plan, and automatic
      retries (Phase 8)
- [ ] Stage E: a notification when images are ready
- [ ] Simulator and TestFlight checks after each stage

## Stage A: quick wins (app only)

1. **3 plans by default.** The plan count starts at 3 instead of 1, and the
   choice moves to the top of the Blueprint screen's Variations card.
2. **Hide internal detail outside inspection builds.**
   - **Reference ready:** the color profile, EXIF rotation, file size and
     asset ID rows.
   - **Every step:** "Check passed / Passed on attempt N" cards.
   - **Image cards:** model name and timing.

   These stay in inspection builds (`showAiInspection`). Normal builds show a
   short line only when something failed.
3. **Shorter analysis.** Normal builds show three rows (hook, scene, camera)
   and a **More** toggle for the rest.
4. **A main button pinned to the bottom of each Create screen.**
   `AppScreen` gets an optional bottom action bar used for:
   - **Analyze**, then **Build blueprint**
   - **Plan variations**
   - **Create images**
   - **Review set**

   Errors from these actions appear in the bar, not only in a brief banner.
5. **Save on continue.** When nothing was edited, **Plan variations** and
   **Create images** save the draft first and carry on, so there's no
   separate **Save** tap. **Save** is shown only when there are edits.
6. **A first screen that isn't blank.** The empty Create tab gets an upload
   card ("Upload a slide to start") with a button, as well as the **+** in
   the nav bar.
7. **Clear reference choice.** The **Create** button becomes **Use this
   slide**, with a short line: "JustPost makes variations of the slide on
   screen."
8. **Results grid on the Images screen.**
   - A 2-column grid of thumbnails, each with a passed or didn't-pass badge.
   - Tapping one opens a detail sheet with the image beside the reference,
     the text style and position controls, **Show without text**, **What was
     checked**, **Try again** and **Fix in blueprint**.
   - A **Retry all that failed** button when 2 or more failed.
9. **Export from the grid.** Passed slides have a tick box. **Export
   selected** saves the set (`save_final_set`, in grid order) and opens a
   small sheet with **Save to Photos** and **Share**. **Review set** stays
   for reordering.
10. **The You tab.** The three "coming soon" rows are replaced by today's
    usage (see Stage C for the data) or removed until there's something to
    show. The tab itself stays.
11. **Bigger step bar targets.** Step bar chips get at least 44 pt tap
    targets and higher contrast.

## Stage B: one-tap Auto run (driven by the app)

- **Use this slide** starts an **Auto** run. A new Progress screen calls the
  existing functions in order:
  1. `ingest_asset`
  2. `analyze_asset`
  3. `build_blueprint`
  4. `save_blueprint` with the AI draft unedited
  5. `plan_variations` (3 plans)
  6. `save_plans`
  7. `generate_variation` for each plan, in parallel
  8. `render_slide`
- The Progress screen lists the steps: "Analyzed ✓, Blueprint ✓, 3 plans ✓,
  making images (1 of 3 done)…". Each finished step can be tapped to open its
  editor.
- **Review before images** is a switch on the Progress screen (remembered on
  the phone). When it's on, the run stops after the plans and opens the Plans
  screen, which is today's flow.
- If a step fails its checks, the run stops there and shows the reason with
  **Try again** and **Edit** (which opens that step's editor). Nothing after
  a failed step runs.
- When images arrive, the Progress screen becomes the results grid from
  Stage A.
- **Limitation:** the app drives the run, so leaving the Progress screen or
  closing the app stops it. The screen says so. Stage C removes this.

## Stage C: Auto on the server, with resumable progress

- **New function `start_auto_run(assetId, planCount, reviewFirst)`.** It
  records a run and queues the steps as Cloud Tasks
  (`tasks.on_task_dispatched`). Each step runs in its own function call with
  its current timeout. Each image is its own task, so images are made in
  parallel.
- The steps reuse the existing `run_*` functions, so the checks, retries and
  daily limits are exactly the ones used today.
- **New function `get_progress(assetId)`.** It returns each step's state and,
  for each plan, its status. A plan's image and slide paths are included only
  when it passed (or when the inspection switch is on, as today). The app
  checks it every few seconds while the Progress screen is open.
- **Leaving is safe.** The run carries on, and opening the reference from
  the Library brings you back to the Progress screen or the results grid.
  This replaces the Library's "can't continue editing" follow-up for runs
  started this way.
- **Usage.** `get_progress` also returns how much of today's limits are
  used, for the You tab and for a line like "7 images left today" before
  **Use this slide**.
- **Stage of each image.** The server records "making", "checking" and
  "adding text" for each plan, so the grid shows which stage each image is
  at instead of a generic spinner.

## Stage D: lighter fixes

- **Try with a note** on one plan. You type a short note (up to 200
  characters, for example "camera slightly above eye level"), and only that
  plan's image is made again. The note:
  - is stored on that image's run, not on the plans, so the other plans and
    their passed images are untouched;
  - is added to the image request under "Keep";
  - becomes one more required check question, so a "no" or "unsure" rejects
    the image like any other rule.

  It is your own text, checked for length and control characters. It never
  changes limits, permissions or what the server accepts.
- **Automatic retries (Phase 8).** When an image doesn't pass, the server
  makes one more attempt with the checker's reasons added to the request.
  The retry counts against the daily image limit, and the grid shows
  "attempt 2". This builds on the Phase 8 section of
  [`v1-backend-plan.md`](v1-backend-plan.md).

## Stage E: notifications

- A push notification ("Your 3 variations are ready") when an Auto run
  finishes while the app is in the background. It needs Firebase Cloud
  Messaging, an APNs key in the Apple developer account and the iOS push
  capability. It's a separate stage because of that account setup.

## Conflicts flagged, and how they are resolved

- **An Auto run confirms the AI's blueprint and plans without you reading
  them.** Until now, "confirmed" meant you had seen them. They have still
  passed their schema checks, and every image is still checked against them.
  But nobody has confirmed they're what you meant. Resolved by:
  - recording `confirmedBy: "auto"` or `"user"` on the blueprint and plans;
  - labelling auto-confirmed steps **AI, not reviewed** on the Progress
    screen and in the editors;
  - offering **Review before images** for anyone who wants the old flow.

  Nothing downstream treats "auto" and "user" differently.
- **3 plans by default triples the cost of each run.** The daily image limit
  is 10, so that's about 3 Auto runs a day, and **Retry all that failed** and
  automatic retries use the same limit. Resolved by showing "N images left
  today" before starting (Stage C) and turning **Retry all** off when there
  aren't enough left. Raising the limit is your call and isn't part of this
  plan.
- **Stage B's run stops if you leave the screen.** Stage B accepts this, and
  says so on screen, to ship quickly. Stage C is the fix. If you'd rather not
  ship a run that can be interrupted, skip B and build C directly.
- **The app still doesn't read Firestore directly.** Phase 9 removed all
  client reads, so the server can filter out images that didn't pass. Live
  progress could have come from a Firestore listener, but that would undo
  this. `get_progress` is polled through a function instead. It's slightly
  slower (a few seconds) but keeps the rule.
- **Each image currently says only "creating and checking".**
  `generate_variation` makes and checks the image in one call, so the app
  can't see which stage it's at. Stage A doesn't invent stages or estimates.
  Real stages arrive with Stage C.
- **The picker selects several photos but uses one.** The app's description
  is "slideshow variation studio", so choosing several may matter later.
  Stage A keeps multiple selection and makes the choice clear (**Use this
  slide**) instead of switching to picking one photo.
- **A note for one plan doesn't fit how plans are versioned.** Editing one
  plan raises `plansVersion` for all of them, and that marks every image out
  of date. Stage D stores the note on the image's run instead, so the plans
  and their version are unchanged.

## Verification

1. **Unchanged guarantees,** pinned by backend and app tests in every stage:
   - an image that didn't pass never gets a path on the asset, in
     `get_progress`, or in the grid, outside inspection;
   - `save_final_set` still refuses slides that didn't pass, including when
     they're picked from the grid;
   - "unsure" still fails, including for a plan's note;
   - an Auto run stops at the first step whose check failed and runs nothing
     after it.
2. **Stage A:** widget tests for:
   - the default of 3 plans;
   - internal detail hidden without `showAiInspection` and shown with it;
   - save on continue (no extra save call when nothing changed, and saved
     edits are used);
   - the bottom action bar;
   - the grid (detail sheet, **Retry all that failed**, **Export
     selected**);
   - the empty Create screen.
3. **Stage B:** a widget test with fake services runs the whole chain. It
   also checks:
   - a failed check stops the chain;
   - **Review before images** stops it at the plans;
   - tapping a finished step opens its editor.
4. **Stage C:** backend tests for:
   - `start_auto_run`, with each task step run by hand and the same limits
     applied;
   - `get_progress` hiding image paths that didn't pass;
   - an interrupted run resuming;
   - 2 runs for the same reference refused while one is still going.
5. **Stage D:** backend tests for:
   - a note becoming a required check;
   - other plans left untouched;
   - one automatic retry that counts against the limit.
6. **On a phone, after each stage:** time from **Use this slide** to the
   first image, and count the taps. Target: 1 tap, and no scrolling before
   the first image.

## Follow-ups (not in this plan)

- Larger exports (from Phase 9).
- Deleting a reference and its files from the Library.
- Ranking passed slides.
- Choosing several slides from one upload as separate references.
