// Camera controls for a page hosting the runtime: drag, wheel, and the four buttons.
//
// ## Why this is not in Bevy
//
// It looks like engine work, and it would be, in a native window. On the web it cannot be:
// winit reports pointer motion through `DeviceEvent::MouseMotion`, which browsers only emit
// under pointer lock, and the window-event route did not reach this canvas either — a drag
// produced nothing at all, with no error to say why. A button drawn by Bevy needs a cursor
// position and a click, which is that same path. It would be dead for the same reason.
//
// The page, meanwhile, has `mousemove` and `wheel` that have always worked, and a message
// channel to the runtime already carrying whole scenes. So the seam moves: the page decides
// what a gesture means, the runtime applies it. Buttons and gestures then travel one path
// instead of two that can disagree.
//
// ## Why a module rather than a copy in each page
//
// Two pages host the runtime — the embedded one and the test harness — and a third will exist
// the day another plugin wants a viewport. Controls copied into each are controls that drift:
// the harness would keep a bug the embedded page had fixed, which is the worst possible place
// for them to differ, because the harness is what you reach for to decide whether a bug is
// real.

/** Radians per pixel dragged. Tuned by feel: a drag across the viewport is a bit over half a turn. */
const TURN = 0.008;
const PITCH = 0.006;
/** One wheel notch or button press, as a proportion of the current distance. */
const STEP = 0.18;

/**
 * Wire a canvas and a button row to a runtime.
 *
 * @param {object}   opts
 * @param {Element}  opts.canvas   the render surface; gestures are read from it
 * @param {Element}  [opts.buttons] container for the four controls; created on demand
 * @param {(text: string) => void} opts.send  hands one JSON message to the runtime
 */
export function installCameraControls({ canvas, buttons, send }) {
  const camera = (cmd) => send(JSON.stringify({ type: 'camera', ...cmd }));

  // ── Gestures ────────────────────────────────────────────────────────────────
  let dragging = false;
  let lx = 0;
  let ly = 0;

  canvas.addEventListener('mousedown', (e) => {
    if (e.button !== 0) return;
    dragging = true;
    lx = e.clientX;
    ly = e.clientY;
    e.preventDefault();
  });

  // On `window`, not the canvas: a drag that leaves the viewport should keep turning until
  // the button comes up, which is what every 3D viewer does and what the hand expects.
  window.addEventListener('mousemove', (e) => {
    if (!dragging) return;
    const dx = e.clientX - lx;
    const dy = e.clientY - ly;
    lx = e.clientX;
    ly = e.clientY;
    if (dx || dy) camera({ yaw: -dx * TURN, pitch: dy * PITCH });
  });
  window.addEventListener('mouseup', () => { dragging = false; });

  canvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    // deltaMode 0 is pixels (a trackpad, tens per gesture); 1 is lines (a wheel, ~1 a notch).
    const notches = e.deltaMode === 0 ? e.deltaY / 100 : e.deltaY;
    camera({ zoom: notches * STEP });
  }, { passive: false });

  // ── Buttons ─────────────────────────────────────────────────────────────────
  if (!buttons) return;
  const add = (id, glyph, title, cmd) => {
    const b = document.createElement('button');
    b.id = id;
    b.textContent = glyph;
    b.title = title;
    b.onclick = () => camera(cmd);
    buttons.appendChild(b);
  };
  add('cam-in',    '+', 'Zoom in',  { zoom: -STEP * 2 });
  add('cam-out',   '−', 'Zoom out', { zoom:  STEP * 2 });
  // Two separate controls on purpose. "Let it spin again from where I have it" and "forget
  // what I did to the camera" are both reasonable things to want, and one button that does
  // both means you cannot have the first without losing the angle you just found.
  add('cam-spin',  '⟳', 'Resume the turntable, keeping this angle', { spin: true });
  add('cam-reset', '↺', "Back to the scene's own framing",          { reset: true });
}

/**
 * The stylesheet for the button row, so a host page carries no copy of it.
 *
 * Every colour reads an Arbor token with a literal fallback: inside the app the buttons
 * follow whatever theme is active, and in a bare page — the harness before it grew a palette,
 * or any future embedder — they still look like themselves instead of like unstyled browser
 * chrome. One rule set, two contexts, no fork.
 *
 * The surface is translucent on purpose: these sit ON the picture, and a solid chip would cut
 * a hole in the thing you are trying to look at.
 */
export const CAMERA_CSS = `
  .cam-controls {
    position: absolute; right: 10px; bottom: 10px; z-index: 2;
    display: flex; flex-direction: column; gap: 4px;
  }
  .cam-controls button {
    width: 26px; height: 26px; padding: 0; cursor: pointer;
    border-radius: var(--radius-sm, 4px);
    font: 14px/1 var(--font-ui-sans, system-ui, sans-serif);
    color: var(--text-secondary, #9da0a8);
    background: color-mix(in srgb, var(--bg-elevated, #2b2d30) 78%, transparent);
    border: 1px solid var(--border-subtle, #2e3035);
    /* Over a lit 3D scene the buttons need to hold their own edge against whatever is
       behind them; the border alone disappears on a bright highlight. */
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.45);
  }
  .cam-controls button:hover {
    color: var(--text-primary, #dfe1e5);
    background: color-mix(in srgb, var(--bg-hover, #313436) 92%, transparent);
  }
  .cam-controls button:active { transform: translateY(1px); }
`;
