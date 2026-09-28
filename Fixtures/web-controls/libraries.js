// Libraries come from jsDelivr, pinned. A file:// page cannot load a local module
// script, so modules are loaded with import() from this classic script.
(function () {
  var CDN = 'https://cdn.jsdelivr.net/npm/';
  var FLUENT = CDN + '@fluentui/web-components@3.1.3/dist/web-components-all.min.js';
  var TOKENS = CDN + '@fluentui/tokens@1.0.0-alpha.24/+esm';
  var MATERIAL = CDN + '@material/web@2.5.0/all.js/+esm';
  var REACT = CDN + 'react@18.3.1/umd/react.production.min.js';
  var REACT_DOM = CDN + 'react-dom@18.3.1/umd/react-dom.production.min.js';

  function $(id) { return document.getElementById(id); }
  function timeout(p, ms, what) {
    return Promise.race([p, new Promise(function (_, no) {
      setTimeout(function () { no(new Error(what + ' timed out after ' + ms + ' ms')); }, ms);
    })]);
  }
  function script(src) {
    return new Promise(function (ok, no) {
      var s = document.createElement('script');
      s.src = src;
      s.onload = ok;
      s.onerror = function () { no(new Error('failed to load ' + src)); };
      document.head.appendChild(s);
    });
  }
  function on(el, types, key, read) {
    types.forEach(function (type) {
      el.addEventListener(type, function (e) { report(key, read(e), e.type); });
    });
  }

  function fluent() {
    return Promise.all([import(FLUENT), import(TOKENS)]).then(function (mods) {
      var wc = mods[0], tokens = mods[1];
      Object.keys(wc).filter(function (k) { return /Definition$/.test(k); }).forEach(function (k) {
        if (!customElements.get(wc[k].name)) wc[k].define(wc.FluentDesignSystem.registry);
      });
      if (wc.setTheme && tokens.webLightTheme) wc.setTheme(tokens.webLightTheme);
      var tags = ['fluent-text-input', 'fluent-dropdown', 'fluent-option', 'fluent-checkbox', 'fluent-switch',
        'fluent-radio-group', 'fluent-slider', 'fluent-menu', 'fluent-menu-list', 'fluent-menu-item', 'fluent-tablist',
        'fluent-tab', 'fluent-dialog', 'fluent-button'];
      return Promise.all(tags.map(function (t) { return customElements.whenDefined(t); })).then(function () {
        wireFluent();
        return 'ok';
      });
    });
  }

  function wireFluent() {
    var text = $('f_text');
    on(text, ['input', 'change'], 'f_text', function () { return text.value; });
    report('f_text', text.value, 'initial');
    ['f_dropdown', 'f_combobox'].forEach(function (id) {
      var d = $(id);
      on(d, ['change', 'input'], id, function () { return d.value; });
      report(id, d.value || null, 'initial');
    });
    ['f_checkbox', 'f_switch'].forEach(function (id) {
      var c = $(id);
      on(c, ['change'], id, function () { return c.checked; });
      report(id, c.checked, 'initial');
    });
    var radio = $('f_radio');
    on(radio, ['change'], 'f_radio', function () { return radio.value || null; });
    report('f_radio', radio.value || null, 'initial');
    var slider = $('f_slider');
    on(slider, ['change', 'input'], 'f_slider', function () { return slider.value; });
    report('f_slider', slider.value, 'initial');
    var menu = $('f_menu');
    on(menu, ['change'], 'f_menu', function (e) { return e.target.textContent.trim(); });
    menu.querySelectorAll('fluent-menu-item').forEach(function (item) {
      item.addEventListener('click', function () { report('f_menu_click', item.textContent.trim(), 'click'); });
    });
    report('f_menu', null, 'initial');
    var tabs = $('f_tabs');
    on(tabs, ['change'], 'f_tabs', function () {
      var t = tabs.querySelector('#' + tabs.activeid);
      return t ? t.textContent.trim() : tabs.activeid;
    });
    report('f_tabs', 'Day', 'initial');
    var dialog = $('f_dialog');
    $('f_dialog_open').addEventListener('click', function () { dialog.show(); });
    $('f_dialog_ok').addEventListener('click', function () { report('f_dialog_ok', true, 'click'); dialog.hide(); });
    on(dialog, ['toggle'], 'f_dialog', function (e) { return e.detail && e.detail.newState || e.newState || 'toggle'; });
    report('f_dialog', 'closed', 'initial');
  }

  function material() {
    return import(MATERIAL).then(function () {
      var tags = ['md-outlined-text-field', 'md-outlined-select', 'md-checkbox', 'md-switch', 'md-radio', 'md-slider',
        'md-menu', 'md-tabs', 'md-dialog'];
      return Promise.all(tags.map(function (t) { return customElements.whenDefined(t); })).then(function () {
        wireMaterial();
        return 'ok';
      });
    });
  }

  function wireMaterial() {
    var text = $('m_text');
    on(text, ['input', 'change'], 'm_text', function () { return text.value; });
    report('m_text', text.value, 'initial');
    var select = $('m_select');
    on(select, ['change', 'input'], 'm_select', function () { return select.value; });
    report('m_select', '5 minutes', 'initial');
    var check = $('m_checkbox');
    on(check, ['change'], 'm_checkbox', function () { return check.checked; });
    report('m_checkbox', false, 'initial');
    var sw = $('m_switch');
    on(sw, ['change'], 'm_switch', function () { return sw.selected; });
    report('m_switch', false, 'initial');
    document.querySelectorAll('md-radio[name=m_radio]').forEach(function (r) {
      r.addEventListener('change', function () { report('m_radio', r.value, 'change'); });
    });
    report('m_radio', 'Busy', 'initial');
    var slider = $('m_slider');
    on(slider, ['change', 'input'], 'm_slider', function () { return slider.value; });
    report('m_slider', 50, 'initial');
    var menu = $('m_menu'), button = $('m_menu_button');
    button.addEventListener('click', function () { menu.open = !menu.open; });
    on(menu, ['close-menu'], 'm_menu', function (e) {
      var item = e.detail && e.detail.itemPath && e.detail.itemPath[0];
      return item ? item.textContent.trim() : null;
    });
    on(menu, ['opened', 'closed'], 'm_menu_state', function (e) { return e.type; });
    report('m_menu', null, 'initial');
    var tabs = $('m_tabs');
    on(tabs, ['change'], 'm_tabs', function () { return tabs.activeTab ? tabs.activeTab.textContent.trim() : tabs.activeTabIndex; });
    report('m_tabs', 'Day', 'initial');
    var dialog = $('m_dialog');
    $('m_dialog_open').addEventListener('click', function () { dialog.show(); });
    on(dialog, ['opened'], 'm_dialog', function () { return 'open'; });
    on(dialog, ['closed'], 'm_dialog', function () { return dialog.returnValue || 'cancel'; });
    report('m_dialog', 'closed', 'initial');
  }

  function react() {
    return script(REACT).then(function () { return script(REACT_DOM); }).then(function () {
      var h = React.createElement;
      function Field() {
        var s = React.useState('Draft agenda'), value = s[0], set = s[1];
        var c = React.useState(false), checked = c[0], setChecked = c[1];
        React.useEffect(function () { report('r_text', value, 'render'); }, [value]);
        React.useEffect(function () { report('r_checkbox', checked, 'render'); }, [checked]);
        return h('div', null,
          h('div', { className: 'row' },
            h('label', { className: 'tag', htmlFor: 'r_text' }, 'r_text'),
            h('input', { id: 'r_text', value: value, onChange: function (e) { set(e.target.value); } }),
            h('output', { id: 'r_text_state' }, 'state: ' + value)),
          h('div', { className: 'row' },
            h('label', { className: 'tag', htmlFor: 'r_checkbox' }, 'r_checkbox'),
            h('input', { id: 'r_checkbox', type: 'checkbox', checked: checked,
              onChange: function (e) { setChecked(e.target.checked); } }),
            h('output', { id: 'r_checkbox_state' }, 'state: ' + checked)));
      }
      ReactDOM.createRoot($('react-root')).render(h(Field));
      return 'ok';
    });
  }

  var loads = { fluent: fluent, material: material, react: react };
  Promise.all(Object.keys(loads).map(function (name) {
    return timeout(loads[name](), 20000, name).then(
      function (status) { reportLib(name, status); },
      function (e) { reportLib(name, 'error: ' + e.message); });
  })).then(function () { reportLib('ready', true); });
})();
