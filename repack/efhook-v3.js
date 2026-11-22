// efhook-v3.js — reveal the R33 (MR330) parse module at runtime.
// The chain (verified in decompiled app):
//   EcoProtocol.parse → ecoProtocolCallback → EcoPacket →
//   EcoActiveEventListener.onEvent(int, EcoPacket)  [abstract bases: zv.b (GE305),
//   ru.c (YJ751), m50.b (BleListener), ...] → concrete module parses payload.
// This hook logs, for EVERY onEvent: the CONCRETE class name + the full packet
// (ver/seq/src/dSrc/dDst/cmdSet/cmdId/payload). The class that consumes
// src=0x02/0x03/0x04/0x05 for the R33 is the MR330 parser — then we can read
// its decompiled offsets statically.
var TAG = "[EFV3] ";
function toHex(arr) {
    if (arr === null) return "null";
    try {
        var bytes = Java.array('byte', arr);
        var out = [];
        for (var i = 0; i < bytes.length; i++) {
            var v = bytes[i] & 0xff;
            out.push((v < 16 ? "0" : "") + v.toString(16));
        }
        return out.join("");
    } catch (e) { return "hexerr"; }
}

function hookOnEvent() {
    var hooked = 0;
    var hookedNames = {};
    function scan() {
        Java.enumerateLoadedClasses({
            onMatch: function (name) {
                if (name.indexOf('com.ecoflow') !== 0 || hookedNames[name]) return;
                try {
                    var cls = Java.use(name);
                    // signature 1: onEvent(int, EcoPacket)
                    try {
                        var m = cls.onEvent.overload('int', 'com.ecoflow.cbb.smartdevice.bean.EcoPacket');
                        m.implementation = function (i, pkt) {
                            try {
                                console.log(TAG + "onEvent(int,pkt) cls=" + name +
                                    " i=" + i +
                                    " src=0x" + ("0" + (pkt.getSrc() & 255).toString(16)).slice(-2) +
                                    " dst=0x" + ("0" + (pkt.getDst() & 255).toString(16)).slice(-2) +
                                    " cmdSet=0x" + ("0" + (pkt.getCmdSet() & 255).toString(16)).slice(-2) +
                                    " cmdId=0x" + ("0" + (pkt.getCmdId() & 255).toString(16)).slice(-2) +
                                    " seq=" + pkt.getSeq() +
                                    " payload=" + toHex(pkt.getPayLoad()));
                            } catch (e) { console.log(TAG + "onEvent logerr " + e); }
                            return m.call(this, i, pkt);
                        };
                        hookedNames[name] = 1; hooked++;
                    } catch (e) {}
                    // signature 2: onEvent(List)
                    try {
                        var m2 = cls.onEvent.overload('java.util.List');
                        m2.implementation = function (lst) {
                            console.log(TAG + "onEvent(List) cls=" + name + " items=" + lst.size());
                            try {
                                var it = lst.iterator();
                                while (it.hasNext()) {
                                    var cd = it.next();
                                    var clsCd = cd.getClass().getName();
                                    console.log(TAG + "  item class=" + clsCd + " toString=" + cd.toString());
                                }
                            } catch (e2) { console.log(TAG + "list logerr " + e2); }
                            return m2.call(this, lst);
                        };
                        hookedNames[name] = 1; hooked++;
                    } catch (e) {}
                } catch (e) {}
            },
            onComplete: function () {
                console.log(TAG + "onEvent scan pass done (total hooked: " + hooked + ")");
            }
        });
    }
    // rescan a few times so classes loaded after connect are caught too
    scan();
    var pass = 1;
    var iv = setInterval(function () {
        pass++;
        if (pass <= 8) scan(); else clearInterval(iv);
    }, 20000);
}

function hookFrames() {
    var TE = Java.use("com.ecoflow.jni.TreatyEngine");
    TE.aesDecryptFrame.overload('[B', '[B', '[B').implementation = function (key, iv, data) {
        var r = this.aesDecryptFrame(key, iv, data);
        console.log(TAG + "aesDecryptFrame key=" + toHex(key) + " iv=" + toHex(iv) + " frame=" + toHex(data));
        return r;
    };
    TE.aesEncryptFrame.overload('[B', 'int', 'int', 'int', '[B', '[B').implementation = function (data, pt, ft, ver, key, iv) {
        console.log(TAG + "aesEncryptFrame pt=" + pt + " ft=" + ft + " ver=" + ver + " key=" + toHex(key) + " iv=" + toHex(iv) + " data=" + toHex(data));
        return this.aesEncryptFrame(data, pt, ft, ver, key, iv);
    };
    // also hook assemblePacket to see FrameInfo→EcoPacket mapping
    try {
        var S = Java.use('com.ecoflow.cbb.databus.ble.protocol.encrypt.EcoProtocolParseTypeSession');
        S.assemblePacket.overload('com.ecoflow.jni.bean.FrameInfo').implementation = function (fi) {
            var r = this.assemblePacket(fi);
            console.log(TAG + "assemblePacket fi.src=" + fi.getSrc() + " cmdFunc=" + fi.getCmdFunc() + " cmdId=" + fi.getCmdId() + " pdata=" + toHex(fi.getPdata()));
            return r;
        };
    } catch (e) {}
    console.log(TAG + "frame hooks installed");
}

function installAll() {
    hookFrames();
    hookOnEvent();
}

function tryHook(attempt) {
    if (attempt > 240) { console.log(TAG + "giving up"); return; }
    try {
        if (typeof Java === "undefined" || !Java.available) {
            setTimeout(function () { tryHook(attempt + 1); }, 500);
            return;
        }
        Java.perform(function () { installAll(); });
    } catch (e) {
        console.log(TAG + "attempt " + attempt + " failed: " + e);
        setTimeout(function () { tryHook(attempt + 1); }, 1000);
    }
}
setTimeout(function () { tryHook(0); }, 10000);
