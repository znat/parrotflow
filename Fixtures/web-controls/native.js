(function () {
  function $(id) { return document.getElementById(id); }
  function watch(id, read) {
    var el = $(id);
    ['input', 'change'].forEach(function (type) {
      el.addEventListener(type, function (e) { report(id, read(el), e.type + (e.isTrusted ? '' : ' (untrusted)')); });
    });
    report(id, read(el), 'initial');
  }
  var value = function (el) { return el.value; };
  ['n_text', 'n_textarea', 'n_date', 'n_time', 'n_datetime', 'n_select', 'n_range', 'n_number'].forEach(function (id) {
    watch(id, value);
  });
  watch('n_checkbox', function (el) { return el.checked; });
  watch('n_editable', function (el) { return el.innerText; });

  function radio() {
    var on = document.querySelector('input[name=n_radio]:checked');
    return on ? on.value : null;
  }
  document.querySelectorAll('input[name=n_radio]').forEach(function (r) {
    r.addEventListener('change', function (e) { report('n_radio', radio(), e.type); });
  });
  report('n_radio', radio(), 'initial');

  var details = $('n_details');
  details.addEventListener('toggle', function () { report('n_details', details.open, 'toggle'); });
  report('n_details', details.open, 'initial');

  var dialog = $('n_dialog');
  $('n_dialog_open').addEventListener('click', function () {
    dialog.showModal();
    report('n_dialog', 'open', 'click');
  });
  dialog.addEventListener('close', function () { report('n_dialog', dialog.returnValue || 'cancel', 'close'); });
  report('n_dialog', 'closed', 'initial');
})();
