// efhook-v4.js — v2's PROVEN-working hooks (full telemetry stream) +
// safe onEvent(int, EcoPacket) interception to reveal the R33 parse class.
// NO assemblePacket hook (v3's version broke the app's auth loop).
var TAG = "[EFV4] ";
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

function hookFrames() {
    var TE = Java.use("com.ecoflow.jni.TreatyEngine");
    TE.aesEncryptFrame.overload('[B', 'int', 'int', 'int', '[B', '[B').implementation = function (data, pt, ft, ver, key, iv) {
        console.log(TAG + "aesEncryptFrame pt=" + pt + " ft=" + ft + " ver=" + ver + " key=" + toHex(key) + " iv=" + toHex(iv) + " data=" + toHex(data));
        return this.aesEncryptFrame(data, pt, ft, ver, key, iv);
    };
    TE.aesDecryptFrame.overload('[B', '[B', '[B').implementation = function (key, iv, data) {
        var r = this.aesDecryptFrame(key, iv, data);
        console.log(TAG + "aesDecryptFrame key=" + toHex(key) + " iv=" + toHex(iv) + " frame=" + toHex(data));
        return r;
    };
    console.log(TAG + "frame hooks installed");
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
                    try {
                        var m = cls.onEvent.overload('int', 'com.ecoflow.cbb.smartdevice.bean.EcoPacket');
                        m.implementation = function (i, pkt) {
                            try {
                                console.log(TAG + "onEvent cls=" + name +
                                    " i=" + i +
                                    " src=0x" + ("0" + (pkt.getSrc() & 255).toString(16)).slice(-2) +
                                    " dst=0x" + ("0" + (pkt.getDst() & 255).toString(16)).slice(-2) +
                                    " cmdSet=0x" + ("0" + (pkt.getCmdSet() & 255).toString(16)).slice(-2) +
                                    " cmdId=0x" + ("0" + (pkt.getCmdId() & 255).toString(16)).slice(-2) +
                                    " payload=" + toHex(pkt.getPayLoad()));
                            } catch (e) { console.log(TAG + "onEvent logerr " + e); }
                            return m.call(this, i, pkt);
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
    scan();
    var pass = 1;
    var iv = setInterval(function () {
        pass++;
        if (pass <= 8) scan(); else clearInterval(iv);
    }, 20000);
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
