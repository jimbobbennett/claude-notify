(() => {
  const MAX_VISIBLE = 4;
  const grid = document.getElementById('grid');
  const template = document.getElementById('card-template');
  const body = document.body;

  // session_id -> { card: HTMLElement, state: 'idle'|'dancing' }
  const cards = new Map();

  const BORED_ACTS = ['act-yawn', 'act-look', 'act-blink', 'act-sigh', 'act-sleep', 'act-tilt'];
  const BORED_DURATIONS = {
    'act-yawn': 1700, 'act-look': 2500, 'act-blink': 600,
    'act-sigh': 1900, 'act-sleep': 3100, 'act-tilt': 1500,
  };

  function makeCard(sessionId) {
    const node = template.content.firstElementChild.cloneNode(true);
    node.dataset.sessionId = sessionId;
    return node;
  }

  function visibleSessions(sessions) {
    // Dancing first; within each state group, sort alphabetically by label so
    // positions stay stable across heartbeats (last_seen ticks constantly).
    const arr = Object.entries(sessions).map(([id, s]) => ({ id, ...s }));
    arr.sort((a, b) => {
      if (a.state !== b.state) return a.state === 'dancing' ? -1 : 1;
      const aLabel = (a.label || '').toLowerCase();
      const bLabel = (b.label || '').toLowerCase();
      if (aLabel !== bLabel) return aLabel < bLabel ? -1 : 1;
      return a.id < b.id ? -1 : 1;
    });
    return arr.slice(0, MAX_VISIBLE);
  }

  function render(snapshot) {
    const sessions = snapshot.sessions || {};
    const visible = visibleSessions(sessions);
    const visibleIds = new Set(visible.map(s => s.id));

    // Remove cards that are no longer visible.
    for (const [id, info] of cards) {
      if (!visibleIds.has(id)) {
        info.card.remove();
        cards.delete(id);
      }
    }

    // Add / update / reorder cards.
    let anyDancing = false;
    visible.forEach((s, i) => {
      let info = cards.get(s.id);
      if (!info) {
        const card = makeCard(s.id);
        grid.appendChild(card);
        info = { card, state: null };
        cards.set(s.id, info);
      }
      // Ensure DOM order matches priority order (move-if-needed; cheap if same).
      const expectedChild = grid.children[i];
      if (expectedChild !== info.card) grid.insertBefore(info.card, expectedChild || null);

      // State class.
      if (info.state !== s.state) {
        info.card.classList.remove('state-idle', 'state-dancing');
        info.card.classList.add('state-' + s.state);
        info.state = s.state;
      }
      info.card.style.setProperty('--i', i);

      const label = info.card.querySelector('.label');
      const activity = info.card.querySelector('.activity');
      const desiredLabel = s.label || (s.state === 'dancing' ? 'claude' : '');
      if (label.textContent !== desiredLabel) label.textContent = desiredLabel;
      const desiredActivity = s.activity ? s.activity + '…' : '';
      if (activity.textContent !== desiredActivity) activity.textContent = desiredActivity;

      if (s.state === 'dancing') anyDancing = true;
    });

    grid.dataset.count = visible.length;
    body.dataset.anydancing = anyDancing ? '1' : '0';
  }

  // ============ BORED SCHEDULER ============
  // Single global scheduler picks one idle card every 6-15s to play a random
  // bored act. Keeps total animation load low even with 4 idle mascots.
  let boredTimer = null;
  function scheduleBored() {
    clearTimeout(boredTimer);
    const wait = 6000 + Math.random() * 9000;
    boredTimer = setTimeout(playBored, wait);
  }
  function playBored() {
    const idleCards = [...cards.values()]
      .filter(info => info.state === 'idle')
      .map(info => info.card);
    if (idleCards.length === 0) { scheduleBored(); return; }

    const card = idleCards[Math.floor(Math.random() * idleCards.length)];
    const character = card.querySelector('.character');
    const act = BORED_ACTS[Math.floor(Math.random() * BORED_ACTS.length)];
    BORED_ACTS.forEach(a => character.classList.remove(a));
    character.classList.add(act);
    setTimeout(() => character.classList.remove(act), BORED_DURATIONS[act]);
    scheduleBored();
  }

  // ============ SSE ============
  function connect() {
    const es = new EventSource('/events');
    es.onmessage = (e) => {
      try { render(JSON.parse(e.data)); } catch (err) { /* ignore */ }
    };
    es.onerror = () => {
      es.close();
      setTimeout(connect, 2000);
    };
  }

  // Tap toggles a debug "default" session for quick smoke tests on the device.
  document.addEventListener('click', () => {
    const isDancing = [...cards.values()].some(i => i.state === 'dancing');
    fetch(isDancing ? '/idle' : '/notify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ session_id: 'tap', label: 'tap' }),
    });
  });

  scheduleBored();
  connect();
})();
