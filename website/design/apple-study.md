# Apple reference study — Marr web redesign

Examined 2026-10-14: Apple HomeView, MacBook Pro, AirPods Pro, then the iPhone overview and iPhone 18 Pro page. The latest revision includes browser observation of the iPhone camera sequence. Sources:

- [Apple HomeView](https://www.apple.com/apple-homeview/)
- [HomeView stylesheet](https://www.apple.com/v/apple-homeview/a/built/styles/overview.built.css)
- [MacBook Pro](https://www.apple.com/macbook-pro/)
- [AirPods Pro](https://www.apple.com/airpods-pro/)
- [iPhone](https://www.apple.com/iphone/)
- [iPhone 18 Pro](https://www.apple.com/iphone-18-pro/)

## Observed design rules

Apple uses white/#f5f5f7 surfaces, #1d1d1f primary, #6e6e73 secondary, #0071e3 buttons, #0066cc links. HomeView's 48px/600 section heading has near-neutral tracking (-0.144px in the rendered English heading). Its content container is up to 1260px, 87.5% wide. Product imagery dominates the composition; frames don't imitate extra devices. Cards have 28px corners. Hero media plays once, editorial sections fade/translate about30px over .7-.9 seconds, highlights use horizontal scroll-snap and explicit play/pause/navigation. Scrolling animation is reserved for meaningful product transformations.

## Applied to Marr

Removed olive/warm palette, device outline, perspective and colored shadows. Kept native-sized Marr glass tools and windows in a transparent product stage. Hero uses an enlarged window pair. Three horizontal highlights introduce translation, asking and Work. Two product stories provide direct manipulation and explicit step navigation, with one dark Work reveal between them. No global scroll interception or automatic carousel; wheel events are passive. Manual iframe work stops scene synchronization and survives scrolling away, returning and resizing. Only an explicit return to the demonstration, step choice or playback exits manual interaction. Reduced motion removes pinning and transitions while preserving explicit steps.

Product UI remains in demo/ and its source-aligned geometry is independent from website branding. Apple images, logos, and product assets are not reused. Stylized highlight cards are feature illustrations; actual interaction runs in the demo stage. All translation, Conversation, and Work results remain local preset examples with no service calls or project-file writes.

## Earlier HomeView interpretation

HomeView separates normal document scrolling, a horizontal highlights gallery, explicit ProductViewer controls, and selected cinematic sequences. Its hero uses InlineMediaPlayOnce; the entertainment sequence uses about 205vh for one continuous transformation. These observations do not justify turning every detail into a vertically scrubbed step.

The earlier Marr implementation combined 55vh of additional sticky travel with an independent presentation that played once on entry. Its translation and asking sequence lasted 20.7 seconds. Those two timelines did not correspond: fast scrolling left the demonstration before it explained the feature, while slow scrolling could hold a static composition or change the scene without a corresponding gesture. That implementation is superseded by the scroll-led behavior below.

The reading window is landscape (570×492); Conversation keeps its native 420×596 internal geometry but is displayed at .78 scale. A source-only scene is centered, then makes room for the Conversation window. Hero dimensions use available viewport height rather than a fixed 660px stage. These are Marr-specific design decisions based on the observed reference, not claims that the site reproduces Apple's implementation.

## iPhone observation and current interaction revision

The iPhone pages retain ordinary document scrolling for the opening content and use an independently controlled highlights gallery. The iPhone 18 Pro camera section provides a different pattern: its `sticky-container` remained at `top: 0` with a measured height of 901px in the inspected viewport. Between document scroll positions around 4770px and 5265px, the screenshots showed the lens close-up and accompanying text transitioning toward the phone's camera group. The useful reference is that scroll travel produces a visible product transformation. Those measurements describe the inspected session, not a universal Apple layout constant.

Marr now applies that rhythm to its own windows and interactions:

- At widths of at least 541px and heights of at least 700px, with reduced motion disabled, the translation and asking chapter occupies 350svh and Work occupies 300svh. Each uses a 100svh sticky stage. Native scroll position drives the selected step and action progress in both directions.
- `scroll-timeline.js` maps the progress deterministically. It reserves approximately 5% at each end, divides the middle into equal beats, and holds each completed result for reading. Actions finish early within their beat. Scrolling stops when the user stops; entering a chapter does not start an independent timer.
- Explicit pagination and playback take control until the user chooses “跟随滚动”. Pagination does not move the outer page. Playback resumes from the current progress, advances completed steps without rewinding, pauses when less than 55% of the usable stage is visible or the document is hidden, and stops at the final result.
- Manual selections, annotations and conversations are excluded from scroll synchronization and remain intact across scrolling and responsive changes. A selected or paused presentation also retains its explicit state when crossing viewport breakpoints.
- The former ONE MORE THING and separate Work introduction are combined. A 165svh desktop sequence crossfades the introductory title into Work, followed directly by its demonstration. Compact layouts show these elements in normal document order.
- Phones, narrower windows and short windows use normal document flow with explicit playback and local pagination. The phone presentation keeps a fixed 166% scale and pans between the source and conversation instead of changing scale, position and crop simultaneously. `overflow: clip` prevents focus from creating an internal stage scroll.

Only the pacing and interaction principles are referenced. The page continues to use Marr's own interface and assets; no Apple product imagery, logos or other visual assets were copied.

## Verification scope

The revised page was exercised in the browser at 1440×900, 592×828 and 375×812. The automated suite passes 21 tests: 11 for timeline sampling, seeking, playback progression and visibility; 10 for capture controls, cropped viewports and Original geometry. Reduced-motion behavior was reviewed in CSS and state-management code, but was not browser-tested through a simulated system preference.
