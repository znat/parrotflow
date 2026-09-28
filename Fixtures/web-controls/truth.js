// What each control's framework believes, keyed by a stable name. Shown in
// <pre id="truth"> and counted in the title, so a probe can read it over AX.
(function () {
  var truth = { seq: 0, via: {}, libs: {} };
  var pre = document.getElementById('truth');

  function render() {
    var keys = Object.keys(truth).sort();
    var out = {};
    keys.forEach(function (k) { out[k] = truth[k]; });
    pre.textContent = JSON.stringify(out, null, 1);
    document.title = 'Web controls ' + truth.seq;
  }

  window.truth = truth;

  window.report = function (key, value, via) {
    truth[key] = value;
    truth.via[key] = via || '';
    truth.seq += 1;
    render();
  };

  window.reportLib = function (name, status) {
    truth.libs[name] = status;
    truth.seq += 1;
    render();
  };

  window.addEventListener('error', function (e) {
    window.reportLib('error:' + (e.filename || '').split('/').pop(), String(e.message));
  });
  window.addEventListener('unhandledrejection', function (e) {
    window.reportLib('rejection', String(e.reason && e.reason.message || e.reason));
  });

  render();
})();
