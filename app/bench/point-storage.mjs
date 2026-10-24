// Attribute page allocations separately from packed/logical payload bytes.
export function pointStorage(all, one, tables) {
  const packed = one("SELECT 1 FROM sqlite_master WHERE name='hk_blobs'");
  const kinds = {};
  if (packed) {
    const names = { 0: 'quantity', 3: 'route', 4: 'heartbeat', 5: 'ecg' };
    let totalBytes = 0;
    for (const { data } of all('SELECT data FROM hk_blobs')) {
      const b = Buffer.from(data), name = names[b[1]], k = kinds[name] ??= { points: 0, encoded_bytes: 0 };
      k.points += b.readUInt32LE(4); k.encoded_bytes += b.length; totalBytes += b.length;
    }
    const allocated = Object.entries(tables).filter(([name]) => /hk_blobs/.test(name)).reduce((n,[,v])=>n+v,0);
    for (const k of Object.values(kinds)) {
      k.allocated_bytes = allocated * k.encoded_bytes / totalBytes;
      k.allocated_bytes_per_point = k.allocated_bytes / k.points;
      k.encoded_bytes_per_point = k.encoded_bytes / k.points;
    }
  } else {
    for (const [kind, table] of [['quantity','hk_quantity_points'],['route','hk_route_points'],['heartbeat','hk_heartbeat_beats']]) {
      const points = one(`SELECT COUNT(*) n FROM ${table}`).n;
      const bytes = Object.entries(tables).filter(([name])=>name.includes(table)).reduce((n,[,v])=>n+v,0);
      kinds[kind] = { points, allocated_bytes: bytes, allocated_bytes_per_point: bytes / points };
    }
    const ecg = one("SELECT SUM(json_array_length(json_extract(extra_json,'$.voltages_uv'))) n,SUM(length(CAST(json_extract(extra_json,'$.voltages_uv') AS BLOB))) bytes FROM hk_samples WHERE kind='ecg'");
    if (ecg.n) kinds.ecg = { points: ecg.n, encoded_bytes: ecg.bytes, encoded_bytes_per_point: ecg.bytes / ecg.n, allocated_bytes: null, allocated_bytes_per_point: null };
  }
  return { layout: packed ? 'packed-v1' : 'child-rows-and-ecg-json', kinds,
    allocation_note: packed ? 'BLOB table/index page bytes apportioned by encoded bytes; includes page overhead.' : 'Child table and index pages measured directly. ECG JSON shares sample pages; only its logical bytes are attributed.' };
}
