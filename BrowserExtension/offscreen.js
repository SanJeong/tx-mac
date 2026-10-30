const txText = (key, substitutions) => chrome.i18n.getMessage(key, substitutions) || key;
const entries = new Map();
let lastControlsAt = 0;
let controlsEnabled = false;
let latestChannels = [];

const clamp = (value, low, high, fallback) => Number.isFinite(value)
  ? Math.max(low, Math.min(high, value)) : fallback;
const neutral = () => ({ gain: 1, muted: false, eq: [0, 0, 0] });

export function normalizeChannels(channels) {
  const result = new Map();
  if (!Array.isArray(channels)) return result;
  for (const channel of channels) {
    if (!channel || !Number.isInteger(channel.tabId) || channel.tabId < 0 || result.has(channel.tabId)) continue;
    result.set(channel.tabId, {
      gain: clamp(channel.gain, 0, 1, 1),
      muted: channel.muted === true,
      eq: [0, 1, 2].map((index) => clamp(channel.eq?.[index], -18, 18, 0)),
    });
  }
  return result;
}

function smooth(parameter, value, context) {
  const now = context.currentTime;
  parameter.cancelAndHoldAtTime(now);
  parameter.setTargetAtTime(value, now, 0.015);
}

function apply(entry, control) {
  const old = entry.control;
  if (!old || old.gain !== control.gain || old.muted !== control.muted) {
    smooth(entry.gain.gain, control.muted ? 0 : control.gain, entry.context);
  }
  for (let index = 0; index < 3; index++) {
    if (!old || old.eq[index] !== control.eq[index]) {
      smooth(entry.filters[index].gain, control.eq[index], entry.context);
    }
  }
  entry.control = control;
}

function applyLatestControls() {
  const controls = controlsEnabled ? normalizeChannels(latestChannels) : new Map();
  for (const [id, entry] of entries) apply(entry, controls.get(id) ?? neutral());
}

function restoreAll() {
  controlsEnabled = false;
  latestChannels = [];
  for (const entry of entries.values()) apply(entry, neutral());
}

function stopEntry(id) {
  const entry = entries.get(id);
  if (!entry) return;
  entries.delete(id);
  for (const track of entry.stream.getTracks()) {
    track.onended = null;
    track.stop();
  }
  for (const node of [entry.source, ...entry.filters, entry.gain, entry.splitter, ...entry.analysers]) {
    try { node.disconnect(); } catch {}
  }
  void entry.context.close().catch(() => {});
}

async function startEntry(id, streamId) {
  if (!Number.isInteger(id) || id < 0 || typeof streamId !== 'string' || !streamId) {
    throw new Error(txText('invalidCapture'));
  }
  if (entries.has(id)) return;
  let stream;
  let context;
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      audio: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId } },
      video: false,
    });
    context = new AudioContext({ latencyHint: 'interactive' });
    const source = context.createMediaStreamSource(stream);
    const low = context.createBiquadFilter();
    low.type = 'lowshelf'; low.frequency.value = 120; low.gain.value = 0;
    const mid = context.createBiquadFilter();
    mid.type = 'peaking'; mid.frequency.value = 1000; mid.Q.value = Math.SQRT1_2; mid.gain.value = 0;
    const high = context.createBiquadFilter();
    high.type = 'highshelf'; high.frequency.value = 8000; high.gain.value = 0;
    const gain = context.createGain(); gain.gain.value = 1;
    source.connect(low).connect(mid).connect(high).connect(gain).connect(context.destination);
    const splitter = context.createChannelSplitter(2);
    source.connect(splitter);
    const analysers = [context.createAnalyser(), context.createAnalyser()];
    for (let channel = 0; channel < 2; channel++) {
      analysers[channel].fftSize = 512;
      splitter.connect(analysers[channel], channel);
    }
    const entry = {
      stream, context, source, filters: [low, mid, high], gain, splitter, analysers,
      samples: [new Float32Array(512), new Float32Array(512)], control: neutral(),
    };
    entries.set(id, entry);
    for (const track of stream.getTracks()) track.onended = () => stopEntry(id);
    await context.resume();
    if (context.state !== 'running') throw new Error(txText('cannotPlay'));
    applyLatestControls();
  } catch (error) {
    stopEntry(id);
    if (stream) for (const track of stream.getTracks()) track.stop();
    if (context && context.state !== 'closed') await context.close().catch(() => {});
    throw error;
  }
}

function status() {
  const tabs = [];
  for (const [id, entry] of entries) {
    let peak = 0;
    let sum = 0;
    let count = 0;
    for (let channel = 0; channel < 2; channel++) {
      const samples = entry.samples[channel];
      entry.analysers[channel].getFloatTimeDomainData(samples);
      for (const value of samples) {
        if (!Number.isFinite(value)) continue;
        peak = Math.max(peak, Math.abs(value)); sum += value * value; count++;
      }
    }
    tabs.push({ id, peak: clamp(peak, 0, 1, 0), audible: count > 0 && Math.sqrt(sum / count) > 0.00005 });
  }
  return { ok: true, tabs };
}

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.id !== chrome.runtime.id || message?.target !== 'offscreen') return false;
  (async () => {
    switch (message.type) {
      case 'start': await startEntry(message.tabId, message.streamId); return status();
      case 'stop': stopEntry(message.tabId); return status();
      case 'status': return status();
      case 'controls':
        lastControlsAt = performance.now();
        controlsEnabled = message.enabled === true;
        latestChannels = Array.isArray(message.channels) ? message.channels : [];
        applyLatestControls(); return { ok: true };
      case 'restore': restoreAll(); return { ok: true };
      default: return { ok: false, error: txText('unknownAudioRequest') };
    }
  })().then(respond).catch((error) => respond({ ok: false, error: String(error?.message ?? error) }));
  return true;
});

// Restore audio when control heartbeats stop.
setInterval(() => {
  if (controlsEnabled && performance.now() - lastControlsAt > 3000) {
    restoreAll();
    void chrome.runtime.sendMessage({ target: 'worker', type: 'controls-timeout' }).catch(() => {});
  }
}, 500);
