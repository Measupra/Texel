// The only bridge between the page and the system: open/save dialogs, closing, links.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('texel', {
  openImage: () => ipcRenderer.invoke('open-image'),
  saveImage: (name, ext, data) => ipcRenderer.invoke('save-image', { name, ext, data }),
  readText: (rel) => ipcRenderer.invoke('read-text', rel),
  pickImages: () => ipcRenderer.invoke('pick-images'),
  readPicked: (id) => ipcRenderer.invoke('read-picked', id),
  batchFolder: () => ipcRenderer.invoke('batch-folder'),
  chooseBatchFolder: () => ipcRenderer.invoke('choose-batch-folder'),
  writeBatchFile: (name, data) => ipcRenderer.invoke('write-batch-file', { name, data }),
  showBatchFolder: () => ipcRenderer.invoke('show-batch-folder'),
  clipboardReadImage: () => ipcRenderer.invoke('clipboard-read-image'),
  clipboardWriteImage: (data) => ipcRenderer.invoke('clipboard-write-image', data),
  appInfo: () => ipcRenderer.invoke('app-info'),
  openLink: (url) => ipcRenderer.send('open-link', url),
  confirmClose: () => ipcRenderer.send('confirm-close'),
  onCloseRequested: (fn) => ipcRenderer.on('close-requested', fn),
  platform: process.platform,
});
