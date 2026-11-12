const { contextBridge } = require('electron');

contextBridge.exposeInMainWorld('chessKidsDesktop', {
  isDesktop: true,
  platform: process.platform,
  electronVersion: process.versions.electron
});
