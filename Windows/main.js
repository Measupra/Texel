// Texel for Windows: the desktop shell. The interface and engine live in ./app and are served from a
// private app:// origin (secure and cross-origin isolated, which WebGPU and multi-threaded AI need).
const { app, BrowserWindow, protocol, net, ipcMain, dialog, shell, nativeTheme } = require('electron');
const path = require('path');
const fs = require('fs');
const { pathToFileURL } = require('url');

const APP_DIR = path.join(__dirname, 'app');
const TYPES = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css',
  '.wasm': 'application/wasm', '.onnx': 'application/octet-stream', '.png': 'image/png',
  '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.txt': 'text/plain; charset=utf-8', '.json': 'application/json',
};

protocol.registerSchemesAsPrivileged([{
  scheme: 'app',
  privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true, stream: true, codeCache: true },
}]);

// Keep the GPU available for WebGPU even on machines Chromium is cautious about.
app.commandLine.appendSwitch('enable-unsafe-webgpu');
app.commandLine.appendSwitch('ignore-gpu-blocklist');
app.commandLine.appendSwitch('enable-features', 'Vulkan,WebGPU');

let win;
let allowClose = false;

function createWindow() {
  nativeTheme.themeSource = 'dark';
  win = new BrowserWindow({
    width: 1280, height: 840, minWidth: 820, minHeight: 640,
    backgroundColor: '#080912',
    title: 'Texel',
    icon: path.join(APP_DIR, 'img', 'icon.png'),
    titleBarStyle: 'hidden',
    titleBarOverlay: { color: '#00000000', symbolColor: '#e8eaff', height: 52 },
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      sandbox: true,
      spellcheck: false,
    },
  });
  win.removeMenu();
  win.once('ready-to-show', () => win.show());
  win.loadURL('app://texel/index.html');

  // Ask the page before closing, so an unsaved result or a running upscale isn't lost by accident.
  win.on('close', (e) => {
    if (allowClose) return;
    e.preventDefault();
    win.webContents.send('close-requested');
  });
  win.webContents.on('before-input-event', (e, input) => {
    if (input.type !== 'keyDown') return;
    if (input.key === 'F11') { win.setFullScreen(!win.isFullScreen()); e.preventDefault(); }
    if (input.key === 'F12' || (input.control && input.shift && input.key.toLowerCase() === 'i')) {
      win.webContents.toggleDevTools(); e.preventDefault();
    }
  });
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith('https://')) shell.openExternal(url);
    return { action: 'deny' };
  });
}

app.whenReady().then(() => {
  protocol.handle('app', async (request) => {
    const { pathname } = new URL(request.url);
    const file = path.normalize(path.join(APP_DIR, decodeURIComponent(pathname)));
    if (!file.startsWith(APP_DIR)) return new Response('Not found', { status: 404 });
    const res = await net.fetch(pathToFileURL(file).toString());
    const headers = new Headers(res.headers);
    headers.set('Content-Type', TYPES[path.extname(file).toLowerCase()] || 'application/octet-stream');
    headers.set('Cross-Origin-Opener-Policy', 'same-origin');
    headers.set('Cross-Origin-Embedder-Policy', 'require-corp');
    headers.set('Cross-Origin-Resource-Policy', 'same-origin');
    return new Response(res.body, { status: res.status, headers });
  });
  createWindow();
});
app.on('window-all-closed', () => app.quit());

// ---------------------------------------------------------------- calls from the page

const IMAGE_TYPES = ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif', 'avif', 'tif', 'tiff', 'ico'];

ipcMain.handle('open-image', async () => {
  const r = await dialog.showOpenDialog(win, {
    title: 'Open an Image', properties: ['openFile'],
    filters: [{ name: 'Images', extensions: IMAGE_TYPES }, { name: 'All Files', extensions: ['*'] }],
  });
  if (r.canceled || !r.filePaths.length) return null;
  const file = r.filePaths[0];
  const data = await fs.promises.readFile(file);
  return { name: path.basename(file), data: data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) };
});

ipcMain.handle('save-image', async (_e, { name, ext, data }) => {
  const filters = { png: ['PNG image', ['png']], jpg: ['JPEG image', ['jpg', 'jpeg']], webp: ['WebP image', ['webp']] }[ext];
  const r = await dialog.showSaveDialog(win, {
    title: 'Save', defaultPath: path.join(app.getPath('downloads'), name),
    filters: [{ name: filters[0], extensions: filters[1] }],
  });
  if (r.canceled || !r.filePath) return null;
  await fs.promises.writeFile(r.filePath, Buffer.from(data));
  return path.basename(r.filePath);
});

ipcMain.handle('read-text', async (_e, rel) => {
  const file = path.normalize(path.join(APP_DIR, rel));
  if (!file.startsWith(APP_DIR)) return '';
  return fs.promises.readFile(file, 'utf8').catch(() => '');
});

ipcMain.on('confirm-close', () => { allowClose = true; win.close(); });
ipcMain.on('open-link', (_e, url) => { if (/^https:\/\//.test(url)) shell.openExternal(url); });
ipcMain.handle('app-info', () => ({ version: app.getVersion(), electron: process.versions.electron }));
