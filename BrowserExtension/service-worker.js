const HOST = 'local.tx6mac.browser';
const OFFSCREEN_URL = chrome.runtime.getURL('offscreen.html');
let nativePort = null;
let nativeError = '';
let creatingOffscreen = null;
let snapshotBusy = false;
let reconnectTimer = null;
let reconnectAttempts = 0;
let snapshotTimer = null;
let profileSessionPromise = null;
let lastControlsAt = 0;
let controlsEnabled = false;
let controlGeneration = 0;
let controlQueue = Promise.resolve();
let loadingOwnership = null;
const toggling = new Set();
const detectedTabs = new Map();
const ownedMutes = new Map();
const userOverrides = new Set();

export function safeHost(url) {
  try { return new URL(url).hostname.slice(0, 253); } catch { return ''; }
}

export function tabMetadata(tab, captured = null) {
  let title = String(tab.title || '제목 없는 탭').slice(0, 100);
  if (/[\uD800-\uDBFF]$/.test(title)) title = title.slice(0, -1);
  return {
    id: tab.id, title,
    active: tab.audible === true || captured?.audible === true || ownedMutes.has(tab.id),
    captured: captured !== null, detected: true,
    muted: tab.mutedInfo?.muted === true,
    peak: Number.isFinite(captured?.peak) ? Math.max(0, Math.min(1, captured.peak)) : 0,
    host: safeHost(tab.url),
  };
}

async function profileSession() {
  if (!profileSessionPromise) {
    profileSessionPromise = (async () => {
      const stored = (await chrome.storage.local.get('bridgeSession')).bridgeSession;
      if (typeof stored === 'string' && /^(?:[0-9a-f]{32}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$/i.test(stored)) return stored;
      const session = crypto.randomUUID();
      await chrome.storage.local.set({ bridgeSession: session });
      return session;
    })().catch((error) => { profileSessionPromise = null; throw error; });
  }
  return profileSessionPromise;
}

function appControlsReady() {
  return controlsEnabled && Date.now() - lastControlsAt <= 3000;
}

async function loadOwnership() {
  if (!loadingOwnership) loadingOwnership = (async () => {
    const stored = (await chrome.storage.session.get('tx6OwnedMutes')).tx6OwnedMutes;
    if (!stored || typeof stored !== 'object') return;
    for (const [id, record] of Object.entries(stored)) {
      if (Number.isInteger(Number(id)) && Number(id) >= 0 && typeof record?.original === 'boolean') {
        ownedMutes.set(Number(id), { original: record.original });
      }
    }
  })();
  await loadingOwnership;
}

async function saveOwnership() {
  // 종료 후 남은 음소거를 복구하기 위한 세션 정보입니다. 제목·URL은 저장하지 않습니다.
  await chrome.storage.session.set({ tx6OwnedMutes: Object.fromEntries(ownedMutes) });
}

function mutedByUs(tab) {
  return tab.mutedInfo?.muted === true && tab.mutedInfo?.reason === 'extension' &&
    tab.mutedInfo?.extensionId === chrome.runtime.id;
}

async function restoreOwnedMute(id) {
  const record = ownedMutes.get(id);
  if (!record) return;
  let tab;
  try { tab = await chrome.tabs.get(id); } catch { ownedMutes.delete(id); await saveOwnership(); return; }
  // 사용자가 Chrome에서 직접 바꾼 값이나 다른 확장의 음소거는 건드리지 않습니다.
  if (mutedByUs(tab)) await chrome.tabs.update(id, { muted: record.original });
  ownedMutes.delete(id);
  await saveOwnership();
}

async function restoreAllOwnedMutes() {
  await loadOwnership();
  await Promise.allSettled([...ownedMutes.keys()].map((id) => restoreOwnedMute(id)));
  userOverrides.clear();
}

async function offscreenExists() {
  const contexts = await chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'], documentUrls: [OFFSCREEN_URL] });
  return contexts.length > 0;
}

async function ensureOffscreen() {
  if (await offscreenExists()) return;
  if (!creatingOffscreen) creatingOffscreen = chrome.offscreen.createDocument({
    url: 'offscreen.html', reasons: ['USER_MEDIA'],
    justification: '탭 오디오의 음량·EQ 처리와 앱 연결 중단 시 원래 음량·음소거 상태를 복구합니다. 녹음하지 않습니다.',
  }).finally(() => { creatingOffscreen = null; });
  await creatingOffscreen;
}

async function offscreen(message) {
  if (!(await offscreenExists())) return { ok: true, tabs: [] };
  const response = await chrome.runtime.sendMessage({ ...message, target: 'offscreen' });
  if (!response?.ok) throw new Error(response?.error || '탭 오디오 처리 응답이 없습니다.');
  return response;
}

async function badge(tabId, captured, error = false) {
  const ready = captured && appControlsReady();
  const detected = detectedTabs.has(tabId);
  await Promise.allSettled([
    chrome.action.setBadgeBackgroundColor({ tabId, color: error ? '#CC4A28' : ready ? '#607F65' : '#9B8956' }),
    chrome.action.setBadgeText({ tabId, text: error ? '!' : captured ? (ready ? 'ON' : 'CAP') : detected ? 'DET' : '' }),
    chrome.action.setTitle({ tabId, title: error
      ? `TX · MAC: ${nativeError || '연결 오류 — 다시 눌러 주세요.'}`
      : !captured ? '소리 나는 탭 자동 감지 · 음량/EQ 연결: 클릭 또는 Command+Shift+6'
      : ready ? 'TX · MAC 제어 연결됨 · 클릭 또는 Command+Shift+6으로 원래 재생 복구'
      : '탭 오디오 연결됨 / 맥 앱 믹서 대기 · 현재 원래 음량 재생 · 클릭하면 연결 해제' }),
  ]);
}

async function refreshBadges() {
  const state = await offscreen({ type: 'status' });
  const captured = new Set((state.tabs || []).map((tab) => tab.id));
  await Promise.allSettled([...new Set([...detectedTabs.keys(), ...captured])].map((id) => badge(id, captured.has(id))));
}

async function publishSnapshot() {
  if (!nativePort || snapshotBusy) return;
  snapshotBusy = true;
  try {
    await loadOwnership();
    const state = await offscreen({ type: 'status' });
    const captured = new Map((state.tabs || []).map((tab) => [tab.id, tab]));
    // 자동 감지에 필요한 현재 재생 탭과 이전에 감지한 탭만 조회합니다.
    const audible = await chrome.tabs.query({ audible: true });
    for (const tab of audible) if (Number.isInteger(tab.id)) detectedTabs.set(tab.id, tabMetadata(tab, captured.get(tab.id) ?? null));
    const ids = [...new Set([...detectedTabs.keys(), ...captured.keys(), ...ownedMutes.keys()])];
    const fetched = await Promise.allSettled(ids.map((id) => chrome.tabs.get(id)));
    for (let index = 0; index < fetched.length; index++) {
      const result = fetched[index];
      if (result.status === 'fulfilled') detectedTabs.set(ids[index], tabMetadata(result.value, captured.get(ids[index]) ?? null));
      else { detectedTabs.delete(ids[index]); ownedMutes.delete(ids[index]); userOverrides.delete(ids[index]); }
    }
    // 네이티브 메시지 크기를 제한하되 캡처·앱이 음소거한 탭은 먼저 유지합니다.
    const metadata = [...detectedTabs.values()].sort((a, b) =>
      Number(b.captured || ownedMutes.has(b.id)) - Number(a.captured || ownedMutes.has(a.id)) || Number(b.active) - Number(a.active)).slice(0, 200);
    const message = { type: 'tabs', profileSession: await profileSession(), tabs: metadata };
    await Promise.allSettled(metadata.map((tab) => badge(tab.id, tab.captured)));
    if (nativeError) message.error = nativeError.slice(0, 300);
    nativePort?.postMessage(message);
  } catch (error) { nativeError = String(error?.message ?? error).slice(0, 300); }
  finally { snapshotBusy = false; }
}

function enqueue(work) {
  controlQueue = controlQueue.catch(() => {}).then(work).catch((error) => { nativeError = String(error?.message ?? error).slice(0, 300); });
  return controlQueue;
}

async function applyUncapturedControls(message, generation) {
  await loadOwnership();
  if (generation !== controlGeneration) return;
  const state = await offscreen({ type: 'status' });
  const captured = new Set((state.tabs || []).map((tab) => tab.id));
  const channels = new Map();
  for (const channel of Array.isArray(message.channels) ? message.channels : []) {
    if (channel && Number.isInteger(channel.tabId) && channel.tabId >= 0 && !channels.has(channel.tabId)) channels.set(channel.tabId, channel);
  }
  for (const id of [...ownedMutes.keys()]) {
    if (!appControlsReady() || captured.has(id) || !channels.has(id) || channels.get(id).muted !== true) await restoreOwnedMute(id);
  }
  for (const id of [...userOverrides]) if (!channels.has(id) || captured.has(id)) userOverrides.delete(id);
  if (!appControlsReady() || generation !== controlGeneration) return;
  for (const [id, channel] of channels) {
    if (captured.has(id) || toggling.has(id) || !detectedTabs.has(id)) continue;
    if (channel.muted !== true) { userOverrides.delete(id); continue; }
    if (userOverrides.has(id)) continue;
    let tab;
    try { tab = await chrome.tabs.get(id); } catch { continue; }
    if (ownedMutes.has(id)) {
      if (mutedByUs(tab)) continue;
      ownedMutes.delete(id); userOverrides.add(id); await saveOwnership(); continue;
    }
    if (tab.mutedInfo?.muted === true) continue;
    // DOM 문서의 watchdog도 유지하여 서비스 워커 중단 시 복구할 수 있게 합니다.
    await ensureOffscreen();
    if (!appControlsReady() || generation !== controlGeneration) return;
    ownedMutes.set(id, { original: false }); await saveOwnership();
    if (!appControlsReady() || generation !== controlGeneration || toggling.has(id)) { await restoreOwnedMute(id); return; }
    try { await chrome.tabs.update(id, { muted: true }); }
    catch (error) { ownedMutes.delete(id); await saveOwnership(); throw error; }
  }
}

function failOpen() {
  controlsEnabled = false; lastControlsAt = 0; controlGeneration++;
  return enqueue(async () => {
    await restoreAllOwnedMutes();
    await offscreen({ type: 'restore' });
    await refreshBadges();
  });
}

function keepSnapshots() {
  if (!snapshotTimer) snapshotTimer = setInterval(() => { void publishSnapshot(); }, 1000);
}

function connectNative() {
  if (nativePort) return;
  if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
  try {
    const port = chrome.runtime.connectNative(HOST); nativePort = port; keepSnapshots();
    port.onMessage.addListener((message) => {
      if (nativePort !== port || message?.type !== 'controls') return;
      nativeError = ''; reconnectAttempts = 0; lastControlsAt = Date.now(); controlsEnabled = message.enabled === true;
      const generation = ++controlGeneration;
      void enqueue(async () => {
        await applyUncapturedControls(message, generation);
        if (generation !== controlGeneration) return;
        await offscreen({ type: 'controls', channels: message.channels, enabled: appControlsReady() });
        await refreshBadges();
      });
    });
    port.onDisconnect.addListener(() => {
      if (nativePort !== port) return;
      const detail = chrome.runtime.lastError?.message; nativePort = null;
      if (snapshotTimer) { clearInterval(snapshotTimer); snapshotTimer = null; }
      nativeError = detail ? `맥 앱 연결이 끊겼습니다: ${detail}` : '맥 앱 연결이 끊겼습니다. 원래 음량과 음소거로 복구합니다.';
      void failOpen();
      if (reconnectAttempts < 3) {
        const delay = [2000, 5000, 15000][reconnectAttempts++];
        reconnectTimer = setTimeout(() => { reconnectTimer = null; connectNative(); }, delay);
      }
    });
    void publishSnapshot();
  } catch (error) {
    nativePort = null; nativeError = `맥 앱 연결을 확인하세요: ${String(error?.message ?? error)}`; void failOpen();
  }
}

async function toggleTab(tab) {
  if (!Number.isInteger(tab.id) || toggling.has(tab.id)) return;
  toggling.add(tab.id);
  try {
    reconnectAttempts = 0; connectNative();
    const current = await offscreen({ type: 'status' });
    if (current.tabs?.some((entry) => entry.id === tab.id)) {
      await offscreen({ type: 'stop', tabId: tab.id }); await badge(tab.id, false);
    } else {
      await loadOwnership(); await restoreOwnedMute(tab.id); userOverrides.delete(tab.id);
      await ensureOffscreen();
      const streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tab.id });
      await offscreen({ type: 'start', tabId: tab.id, streamId }); await badge(tab.id, true);
    }
    await publishSnapshot();
  } catch (error) {
    nativeError = `이 탭을 연결할 수 없습니다: ${String(error?.message ?? error)}`.slice(0, 300);
    await badge(tab.id, false, true); await publishSnapshot();
  } finally { toggling.delete(tab.id); }
}

chrome.runtime.onMessage.addListener((message, sender) => {
  if (sender.id !== chrome.runtime.id || message?.target !== 'worker' || message.type !== 'controls-timeout') return false;
  void failOpen(); return false;
});
chrome.action.onClicked.addListener((tab) => { void toggleTab(tab); });
chrome.tabs.onRemoved.addListener((id) => {
  detectedTabs.delete(id); ownedMutes.delete(id); userOverrides.delete(id);
  void saveOwnership().catch(() => {});
  void offscreen({ type: 'stop', tabId: id }).then(() => publishSnapshot()).catch(() => {});
});
chrome.tabs.onUpdated.addListener((id, change) => {
  if (change.audible !== undefined || (detectedTabs.has(id) && (change.title !== undefined || change.mutedInfo !== undefined))) void publishSnapshot();
});
chrome.tabCapture.onStatusChanged.addListener((info) => {
  if (info.status === 'stopped' || info.status === 'error') {
    void offscreen({ type: 'stop', tabId: info.tabId }).catch(() => {}); void badge(info.tabId, false, info.status === 'error');
  }
  void publishSnapshot();
});
chrome.runtime.onInstalled.addListener(() => { reconnectAttempts = 0; connectNative(); });
chrome.runtime.onStartup.addListener(() => { reconnectAttempts = 0; connectNative(); });
setInterval(() => { if ((controlsEnabled || ownedMutes.size) && !appControlsReady()) void failOpen(); }, 500);
// 서비스 워커 재시작 후 남은 이 확장 소유의 음소거만 복구합니다.
void enqueue(() => restoreAllOwnedMutes());
connectNative();
