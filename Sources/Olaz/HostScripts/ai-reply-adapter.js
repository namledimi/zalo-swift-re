// Observe only explicitly enabled conversations, including those not open in the native UI.
// Loading/activating a message cache does not open a chat or mark it read.
(() => {
  'use strict';
  if (window.__zaloAI || !location.pathname.endsWith('/index.html')) return;
  const watches = new Map();
  let preview = null;
  const core = () => window.__zaloChat && window.__zaloChat.__core;
  const recent = (id) => {
    const c = core();
    if (!c) return [];
    const conv = c.convOf(id);
    const time = (m) => {
      const t = Number(m.sendDttm || m.serverTime || m.ts || m.localDttm || m.date || 0);
      return t > 0 && t < 1e12 ? t * 1000 : t;
    };
    const raw = (conv && conv.messages || []).slice().sort((a, b) => time(a) - time(b)).slice(-30);
    return c.mapAll(raw, id)
      .filter((m) => m && m.id && m.date > 0).sort((a, b) => a.date - b.date).slice(-30);
  };
  const publish = (id, watch) => {
    if (watches.get(id) !== watch) return;
    const c = core(), messages = recent(id);
    if (!c || !messages.length) return;
    // Status/reaction/avatar changes are not new messages.
    const signature = JSON.stringify(messages.map((m) => [m.id, m.text, m.kind.type, m.isMine, m.date]));
    if (signature === watch.signature) return;
    watch.signature = signature;
    try {
      window.webkit.messageHandlers.zstate.postMessage({ page: 'main', aiReply: {
        account: c.meNow(), conversationId: id, messages,
      } });
    } catch {}
  };
  const tick = () => {
    if (!watches.size) return;
    const c = core();
    if (!c || !c.S.loader) return;
    if (!preview && window.__zaloRequire && window.__zaloDI) {
      for (const r of window.__zaloDI(window.__zaloRequire)) {
        const i = r.instance;
        if (i && typeof i.convertDBMessageToPreviewItem === 'function') { preview = i; break; }
      }
    }
    for (const [id, watch] of watches) {
      publish(id, watch);
      const p = c.safe(() => preview.data.get(id), null);
      const stamp = p ? String(p.messageTime || p.sendDttm || p.ts || '') : '';
      if (watch.loading || (watch.loaded && stamp === watch.stamp)) continue;
      watch.loading = true;
      watch.stamp = stamp;
      Promise.resolve().then(() => c.S.loader.getLastMessagesForConversation(id, {})).then(() => {
        if (watches.get(id) !== watch) {
          if (c.openConversationId() !== id && !watches.has(id)) c.safe(() => c.S.loader.cacheMessageLoader.get(id).deActive(), null);
          return;
        }
        watch.loaded = true;
        c.safe(() => c.S.loader.cacheMessageLoader.get(id).active(), null);
        publish(id, watch);
      }).catch(() => {
        // Retry on a later preview change, without logging message content.
        watch.loaded = true;
      }).finally(() => { watch.loading = false; });
    }
  };
  window.__zaloAI = {
    isWatching(id) { return watches.has(String(id)); },
    watch(ids) {
      const next = new Set((Array.isArray(ids) ? ids : []).slice(0, 20).map(String));
      const c = core();
      for (const id of watches.keys()) if (!next.has(id)) {
        watches.delete(id);
        if (c && c.openConversationId() !== id) c.safe(() => c.S.loader.cacheMessageLoader.get(id).deActive(), null);
      }
      for (const id of next) if (!watches.has(id)) watches.set(id, { stamp: '', loaded: false, loading: false, signature: null });
      tick();
      return true;
    },
    isCurrent(id, trigger) {
      if (!watches.has(String(id))) return false;
      const messages = recent(String(id)), last = messages[messages.length - 1];
      return !!last && last.id === String(trigger) && !last.isMine && last.kind.type === 'text';
    },
  };
  setInterval(tick, 1200);
})();
