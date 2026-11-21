#!/usr/bin/env python3
"""Parse a btsnoop HCI log and dump ATT/GATT traffic (reconstructed EcoFlow session analysis)."""
import sys, struct, zlib

def parse_btsnoop(path):
    data = open(path, 'rb').read()
    if data[:8] != b'btsnoop\x00':
        raise SystemExit(f"not btsnoop: {data[:16]}")
    version, datalink = struct.unpack('>II', data[8:16])
    print(f"# btsnoop v{version} datalink={datalink} size={len(data)}")
    pos = 16
    records = []
    while pos + 24 <= len(data):
        orig_len, incl_len, flags, drops = struct.unpack('>IIII', data[pos:pos+16])
        pos += 24
        pkt = data[pos:pos+incl_len]
        pos += incl_len
        records.append((flags, pkt))
    return records

def parse_h4(records):
    out = []
    acl_reasm = {}
    for flags, pkt in records:
        if not pkt: continue
        ptype = pkt[0]
        direction = '->dev' if (flags & 1) == 0 else '<-app'
        if ptype == 0x02:  # ACL
            if len(pkt) < 9: continue
            handle_le = struct.unpack('<H', pkt[1:3])[0]
            handle = handle_le & 0xFFF
            pb = (handle_le >> 12) & 0x3
            dlen = struct.unpack('<H', pkt[3:5])[0]
            payload = pkt[5:5+dlen]
            key = handle
            if pb in (0, 2):  # start of L2CAP pdu
                acl_reasm[key] = bytearray(payload)
            else:  # continuation
                if key in acl_reasm:
                    acl_reasm[key] += payload
                else:
                    continue
            buf = acl_reasm.get(key)
            if buf is None or len(buf) < 4: continue
            l2len, cid = struct.unpack('<HH', buf[:4])
            if len(buf) - 4 < l2len:
                continue  # incomplete yet
            l2data = bytes(buf[4:4+l2len])
            del acl_reasm[key]
            if cid == 0x0004:  # ATT
                out.append((direction, handle, 'ATT', l2data))
            elif cid == 0x0006:  # SMP
                out.append((direction, handle, 'SMP', l2data))
        elif ptype == 0x04:  # HCI event
            out.append((direction, 0, 'EVT', pkt))
    return out

ATT_NAMES = {
    0x08: 'EXEC_WRITE_RSP', 0x12: 'FIND_INFO_REQ', 0x52: 'WRITE_CMD', 0x53: 'WRITE_SIGNED',
    0x1B: 'HANDLE_VALUE_NOTIF', 0x1D: 'HANDLE_VALUE_IND', 0x1E: 'HANDLE_VALUE_CFM',
    0x0A: 'MTU_REQ', 0x0B: 'MTU_RSP', 0x12: 'FIND_INFO_REQ', 0x13: 'FIND_INFO_RSP',
    0x1A: 'HANDLE_VALUE_CONF',
}

def att_desc(data):
    if not data: return ''
    op = data[0]
    name = ATT_NAMES.get(op)
    if name is None:
        if op in (0x02, 0x03): name = 'READ_RSP' if op == 0x03 else 'WRITE_REQ'
        elif op in (0x04, 0x05): name = 'READ_BLOB_REQ/RSP'
        elif op in (0x10, 0x11): name = 'READ_BY_TYPE_REQ/RSP'
        elif op in (0x06, 0x07): name = 'PREP_WRITE_REQ/RSP'
        elif op in (0x16, 0x17): name = 'EXEC_WRITE_REQ/RSP'
        else: name = f'op_{op:02x}'
    if op == 0x52:  # write cmd: handle(2) + value
        h = struct.unpack('<H', data[1:3])[0]
        return f'WRITE_CMD handle={h:04x} value={data[3:].hex()}'
    if op == 0x02:
        h = struct.unpack('<H', data[1:3])[0]
        return f'WRITE_REQ handle={h:04x} value={data[3:].hex()}'
    if op == 0x1B:  # notification: handle(2) + value
        h = struct.unpack('<H', data[1:3])[0]
        return f'NOTIFY handle={h:04x} value={data[3:].hex()}'
    if op == 0x1D:
        h = struct.unpack('<H', data[1:3])[0]
        return f'INDICATE handle={h:04x} value={data[3:].hex()}'
    return f'{name} {data[1:].hex()}'

def main():
    path = sys.argv[1]
    records = parse_btsnoop(path)
    out = parse_h4(records)
    att_count = 0
    for direction, handle, kind, data in out:
        if kind == 'ATT':
            att_count += 1
            print(f'{direction} h={handle:04x} {att_desc(data)}')
        elif kind == 'SMP':
            print(f'{direction} SMP {data.hex()}')
    print(f'# total ATT packets: {att_count}')

if __name__ == '__main__':
    main()
