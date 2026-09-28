// An Electron app like Teams or Slack, for axkit. It shows its window
// without taking the focus, so a check can run while someone works.
const { app, BrowserWindow } = require('electron');
const path = require('path');

app.whenReady().then(() => {
  const window = new BrowserWindow({
    width: 1200, height: 900, show: false, title: 'Electron controls',
    webPreferences: { contextIsolation: true },
  });
  window.loadFile(path.join(__dirname, 'index.html'));
  window.once('ready-to-show', () => window.showInactive());
});

app.on('window-all-closed', () => app.quit());
