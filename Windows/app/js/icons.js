// Line icons in the spirit of the SF Symbols used on Mac and iPhone (24×24, drawn with currentColor).
const P = {
  x: '<path d="M6 6l12 12M18 6L6 18"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  save: '<path d="M12 4v10m0 0l-4-4m4 4l4-4"/><path d="M5 14v4a2 2 0 002 2h10a2 2 0 002-2v-4"/>',
  check: '<circle cx="12" cy="12" r="9" fill="currentColor" stroke="none"/><path d="M8 12.5l2.6 2.6L16 9.6" stroke="#0b0d18" stroke-width="2.2"/>',
  sparkles: '<path d="M10 3l1.6 4.9L16.5 9.5l-4.9 1.6L10 16l-1.6-4.9L3.5 9.5l4.9-1.6z" fill="currentColor" stroke="none"/><path d="M18 14l.8 2.2L21 17l-2.2.8L18 20l-.8-2.2L15 17l2.2-.8z" fill="currentColor" stroke="none"/><path d="M17.5 3.5l.5 1.4 1.4.5-1.4.5-.5 1.4-.5-1.4-1.4-.5 1.4-.5z" fill="currentColor" stroke="none"/>',
  wand: '<path d="M4 20L15 9"/><path d="M13.5 7.5l3 3"/><path d="M18 2.5l.6 1.9 1.9.6-1.9.6-.6 1.9-.6-1.9-1.9-.6 1.9-.6z" fill="currentColor"/><path d="M8 3l.4 1.1 1.1.4-1.1.4L8 6l-.4-1.1-1.1-.4 1.1-.4z" fill="currentColor"/><path d="M20 12l.4 1.1 1.1.4-1.1.4-.4 1.1-.4-1.1-1.1-.4 1.1-.4z" fill="currentColor"/>',
  cpu: '<rect x="6" y="6" width="12" height="12" rx="2"/><rect x="9.5" y="9.5" width="5" height="5" rx="1"/><path d="M9 3v3M15 3v3M9 18v3M15 18v3M3 9h3M3 15h3M18 9h3M18 15h3"/>',
  aperture: '<circle cx="12" cy="12" r="9"/><path d="M14.3 3.3L9.6 11.4M20.5 9L11.2 9.1M18.2 18.6l-4.6-8M9.7 20.7l4.7-8.1M3.5 15l9.3-.1M5.8 5.4l4.6 8"/>',
  bolt: '<path d="M13 2L4.5 13.5H12L11 22l8.5-11.5H12z" fill="currentColor" stroke-linejoin="round"/>',
  palette: '<path d="M12 3a9 9 0 100 18c1.2 0 2-.8 2-1.9 0-.5-.2-1-.5-1.3-.3-.4-.5-.8-.5-1.3 0-1 .8-1.8 1.8-1.8H17a4 4 0 004-4C21 6.6 17 3 12 3z"/><circle cx="7.5" cy="11" r="1.3" fill="currentColor"/><circle cx="10" cy="7" r="1.3" fill="currentColor"/><circle cx="15" cy="7" r="1.3" fill="currentColor"/>',
  folder: '<path d="M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z"/>',
  paste: '<rect x="5" y="4" width="14" height="17" rx="2"/><path d="M9 4V3h6v1M9 4a1 1 0 001 1h4a1 1 0 001-1"/><path d="M9 11h6M9 15h4"/>',
  lock: '<rect x="5" y="11" width="14" height="9" rx="2" fill="currentColor"/><path d="M8 11V8a4 4 0 018 0v3"/>',
  expand: '<path d="M14 4h6v6M10 20H4v-6M20 4l-7 7M4 20l7-7"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6"/><circle cx="12" cy="7.6" r=".9" fill="currentColor"/>',
  stop: '<rect x="6" y="6" width="12" height="12" rx="2" fill="currentColor"/>',
  home: '<path d="M4 11l8-7 8 7v8a1 1 0 01-1 1h-4v-6h-6v6H5a1 1 0 01-1-1z" fill="currentColor"/>',
  arrowRight: '<path d="M5 12h14m-5-5l5 5-5 5"/>',
  split: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M12 5v14"/>',
  smile: '<circle cx="12" cy="12" r="9"/><path d="M8.5 14.5a4.5 4.5 0 007 0"/><circle cx="9" cy="10" r="1" fill="currentColor"/><circle cx="15" cy="10" r="1" fill="currentColor"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
  sliders: '<path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/>',
  chevron: '<path d="M7 10l5 5 5-5"/>',
  chevronUp: '<path d="M7 14l5-5 5 5"/>',
  leftRight: '<path d="M4 12h16M8 8l-4 4 4 4M16 8l4 4-4 4"/>',
  warning: '<path d="M12 3l10 18H2z" fill="currentColor" stroke="none"/><path d="M12 10v5" stroke="#0b0d18"/><circle cx="12" cy="18" r=".9" fill="#0b0d18" stroke="none"/>',
  image: '<rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="8.5" cy="9.5" r="1.5"/><path d="M21 16l-5-5-9 9"/>',
  circle: '<circle cx="12" cy="12" r="8.5"/>',
  tick: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  stack: '<rect x="3" y="8" width="14" height="12" rx="2"/><path d="M7 4.5h11.5A2.5 2.5 0 0121 7v9.5"/>',
  copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 00-2-2H6a2 2 0 00-2 2v8a2 2 0 002 2h2"/>',
};

export function icon(name, cls = '') {
  return `<svg class="ic ${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${P[name] || ''}</svg>`;
}
