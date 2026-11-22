var TAG = "[EFHOOK] ";
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
    TE.generateShareKey.overload('[B', '[B', 'int').implementation = function (appPriv, devPub, t) {
        var r = this.generateShareKey(appPriv, devPub, t);
        console.log(TAG + "generateShareKey type=" + t + " appPriv=" + toHex(appPriv) + " devPub=" + toHex(devPub) + " share=" + toHex(r));
        return r;
    };
    TE.aesDecryptKey.overload('[B', '[B', '[B').implementation = function (key, iv, ct) {
        var r = this.aesDecryptKey(key, iv, ct);
        console.log(TAG + "aesDecryptKey key=" + toHex(key) + " iv=" + toHex(iv) + " ct=" + toHex(ct) + " plain=" + toHex(r));
        return r;
    };
    TE.generateSessionKey.overload('[B', '[B').implementation = function (seed, sRand) {
        var r = this.generateSessionKey(seed, sRand);
        console.log(TAG + "generateSessionKey seed=" + toHex(seed) + " sRand=" + toHex(sRand) + " sessionKey=" + toHex(r));
        return r;
    };
    TE.aesEncryptFrame.overload('[B', 'int', 'int', 'int', '[B', '[B').implementation = function (data, pt, ft, ver, key, iv) {
        console.log(TAG + "aesEncryptFrame pt=" + pt + " ft=" + ft + " ver=" + ver + " key=" + toHex(key) + " iv=" + toHex(iv) + " data=" + toHex(data));
        return this.aesEncryptFrame(data, pt, ft, ver, key, iv);
    };
    TE.aesDecryptFrame.overload('[B', '[B', '[B').implementation = function (key, iv, data) {
        var r = this.aesDecryptFrame(key, iv, data);
        console.log(TAG + "aesDecryptFrame key=" + toHex(key) + " iv=" + toHex(iv) + " frame=" + toHex(data));
        return r;
    };
    console.log(TAG + "treaty hooks installed");
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
