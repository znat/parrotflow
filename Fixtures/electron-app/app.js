// Each control reports what the app believes into the truth block, as the
// web page does. The behaviours copy what was seen in Teams and Slack.
(function () {
  function $(id) { return document.getElementById(id); }
  var people = [
    { name: 'Alice Martin', email: 'alice.martin@example.com' },
    { name: 'Alice Martin External', email: 'alice.m@gmail.example' },
    { name: 'Bruno Costa', email: 'bruno.costa@example.com' },
    { name: 'Chloe Dubois', email: 'chloe.dubois@example.com' },
  ];

  // App bar.
  document.querySelectorAll('[role=tab]').forEach(function (tab) {
    tab.addEventListener('click', function () {
      document.querySelectorAll('[role=tab]').forEach(function (t) { t.setAttribute('aria-selected', t === tab); });
      $('calendar').hidden = tab.id !== 'tab_calendar';
      $('chat').hidden = tab.id !== 'tab_chat';
      report('view', tab.textContent, 'click');
    });
  });

  // "Create a new event.": the main part does nothing, the arrow opens a menu.
  $('create_main').addEventListener('click', function () { report('create_main', 'pressed', 'click'); });
  $('create_menu').addEventListener('click', function () {
    var open = $('create_items').hidden;
    $('create_items').hidden = !open;
    $('create_menu').setAttribute('aria-expanded', open);
  });
  $('create_items').querySelectorAll('[role=menuitem]').forEach(function (item) {
    item.addEventListener('click', function () {
      $('create_items').hidden = true;
      $('create_menu').setAttribute('aria-expanded', false);
      report('create', item.textContent, 'click');
      if (item.textContent === 'Event') { $('event').hidden = false; report('form', 'open', 'click'); }
    });
  });

  $('title').addEventListener('input', function () { report('title', $('title').value, 'input'); });

  // Attendees: the list is not in the tree; the highlighted row is announced
  // as "Name - email k of N". The first match is highlighted already, so a
  // bare Return picks it and Down then Return picks the second.
  var matches = [], on = 0, chosen = [];
  function query() { return $('attendees').innerText.trim().toLowerCase(); }
  function show() {
    var list = $('suggestions');
    list.replaceChildren();
    matches.forEach(function (p, i) {
      var row = document.createElement('div');
      row.textContent = p.name + ' ' + p.email;
      if (i === on) row.className = 'on';
      list.appendChild(row);
    });
    list.hidden = matches.length === 0;
    $('announce').textContent = matches.length
      ? matches[on].name + ' - ' + matches[on].email + ' ' + (on + 1) + ' of ' + matches.length : '';
  }
  $('attendees').addEventListener('input', function () {
    var q = query();
    matches = q ? people.filter(function (p) { return p.name.toLowerCase().indexOf(q) === 0; }) : [];
    on = 0;
    show();
  });
  $('attendees').addEventListener('keydown', function (e) {
    if (e.key === 'ArrowDown' && matches.length) { on = Math.min(on + 1, matches.length - 1); show(); e.preventDefault(); }
    else if (e.key === 'ArrowUp' && matches.length) { on = Math.max(on - 1, 0); show(); e.preventDefault(); }
    else if (e.key === 'Enter' && matches.length) {
      e.preventDefault();
      var p = matches[on];
      chosen.push(p.email);
      var chip = document.createElement('span');
      chip.className = 'chip';
      chip.setAttribute('role', 'group');
      chip.setAttribute('aria-label', p.name + ' Unknown');
      chip.textContent = p.name;
      $('chips').appendChild(chip);
      $('attendees').textContent = '';
      matches = [];
      show();
      $('announce').textContent = p.name + ' added.';
      report('attendees', chosen.slice(), 'Enter');
    }
  });

  // Date and time sit behind a summary button named after the slot.
  var start = { d: 28, m: 9, y: 26, h: 12, min: 0 };
  function two(n) { return (n < 10 ? '0' : '') + n; }
  var days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  function summary() {
    var date = new Date(2000 + start.y, start.m - 1, start.d);
    var end = start.h * 60 + start.min + 30;
    $('summary').textContent = days[date.getDay()] + ' ' + two(start.d) + '/' + two(start.m) + '/' + two(start.y)
      + ' ' + two(start.h) + ':' + two(start.min) + ' - ' + two(Math.floor(end / 60) % 24) + ':' + two(end % 60);
    $('end_time').textContent = two(Math.floor(end / 60) % 24) + ':' + two(end % 60);
  }
  function commitDate() {
    var m = /^(\d{2})\/(\d{2})\/(\d{2})$/.exec($('start_date').value);
    if (m) { start.d = +m[1]; start.m = +m[2]; start.y = +m[3]; }
    report('start_date', $('start_date').value, m ? 'commit' : 'rejected');
    summary();
  }
  var lastTime = '12:00', typing = false;
  function commitTime() {
    var m = /^(\d{1,2}):(\d{2})$/.exec($('start_time').value);
    if (m) { start.h = +m[1]; start.min = +m[2]; lastTime = $('start_time').value; }
    else $('start_time').value = lastTime;
    report('start_time', lastTime, 'commit');
    summary();
    report('end_time', $('end_time').textContent, 'follow');
  }
  $('summary').addEventListener('click', function () {
    $('times').hidden = false;
    $('summary').setAttribute('aria-expanded', true);
    $('start_date').value = two(start.d) + '/' + two(start.m) + '/' + two(start.y);
    $('start_time').value = lastTime;
    report('times', 'open', 'click');
  });
  // Typing appends to the date unless it is selected, as in Teams.
  $('start_date').addEventListener('keydown', function (e) { if (e.key === 'Enter') { commitDate(); e.preventDefault(); } });
  $('start_date').addEventListener('change', commitDate);
  // Typing replaces the time; Return keeps it; Escape reverts it.
  $('start_time').addEventListener('focus', function () { typing = false; });
  $('start_time').addEventListener('beforeinput', function () {
    if (!typing) { typing = true; $('start_time').value = ''; }
  });
  $('start_time').addEventListener('keydown', function (e) {
    if (e.key === 'Enter') { commitTime(); typing = false; e.preventDefault(); }
    else if (e.key === 'Escape') {
      $('start_time').value = lastTime; typing = false;
      report('start_time', lastTime, 'Escape'); e.stopPropagation();
    }
  });
  $('start_time').addEventListener('change', function () { if (typing) return; commitTime(); });
  // Escape anywhere else in the form asks whether to discard it.
  $('event').addEventListener('keydown', function (e) {
    if (e.key === 'Escape') { $('discard').hidden = false; report('discard', 'asked', 'Escape'); }
  });
  $('discard_no').addEventListener('click', function () { $('discard').hidden = true; report('discard', 'kept', 'click'); });
  $('discard_yes').addEventListener('click', function () {
    $('discard').hidden = true; $('event').hidden = true; report('discard', 'discarded', 'click');
  });

  // Slack: suggestions are menu items, a group conversation among them, and
  // the chosen people live in the To: field's value, split by no-break spaces.
  var rooms = [
    { name: 'Alice Martin', members: ['Alice Martin'] },
    { name: 'Alice Martin, Bruno Costa', members: ['Alice Martin', 'Bruno Costa'] },
    { name: 'Bruno Costa', members: ['Bruno Costa'] },
    { name: 'Chloe Dubois', members: ['Chloe Dubois'] },
  ];
  var recipients = [];
  $('new_message').addEventListener('click', function () { $('compose').hidden = false; report('compose', 'open', 'click'); });
  function typed() {
    var parts = $('to').value.split('\u00a0');
    return parts[parts.length - 1].trim().toLowerCase();
  }
  $('to').addEventListener('input', function () {
    var q = typed(), items = $('to_items');
    items.replaceChildren();
    rooms.filter(function (r) { return q && r.name.toLowerCase().indexOf(q) >= 0; }).forEach(function (r) {
      var item = document.createElement('div');
      item.setAttribute('role', 'menuitem');
      item.tabIndex = -1;
      item.textContent = r.name;
      item.addEventListener('click', function () {
        recipients = r.members.slice();
        $('to').value = '\u00a0' + recipients.join(' \u00a0 ') + ' \u00a0';
        items.hidden = true;
        $('to').setAttribute('aria-expanded', false);
        $('message').setAttribute('aria-label', 'Message to ' + recipients.join(', '));
        report('recipients', recipients.slice(), 'click');
      });
      items.appendChild(item);
    });
    items.hidden = !items.children.length;
    $('to').setAttribute('aria-expanded', !items.hidden);
  });
  $('message').addEventListener('input', function () { report('message', $('message').innerText, 'input'); });

  summary();
  report('ready', true, 'initial');
})();
