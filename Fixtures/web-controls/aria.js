// Hand-written ARIA widgets after the W3C ARIA Authoring Practices examples.
(function () {
  function $(id) { return document.getElementById(id); }

  // Combobox with a listbox popup (APG "list autocomplete").
  var people = [
    ['Alice Martin', 'alice.martin@example.com'], ['Alan Dubois', 'alan.dubois@example.com'],
    ['Bruno Keller', 'bruno.keller@example.com'], ['Chloe Petit', 'chloe.petit@example.com'],
    ['Dana Novak', 'dana.novak@example.com'],
  ];
  var input = $('a_combobox'), list = $('a_combobox_list'), active = -1, shown = [];
  function fill() {
    var q = input.value.toLowerCase();
    shown = people.filter(function (p) { return (p[0] + ' ' + p[1]).toLowerCase().indexOf(q) >= 0; });
    active = -1;
    input.removeAttribute('aria-activedescendant');
    list.replaceChildren();
    shown.forEach(function (p, i) {
      var li = document.createElement('li');
      li.id = 'a_combobox_opt_' + i;
      li.setAttribute('role', 'option');
      li.setAttribute('aria-selected', 'false');
      li.textContent = p[0] + ' <' + p[1] + '>';
      li.addEventListener('mousedown', function (e) { e.preventDefault(); choose(i, 'click'); });
      list.appendChild(li);
    });
  }
  function open() {
    fill();
    list.hidden = shown.length === 0;
    input.setAttribute('aria-expanded', String(!list.hidden));
  }
  function close() {
    list.hidden = true;
    active = -1;
    input.setAttribute('aria-expanded', 'false');
    input.removeAttribute('aria-activedescendant');
  }
  function move(to) {
    var opts = list.querySelectorAll('[role=option]');
    if (!opts.length) return;
    active = (to + opts.length) % opts.length;
    opts.forEach(function (o, i) { o.setAttribute('aria-selected', String(i === active)); });
    input.setAttribute('aria-activedescendant', opts[active].id);
  }
  function choose(i, via) {
    var p = shown[i];
    input.value = p[0];
    close();
    report('a_combobox', p[1], via);
  }
  input.addEventListener('input', function () { open(); report('a_combobox_text', input.value, 'input'); });
  input.addEventListener('keydown', function (e) {
    if (e.key === 'ArrowDown') { if (list.hidden) open(); move(active + 1); e.preventDefault(); }
    else if (e.key === 'ArrowUp') { if (list.hidden) open(); move(active - 1); e.preventDefault(); }
    else if (e.key === 'Enter') { if (!list.hidden && active >= 0) { choose(active, 'Enter'); e.preventDefault(); } }
    else if (e.key === 'Escape') { if (!list.hidden) close(); else { input.value = ''; report('a_combobox_text', '', 'Escape'); } }
  });
  input.addEventListener('blur', close);
  report('a_combobox', null, 'initial');
  report('a_combobox_text', input.value, 'initial');

  // Menu button (APG "actions menu button").
  var mb = $('a_menu_button'), menu = $('a_menu');
  var items = Array.prototype.slice.call(menu.querySelectorAll('[role=menuitem]'));
  function openMenu(at) {
    menu.hidden = false;
    mb.setAttribute('aria-expanded', 'true');
    items[(at + items.length) % items.length].focus();
  }
  function closeMenu(focusButton) {
    menu.hidden = true;
    mb.setAttribute('aria-expanded', 'false');
    if (focusButton) mb.focus();
  }
  mb.addEventListener('click', function () { if (menu.hidden) openMenu(0); else closeMenu(true); });
  mb.addEventListener('keydown', function (e) {
    if (e.key === 'ArrowDown') { openMenu(0); e.preventDefault(); }
    if (e.key === 'ArrowUp') { openMenu(-1); e.preventDefault(); }
  });
  items.forEach(function (item, i) {
    item.addEventListener('click', function () { report('a_menu', item.textContent, 'click'); closeMenu(true); });
    item.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowDown') items[(i + 1) % items.length].focus();
      else if (e.key === 'ArrowUp') items[(i - 1 + items.length) % items.length].focus();
      else if (e.key === 'Home') items[0].focus();
      else if (e.key === 'End') items[items.length - 1].focus();
      else if (e.key === 'Escape') closeMenu(true);
      else if (e.key === 'Tab') closeMenu(false);
      else if (e.key === 'Enter' || e.key === ' ') { report('a_menu', item.textContent, e.key === ' ' ? 'Space' : 'Enter'); closeMenu(true); }
      else return;
      e.preventDefault();
    });
  });
  report('a_menu', null, 'initial');

  // Tabs with automatic activation.
  var tabs = Array.prototype.slice.call(document.querySelectorAll('#a_tabs [role=tab]'));
  function select(i, via) {
    tabs.forEach(function (t, j) {
      t.setAttribute('aria-selected', String(i === j));
      t.tabIndex = i === j ? 0 : -1;
    });
    tabs[i].focus();
    $('a_panel').textContent = tabs[i].textContent + ' view';
    $('a_panel').setAttribute('aria-labelledby', tabs[i].id);
    report('a_tabs', tabs[i].textContent, via);
  }
  tabs.forEach(function (t, i) {
    t.addEventListener('click', function () { select(i, 'click'); });
    t.addEventListener('keydown', function (e) {
      var n = tabs.length;
      if (e.key === 'ArrowRight') select((i + 1) % n, 'ArrowRight');
      else if (e.key === 'ArrowLeft') select((i - 1 + n) % n, 'ArrowLeft');
      else if (e.key === 'Home') select(0, 'Home');
      else if (e.key === 'End') select(n - 1, 'End');
      else return;
      e.preventDefault();
    });
  });
  report('a_tabs', 'Day', 'initial');

  // Date picker dialog with a grid (APG "date picker dialog").
  var dInput = $('a_date'), dButton = $('a_date_button'), dDialog = $('a_date_dialog');
  var grid = $('a_date_grid').tBodies[0], focusDay = null;
  function iso(d) { return d.toISOString().slice(0, 10); }
  function parse(s) { var d = new Date(s + 'T00:00:00Z'); return isNaN(d) ? new Date(Date.UTC(2026, 9, 15)) : d; }
  function addDays(d, n) { return new Date(d.getTime() + n * 86400000); }
  function addMonths(d, n) { var r = new Date(d); r.setUTCMonth(r.getUTCMonth() + n); return r; }
  function renderGrid() {
    var first = new Date(Date.UTC(focusDay.getUTCFullYear(), focusDay.getUTCMonth(), 1));
    var start = addDays(first, -((first.getUTCDay() + 6) % 7));
    $('a_date_month').textContent = first.toLocaleString('en-US', { month: 'long', year: 'numeric', timeZone: 'UTC' });
    grid.replaceChildren();
    for (var w = 0; w < 6; w++) {
      var tr = document.createElement('tr');
      for (var k = 0; k < 7; k++) {
        var day = addDays(start, w * 7 + k), td = document.createElement('td');
        td.textContent = day.getUTCDate();
        td.dataset.date = iso(day);
        td.tabIndex = iso(day) === iso(focusDay) ? 0 : -1;
        td.setAttribute('aria-selected', String(iso(day) === dInput.value));
        if (day.getUTCMonth() !== first.getUTCMonth()) td.style.color = '#aaa';
        td.addEventListener('click', function (e) { pick(e.currentTarget.dataset.date, 'click'); });
        tr.appendChild(td);
      }
      grid.appendChild(tr);
    }
  }
  function focusCell() {
    renderGrid();
    var cell = grid.querySelector('td[data-date="' + iso(focusDay) + '"]');
    if (cell) cell.focus();
  }
  function openDate() {
    focusDay = parse(dInput.value);
    dDialog.hidden = false;
    dButton.setAttribute('aria-expanded', 'true');
    focusCell();
    report('a_date_dialog', 'open', 'open');
  }
  function closeDate(via) {
    dDialog.hidden = true;
    dButton.setAttribute('aria-expanded', 'false');
    dButton.focus();
    report('a_date_dialog', 'closed', via);
  }
  function pick(date, via) {
    dInput.value = date;
    report('a_date', date, via);
    closeDate(via);
  }
  dButton.addEventListener('click', function () { if (dDialog.hidden) openDate(); else closeDate('click'); });
  $('a_date_prev').addEventListener('click', function () { focusDay = addMonths(focusDay, -1); renderGrid(); });
  $('a_date_next').addEventListener('click', function () { focusDay = addMonths(focusDay, 1); renderGrid(); });
  $('a_date_cancel').addEventListener('click', function () { closeDate('cancel'); });
  $('a_date_ok').addEventListener('click', function () { pick(iso(focusDay), 'ok'); });
  grid.addEventListener('keydown', function (e) {
    var moves = { ArrowRight: 1, ArrowLeft: -1, ArrowDown: 7, ArrowUp: -7 };
    if (moves[e.key]) focusDay = addDays(focusDay, moves[e.key]);
    else if (e.key === 'PageDown') focusDay = addMonths(focusDay, 1);
    else if (e.key === 'PageUp') focusDay = addMonths(focusDay, -1);
    else if (e.key === 'Home') focusDay = addDays(focusDay, -((focusDay.getUTCDay() + 6) % 7));
    else if (e.key === 'End') focusDay = addDays(focusDay, 6 - ((focusDay.getUTCDay() + 6) % 7));
    else if (e.key === 'Enter' || e.key === ' ') { pick(iso(focusDay), e.key === ' ' ? 'Space' : 'Enter'); e.preventDefault(); return; }
    else return;
    e.preventDefault();
    focusCell();
  });
  dDialog.addEventListener('keydown', function (e) { if (e.key === 'Escape') { closeDate('Escape'); e.preventDefault(); } });
  dInput.addEventListener('change', function () { report('a_date', dInput.value, 'change'); });
  report('a_date', dInput.value, 'initial');
  report('a_date_dialog', 'closed', 'initial');

  // Spinbutton.
  var spin = $('a_spin');
  function setSpin(v, via) {
    v = Math.max(0, Math.min(20, v));
    spin.setAttribute('aria-valuenow', String(v));
    spin.textContent = String(v);
    report('a_spin', v, via);
  }
  spin.addEventListener('keydown', function (e) {
    var now = Number(spin.getAttribute('aria-valuenow'));
    var to = { ArrowUp: now + 1, ArrowDown: now - 1, PageUp: now + 5, PageDown: now - 5, Home: 0, End: 20 }[e.key];
    if (to === undefined) return;
    setSpin(to, e.key);
    e.preventDefault();
  });
  report('a_spin', 2, 'initial');

  // Switch.
  var sw = $('a_switch');
  sw.addEventListener('click', function (e) {
    var on = sw.getAttribute('aria-checked') !== 'true';
    sw.setAttribute('aria-checked', String(on));
    report('a_switch', on, e.detail === 0 ? 'keyboard click' : 'click');
  });
  report('a_switch', false, 'initial');

  // Tree view, single select, roving tabindex.
  var tree = $('a_tree');
  function visible() {
    return Array.prototype.filter.call(tree.querySelectorAll('[role=treeitem]'), function (t) {
      for (var p = t.parentElement.closest('[role=treeitem]'); p; p = p.parentElement.closest('[role=treeitem]')) {
        if (p.getAttribute('aria-expanded') !== 'true') return false;
      }
      return true;
    });
  }
  function expanded() {
    return Array.prototype.filter.call(tree.querySelectorAll('[aria-expanded=true]'), function () { return true; })
      .map(function (t) { return t.dataset.name; });
  }
  function focusItem(t) {
    tree.querySelectorAll('[role=treeitem]').forEach(function (x) { x.tabIndex = -1; });
    t.tabIndex = 0;
    t.focus();
  }
  function setExpanded(t, on, via) {
    if (!t.hasAttribute('aria-expanded')) return;
    t.setAttribute('aria-expanded', String(on));
    report('a_tree_expanded', expanded(), via);
  }
  function selectItem(t, via) {
    tree.querySelectorAll('[role=treeitem]').forEach(function (x) { x.removeAttribute('aria-selected'); });
    t.setAttribute('aria-selected', 'true');
    report('a_tree_selected', t.dataset.name, via);
  }
  tree.addEventListener('keydown', function (e) {
    var t = e.target.closest('[role=treeitem]'), v = visible(), i = v.indexOf(t);
    if (!t) return;
    if (e.key === 'ArrowDown' && i < v.length - 1) focusItem(v[i + 1]);
    else if (e.key === 'ArrowUp' && i > 0) focusItem(v[i - 1]);
    else if (e.key === 'ArrowRight') {
      if (t.getAttribute('aria-expanded') === 'false') setExpanded(t, true, 'ArrowRight');
      else if (t.getAttribute('aria-expanded') === 'true') focusItem(t.querySelector('[role=treeitem]'));
    } else if (e.key === 'ArrowLeft') {
      if (t.getAttribute('aria-expanded') === 'true') setExpanded(t, false, 'ArrowLeft');
      else { var up = t.parentElement.closest('[role=treeitem]'); if (up) focusItem(up); }
    } else if (e.key === 'Home') focusItem(v[0]);
    else if (e.key === 'End') focusItem(v[v.length - 1]);
    else if (e.key === 'Enter' || e.key === ' ') selectItem(t, e.key === ' ' ? 'Space' : 'Enter');
    else return;
    e.preventDefault();
  });
  tree.addEventListener('click', function (e) {
    var t = e.target.closest('[role=treeitem]');
    if (!t) return;
    focusItem(t);
    if (t.hasAttribute('aria-expanded')) setExpanded(t, t.getAttribute('aria-expanded') !== 'true', 'click');
    selectItem(t, 'click');
  });
  report('a_tree_expanded', [], 'initial');
  report('a_tree_selected', null, 'initial');

  // Disclosure.
  var disc = $('a_disclosure');
  disc.addEventListener('click', function (e) {
    var on = disc.getAttribute('aria-expanded') !== 'true';
    disc.setAttribute('aria-expanded', String(on));
    $('a_disclosure_panel').hidden = !on;
    report('a_disclosure', on, e.detail === 0 ? 'keyboard click' : 'click');
  });
  report('a_disclosure', false, 'initial');

  // Modal dialog.
  var dlg = $('a_dialog'), backdrop = $('a_dialog_backdrop'), opener = $('a_dialog_open');
  function openDialog() {
    dlg.hidden = false;
    backdrop.hidden = false;
    $('a_dialog_input').focus();
    report('a_dialog', 'open', 'open');
  }
  function closeDialog(how) {
    dlg.hidden = true;
    backdrop.hidden = true;
    opener.focus();
    report('a_dialog', how, how);
  }
  opener.addEventListener('click', openDialog);
  $('a_dialog_cancel').addEventListener('click', function () { closeDialog('cancel'); });
  $('a_dialog_ok').addEventListener('click', function () {
    report('a_dialog_name', $('a_dialog_input').value, 'ok');
    closeDialog('ok');
  });
  dlg.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') { closeDialog('cancel'); e.preventDefault(); }
    if (e.key === 'Tab') {
      var f = dlg.querySelectorAll('input, button'), first = f[0], last = f[f.length - 1];
      if (e.shiftKey && document.activeElement === first) { last.focus(); e.preventDefault(); }
      else if (!e.shiftKey && document.activeElement === last) { first.focus(); e.preventDefault(); }
    }
  });
  report('a_dialog', 'closed', 'initial');
})();
