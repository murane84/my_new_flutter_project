# Aluta — Friend List & "Our Space" Design Spec
**A future-reference design document for the friend-list rebuild + relationship spaces + personalization.**
Companion to: *Aluta Technical Analysis & Roadmap* and *Aluta Monetization & Positioning Brief*.
Mocks: `aluta-friendlist-concepts.html` (01–04), `aluta-friendlist-concept-05-hybrid.html` (recommended direction), `aluta-friendlist-concept-05b-ourspace.html` (Our Space + personalization).
Status: Design reference — not final visuals. Date: August 2026.

---

## 0. The rule this whole surface obeys
> Aluta is **not a messenger that plays music**. It is a way for two or more people to **feel close — present to each other — even when apart.**

Every element on the friend list either **makes two people feel more together**, or it waits. The friend list is the *front door* to that feeling, and — not coincidentally — the front door to **C1 (Listening Rooms)**.

The thing that makes the current page read as WhatsApp is the **arrangement** (sorted by last message; a row = a text preview), not the palette. So the rebuild changes **what the list is sorted by** and **what a row is made of**.

---

## 1. The chosen direction — Concept 05 "The Hybrid"
A fusion of Concept 01 (Tuned In) + Concept 04 (Vinyl), with Concept 03's story-ring folded in and Concept 02's mosaic kept as a *mode*, not the home.

### 1.1 Structure (top → bottom)
1. **Our Space** — pinned relationship(s). The wedge. *(§2)*
2. **Listening now · N** — friends currently playing/​in a room, **one-tap Join**. Sorted by presence, not recency. The emotional hook (FOMO + instant togetherness).
3. **Your circle** — everyone else, as rows, with one contextual line.

Presence decides order. Recency is secondary. A quiet person is never above a live one.

### 1.2 The row's contextual line — strict priority (never stack)
`live track` → `typing…` → `unread preview` → `taste-match` → `last seen`

Only **one** line shows, chosen by the highest-priority available state. "82% taste match · you both love Goon" replaces a dead "Contact" label with a reason to reach out — the music-graph moat surfaced where it creates a spark.

### 1.3 The signature "disc" (identity mark)
One avatar carries three states at once, no separate stories strip:
- **Outer ring** — story state: gradient = unseen, grey = seen, none = no story.
- **Mid arc** — a coral arc of the **real track position**, bound to the audio handler. Shown **only while actually playing**.
- **Inner** — a vinyl record (avatar/initials as the label) that **spins only while playing**.

Motion always means something. Idle discs are still.

### 1.4 Carried decisions (from the concept set — keep)
- **Kill the fake "0 online" pill.** Only show presence when truthful; "Listening now" *is* truthful presence — lean on it.
- **Drop the four identical red call buttons.** Nothing competes with **Join**. Call/message/dedicate/remove move into swipe (mobile) and row-hover (desktop).
- **Join is the only persistent CTA.** Protect its salience.
- **Type hierarchy:** name 15sp bold · preview 12sp @ ~60% · timestamp 10.5sp.

---

## 2. "Our Space" — the bond as a place
The pinned tile at the very top is **not a chat thread and not auto-assigned**. It is a *deliberate pin* — "this bond matters" — and it opens a **relationship profile**: the story of that connection through Aluta.

### 2.1 Single vs. multiple — bounded, scarce
The brief's unit is *"a linked pair **or a small circle**."* So:
- **One primary bond** → the hero card (wide, themed gradient). Usually the couple wedge.
- **A few more** → a horizontal **"Your Spaces"** row of smaller chips (family, a best friend). "＋" creates a new one.
- **Scarcity is the point.** If everyone is pinned, nothing is special. Suggested cap: small (e.g. 1 hero + up to ~4 chips), tunable.

### 2.2 What an Our Space contains (the relationship profile)
Opening a Space shows the connection's history — *not* messages:
- **Header:** overlapping avatars, shared name ("You & Belyner"), Together badge, the Space's theme colour.
- **Stats:** "Close since <date>", "days in a song" (accumulated shared-listening time), "🔥 listen streak", next milestone/anniversary countdown.
- **"Your song":** the most-played-together track, with play + count ("played together 43×").
- **Pinned moments:** a grid of saved moments — a dedication, a voice note, a photo, "first song", a memorable talk. User-pinnable.
- **Actions:** ▶ **Listen together** (into a private room for the bond) · 🎁 **Send a moment** · edit (name · theme).

### 2.3 Free vs. Together (monetization, kind by design)
- **Free:** 1 Space + recent history.
- **Together plan:** multiple Spaces + **history kept forever** + custom themes.
Upgrading **deepens closeness**; it never gates basic use. "People pay to not lose their memories."

---

## 3. Personalization — dark is the default, not a cage
Dark is the **signature brand identity** (red+black brand; dark makes cover art, the vinyl, and the glow pop; reads intimate/after-hours — on-thesis). Personalization layers on top in **three tiers**, always **curated presets, never a raw colour wheel**, so it can't fragment the brand or look bad.

| Tier | Scope | Free | Together / Moments |
|---|---|---|---|
| 1. App theme | whole app | Dark (default) · Light · System | — |
| 2. Accent | whole app | small preset set (Coral default) | — |
| 3. Space colour | per relationship | preset colours | **custom gradients · seasonal packs** |

Precedent already shipped: the **Now Playing background chooser** is per-surface theming in the same spirit — extend that system, don't invent a new one. Guardrail: **presets, not a free-for-all.**

---

## 4. Monetization mapping (where this surface earns)
From the brief — *subscription is the floor, moments are the spikes, ads fund reach, premium experiences are the ceiling* — in that order.
- **Lever 1 · Together subscription** → Our Space (multiple + forever-history + custom theme), priority room reliability.
- **Lever 2 · Moments & gifting** → the 🎁 dedication affordance on rows and inside a Space (song dedications, "thinking of you", anniversary animations, sticker/effect packs).
- **Lever 3 · Ads (free tier, reach)** → **the hard rule, made visible in the design:** *no ad ever inside a room, a call, or a thread.* Ads live only in public/discover surfaces (e.g. the desktop right-pane's discover area *between* sessions). On mobile the list stays clean.
- **Lever 4 · Premium synchronous experiences** (later) → watch-together, "tonight" ambient mode, guided rituals — expansions of Together.

---

## 5. Responsiveness — reflow, don't stretch
The mocks are phone-first, but Aluta is **Android + Windows + Web**. The layout must reflow:
- **Mobile:** stacked zones (Our Space → Listening now → Your circle). Actions via **swipe**; long-press → quick sheet.
- **Desktop/Web (wide):** the list **collapses to a left rail**; the **right pane becomes the presence surface** — a live **room preview** (Listen together / Wave) + a **"now playing wall"** (Concept 02's mosaic, finally in its right home as a *mode*). Actions via **row hover**. The right pane is the intimate surface → **it stays ad-free by design.**
- Touch targets ≥ 44–56dp; guard long all-caps names (e.g. "WIFEY HALOTEL") — the track line truncates before the name.

---

## 6. Motion & accessibility budget
- Animate **only on-screen AND currently-playing** discs; freeze off-screen; one shared ticker.
- The progress arc is bound to **real** playback position — true, not decorative.
- Respect `prefers-reduced-motion` (already honored in the mocks).
- Join → satisfying transition (row art expands into the room; shared-element feel) + haptic on mobile.
- When a friend **starts** playing, their row animates up into "Listening now" live (via the presence broadcast, §7).

---

## 7. What must exist behind it (data + backend) — and the C1 bridge
The "Listening now" spine only works with **live now-playing presence**, and that same layer is exactly what **C1 Listening Rooms** needs. **Build it once; both surfaces get it.**

### 7.1 The enabler: now-playing presence broadcast
- A lightweight, **expiring** presence signal over the WebSocket: `user X is playing track Y (art, position, room?)`, refreshed on play/seek/track-change, auto-expiring on stop/timeout.
- Friends' clients subscribe → rows move between "Listening now" and "Your circle" in real time.
- Extends the existing `story_posted`-style WS events; this is a *presence* channel, not a story.

### 7.2 Non-negotiable foundations underneath (from the roadmap/brief — do first)
1. **A1 — Authenticate the main WebSocket** (`/ws/{user_id}` currently accepts any id). *Security floor; before any paid user.*
2. **A3 — WS-first delivery** (demote the 2s poll to reconnect-only). *Presence must feel instant.*
3. **A2 — Push notifications (FCM)** so "come listen with me" reaches people who are apart. *(Already integrated this cycle — keep hardened.)*
4. **A4/A5 — P2P Listen-Together (WebRTC) + lock down media.** *Scale + trust for rooms.*

### 7.3 New data model (sketch — refine at build time)
- **RelationshipSpace**: id, member_ids (pair or small circle), name, theme, created/"close_since", pinned_moment_ids, is_primary, plan_tier. (Backend addition; the existing `Friend` table stays for the plain circle.)
- **PinnedMoment**: id, space_id, kind (dedication|voice|photo|song|note), ref, created_at.
- **ListenPresence** (ephemeral, likely in-memory/WS-scoped): user_id, track {title, artist, art}, position, room_id?, expires_at.
- **Aggregates** ("days in a song", streak, play-together counts): derive from listen sessions; store rollups per space.

---

## 8. Build order (suggested, incremental)
Each step is shippable and de-risks the next.
1. **Presence broadcast** (§7.1) on top of **A1 auth** (§7.2.1) — unlocks a *truthful* "Listening now" and is C1's foundation.
2. **Friend list v2 shell** — new zones (Listening now / Your circle), the **disc** component, one-line priority, swipe/hover actions. (Pure client; scoped-circle backend already done.)
3. **Our Space (single hero)** — RelationshipSpace model, pin one bond, the relationship-profile screen (stats + your song + moments).
4. **Multiple Spaces + chip row.**
5. **Personalization** — app accent + per-Space colour presets (reuse the Now Playing theming system).
6. **Monetization surfaces** — Together gating (multiple Spaces, forever-history, custom themes), 🎁 moments.
7. **Desktop reflow** — rail + presence pane + now-playing wall.
→ Then C1 Listening Rooms sits naturally on the presence + P2P foundation already laid.

---

## 9. Open decisions (park here; resolve at build time)
- Exact **cap** on number of Spaces (hero + N chips).
- Is an Our Space **strictly the pair/circle members**, or can it hold non-mutual "one-way admiration"? (Recommend: mutual only, consistent with the instant-mutual friend model.)
- **"Days in a song"** definition — sum of overlapping shared-listening time vs. count of days with any shared listen. (Recommend: days with ≥1 shared listen, simpler + kinder.)
- Whether **taste-match %** is computed server-side nightly or on demand.
- Ad placement specifics for the desktop discover pane (kept **out** of every intimate surface).

---

*Kept in `Aluta Project Audit Report/` beside the roadmap, monetization brief, and the concept mocks. This is the living reference for the friend-list rebuild and the C1 front door; update as decisions land.*
