// Pure timestamp codec shared by SQLite read views and packed series.
export function stampParts(iso: string) {
  const match = /([+-])(\d{2}):(\d{2})$/.exec(iso);
  const offset = match ? (match[1] === '-' ? -1 : 1) * (+match[2] * 60 + +match[3]) : 0;
  const digits = /\.(\d+)/.exec(iso)?.[1].length ?? 0;
  const exceptional = digits > 3 || iso.endsWith('-00:00');
  return { offset, format: exceptional ? 255 : digits + (iso.endsWith('Z') ? 4 : 0), original: exceptional ? iso : undefined };
}
export function rebuildISO(ms: number, offset: number, format: number, original?: string): string {
  if (original) return original;
  const digits = format & 3, local = new Date(ms + offset * 60000).toISOString();
  const time = local.slice(0, 19) + (digits ? '.' + local.slice(20, 20 + digits) : '');
  return time + (format & 4 ? 'Z' : `${offset < 0 ? '-' : '+'}${String(Math.floor(Math.abs(offset) / 60)).padStart(2, '0')}:${String(Math.abs(offset) % 60).padStart(2, '0')}`);
}
