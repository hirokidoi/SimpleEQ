# 開発者向けメモ

ユーザー向けの説明・動作環境・セットアップは [README](README.md) を参照

---

## Overview

SimpleEQ is an application that intercepts all of the output audio on macOS, applies a graphic equalizer to it, and delivers the processed audio to the real output device.
First, let us trace, participant by participant, where the audio passes through and where it goes out.

1. On launch, the app switches the system default output to the dedicated driver. From then on, every sound the system plays — browsers, music players, and so on — flows into the dedicated driver.
2. The dedicated driver never plays the audio it receives out to the outside. It only writes it into a ring in shared memory, and nothing is ever audible from the dedicated driver itself.
3. The app's audio engine reads this ring, applies the EQ and the preamp, and then hands the audio to the real output device the user selected (speakers, headphones, and so on). It never writes back to the dedicated driver.
4. The output device actually plays the sound.

In other words, system audio travels a single path: dedicated driver (capture point) → shared memory (handoff) → the app's audio engine (processing) → output device (exit).
Turning the EQ off to bypass processing does not change the path itself; only the processing stage is skipped.

To make this path hold together, the app observes several rules.

- The dedicated driver and the app are separate processes, yet they read and write the same structures across shared memory, so a contract both sides agree on is required (→ The Shared Header Contract)
- Audio-related processing must keep running without dropping anything, so the places where it may be handled are strictly partitioned (→ Crossing Rules Between the Audio World and the UI World, Constraints on the Realtime Path)
- Too much or too little audio accumulating in the ring is a problem either way, so it is controlled to stay within a fixed range at all times (→ Occupancy Control)
- The output destination can move due to environmental changes (waking from sleep, another device being connected, and so on), so it is kept in sync by continually checking the actual state (→ Managing the Output Device Route, Restore Target and Restore Obligation)
- Replacing or uninstalling the dedicated driver itself is dangerous while audio is playing, so it is done only after a safety check (→ The Safety Guard Before Driver Operations, Determining Driver Liveness and Automatic Restart)

All of these states can be inspected as actual numbers from the Diagnostics screen.

---

## Glossary

- **Dedicated driver** — A CoreAudio driver based on Apple's official sample. The system sees it as a single output device. Pointing the default output at it makes every sound the system plays reach the app by way of the dedicated driver.
- **HAL / AUHAL** — The HAL is the layer in which CoreAudio absorbs hardware differences (Hardware Abstraction Layer). The dedicated driver runs as a plug-in inserted into this layer, and both driving the IO cycle and stamping the presentation time are done by this layer. AUHAL is the audio unit that connects to this layer, which the app uses to hand audio to the real output device.
- **Shared memory / shared header** — A cross-process memory region that the dedicated driver and the app read and write with the same layout. Because the two are separate processes, they have no other means of exchanging audio data and part of their state.
- **Ring** — A circular buffer placed in shared memory. The writing side (the dedicated driver) and the reading side (the app) are fixed one to one (single producer, single consumer), so consistency holds without locks even when the two advance at different paces.
- **Audio world / UI world** — The two execution domains inside the app: a single serial queue that solely owns the audio-related resources, and the main thread that builds and operates the screen. How they cross into each other is bound by explicit rules (→ Crossing Rules Between the Audio World and the UI World).
- **Analyzer** — The component that analyzes the output audio and produces the level meter values. Capture is performed by the realtime output callback and analysis by the drawing side, so it is a single producer and a single consumer and sits outside the crossing rules (→ Crossing Rules Between the Audio World and the UI World).
- **Token** — An empty type that can only be created on the audio world's queue and that every function mutating an audio resource requires as an argument, so calling one from outside the queue fails to compile. What it carries is not a value but proof that execution is happening somewhere the call is allowed. Reading it as data makes the crossing rules that follow impossible to follow.
- **Occupancy / target occupancy / ceiling occupancy** — Occupancy is the amount of audio accumulated in the ring that has not yet been read; target occupancy is the level the reading side tries to hold it at; ceiling occupancy is the boundary past which correction becomes necessary. The mechanism that maintains the relationship among these three is the subject of → Occupancy Control.
- **Priming** — Stopping consumption and waiting until occupancy reaches the target. Beginning consumption before it is reached breaks the instantaneous floor and cuts the audio off (→ Occupancy Control).
- **Control lease** — The expiry the app attaches to the per-application gains it pushes to the dedicated driver, renewed for as long as the app is running, so that gains cannot outlive the app that set them (→ Operating Rules for the Dedicated Driver).
- **Heartbeat** — A unit of no-op work posted periodically to the audio world's queue. The fact that it runs and returns a timestamp is itself the evidence that the queue is not stuck.
- **Presentation time** — The time the HAL hands to the dedicated driver on every IO cycle, representing when that audio will be played (→ Constraints on the Realtime Path).
- **Bypass** — The state in which the EQ and preamp processing is skipped and the input is passed straight to the output, without the audio path itself changing.
- **Normal view / compact view** — Two ways of presenting the contents of the EQ window. The frame stays as one and only the contents are swapped, so the two are not separate windows, and the window position is held separately per view. Which view is shown and whether the mixer surface is shown are two states that do not constrain each other, so either view can be carrying the mixer.
- **Target** — How much of a rise the automatic preamp adjustment is willing to leave in place, measured against the level a typical signal is expected to gain. It is not a ceiling on the peak (→ Deriving the Preamp). Raising it leaves the preamp shallower, which buys level at the cost of the peak indicator lighting more often.
- **Measurement chain** — An offline EQ chain built solely to measure the composite frequency response used to derive the preamp (→ Deriving the Preamp). It never sits on the audio path, and it is a separate chain from the one actually processing audio.

---

## The Dedicated Driver

It is based on Apple's official sample, NullAudio.
Everything else (the skeleton of AudioServerPlugIn property dispatch, the basic implementation of the box and plug-in objects, and so on) follows the sample's structure, and what SimpleEQ adds is the following.

- Writing audio out to shared memory (the layout definition lives in `Driver/Shared/`)
- Custom properties for the visibility override and the display-name override (showing/hiding the device from the general UI and switching the display name at runtime)
- A custom property for synthesizing drift (kept hidden as a standalone device custom property; for accelerated testing)
- A custom property carrying the per-application gains, and a table of the clients attached to the device, through which those gains are applied to each client's own output (→ The Per-Application Mixer)
- A setup in which the dB range of the Volume/Mute controls is obtained from the single source in the shared header. These controls themselves, however, do not act on the audio on the path (→ Operating Rules for the Dedicated Driver)
- Following multiple sample rates and deriving the ring capacity
- Declaring the device icon (pointing at an image bundled into the bundle)

The driver binary is bundled into the app bundle. The app only places it at the installation location and never builds it at runtime.

---

## Operating Rules for the Dedicated Driver

The dedicated driver has a fixed composition of one box and one device, and the object IDs do not change after launch.

For a selector to work as a custom property, it must be declared to the host in advance.
Only after seeing that declaration does the host start forwarding Has/Get/Set requests for that selector to the driver.
The data type of a custom property is limited to the string type or the property list type, and raw numbers and booleans are wrapped in these types for exchange.
A hidden custom property (one not exposed to the general UI) is not protected by that alone. Anyone who reaches it through the standard property API can Set it.

The visibility override is held as a custom property because the standard selector does not work for it. The standard selector that expresses whether a device is hidden from the general UI has its writes from external clients rejected by the host.
Replacing it on the assumption that the standard one suffices makes writes silently stop taking effect.

The driver acts on the audio passing through it in exactly one way: it multiplies each client's own output buffer by a per-application gain, in place, before that audio is mixed and written to the ring. It interprets nothing about the table of gains it is handed (→ The Per-Application Mixer).

A gain that is not neutral is only honored while the push that set it is still current. Each push carries a control lease, and once it expires, the driver ramps every client back to neutral on its own. This is the single condition that covers the app being quit, killed, or hung — nothing about the audio path is left muted by an app that is no longer there.

The Volume/Mute controls the driver exposes are a separate matter. They are the window through which the system's volume keys and volume UI operate, and the driver does not act on the audio on their behalf; volume and mute are each carried out either by the real output device or by the app's own gain stage (→ Managing the Output Device Route).
Where the app's own gain stage is the one carrying it out, the gain is derived from the same dB range the driver declared.
The upper end of that range being unity is what structurally guarantees that the app's output stage never moves into amplification even when the system volume is at maximum. Moving the upper end loses that guarantee.

State the driver holds only in process memory — whether the box is claimed, the device visibility, the display-name override, and so on — is not persisted. It returns to the defaults every time the host's service restarts.

The host never fully releases a plug-in it has loaded. The reference count returning to 0 must not be treated as the trigger for release or cleanup, and the count itself is maintained only to honor the calling convention.

---

## Versions

There are three of them, each with a different role. They are not kept in lockstep.

| Version | Role | When it is bumped |
|---|---|---|
| App version | Human-readable identifier of the app | Bumped manually when the app is modified |
| Driver version | Human-readable identifier of the driver | Bumped manually when the driver is modified |
| Shared header layout version | The compatibility contract between the app and the driver; machine-read | When the shared memory format changes |

The app and the driver can be modified separately, so their versions are held separately as well. A change to the driver's format bumps both the driver version and the layout version.

The driver version is carried in the shared header, and the app reads it from there. There is no path that reads information from the driver bundle.
It is read only while the layout version matches, and not being able to read it is itself the cue that a driver reinstall is required.

Where the same value is placed in more than one location — the driver version, the driver's bundle identifier, the device icon file name, the list of sample rates the driver declares, the relative placement of the bundled items — the match is not left to humans; the tests enforce it.
Moving only one side makes the tests fail.

The driver version and layout version shown on screen are the values actually written in the shared header, not the values the app expects.
The moment the two disagree is exactly when you want to read them, so they are never shown skewed toward the app's expected values (→ Diagnostics).

Version consistency only holds once the shared header — the foundation of the exchange — is in place.

---

## The Shared Header Contract

The shared header has two roles.
One is the definition of the shared memory layout: the structure definitions exist only here, and no duplicates are placed on either the driver side or the app side.
The other is to serve as the single home for the values that must agree between the driver and the app (the device identifier, the custom property selectors, the output volume dB range, the installation paths, and so on).
Both sides either reference this header directly or read it through dedicated accessors that do not redeclare the values, and neither side keeps a duplicate of a value.

Of these, the device UID is the external interface that a user-assembled Aggregate device configuration points at. Changing it with the intent of tidying up its spelling silently breaks the user's own configuration.
The tests still pass, so there is nothing to catch it.

The ring in shared memory that the dedicated driver writes to assumes a one-to-one composition, with the writing side fixed to the dedicated driver's IO thread and the reading side fixed to the app's output render callback.
Structure offsets are not hand-written on the app side; they are accessed only through thin C functions that take the header defining the layout as the common source, and no duplicate is kept.

The visibility of the shared region rests solely on publication order. This order is detected neither by the compiler nor by the tests, so when adding a field, always confirm where it is written.

- The group of fields for initialization is fully written first, and the identifying value is published last. The reading side confirms the identifying value is as expected before reading anything else. This pairing alone is the basis for "if the identifying value can be read, the rest can be read too"
- The audio payload is written first, then the write counter is published. The reading side reads the counter, then reads the payload. Writes where the value does not change from the previous one (writes that rewrote the same position) must be published as well. Omitting them leaves the rewritten content with nothing on the reading side to pair with
- The actual sample rate is updated first, then the generation counter is advanced. By the moment the reading side observes the generation change, the new value can be read as well
- For the write-time snapshot, a dedicated sequence number is advanced to an odd value, then the contents are written, and after writing it is brought back to an even value.
The reading side confirms the sequence number is **even** before reading the contents, and after reading, reads the sequence number once more to see whether the two match.
Reads where it was odd, and reads where the two disagreed, discard that read's value and use the previous snapshot

Some fields have no ordering pair. The most recent IO cycle length, the group of metrics concerning the write position, and the per-client activity a seat in the client table carries (its cycle counter, its peak, its clip count, the gain being applied to it) are those fields; these only rule out races, and guarantee no ordering.
They are values read as a rough indication, and their ordering relative to other values carries no meaning. When adding a field, decide first which of the two treatments it gets.

The client table applies the pairing above one seat at a time: the process and bundle a seat describes are written first, and the seat's identifying value is published last, so a reading side that sees a non-zero identifying value can read the rest of that seat. Freeing a seat invalidates its identifying value before anything else is touched, for the same reason recreating the shared memory file does.
Of the per-application gains, only the expiry that governs them lives here; the gains themselves are held in the driver's own memory (→ The Per-Application Mixer).

The last snapshot needs a caution the other three do not.
Because **the reading side does not retry** by design, if the sequence number sticks at an odd value, the reading side's timestamp stops updating entirely from then on.
The false verdict that the writer has stopped then sticks as well, and it never clears on its own. Three things must be observed to prevent this.

- The increment of the sequence number is done as a single read-modify-write. Splitting it into a naive load and store loses the increment whenever writers overlap, leaving it odd
- It is also restamped at the moment IO starts, and stamped before the running state is declared. Reversing the order lets a reading side that observed the running state read a timestamp left over from the previous run
- It is updated after the audio payload is published. The visibility of the audio data and the visibility of the timestamp are separate contracts, and the ordering of one is not used as the basis for the other

The shared memory file survives across reloads, so rewriting the initialization group while a valid identifying value is still in place lets the reading side observe "the identifying value is valid, the contents are mid-rewrite". When recreating it, invalidate the identifying value before writing.

The app's audio engine only reads this ring; it never writes to it or uses it as an output target.
This means the app never breaks the path along which an external tool reads the raw audio from the dedicated driver.

The shared memory file remains after the process exits, so the ring may hold the remains of audio from the previous run.
The first connection discards everything up to the writer's current position rather than treating it as the continuation of the sound that was playing.

---

## Crossing Rules Between the Audio World and the UI World

The audio-related resources (device queries, audio units, shared memory, and so on) are owned solely by a single serial queue called the audio world.
These resources may be touched only on this queue, and every operation that mutates a resource is required to take a token as an argument, which enforces the boundary at compile time.
What the token binds is ownership and mutation; it does not bind references themselves. Individual CoreAudio calls can block when coreaudiod backs up, so no path is created that calls them directly from outside this serial queue.

The analyzer does not count as one of these resources. Capture and analysis/display are directly connected as a single producer and a single consumer, so it is treated as being outside the scope of this rule.

The per-application meter values are carved out for the same reason and in the same shape: a single-producer, single-consumer holder of fixed-length arrays and atomic scalars, so no new exception has to be invented for it. What does not go through it is the roster — which client is present, and which application it belongs to — because that is not a per-frame value and copying strings is not something the realtime path does. The roster is read as an ordinary low-frequency request on the audio world's queue.

The analyzer's internals (the working buffers, the analysis window, the capture ring) are rebuilt whenever the sample rate changes. The rebuild is mutually exclusive with analysis by way of a lock, but capture is a realtime path and therefore takes no lock. That the two never overlap is guaranteed solely by the ordering that **the rebuild is only ever done while the output stage is stopped**. This order is detected neither by the compiler nor by the tests, so when adding places that call the rebuild, always confirm that the output stage is stopped at that point. The fact that the analyzer reference itself never moves is no substitute for this ordering.

The measurement chain (→ Deriving the Preamp) is excluded from these resources in the same way, for two reasons: it never sits on the audio path, and a single queue of its own is the only place that creates and uses it; and placing it behind a queue where CoreAudio's synchronous calls can back up would drag the derivation down along with them, the same reasoning that keeps determining the dedicated driver's availability off that queue (→ Determining Driver Liveness and Automatic Restart). What it derives reaches the UI world through the same outbound path as everything else that crosses from the audio world.

The way crossing works is defined asymmetrically by direction.

**From the UI world to the audio world** — The UI world never directly rewrites the audio world's state. Instead it submits a request saying "please do this" to the queue, and the actual reads and writes happen on the queue. At the moment it posts the request, the UI world side does not know the result.

**From the audio world to the UI world** — Code on the queue never directly reads or writes the UI world's state either. Even processing that is closed within the UI world, such as persistence, is done from the audio world's side only through an outbound notification path, and no direct write occurs.

Breaking this asymmetric handoff invalidates the premise of serial execution in the audio world — that judging, writing, and re-judging complete as a single pass on the same queue — because it creates room for another path to rewrite the intermediate state asynchronously.

Among the requests submitted to the queue, those carrying a key that denotes the same kind can be coalesced down to just the latest one.
This is a mechanism for requests where only the latest one carries meaning, such as periodic reconciliation or continuous updates during a drag, and the submission order across different keys is preserved.
Requests that must not be dropped, such as driver operations, are submitted through a separate path that is not subject to coalescing.

The realtime callbacks themselves do not require this token rule. CoreAudio callbacks are registered as C function pointers and cannot carry isolation, so they are placed outside the concurrency model this rule binds.

Building the UI side itself does not touch the audio world at all. Starting subscriptions and observations, which carry side effects, is done as an explicit step separate from building.

Values shaped for display (values that have passed through clamping, smoothing, or holding) are not fed back as material for a judgement.
When processing sits on the path from where a value is produced to where it reaches the display, overshoot and the very instant it occurred can no longer be expressed, so wherever a judgement is needed, the value is read by going back to the unprocessed form.
The clip indication on the level meter is judged on the amplitude before the system volume is applied, the same point the meter itself is drawn from. Judging it after would leave the indication meaning one thing on an output device that carries its own volume and another where the app carries it, since only in the latter case does the system volume reach the app's gain stage at all.
When values for a judgement arrive at a finer interval than the drawing interval, the analyzer itself takes the maximum of what arrived in that drawing interval before judging. The drawing side never accumulates several drawing intervals' worth before reading. How long a judgement's result stays displayed on screen (such as holding a clip indication) is managed by the drawing side using elapsed time.
Even when a judgement is derived from multiple inputs, the result is not held as state. Holding it would mean chasing "the instant it changed" separately for as many inputs as there are, so the same judgement is re-read each time at the point where drawing and evaluation happen.

This "derive each time" shows up concretely in the warning indication in the top bar and in the dimming/disabling of each control. The single fact that "there is no way for it to affect the audio" appears split across these two different presentations.

The conditions are not fully identical, however. The dimming/disabling side requires, in addition to no warning being shown, that the availability of the dedicated driver is not still being checked.
No warning is shown while the check is in progress, so right after launch there is an interval where the controls alone are disabled with no warning present. This is intended behavior, meant to avoid looking operable while nothing has been determined yet.

The divergence occurs in the other direction as well. In the interval where the driver has been found but the first assembly at launch has not finished and the output path cannot be established, no warning is shown and the controls remain enabled as well.
This is meant to avoid reporting an absence at a stage where nothing has been tried yet as an anomaly, but this interval is the only one where the fact that "there is no way for it to affect the audio" surfaces in neither presentation.

---

## The Per-Application Mixer

The division of labour is that the driver applies gains and decides nothing, and the app decides everything and touches no audio. What the driver is handed is a table of keys and gains; it matches a client against that table and multiplies. Which process belongs to which application, and what gain a row carries, are both settled on the app's side, because working that out needs interfaces that have no business running inside the host's audio service.

Tracing a client back to an application falls through four steps, in order: ask the system which process is responsible for it; failing that, walk up to the parent process; failing that, take the process as the application itself; failing that, give up. Giving up means no row and no entry — a client that cannot be named is not offered as something to control. The first step exists because an application that plays through a helper process would otherwise appear as the helper rather than as itself, and because two applications embedding the same framework would otherwise collapse into a single row under one bundle identifier. The symbol it calls is not part of the published interface, so it is looked up at run time and held as an optional: writing a declaration and calling it directly makes the app fail to launch wherever the symbol is absent. The step's availability is therefore a state the app can be in, and one that degrades silently, so it is surfaced in the Diagnostics screen rather than left to be inferred.

Two key spaces are in play and they must not be confused. What a row is saved under is chosen by the app and never moves for the driver's convenience. What a client is matched against is built by the shared header, from the client's own bundle identifier or, lacking one, its process id. A row saved under an application's identifier can therefore own several match keys at once, one per helper process, and the two spaces are related only through the resolution above. Both use the same `bundle:` prefix on the way in, which is exactly why the distinction has to be held deliberately.

A gain that is not neutral is only honored while its push is current (→ Control lease). The app renews on a period derived from the lease's own length, so the two cannot drift apart into a state where renewal arrives after expiry. Neutral rows are left out of the table entirely, which is what makes "nothing is being controlled" and "nothing is being pushed" the same condition, decided by comparing tables alone. The gains are written before the expiry is armed, so a realtime reader that sees an armed expiry is guaranteed to see the gains it governs.

A row keeps the match keys its clients have been seen under, so a relaunched application is matched the moment it takes a seat. Only a key built from a bundle identifier inside the row's own namespace is kept: a process id names a process that no longer exists, and a shared framework's identifier would go on being applied to whatever else embeds that framework once this application is gone. Deleting a row forgets the keys it held.

A match key that turns out to name the clients of two different applications belongs to neither: it is left out of the table entirely rather than resolved in favour of one. Every application the keys in play reach is counted here, whether or not it has a row of its own. Those clients keep whatever the system gives them, which is preferable to one row's setting silently reaching another application's audio.

---

## Constraints on the Realtime Path

The output render callback and the paths called from it, and the point where the dedicated driver writes audio into shared memory, all perform no locking, no memory allocation, and no logging.
This applies to the point where audio is written, not to everything called from the same IO thread (the point that responds to time reporting does take a lock).
They do nothing but pass values between preallocated buffers. Nor does the writing side make any decision about whether to write. As long as the deadline is met, it always writes, even when the presentation time has not advanced from the previous cycle.

Where a per-client value on this path needs an atomic float — a gain, a peak — it is carried as a bit-pattern integer instead. A plain atomic float's lock-freedom is implementation-defined, so declaring one could quietly reintroduce a lock here on whatever platform does not provide it lock-free.

Two values bound this path, and neither is free to move without checking what it costs. The frame count the render path preallocates for (`AudioConfig.maxRenderFrames`) is a hard ceiling rather than a hint: a request above it fails that render outright instead of degrading. The IO buffer length asked of the output device (`AudioConfig.ioBufferDeadlineSeconds`, held at a reference rate and converted per device) trades latency against how much slack the render has to meet its deadline, so shortening it moves toward dropouts.

The side that takes locks is the control path outside this realtime path. Some processing that rewrites the driving state itself takes multiple locks nested inside one another (starting IO is such a case).
The order of this nesting is kept aligned across paths. If even one path reverses the order, deadlock becomes possible.

The field that expresses the actual data amount of the output buffer is lowered on every render to the number of bytes the OS actually produced (by nature, the value only ever decreases).
When the requested frame count decreases and then increases again, forgetting to restore this value makes every subsequent render fail continuously, with no recovery on its own.
Waking from display sleep, a rate change on the output device, and a coreaudiod restart can each produce this situation, so it is restored unconditionally on every render.

While a configuration change (such as a rate switch) is being handled, the host guarantees that IO stays stopped. Only because of this guarantee is it acceptable to touch shared state while handling a configuration change.
A configuration change issues a change notification twice: at the point of acceptance, and after the new value has been published to the shared header. With only the notification at acceptance, a window remains in which a side that re-reads on seeing it still grabs the old value.

The value that tracks the write position is not something whose remainder can be used directly as an index into the ring. The actual write start position is obtained by going through a separate anchor calculation.

There are two values of different natures here, and confusing them invites incorrect modifications.

- **Write counter** — While running, it increases monotonically and never rewinds even across discontinuities such as a rate change. Correctness as seen from the reading side depends only on whether the signal that indicates a discontinuity differs from the value observed last time. However, when the dedicated driver re-prepares the shared region, it starts counting again from 0, so the reading side treats the counter going backwards as a normal path rather than an anomaly
- **Anchor-derived write start position** — This one, conversely, is re-established. There are three cases in which it is re-established: when the anchor itself is invalid, when the presentation time handed over from the HAL is an invalid value, and when the computed position ends up a full ring capacity away in either direction

When an interval that has never been written on that timeline lies just ahead of the write start, that interval is filled with silence before the payload is written.
Advancing only the counter without filling it lets the previous audio still sitting in the ring be read out as if it were new.
When the deadline is missed, no half-finished data is written; the whole write is skipped, and only the fact that it was skipped is recorded.
The next write fills the gap ahead of it with silence, so old audio never surfaces.

---

## Deriving the Preamp

While automatic adjustment is on, the preamp is not an independent piece of state; it is a dependent variable of the curve, the target, and the rate the driver has declared.

This differs from the "derive it again each time" pattern used for the top-bar warning and for dimming/disabling controls (→ Crossing Rules Between the Audio World and the UI World). Deriving the preamp is not cheap, so rather than deriving on every frame, it derives only when the input changes and caches the result. Staying at zero cost while idle is the property given the highest priority.

Derivation happens in exactly one place. What triggers it is the storage points of the inputs themselves, not the paths that mutate them, so a new mutation path cannot miss a hook by construction. The rate is the one input that arrives from outside the UI world, and it is taken in at the single point that receives that notification. Two more points ask for it directly: the step that starts the derivation at launch, and the control that returns to automatic, which asks again so that a measurement that failed is not left standing.

It remembers whether the value it currently holds is the derived value for the current input, and does nothing only when both the input and the held value agree. Remembering only the input would leave it unable to notice an external write to the held value.

Measurement runs on a queue of its own, so the relationship is established after the fact rather than at the moment an input changes. Until the first derivation lands, what is shown and applied is the value carried over from the previous run.

The chain's default dependency is built behind a lazily populated box rather than as the default argument itself, because Swift evaluates a default-argument expression at the call site: constructing it there would build the chain on the caller's thread instead of on the measurement queue it has to stay on.

Measurement results are cached keyed by the curve and the declared rate. The target does not affect measurement.

A rate change has no dedicated follow-up mechanism of its own: a mismatch between the requested rate and the rate the measurement chain was built for is itself what triggers rebuilding it.

Automatic mode blocks none of the preamp's controls: placing a value through any of them drops automatic mode, and the controls that hand it back take it back to automatic. What gates them is the same rule that gates every other control — while there is no way for the setting to reach the audio, they are dimmed and refused. The one that sets the target carries a second condition of its own, since it has nothing to act on while the derivation is off. Deriving still continues there, so the value is already right at the moment the audio comes back.

What a preview shows is only ever what applying it would produce. Since applying a preset moves the preamp as well, hovering one shows the value derived from that preset's curve, asked for without disturbing the value being held. Where the answer is not yet at hand, the value currently in effect is shown until it is.

The point where it is applied to the audio sits ahead of the EQ, so what it takes away offsets what the EQ adds at the same place in the chain. How much it takes away is not the whole of what the EQ adds: the target leaves that much of the expected rise in place, and the result is bounded at both ends and rounded toward the deeper side.

What the EQ adds is read two ways, and the deeper of the two decides. One is the rise a typical signal would see, which is what the target is measured against. The other is the steepest rise anywhere in the band, allowed to sit a fixed distance above the first; it is there so that lifting one narrow band steeply is not waved through by an average that barely moves. Where the second decides, the peak can still land above the target.

---

## Occupancy Control

The reading side consumes the audio accumulated in the ring and not yet read (the occupancy) while holding it at a fixed target occupancy.
The target occupancy is derived from the length of the block the writer writes at once, the observed frame count the client (the real output device) requests, and a margin for phase jitter. It is recomputed whenever either observed value changes.
The "writer's block length" here is not the value the dedicated driver declares but a value the reading side estimates by watching the increments of the write counter over an observation window; it differs from the most recent IO cycle length the driver declares in both who computes it and when (the Diagnostics screen lets you compare the two side by side → Diagnostics).

When the target occupancy has grown but the current occupancy has not yet reached it, consumption is halted so as not to break the instantaneous floor, and it resumes only after occupancy reaches the new target.

When occupancy exceeds the ceiling occupancy, the handling splits into two paths by cause. A stall on the reader side, or a step caused by switching the output destination or output stage, is far too large for ordinary correction to catch up with, so it is resynchronized immediately.
Gradual overshoot caused by clock drift is treated as within the authority of correction, and is trimmed only if it persists.
Handling both together with a single time threshold would drag the cost of an already-occurred dropout along as a long delay, so they are split by cause.
The maximum correction rate (`AudioConfig.driftCorrectionMaxRateFraction`) only sizes that wait. Nothing applies it to the audio: what eventually happens is a discard, never a change of rate, and the rate is there to express how long a walk back would have taken. Raising it shortens the wait, so overshoot is acted on sooner and more often.

There are four triggers for rebuilding the occupancy (discarding what is there now and re-priming up to the target): the first sync at connection time, resumption across a stop of the output stage, continued silence at the output stage, and a step with no definable counterpart to blend with.
These four are each counted as an independent metric. Merging the reasons into a single count would make a normal rebuild due to silence indistinguishable from a rebuild due to an abnormal stall, and isolating the cause would become impossible.
The first sync is likewise counted separately from an ordinary resync that crossfades a step that does have a counterpart to blend with.

A rebuild triggered by silence is performed only when both conditions hold: the output stage has stayed silent for a fixed duration (`OccupancyPolicy.silenceHoldSeconds`), and the occupancy clearly exceeds the target.
The judgement of whether it is off target carries a slack of one write unit, because on paths where the client's requested frame count varies from call to call even a healthy state has occupancy peaks slightly above the target, and without the slack every one of them would create a late start coming out of silence.

When trimming the read position down to the target, if a counterpart to blend with exists, the old and new cursors are joined by a crossfade — the same for an immediate resync triggered by a discontinuity and for a trim triggered by clock drift.
Because two correlated signals are being blended, a ramp of a few milliseconds (`OccupancyPolicy.seamFadeSeconds`) is enough, and stretching it longer sounds more unnatural, not less.

The seam with silence is decided differently (`OccupancyPolicy.silenceSeamFadeSeconds`): here the amplitude itself is moved between the signal and silence, so it must move more slowly than the period of the lowest band the EQ can handle.
The two lengths are independent, and the rationale for one is never carried over to the other. Inserted silence always leaves a trace in the metrics; no insertion is ever done silently.

While occupancy is being stabilized, the route itself — which device the audio goes out to in the first place — also needs to keep following environmental changes.

---

## Managing the Output Device Route

The app defines where the output should be, and the processing that reconciles this against the actual state of the device configuration is consolidated into a single entry point. Reconciliation is idempotent: when the actual state matches the intended state, nothing is written.

There are six targets of reconciliation: the visibility of the dedicated driver's device, the watch registered on that device, the output destination itself, the restore target, taking over a default output that has moved off the dedicated driver, and automatic restart after a stop. None of them holds up if a once-resolved value is cached and then used without verification.
The identifier assigned to the dedicated driver's device can change on waking from display sleep or on a coreaudiod restart, so just before use it is verified by the UID — the sole key for identification, persistence, and resolution — and re-resolved from the UID if it has gone stale.
The device actually being pointed at as the output destination can also be re-pointed without the app's involvement, by AUHAL's built-in fallback, so that ID is not cached either: it is read back from the output unit each time and matched against the intended destination by UID.

There are three kinds of triggers for reconciliation: HAL configuration change notifications, a low-frequency periodic recheck, and explicit user operations.
The periodic recheck performs reads only, and escalates to a write-bearing reconciliation only when the actual state disagrees with the intended state.
Without preserving this asymmetry, every tick of the periodic timer would produce writes to CoreAudio, and even harmless fluctuations would be reconciled.
Configuration change notifications can fire in bursts, such as when waking from display sleep, so notifications arriving within a short coalescing window are bundled into a single reconciliation pass.

The dedicated driver's device carries the real output destination in its own display name. A change to that name reaches only the clients watching that one device, and announcing it more loudly does not help: the host drops any announcement whose underlying value did not actually change. So the name change is followed by handing the system default output to the real output destination and immediately taking it back, which is a change the surfaces presenting the current output do observe. Nothing is placed between the two writes; a dwell there would let unprocessed audio out.

Both the name and the handoff are separate from the reconciliation targets listed above, and the read-only recheck performs neither: a stale name waits for the next write-bearing pass. This is the one place where the route management writes the system default output for a presentation-side purpose, so it is done only when the name was actually written and the dedicated driver is confirmed to hold the default output — confirmed, because a default output that cannot be read at that moment must not be treated as held. If the driver cannot be given the default output back, the route is recovered through the ordinary path that claims it. Where that path can read the default output, it replaces the restore target with whatever the default output is at that point, whether or not its own write succeeds, and the loss is accepted because the alternative leaves unprocessed audio playing with no way for the user to tell why.

The default output moving off the dedicated driver takes the audio away from the app entirely: nothing arrives any more, and the processing stays alive with nothing to work on. Where the destination it moved to is one the app could itself have offered as an output choice, that move is treated as a choice of output destination rather than as a fault, and the route continues through it — the output destination is switched to that device, and the default output is claimed back for the dedicated driver.

The order of those two is not interchangeable. Claiming the default output back before the output destination has moved would put the audio out of the destination the user has just left, so the switch comes first and the claim second.

The display name is written between the two, ahead of the claim rather than after it. The claim is itself a change of the default output, so a name already in place by then reaches the surfaces presenting the current output on the strength of that change alone, and the handoff described above is not performed on this path. Writing the name after the claim would announce the previous name and then require that handoff, which spends two more writes of the default output and opens the very window during which unprocessed audio can leave.

Which destinations qualify is decided by the same rule that keeps dangerous and unresolvable devices out of the output choices. One that does not qualify is left alone, and the state where the audio does not arrive remains visible as the warning it is. There is no retry and no fallback of its own: a switch, a name write, or a claim that does not succeed is left for a later pass to find, since every pass re-reads the actual state regardless.

The claim goes through the same path the app uses to claim the default output at launch, so the restore target follows to the destination that was taken over, and a clean exit puts the audio back where the user last left it. This continuation is performed only while audio processing is running; while it is stopped, where the output should go is the resume path's decision (→ Determining Driver Liveness and Automatic Restart).

The read-only recheck counts a destination waiting to be taken over as a disagreement with the intended state and escalates to a write-bearing pass, so a notification that was never delivered is still picked up at the next recheck.

The delay between the user's choice and the switch is dominated by the coalescing window: the notification itself arrives at once, and the work that follows it is short by comparison. Shortening the window shortens the delay by the same amount, and what it spends in return is how tightly a burst of notifications is bundled — and with it, how many times the output stage is restarted across that burst.

Whether any of this is done at all is a setting, because the behavior closes a route that exists without it: choosing another destination in the system's own UI is how a user moves the audio out from under the app while it keeps running.

Reaching a write-bearing reconciliation pass also rebinds the volume route to whichever real output device the output stage is pointing at by then. This is separate from the reconciliation targets listed above, and the read-only recheck does not perform it. That binding is what decides whether the system's volume operations reach the real output device or the app's own gain stage.

Which control on the device that binding reaches for is resolved per device, because a device does not have to carry its volume in the same place as the next one. The main element's own volume control is used where the device has one; where it does not, the virtual main volume — the same window the system's volume UI operates through — is used instead. A device that carries volume only per channel is reachable solely through the latter, and writing those channels directly would discard the balance held between them. Mute has no such second window to fall back to, so it is looked for on the main element alone.

Capability, reads, and writes all follow that resolution. The subscription to changes does not: it is placed on every window a device could carry, whatever this one turns out to carry. Registering and unregistering are then guaranteed to name the same set without either side having to ask the device, which matters because an identifier can come to point at a different device between the two, and a resolution done afresh at unregister time could then name a window the registration never used, leaving a subscription behind. The cost of covering a window the device does not carry is the error returned by the call and nothing else.

Binding reads the dedicated driver's own volume and mute afresh rather than reusing what the app last observed, falling back to what it holds only when they cannot be read at that moment. Either way the value is used solely as the input for aligning the two sides — it never stands in for a volume operation the user performed. The driver's copy returns to its defaults whenever the host's service restarts, so a value the app is still holding from before says nothing about what the driver carries now; treating a stale one as the current state lets the wrong value be pushed onto the real output device.

Where the app's own gain stage is the one carrying volume, the position it starts from on binding depends on what is known about that output destination. One already seen in the same session resumes at the position it was left at; one not seen yet starts at unity, which is where it would sit with the app absent. The first binding after launch is the exception, and continues from the position the dedicated driver still carries. None of these positions outlive the process, so none of them are restored across a relaunch. Landing on a destination not seen yet is therefore a move toward louder, bounded by unity.

The dedicated driver's own device, and any Aggregate/Multi-Output device that contains it, are excluded from the output destination choices.
The dedicated driver is the side that captures system audio by way of shared memory, so making one of these the output destination would turn it into a feedback loop path where the post-EQ output circles back into its own capture point.
AirPlay destinations are excluded as well. An AirPlay device disappears from the HAL's list once the system output selection moves off that endpoint, so one saved anywhere leaves behind a value that can never be resolved again.

Where these exclusions act is not uniform, and the difference matters when reading a saved value. All three are refused wherever a destination the app is to output through is resolved.
What can reach the saved restore target is a narrower question. The dedicated driver's own device never does. An Aggregate/Multi-Output containing it and an AirPlay device both can, because the record made when the default output moves away on its own takes whatever it moved to as it stands.
Putting the system default output back is a separate path again, and it consults none of this. A saved value that no longer resolves is therefore a state that can actually be met, rather than one to be read as impossible.
If the output destination does change to one of these dangerous paths while running, it falls back to the restore target (the output destination the user had selected before the switch). If the fallback destination cannot be resolved either, it does not stop at merely showing a warning: audio processing itself is stopped.

The dedicated driver's device is hidden by default and carries a fixed name. The app makes it visible at launch and hides it again on a clean exit once the output destination has been put back. The name returns to the fixed one on a clean exit as well, and whenever no output destination has been settled as safe to use.
The session that made it visible bears responsibility for maintaining that visibility only while the running state of audio processing calls for it, and does not maintain it across a stop that presupposes a restart.
Maintaining it would leave a device nobody consumes in the list with no way to put it back.
The dedicated driver's device can revert to the default hidden state on events such as a coreaudiod restart, so the periodic recheck in reconciliation reads the actual visibility value and reapplies it if it has gone back to hidden.
Whether the resolved identifier changed from last time is used as a proxy indicator only when the actual visibility value cannot be read.

The "restore" that is part of this route management has state of its own, distinctive enough to be worth digging into in its own section.

---

## Restore Target and Restore Obligation

A session that has made the dedicated driver claim the default output holds two pieces of state separately: the "obligation" to put the original output destination back on exit, and the "restore target", which is where to put it back to.
The obligation is set only when this app actually performed the switch in this session (or when the obligation from the previous launch has been carried over). The restore target keeps being updated to follow reality regardless of whether the obligation exists.

If the user or another app moves the default output away from the dedicated driver during the session, the claim is considered released and the obligation is dropped.
The default output at that moment, however, is recorded as the next restore target. If the claim returns to the dedicated driver, the obligation is set again as well, as long as it originates from this app's own switch.

The value representing whether the obligation exists is persisted. Because of that, an exit that could not restore properly — a force quit, for instance — can leave the obligation still set at the next launch.
Restoring unconditionally on the basis of this value alone would overwrite the user's own choice with a past saved value in the case where the user reselected the output destination themselves after the exit.
For that reason, both carrying out the restore and setting the obligation again are judged not by the persisted value alone but together with the reality of whether the dedicated driver's device is in fact still being claimed.

---

## The Safety Guard Before Driver Operations

Before performing an operation that rewrites or deletes the dedicated driver's binary (install, update, uninstall), the safety guard must always be passed through.
Performing such an operation as-is while the dedicated driver's binary is being referenced as the system's current default output can destabilize coreaudiod itself.

The guard switches to a safe real device before permitting the operation to run, and it does so only when the current default output is either the dedicated driver's own device or an Aggregate/Multi-Output device that contains it.
Where it moves to is the restore target, but it holds that destination to a condition the restore path itself does not impose: a destination that reaches the dedicated driver is refused rather than written, since moving there would leave the very state the guard exists to rule out. An Aggregate/Multi-Output containing the driver can be the restore target (→ Managing the Output Device Route), so that is a destination actually met rather than a hypothetical one.
If it cannot move away to a safe destination, the operation itself is not run.

Running the operation (an external process that involves elevating to administrator privileges) does not occupy the serial queue that owns the audio-related resources.
The queue is relinquished once the safety guard has passed, and once the external process completes, it returns to that queue to do the cleanup (rediscovery and reconciliation).

Operating safely presupposes being able to determine correctly whether the dedicated driver is currently alive.

---

## Determining Driver Liveness and Automatic Restart

Determining the dedicated driver's availability and version is derived solely from the result of opening shared memory, and does not call CoreAudio.
Even so, determining it on the serial queue that owns the audio-related resources would mean that while the CoreAudio synchronous calls queued there are stuck waiting on coreaudiod, the display stays pinned at "checking" even though the information needed for the determination is available. For that reason, determining availability is done on a separate path that does not go through that serial queue.

Immediately after opening shared memory there can be a window in which the header's identifying value temporarily shows an invalid value (the state where the driver's initialization has not finished).
In situations where a response can be waited on, such as right after launch or when determining availability, this invalid value is retried up to a fixed number of times by reopening. On repeatedly executed restart paths, on the other hand, no retry is performed.
Piling retry waits onto a frequently traveled path would accumulate delay with every failure.

The automatic restart that runs once the intended output destination becomes usable itself switches and restores the default output when assembly fails, and that produces configuration change notifications.
Those notifications wake the reconciliation processing again, so retrying without an interval would let failure keep driving itself and monopolize the audio service.
To avoid this, automatic restart attempts are throttled by both an interval and a consecutive-failure count, and give up once the limit is reached. If an attempt succeeds, the consecutive-failure count starts over.
Restarts from the user's own operation are not subject to this throttling, so recovery is still possible by operating it after it has given up.

Whether the serial queue that owns the audio-related resources is actually getting work done is judged by continuously posting no-op work (a heartbeat) to that queue at a fixed interval (`AppDelegate.audioWorldHeartbeatInterval`) and looking at the timestamp that comes back.
The heartbeat itself reads no CoreAudio and no state, so it never becomes a new source of congestion itself.
Intervals where the heartbeat was not actually posted, such as when the timer was coalesced away, are excluded from the judgement so they are not misjudged as no response.

---

## Diagnostics

Diagnostics is a screen for inspecting the audio world's internal state as numbers, and it does not appear in the normal usage flow.

### How to Open

The menu bar menu always has the Diagnostics-related items built in, but they are hidden by default.
They are shown only when a modifier key (Option) was held down at the moment the menu was opened. Pressing Option after the menu has opened has no effect, so it must be held while opening the menu.
Three items are shown: the operation to open the Diagnostics screen, the operation to reset the metrics (which can be performed even without the screen open), and the operation to export them straight to a file.

The other entry point is the Settings button on the preset rail in the normal view. It performs the same check at the moment it is clicked, opening the Diagnostics screen if Option is held and the normal Settings screen otherwise.

### Screen Layout

The screen is divided into panels (sections), each of which tries to answer a different question.

- A panel that reflects what configuration it is running in right now. Versions, the sample rates in various places, the driver's IO running state, the ring capacity, the target and ceiling occupancy, and so on are laid out here.
- A panel that reflects whether the audio is flowing without interruption. Occupancy and its gauge, the recent fluctuation range, the peak amplitude, and so on are laid out here.
- A panel that reflects what has happened so far. The number of times occupancy was cleared, the number of anomalies observed on the writing side, and so on are laid out as cumulative totals since the last reset.
- A panel for actually performing a reset or an export (it exists only on the screen and is not included in the exported text).

The item definitions for the upper three panels are produced from the same place for both the on-screen display and the exported text, so it is structurally impossible for the two to diverge.
The gauge exists only on screen; the export carries the corresponding numbers.

### Display When a Value Cannot Be Read

Values that reflect "the current configuration" are not padded with 0 or with the previous value while they cannot be observed; they are shown with a dedicated representation (`"---"`). There are several factors that can stop updates — the reader, the output destination, the responsiveness of the audio world — and the same policy applies to all of them.
This is not a matter of appearance but of correctness as a diagnostic. Showing the previous value or 0 while observation has stopped makes something that is in fact stopped look like it is running, or makes something that is running look abnormal, and misleads the search for the cause.

Values that reflect "what has happened so far" (the number of clears, and so on) are outside this treatment: they express what has happened up to now as-is, regardless of whether observation is available. They are never shrunk just because observation was interrupted.

When the dedicated driver newly re-prepares the shared region, the progress counters read from it start counting again from 0.
The side that consumes them does not assume the value increases monotonically; it re-establishes its baseline from the value that was observable at the demarcation point (a reset of the metrics, for instance).
Without re-establishing the baseline, "progress since the demarcation" would always be reported as 0 no matter how far it advances afterwards.

### How to Read the Numbers

The following is a guide to reading, in actual operation, the values on each of the panels reflecting "the current configuration", "the health of the audio flow", and "what has happened so far".

**Occupancy (current, target, ceiling)**
The current occupancy uses the median over the recent observation window (described below), to avoid the noise of a single observation.
The target occupancy is derived as described in → Occupancy Control.
The ceiling occupancy is the target plus a margin so that a backlog right after recovery is not misjudged as an anomaly even if the reader stalls for the worst case (`OccupancyPolicy.readerStopWorstCaseSeconds`), plus the write block length.

In a healthy state, the current occupancy stays stable around the target and does not stick at 0 or at the ceiling.
If the current occupancy frequently reaches 0, or if the number of re-primings due to a stalled writer keeps increasing, that is a sign of breaking the instantaneous floor — in other words, a sign in the direction of audio dropouts.
Conversely, if the current occupancy frequently sits near the ceiling, drift trims, resyncs, and in some cases occupancy clears are happening often. Since a single overshoot in itself is ignored as within the authority of correction, look at whether it is repeating or sustained.

**Occupancy window statistics (min, median, max)**
The distribution of the occupancy recorded over the recent observation window.
The window is a fixed-length ring that records one entry each time the output callback is invoked, and its size is defined by `AudioRuntimeMetrics.availableWindowCapacity`.
Separately from this there is also a window for determining the writer's block length (`SharedRingReader.writerBlockObservationWindowCalls`).
What they record differs, so do not confuse the two. A large gap between min and max means occupancy is swinging widely over a short time. It needs to be read together with the target and the ceiling.

**Running maximum of the target occupancy**
The maximum value the target occupancy has reached since the last reset. If it is clearly larger than the current target, it indicates there was a moment in the past when the target jumped.
The fact of the jump, read together with the number of re-primings (on the target-growth side), gives a sense of its frequency and scale.

**Peak**
Two running maximums of the amplitude, each held since the last reset: one taken before the system volume is applied, one after.
The one before is the output of the EQ and the preamp alone, and does not move with the system volume. The one after is what actually leaves for the output device: where the app's own gain stage carries volume or mute it follows what the app applies, and where the real output device carries both, the two agree.
The amplitude itself and dBFS relative to full scale are shown together. The amplitude is dimensionless, so where it will clip is read on the dBFS side.
The one before is what tells whether the EQ or the preamp is boosting too much. The gap between the two is how far the system volume is pulling the output down.

**The driver's generation counter**
A value that advances each time the dedicated driver starts IO and each time it changes the sample rate. Only whether it differs from the value read last time carries meaning; the value itself does not.
The number of changes is laid out as a separate metric on the "what has happened so far" side. If it keeps increasing with no operation or environmental change to account for it, the driver's IO is being brought up again and again.

**Partial reads and priming waits**
Both count calls where the requested frame count could not be satisfied, but they split into separate metrics by how far short they fell.
A call where not even one frame could be returned is counted as a priming wait, and accumulates as the duration for which the requested frame count was filled with silence.
Because it represents a state where there is not yet any audio to return, it includes not only calls while building up toward the target but also calls where the occupancy was entirely discarded.
A call where only part could be returned is counted as a partial read, and the shortfall accumulates into the dropped frame count.
Priming waits increase even in normal operation right after connecting or right after a restart, but a partial read is a call where supply ran out midway through a request, so an increase should be read as a sign in the direction of audio dropouts.

**Priming trim**
The number of times and the amount discarded when the occupancy at the point priming completed exceeded the target. It is a trim to land exactly on the target, and it always occurs whenever there is an overshoot.
There are two reasons an overshoot appears: writes arriving in a unit larger than the unit used to derive the target and stepping over it, and occupancy already being left over at the point the wait was entered (such as when the target grew and the wait was re-entered).
The former overshoot fits within one write, while the latter can become large depending on how much was left over at the point the wait was entered.
The discarded amount alone does not isolate the cause, so read it together with the re-priming triggers (writer stall / target growth).

**Occupancy clear counts by trigger**
The four triggers described in Occupancy Control (first sync, output restart, silence, seam) each have their own counter. Of these, only the first sync is placed on a separate row so that the discarded amount can be read alongside it, and what is laid out here is the remaining three.
Output restart and silence are values that increase in normal operation too, such as on device switches or when silent intervals occur, and increasing is not in itself an anomaly (the same goes for first sync on its separate row, which increases on every connection).
Look at whether the number of increases is proportionate to the number of operations and environmental changes.
The seam (a step with no definable counterpart to blend with) indicates a collapse beyond the margin Occupancy Control assumes, so an upward trend is itself worth suspecting.

Paths that only trim down to the target with a crossfade (resync, drift trim) each have their own counter as well.
For a resync, increasing by about one right after an output destination or rate switch is normal, but if it increases with no switch to account for it, suspect that the callback interval on the reader side widened (processing delays, for instance).
A drift trim is the ordinary correction for a gradual clock offset, and occurring occasionally at low frequency is within the normal range.
If the frequency or the amount discarded per occurrence clearly increases, that is a sign that the clock offset between the writer and the reader is larger than usual.

**Write position observations**
Four values decided by the dedicated driver's IO side, which the app simply transcribes and displays: presentation time stalls, presentation time inconsistencies, deadline overruns, and gaps filled with silence.
Only the deadline overruns directly express actual harm — those are the cycles where the write was skipped entirely and data was lost. Stalls and inconsistencies stay observations of disorder in the HAL-side metadata, since the writes themselves were not stopped, and silence fills tend to follow a deadline overrun rather than stand on their own.
Ideally all four are 0, but in terms of the weight of actual harm it is reasonable to read them in this order: deadline overruns, silence fills, presentation time inconsistencies, presentation time stalls.

**The driver's running state and the block length estimate**
The driver's IO running state and the block length actually processed in the most recent IO cycle are values the dedicated driver itself declares.
The block length that Occupancy Control uses, on the other hand, is a value the app side estimates by watching the increments of the write counter over an observation window; both who computes it and when it updates differ (→ Occupancy Control).
In a healthy state the two should be close in value, but there is no mechanism that automatically reconciles them and warns, so a large or sustained divergence has to be noticed by eye.

**The driver's actual rate and the output device's actual rate**
The rate the app uses for EQ processing is the rate declared by the dedicated driver.
Separately from that, the nominal rate of the output device that actually plays the audio is displayed alongside it. The two are treated as separate clock domains, and the design assumes they can disagree.
The reason the two values are shown side by side is to make it possible to confirm by eye whether these two clock domains currently agree.

**The volume route**
Volume and mute are laid out side by side, each written as the side carrying it out followed by the value in effect on that side.
The real output device carrying it out is the ordinary case for a device that has a control of its own. The app's own gain stage stands in for a device that has no such control, and for one whose control does not accept writes.
A marking of having been downgraded means the device advertised a control that accepts writes but did not follow through — the write itself failed, or the value could not be read at all.
Whether the value read back matches the value written is not part of that judgement for volume: the device and the dedicated driver hold it on grids of their own, so a write that comes back sitting where it started is a legitimate result of the device's grid rather than evidence of a control that does nothing, and what comes back is taken as that device's own value. Mute has no grid, so there a value that comes back differing from the one written does mean the write did not take.
The marking clears when the route is bound again to a different output destination, or when the dedicated driver's identifier is re-resolved; a rebinding that lands on the same output destination leaves it as it stands. An increase in how often it appears is a sign to suspect the device itself.
While nothing is bound — audio processing stopped, or the interval right after launch — neither the side nor the value is shown as what the binding before it held.

**Gauge**
It is attached only to the occupancy row, and uses its horizontal width as the range from 0 to the ceiling occupancy.
The right edge of the fill is the current occupancy, and the divider line marks the position of the target. A state where the fill goes past the divider and approaches the right edge means occupancy is approaching the ceiling.
If it is temporary, it is within expectations as consumption of the margin Occupancy Control assumes; if it is sustained or frequent, it is grounds for suspecting the system is being pushed, read together with the increases in each counter.
Note that the gauge's current position is the median of the window statistics and is a different value from the instantaneous occupancy the realtime path actually uses for its judgements. While the reader cannot observe, the current, target, and ceiling values are all drawn as 0.

**The per-application gains and the clients behind them**
The channel count is what the user has arranged; the count beside it is how many of those are set to anything other than unity. The client count is how many processes are attached to the dedicated driver against the size of the table that holds them, which is mostly system daemons that never produce a sound — a client being listed says nothing about whether it is playing.
The breakdown of how each client was traced back to an application says which of the four steps decided it. The row above it says which of those steps are available at all: losing the first one is a silent degradation, in which processes that share a bundle identifier collapse into one row, so the availability is shown in its own right rather than inferred from the breakdown.
The lease is the remaining time on the expiry that governs those gains. It reads as absent whenever no channel is set to anything other than unity, since there is nothing to take away then.

**Failures on the mixer's path**
These three answer the same question — why a gain did not take effect — at three different points, and all are normally zero.
A registration failure means a client could not be placed in the driver's table, so nothing can tell which application its audio belongs to and its gain never applies. A release by lease expiry means the app stopped renewing and the driver returned every client to unity on its own, which is the failure path for the app being killed or hung. A handover failure means the driver received more gains than its table holds and dropped the remainder, which leaves exactly those applications unaffected.

### Export

The export uses a snapshot newly taken from the audio world at the moment it runs, not the values currently shown on screen.
The on-screen values are only updated while the screen is open, so on the path that exports directly from the menu without opening the screen, the display values have not been updated.

Times are written through to the offset. The intended use is to lay several exports side by side afterwards and read their ordering, and a missing offset would make that impossible for records taken in different time zones.

When exporting more than once within the same second, a sequence number is appended to avoid an existing file.
The sequence number has an upper limit, however, and firing beyond it within the same second returns the last candidate as-is, so that one export alone overwrites.

---

## Rules for UI Rendering

In the rendering layers that manipulate CALayer directly, the order in which layers are added to the tree is exactly the compositing order.
When there are combinations of elements that overlap, changing the order of addition changes the appearance.
This is a visual regression detected neither by the compiler nor by the tests, so when changing the ordering, check whether any overlapping combinations exist.
Lowering an element's own alpha shows what sits beneath it, and whether that is a defect or the point is what decides the treatment. Where the element has to read as dimmed against an unchanged surrounding, its color is what moves instead. Where what sits beneath is exactly what should come forward, the alpha is the treatment.

The level display receding while the handles are shown is the latter case: what comes forward is the bar's own unlit outline, which is why that outline is left out of the dimming. The clip indication takes a shallower share of the same dimming, since what it reports is an exceedance rather than a level. How far the group recedes is a setting; the share the clip indication takes is not.

The rendering of the EQ itself is closed within CALayer, and SwiftUI's `Canvas` is not used.
`Canvas` carries a per-frame overhead even when its contents are empty, so during interaction a redraw occurs every frame and the CPU load jumps.
This property is not visible from reading the sources; it only becomes apparent through measurement.

`@Published` emits a change notification even when the same value is assigned.
Doing this unconditionally on paths that write values at high frequency, such as mouse drags or per-frame render updates, makes SwiftUI re-evaluate the entire view tree each time and significantly drives up the CPU load during interaction.
For that reason, per-frame display values are not routed through `@Published`; they are reflected directly on the CALayer side.
On paths that do use `@Published`, such as state changes during a drag, assignments are filtered so that a notification is emitted only when the value actually changed.
It also notifies before the property's own storage is updated. A handler that needs the new value takes it from what the publisher delivered; re-reading the model from inside the handler yields the previous one.

Colors applied on a per-frame path are built from their RGB components directly. Going through a SwiftUI `Color` to reach a `CGColor` resolves against the environment on every call, and doing that for each element of each frame costs more than the drawing it feeds. A color that depends only on fixed inputs — an element's index, whether it is lit — is built once and kept.

Periodic work whose only purpose is to drive a window's contents is gated on whether that window is visible. Closing a window does not detach the views inside it, so a view leaving its window is not a signal that arrives on close, and work gated on that alone keeps running for the rest of the session. Hiding a window without closing it delivers no delegate callback at all, so each place that hides one applies the gating itself. The auxiliary windows share a single rule for the decision, so that the gating of one cannot drift from another's. The EQ window's own drawing timer is not among them; it is gated on its own path.
What is read for this is whether the window is visible, not its occlusion state, which has been observed not to update at all in some runtime environments.
Where one surface inside the EQ window stands in the visualizer's place, the gates for the two are derived at a single place from the same inputs rather than written from each side that shows or hides something, because a gate assembled from more than one input is where one of them gets left behind.
A meter that is redrawn every frame discards what it was left holding — the values that piled up while its clock was stopped, and the height it is still drawn at — at the moment it becomes visible again, whether or not the clock itself starts on that occasion. What the smoothing is holding counts as held as well: emptying the input alone leaves it to decay from the height it had, since the next displayed value is built from the previous one. A peak that is cleared on retrieval keeps growing while nothing retrieves it, and a counter read as a difference has no baseline for the interval nobody watched, so the first frame after resuming would otherwise show the whole stopped period at once. Totals that accumulate from a reset are not among them.

If the internal identifier (action) assigned to a menu bar item contains certain words, the OS regards it as a standard settings command and may automatically attach an icon to the display.
What triggers this behavior is the internal identifier itself rather than the item's displayed text, so changing the displayed text does not avoid it.

What a person perceives as the speed at which the visualizer bars rise is not the length of the analysis window but the interval at which analysis results arrive.
The window weights the most recent samples the least, so the response appears not as a "step that starts late" but as a "slope that takes time to climb".
What the eye picks up is the moment it finishes climbing, and the time before that during which the bar is motionless — the interval until the result arrives — is what is perceived as sluggishness.
The analysis step size is decided separately from the window length, so this alone can be tightened without lowering the frequency resolution.

Rendering and analysis are driven by the same timer. There is no dedicated analysis timer; the render timer asks the analyzer every frame to "analyze what has accumulated" and then retrieves the display values.
Analysis processes everything that has accumulated, so the number of windows analyzed is pinned to the frequency at which analysis results arrive (the hop arrival rate) and does not change no matter what the drawing step size is set to.
Rebuilding the analyzer does not clear the values the drawing side is already holding; those are replaced only at the next retrieval. They are dropped at the moment visibility resumes as well, since leaving them shows the previous picture until the next frame lands.

The level meter's smoothing steps are held as a coefficient per update.
Because of that, changing the interval at which analysis results arrive changes how the same step behaves in real time. When the analysis step size is moved, the layout of the steps is redrawn as well.

Tuning items that have a range or a set of steps assume that the default value falls within that range or set of steps.
Falling outside makes the corresponding slider unable to show its initial position, and makes the "restore defaults" operation write a value outside the range.

`NSWindowController` takes the window's delegate for itself when it is created. A delegate assigned before that is replaced with no diagnostic of any kind, and none of its callbacks arrive; the window still opens and closes normally, so the failure reads as a fault in whatever the callbacks were meant to do. Assign the delegate after the controller exists.

A window without a frame cannot become the key window by default, and has no standard path for the close operation either.

Moving a window's style back and forth to and from frameless makes that window stop being composited from then on, drawing none of its contents at all. Prompting a redraw does not bring it back.

The corners of a frameless window are rounded by hand. The window is made non-opaque, and each surface that reaches a corner rounds its own corner. No mask is used.

An AppKit view placed inside SwiftUI takes every click over the overlapping area. This is the same whether it is placed in front or behind.

One of them can decline a click point by point so that the one beneath goes on receiving, and what it declines it declines entirely, the menu included. Being reported the pointer is separate from answering it, so the area a surface watches is not bounded by the area it answers on.

Window movement via background dragging is not used. The operable areas SwiftUI draws have no backing view, and operations within the area turn into window movement.

When moving a window with the pointer, the pointer's position on screen is used. Movement measured within the view stops increasing by however much the window has followed along.

The position at the moment of grabbing is held in a way that does not cause a view update. If an update runs during the drag, the gesture is swapped out and the end notification never arrives.

The consecutive-click count keeps arriving already incremented as long as it is within the detection interval. An operation triggered by a double click is judged on "exactly 2".

Do not overlap a surface that receives double clicks with a surface that responds to single clicks. Delivery of the first click is held back until the second one is seen, which makes the response sluggish.

An inactive window by default does not deliver the first click and uses it only for activation. Whether it is delivered is decided by the surface that became the hit target. SwiftUI controls have no AppKit view, so that surface is the hosting view.

A shadow is drawn outside the layout bounds of what casts it and does not enlarge them. Where a glow is a large part of what makes an element look the size it looks, the area that answers the pointer has to be widened by hand to match, and the widening is taken back out of the gaps around it so that nothing moves on screen. Widening it from the inside — enlarging the hit shape and then pulling the layout size back to what it was — does not work: the click is clipped to the layout bounds even though the pointer shape is not, which leaves the cursor changing over an area that refuses the click.

The shape of the pointer over a surface whose answer does not move is declared on that surface, not set by hand when a hover notification arrives: a shape set by hand is left behind by the press that follows. Where the answer depends on where the pointer is, there is nothing to declare, and it is set afresh on each report of the position instead.

Everything that acts on a handle — grabbing it, and the double click that returns it to its default — answers only while that handle is shown, and reads the same condition the pointer's shape does. What brings the handles into view is a choice between a press and a press held, because a surface that answers a stray press is where a stray press does damage.

Whether the pointer is still inside the visualizer is read from its position, not from the notifications that report it leaving. Both the hover reporting of the UI framework and a tracking region installed by hand announce a departure while the pointer is still inside that area. Keeping the handles visible while the pointer stays there is therefore driven by reading the position. The preset rail still goes by the notifications, where a spurious departure costs one lost preview.

Where elements inside one container fade on separate schedules, the alpha is carried by each layer rather than by the container. It is the alpha alone that moves out of the container; what else the container carries, the compositing order among it, stays where it is.

---

## Settings Persistence

Settings persistence takes the form of encoding and decoding a single structure as a whole.
Decoding fails for the entire structure if even one non-Optional property is missing, and in that case every item returns to its default.
There is no intermediate state in which only some items return to their defaults.
An item added to the format therefore takes the Optional form, its absence being read as that item's default, unless discarding what is already saved is itself the decision: a non-Optional addition takes the curve, the presets, the mixer's channels and the window positions along with it, for the sake of the one item it adds.
Optional is also the form for an item whose absence is the value — that nothing has been settled yet, or that a value should keep following automatically.

The output device selection has two independent pieces of state: the persistence as the default to use at the next launch, and the selection actually switched to in the current session.
Changing the former does not affect the latter, and the latter is session-only and not persisted.

What identifies a resource — the key it is persisted under, and the key it is resolved through — is a symbolic value that does not move with how the resource is presented: a device's UID, a process's bundle identifier. A display name is for display, and the name shown is looked up from the identifier each time rather than stored alongside it. A name is not stable enough to resolve through: it is absent while the thing is hidden, it arrives late across process boundaries, and it changes for reasons that have nothing to do with identity. Where a display name is found in use as a key, it is treated as belonging to the same problem as every other such use rather than as a separate concern.

An identifier that names one of a fixed number of slots carries the slot and nothing else. Whatever a slot happens to start out holding — a title, a curve, a default value — lives in a separate table keyed by that identifier. Giving some slots meaningful names while the rest are left with placeholder ones puts the initial contents inside the identity, and the asymmetry then spreads into every switch and table that has to name them.

---

## Build and Tests

What is required to build is in the [README](README.md).

The app's Xcode project is generated from `project.yml`, so it is not included in the repository.
The dedicated driver's project is not generated; the repository holds it (its build settings are edited by hand). The app's project references it and holds the driver as a dependency of the app's target.

Building the app includes building the driver and bundles the product under Resources in the app bundle. What is bundled is the driver binary, the install and uninstall scripts, and the shared layout header the scripts read.
The scripts read the header relative to their own location, so the bundled items are placed in the same relative arrangement as in the source tree. This arrangement appears split between the side that writes it (`project.yml`) and the side that reads it (the app and both scripts), and the match is enforced by the tests.
The tests do not assemble the app bundle, so whether the bundling itself succeeded is confirmed on a real machine.
The install script looks for the driver binary in the bundled location and, failing that, looks at the build product in the source tree. This is what keeps alive the path for replacing the driver without going through the app.

Installing and removing the driver requires administrator privileges, so they are not run from `make`; it only prints the commands. The printed commands are run by hand.

The tests create a disposable storage area. macOS leaves a preferences file behind for each such name, so `make test` also cleans up after the tests.
If the tests failed and stopped partway, running `make clean-test-prefs` on its own recovers from it.

Some tests drive the real assembly against a real output device, since an audio unit cannot be built without one. Those reach the machine the tests are running on in two ways, and both have to be closed off.

The first is the volume. The volume route binds the dedicated driver's volume to the output device's and mirrors between them, so driving it moves that machine's volume, and the end it converges to is unity. What keeps it out is a stand-in for the device reads and writes the route reaches for.
The second is the sound itself. The output stage really starts, so whatever is in the ring reaches the speakers. What keeps that silent is muting the app's own gain stage, and the mute has to be in place before the assembly runs, since the assembly is what reads it and carries it into the route. It is the app's stage rather than the device's because muting the device would be the very write the first point rules out.

Before reporting the number of tests, run `swift package clean` (`make clean` does not delete that area). Incremental builds drop diagnostics.

---

## License Layout

Two files carry the license, both named `LICENSE`: [the one at the repository root](LICENSE) covers everything except the dedicated driver, and [Driver/SimpleEQAudio/LICENSE](Driver/SimpleEQAudio/LICENSE) covers the driver.

The driver side holds separate terms because the driver bundle physically leaves the app.
It is placed in the system's plug-in directory, remains after the app is deleted, and can also be built and handed over on its own.
So that the license is readable even in that detached state, the driver-side terms carry both the base copyright notice and the SimpleEQ copyright notice, and are self-contained.
They are bundled into the driver bundle's resources at build time.

A `LICENSE` is bundled into the app bundle as well. It is not there to be read; it is there so that the product carries its own terms.

What the About screen presents is only the name of the terms and the copyright notice; it does not present the body of the permission text. The spellings shown on screen are held on the code side, and the match is enforced by the tests. Two things are covered.

- The terms for SimpleEQ as a whole — the format assumes the name, the copyright notice, and the body of the permission text are laid out separated by blank lines. What is shown on screen is the first two paragraphs of that. Breaking the format makes the tests fail
- The dedicated driver's terms — the format assumes it contains the copyright line the screen's attribution shows. There is no constraint on this one's format itself
