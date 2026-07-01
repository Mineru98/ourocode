
const fallbackFrames = [
  {
    title: "Guided starts",
    duration_ms: 1200,
    text: `+-- ourocode terminal region=header_status x=0 y=0 w=88 h=5
| app=ourocode status=healthy runtime=ready
| project=/Users/dev/Project/ourocode
| cwd=/Users/dev/Project/ourocode
+--
+-- Start Modes
| ● ooo pm <goal>        product requirements
|   ooo interview        clarify decisions
|   ooo auto             plan and verify
|   / for commands
+--
> Message ourocode, / for commands
ready · / commands · ooo work`,
    checks: [
      { label: "offline fallback frame", status: "trace" },
      { label: "start modes visible", status: "trace" },
    ],
  },
  {
    title: "PM picker",
    duration_ms: 1400,
    text: `+-- ourocode terminal region=interview x=0 y=0 w=100 h=24
| INTERVIEW
| Round 1 · PM interview
| What outcome should this PM interview produce?
| ● >> [1] Define the target user - anchor the PM brief around the primary audience
| ○ [2] Define the activation outcome - focus on the proof moment
| ○ [3] Audit the existing flow - start from the current path
|
| Enter confirm   Esc pause   /cancel stop
+--`,
    checks: [
      { label: "offline fallback frame", status: "trace" },
      { label: "keyboard controls visible", status: "trace" },
    ],
  },
  {
    title: "Agents and verification",
    duration_ms: 1500,
    text: `+-- Agents Workspace
| Status · running · 2 records
| >> PM interview waiting · live
| Health checks ready · ready
| step · generating answer choices
| progress · answer accepted
| controls · Esc pause, /cancel, /sessions
+-- Verify
| checks: 22/22 passed
| evidence: real terminal replay, visual captures, theme RGB, guided PM flow
+--`,
    checks: [
      { label: "offline fallback frame", status: "trace" },
      { label: "verify evidence visible", status: "trace" },
    ],
  },
];

const state = {
  frames: [],
  index: 0,
  playing: false,
  timer: 0,
  columns: window.innerWidth <= 640 ? 80 : 100,
};

const elements = {
  play: document.querySelector("#play"),
  prev: document.querySelector("#prev"),
  next: document.querySelector("#next"),
  copy: document.querySelector("#copy"),
  terminal: document.querySelector("#terminal"),
  title: document.querySelector("#frame-title"),
  meta: document.querySelector("#frame-meta"),
  status: document.querySelector("#qa-status"),
  scenarios: document.querySelector("#scenarios"),
  checks: document.querySelector("#checks"),
  viewportButtons: document.querySelectorAll("[data-width]"),
};


function canUseFallback() {
  const params = new URLSearchParams(window.location.search);
  return window.location.protocol === "file:" || params.get("demo") === "1";
}

function validateFrames(value) {
  if (!Array.isArray(value)) {
    throw new Error("frames.json must be an array");
  }

  for (const frame of value) {
    if (!frame || typeof frame.title !== "string" || typeof frame.text !== "string") {
      throw new Error("frames.json contains an invalid frame");
    }
    if (!Number.isInteger(frame.duration_ms) || frame.duration_ms <= 0) {
      throw new Error(`invalid duration for frame: ${frame.title}`);
    }
    if (!Array.isArray(frame.checks)) {
      throw new Error(`invalid checks for frame: ${frame.title}`);
    }
  }

  return value;
}

async function loadFrames() {
  try {
    const response = await fetch("./frames.json", { cache: "no-store" });
    if (!response.ok) {
      throw new Error(`frames request failed: ${response.status}`);
    }

    state.frames = validateFrames(await response.json());
    elements.status.textContent = `${state.frames.length} live frames loaded`;
    renderScenarioList();
    renderFrame();
  } catch (error) {
    if (canUseFallback()) {
      state.frames = fallbackFrames;
      elements.status.textContent = `${state.frames.length} offline demo frames loaded; run mix server for live renderer frames`;
      renderScenarioList();
      renderFrame();
      return;
    }

    elements.status.textContent = `Live frame load failed: ${error.message}`;
    elements.terminal.textContent = "Start with: mix run --no-start scripts/tui_qa_server.exs";
  }
}

function renderScenarioList() {
  elements.scenarios.replaceChildren(
    ...state.frames.map((frame, index) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "scenario";
      button.setAttribute("aria-current", String(index === state.index));
      button.innerHTML = `<strong>${frame.title}</strong><span>${frame.duration_ms}ms · ${frame.checks.length} checks</span>`;
      button.addEventListener("click", () => selectFrame(index));
      return button;
    }),
  );
}

function renderFrame() {
  const frame = state.frames[state.index];
  if (!frame) {
    return;
  }

  elements.title.textContent = frame.title;
  elements.meta.textContent = `${state.index + 1}/${state.frames.length} · ${frame.duration_ms}ms`;
  elements.terminal.textContent = frame.text;
  elements.terminal.className = `cols-${state.columns}`;
  elements.checks.replaceChildren(
    ...frame.checks.map((check) => {
      const item = document.createElement("span");
      item.className = "check";
      item.dataset.status = check.status;
      item.textContent = `${check.status}: ${check.label}`;
      return item;
    }),
  );
  renderScenarioList();
  syncViewportButtons();
}

function selectFrame(index) {
  state.index = Math.max(0, Math.min(index, state.frames.length - 1));
  renderFrame();
  scheduleNext();
}

function nextFrame() {
  selectFrame((state.index + 1) % state.frames.length);
}

function prevFrame() {
  selectFrame((state.index - 1 + state.frames.length) % state.frames.length);
}

function togglePlay() {
  state.playing = !state.playing;
  elements.play.textContent = state.playing ? "Pause" : "Play";
  scheduleNext();
}

function scheduleNext() {
  window.clearTimeout(state.timer);
  if (!state.playing || state.frames.length === 0) {
    return;
  }

  const duration = state.frames[state.index].duration_ms || 1000;
  state.timer = window.setTimeout(nextFrame, duration);
}

async function copyFrame() {
  const frame = state.frames[state.index];
  if (!frame) {
    return;
  }

  try {
    await navigator.clipboard.writeText(frame.text);
    elements.status.textContent = "Current frame copied";
  } catch (_error) {
    elements.status.textContent = "Clipboard unavailable; select terminal text manually";
  }
}

function syncViewportButtons() {
  for (const button of elements.viewportButtons) {
    button.setAttribute("aria-current", String(button.dataset.width === String(state.columns)));
  }
}

function setColumns(width) {
  state.columns = Number(width);
  syncViewportButtons();
  renderFrame();
}

elements.play.addEventListener("click", togglePlay);
elements.prev.addEventListener("click", prevFrame);
elements.next.addEventListener("click", nextFrame);
elements.copy.addEventListener("click", copyFrame);

for (const button of elements.viewportButtons) {
  button.addEventListener("click", () => setColumns(button.dataset.width));
}

document.addEventListener("keydown", (event) => {
  if (event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement) {
    return;
  }

  if (event.key === " ") {
    event.preventDefault();
    togglePlay();
  } else if (event.key === "ArrowRight") {
    nextFrame();
  } else if (event.key === "ArrowLeft") {
    prevFrame();
  }
});

loadFrames();

