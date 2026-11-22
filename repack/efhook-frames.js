// efhook-frames.js — minimal: only the two proven-stable crypto hooks.
// Purpose: capture outbound command frames (e.g. the AC toggle) in plaintext.
var TAG = "[EFFR] ";
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

function installAll() {
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
