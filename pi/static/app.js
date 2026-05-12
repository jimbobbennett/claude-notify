(() => {
  const body = document.body;
  const character = document.getElementById('character');
  const status = document.getElementById('status');
  const sessionEl = document.getElementById('session');

  const BORED_ACTS = ['act-yawn', 'act-look', 'act-blink', 'act-sigh', 'act-sleep', 'act-tilt'];
  const BORED_DURATIONS = {
    'act-yawn': 1700,
    'act-look': 2500,
    'act-blink': 600,
    'act-sigh': 1900,
    'act-sleep': 3100,
    'act-tilt': 1500,
  };
  const BORED_STATUSES = {
    'act-yawn': 'yaaawn…',
    'act-look': 'hmm…',
    'act-blink': 'bored…',
    'act-sigh': '*sigh*',
    'act-sleep': 'zzz…',
    'act-tilt': '?',
  };

  let boredTimer = null;
  let currentState = 'idle';

  function clearBoredClasses() {
    BORED_ACTS.forEach(c => character.classList.remove(c));
  }

  function scheduleBored() {
    clearTimeout(boredTimer);
    if (currentState !== 'idle') return;
    const wait = 5000 + Math.random() * 12000;
    boredTimer = setTimeout(playBored, wait);
  }

  function playBored() {
    if (currentState !== 'idle') return;
    clearBoredClasses();
    const act = BORED_ACTS[Math.floor(Math.random() * BORED_ACTS.length)];
    character.classList.add(act);
    status.textContent = BORED_STATUSES[act];
    const dur = BORED_DURATIONS[act] || 1500;
    setTimeout(() => {
      character.classList.remove(act);
      if (currentState === 'idle') status.textContent = 'bored…';
      scheduleBored();
    }, dur);
  }

  function applyState(newState, session) {
    if (newState !== currentState) {
      currentState = newState;
      clearBoredClasses();
      body.classList.remove('state-idle', 'state-dancing');
      body.classList.add('state-' + newState);
      if (newState === 'dancing') {
        status.textContent = 'YOUR TURN!';
        clearTimeout(boredTimer);
      } else {
        status.textContent = 'bored…';
        scheduleBored();
      }
    }
    sessionEl.textContent = newState === 'dancing' ? (session || '') : '';
  }

  function connect() {
    const es = new EventSource('/events');
    es.onmessage = (e) => {
      try {
        const data = JSON.parse(e.data);
        if (data.state) applyState(data.state, data.session);
      } catch (err) { /* ignore */ }
    };
    es.onerror = () => {
      es.close();
      setTimeout(connect, 2000);
    };
  }

  // Tap anywhere to toggle (debug / manual control on the touchscreen)
  document.addEventListener('click', () => {
    const next = currentState === 'dancing' ? 'idle' : 'dancing';
    fetch(next === 'dancing' ? '/notify' : '/idle', { method: 'POST' });
  });

  applyState('idle');
  scheduleBored();
  connect();
})();
