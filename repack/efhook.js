// efhook.js v4 — file logging + console
var TAG = "[EFHOOK] ";
var fw = null;
function flog(s) {
    console.log(TAG + s);
    try {
        if (fw === null) {
            var FW = Java.use("java.io.FileWriter");
            fw = FW.$new("/data/data/com.ecoflow/files/efhook.log", true);
        }
        fw.write(s + "\n");
        fw.flush();
    } catch (e) {}
}
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

function hookSafe(method, sigChars, impl) {
    try {
        var args = sigChars.split('').map(function (c) {
            return c === 'b' ? '[B' : 'int';
        });
        var m = TE[method];
        if (m.overload) {
            var o = m.overload;
            var target;
            if (args.length === 1) target = o(args[0]);
            else if (args.length === 2) target = o(args[0], args[1]);
            else if (args.length === 3) target = o(args[0], args[1], args[2]);
            else if (args.length === 6) target = o(args[0], args[1], args[2], args[3], args[4], args[5]);
            target.implementation = impl;
        } else {
            m.implementation = impl;
        }
        flog("hooked " + method + "(" + sigChars + ")");
    } catch (e) {
        flog("hook fail " + method + ": " + e);
    }
}

var TE = null;
function installAll() {
    if (TE === null) {
        try {
            TE = Java.use("com.ecoflow.jni.TreatyEngine");
        } catch (e) {
            flog("not the ecoflow process (no TreatyEngine)");
            return;
        }
    }

    hookSafe("generateShareKey", "bbb", function (appPriv, devPub, t) {
        var r = this.generateShareKey(appPriv, devPub, t);
        flog("generateShareKey type=" + t + " appPriv=" + toHex(appPriv) + " devPub=" + toHex(devPub) + " share=" + toHex(r));
        return r;
    });
    hookSafe("aesDecryptKey", "bbb", function (key, iv, ct) {
        var r = this.aesDecryptKey(key, iv, ct);
        flog("aesDecryptKey key=" + toHex(key) + " iv=" + toHex(iv) + " ct=" + toHex(ct) + " plain=" + toHex(r));
        return r;
    });
    hookSafe("generateSessionKey", "bb", function (seed, sRand) {
        var r = this.generateSessionKey(seed, sRand);
        flog("generateSessionKey seed=" + toHex(seed) + " sRand=" + toHex(sRand) + " sessionKey=" + toHex(r));
        return r;
    });
    hookSafe("aesEncryptFrame", "biiibb", function (data, pt, ft, ver, key, iv) {
        flog("aesEncryptFrame pt=" + pt + " ft=" + ft + " ver=" + ver + " key=" + toHex(key) + " iv=" + toHex(iv) + " data=" + toHex(data));
        return this.aesEncryptFrame(data, pt, ft, ver, key, iv);
    });
    hookSafe("aesDecryptFrame", "bbb", function (key, iv, data) {
        var r = this.aesDecryptFrame(key, iv, data);
        flog("aesDecryptFrame key=" + toHex(key) + " iv=" + toHex(iv) + " frame=" + toHex(data));
        return r;
    });

    flog("treaty hooks installed");
}

function tryHook(attempt) {
    if (attempt > 240) { flog("giving up"); return; }
    try {
        if (typeof Java === "undefined" || !Java.available) {
            setTimeout(function () { tryHook(attempt + 1); }, 500);
            return;
        }
        Java.perform(function () { installAll(); });
    } catch (e) {
        flog("attempt " + attempt + " failed: " + e);
        setTimeout(function () { tryHook(attempt + 1); }, 1000);
    }
}

setTimeout(function () { tryHook(0); }, 10000);
