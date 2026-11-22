#!/usr/bin/env python3
"""Binary AndroidManifest.xml (AXML) patcher — correct ResXMLTree layout.

START_ELEMENT chunk:
  +0  type(2) headerSize(2) size(4)
  +8  lineNumber(4) comment(4)
  +16 ns(4) name(4)
  +24 attributeStart(2) attributeSize(2) attributeCount(2)
  +30 idIndex(2) classIndex(2) styleIndex(2)
  attrs begin at chunkStart + 16 + attributeStart; each 20B:
    ns(4) name(4) rawValue(4) typedValue{size(2) res0(1) dataType(1) data(4)}
"""
import struct, sys

class Pool:
    def __init__(self, data, off):
        self.data = data; self.off = off
        t, hs, sz = struct.unpack_from('<HHI', data, off)
        self.count, self.scount, self.flags, self.sstart, self.styles = struct.unpack_from('<IIIII', data, off + 8)
        self.utf8 = bool(self.flags & 0x100)
        self.strings = []
        for i in range(self.count):
            o = struct.unpack_from('<I', data, off + 28 + 4*i)[0]
            p = off + self.sstart + o
            if self.utf8:
                n = data[p]
                if n & 0x80: n = ((n & 0x7f) << 8) | data[p+1]; p += 2
                else: p += 1
                m = data[p]
                if m & 0x80: m = ((m & 0x7f) << 8) | data[p+1]; p += 2
                else: p += 1
                self.strings.append(data[p:p+m].decode('utf-8', 'replace'))
            else:
                n = struct.unpack_from('<H', data, p)[0]; p += 2
                self.strings.append(data[p:p+n*2].decode('utf-16-le', 'replace'))
        self.new_chunk = None

    def append(self, s):
        idx = self.count
        if self.utf8:
            enc = s.encode('utf-8')
            hi = len(s) >> 8
            payload = bytes([0x80 | hi, len(s) & 0xff]) if hi else bytes([len(s) & 0x7f])
            payload += bytes([len(enc) & 0x7f]) + enc + b'\x00'
        else:
            enc = s.encode('utf-16-le')
            payload = struct.pack('<H', len(s)) + enc + b'\x00\x00'
        blob_start = self.off + self.sstart
        blob_end = self.off + self.styles if self.styles else self.off + self.size_of(self.data)
        blob = bytes(self.data[blob_start:blob_end])
        new_off = len(blob)
        header = bytearray(self.data[self.off:self.off + 28])
        new_count = self.count + 1
        struct.pack_into('<I', header, 8, new_count)
        # strings blob moves by the extra offset entry
        struct.pack_into('<I', header, 20, 28 + 4 * new_count + (4 * self.scount if self.scount else 0))
        offsets = bytes(self.data[self.off+28:self.off+28+4*self.count]) + struct.pack('<I', new_off)
        new_blob = blob + payload
        self.size_of = lambda d: self.chunk_size
        self.chunk_size = 28 + 4*new_count + len(new_blob)
        struct.pack_into('<I', header, 4, self.chunk_size)
        self.new_chunk = bytes(header) + offsets + new_blob
        self.count = new_count
        self.strings.append(s)
        return idx

    def size_of(self, d):
        t, hs, sz = struct.unpack_from('<HHI', d, self.off)
        return sz

def walk_chunks(data):
    pos = 8
    while pos + 8 <= len(data):
        t, hs, sz = struct.unpack_from('<HHI', data, pos)
        if sz < 8 or pos + sz > len(data): break
        yield pos, t, sz
        pos += sz

def elem_name(data, pos):
    name = struct.unpack_from('<i', data, pos + 20)[0]
    return name

def elem_attrs(data, pos):
    attr_start, attr_size, attr_count = struct.unpack_from('<HHH', data, pos + 24)
    base = pos + 16 + attr_start
    out = {}
    for a in range(attr_count):
        ao = base + a * attr_size
        ns, name, raw = struct.unpack_from('<iii', data, ao)
        out[name] = ao
    return out, (base, attr_size, attr_count)

def main():
    src, dst = sys.argv[1], sys.argv[2]
    data = bytearray(open(src, 'rb').read())
    top_size = struct.unpack_from('<I', data, 4)[0]
    pool_off = next(p for p, t, sz in walk_chunks(data) if t == 0x0001)
    pool = Pool(bytes(data), pool_off)
    names = {}
    for i, s in enumerate(pool.strings): names.setdefault(s, i)

    def idx(s):
        if s in names: return names[s]
        i = pool.append(s)
        names[s] = i
        return i

    # verify attribute integrity of <application>
    app_pos = next(p for p, t, sz in walk_chunks(data)
                   if t == 0x0102 and elem_name(data, p) == names['application'])
    attrs, (base, asize, acount) = elem_attrs(data, app_pos)
    enl = names['extractNativeLibs']
    assert enl in attrs, "extractNativeLibs not found in <application>"
    ao = attrs[enl]
    dt = data[ao + 15]
    assert dt == 0x12, "extractNativeLibs not boolean: %x" % dt
    print("verified <application> attrs; extractNativeLibs attr at", ao)

    # 2. flip extractNativeLibs -> true
    struct.pack_into('<I', data, ao + 16, 0xFFFFFFFF)
    print("extractNativeLibs -> true")

    # 3. remove requiredSplitTypes from <manifest>
    man_pos = next(p for p, t, sz in walk_chunks(data)
                   if t == 0x0102 and elem_name(data, p) == names['manifest'])
    m_attrs, (m_base, m_asize, m_acount) = elem_attrs(data, man_pos)
    rst = names.get('requiredSplitTypes')
    if rst in m_attrs:
        ao2 = m_attrs[rst]
        old_sz = struct.unpack_from('<I', data, man_pos + 4)[0]
        pre = bytes(data[:ao2]); mid = bytes(data[ao2 + m_asize:]); 
        new_top = top_size - m_asize
        data = bytearray(pre + mid)
        struct.pack_into('<I', data, man_pos + 4, old_sz - m_asize)
        struct.pack_into('<H', data, man_pos + 28, m_acount - 1)
        struct.pack_into('<I', data, 4, new_top)
        print("requiredSplitTypes removed; top size adjusted")

    # 4/5. remove vending splits meta-data elements
    for target in ('com.android.vending.splits.required', 'com.android.vending.splits'):
        while True:
            removed = False
            for p, t, sz in list(walk_chunks(data)):
                if t != 0x0102 or elem_name(data, p) != names['meta-data']:
                    continue
                at, (b2, s2, c2) = elem_attrs(data, p)
                nm = names['name']
                if nm in at:
                    raw = struct.unpack_from('<i', data, at[nm] + 8)[0]
                    if raw == names.get(target):
                        # find matching END_ELEMENT
                        depth = 1; q = p + sz; end = None
                        for q2, t2, sz2 in walk_chunks(data):
                            if q2 <= q: continue
                            if t2 == 0x0102: depth += 1
                            elif t2 == 0x0103:
                                depth -= 1
                                if depth == 0: end = q2 + sz2; break
                        assert end
                        data = bytearray(bytes(data[:p]) + bytes(data[end:]))
                        delta = end - p
                        struct.pack_into('<I', data, 4, struct.unpack_from('<I', data, 4)[0] - delta)
                        print(target, "element removed")
                        removed = True
                        break
            if not removed: break

    # 1. add debuggable=true to <application> (inserted in aapt's sorted-by-id order)
    app_pos = next(p for p, t, sz in walk_chunks(data)
                   if t == 0x0102 and elem_name(data, p) == names['application'])
    chunk_size = struct.unpack_from('<I', data, app_pos + 4)[0]
    attr_start, attr_size, attr_count = struct.unpack_from('<HHH', data, app_pos + 24)
    android_ns = next(i for i, s in enumerate(pool.strings) if s == 'http://schemas.android.com/apk/res/android')
    dbg = idx('debuggable')
    new_attr = struct.pack('<iii', android_ns, dbg, -1) + struct.pack('<HBB', 8, 0, 0x12) + struct.pack('<I', 0xFFFFFFFF)
    DBG_ID = 0x0101000f
    # map: attribute name string index -> resource id via RES map chunk
    res_ids = {}
    for p, t, sz in walk_chunks(data):
        if t != 0x0180: continue
        hs = struct.unpack_from('<H', data, p + 2)[0]
        cnt = (sz - hs) // 4
        for i, rid in enumerate(struct.unpack_from('<%dI' % cnt, data, p + hs)):
            res_ids[i] = rid
        break
    base = app_pos + 16 + attr_start
    insert_idx = attr_count
    for a in range(attr_count):
        ao = base + a * attr_size
        an = struct.unpack_from('<i', data, ao + 4)[0]
        rid = res_ids.get(an, 0)
        if rid > DBG_ID:
            insert_idx = a
            break
    insert_at = base + attr_size * insert_idx
    data = bytearray(bytes(data[:insert_at]) + new_attr + bytes(data[insert_at:]))
    struct.pack_into('<I', data, app_pos + 4, chunk_size + attr_size)
    struct.pack_into('<H', data, app_pos + 28, attr_count + 1)
    struct.pack_into('<I', data, 4, struct.unpack_from('<I', data, 4)[0] + attr_size)
    print("debuggable=true added")

    # extend RES_XML_RESOURCE_MAP (0x0180) so index(debuggable) resolves to
    # android:debuggable (0x0101000f); unmapped slots get id 0 (ignored by parser)
    dbg_index = names['debuggable']
    for p, t, sz in walk_chunks(data):
        if t != 0x0180: continue
        hs = struct.unpack_from('<H', data, p + 2)[0]
        cur_count = (sz - hs) // 4
        if dbg_index < cur_count: break
        ids = list(struct.unpack_from('<%dI' % cur_count, data, p + hs))
        while len(ids) < dbg_index: ids.append(0)
        ids.append(0x0101000f)
        new_sz = hs + 4 * len(ids)
        new_map = bytearray(data[p:p + hs]) + bytearray(struct.pack('<%dI' % len(ids), *ids))
        struct.pack_into('<I', new_map, 4, new_sz)
        delta = new_sz - sz
        data = bytearray(bytes(data[:p]) + new_map + bytes(data[p + sz:]))
        struct.pack_into('<I', data, 4, struct.unpack_from('<I', data, 4)[0] + delta)
        print("resource map extended:", cur_count, "->", len(ids), "delta", delta)
        break

    # splice rebuilt string pool
    if pool.new_chunk is not None:
        old_pool_size = struct.unpack_from('<I', data, pool.off + 4)[0]
        delta = len(pool.new_chunk) - old_pool_size
        data = bytearray(bytes(data[:pool.off]) + pool.new_chunk + bytes(data[pool.off + old_pool_size:]))
        struct.pack_into('<I', data, 4, struct.unpack_from('<I', data, 4)[0] + delta)
        print("string pool spliced, delta", delta)

    open(dst, 'wb').write(bytes(data))
    print("written", dst, len(data), "bytes")

if __name__ == '__main__':
    main()
