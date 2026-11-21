#!/usr/bin/env python3
"""Login to EcoFlow API and get user_id + auth token for the BLE session."""
import json, sys, urllib.request, urllib.error, hashlib, os

EMAIL = os.environ.get("ECOFLOW_EMAIL", "<EMAIL>")
PASSWORD = os.environ.get("ECOFLOW_PASSWORD", "<PASSWORD>")  # never hardcode
BASE_URL = "https://api.ecoflow.com"

def login():
    """POST /api/v1/login with email+password (md5 hashed)"""
    # EcoFlow API expects the password as MD5 hash
    pwd_md5 = hashlib.md5(PASSWORD.encode()).hexdigest()
    
    payload = {
        "email": EMAIL,
        "password": pwd_md5,
    }
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{BASE_URL}/api/v1/login",
        data=data,
        headers={
            "Content-Type": "application/json",
            "lang": "en-us",
        },
        method="POST"
    )
    try:
        resp = urllib.request.urlopen(req, timeout=15)
        result = json.loads(resp.read())
        print(json.dumps(result, indent=2))
        return result
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return None

def get_refresh_token(user_id, token):
    """GET /iot-service/user/device/refreshToken?sn=..."""
    sn = "<SN>"
    req = urllib.request.Request(
        f"{BASE_URL}/iot-service/user/device/refreshToken?sn={sn}",
        headers={
            "Authorization": f"Bearer {token}",
            "lang": "en-us",
        },
    )
    try:
        resp = urllib.request.urlopen(req, timeout=15)
        result = json.loads(resp.read())
        print(json.dumps(result, indent=2))
        return result
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()}", file=sys.stderr)
        return None

def adb_curl(method, url, headers=None, data=None):
    """Call API via the phone's network using adb shell curl."""
    import subprocess
    hdr_args = ""
    if headers:
        for k, v in headers.items():
            hdr_args += f" -H '{k}: {v}'"
    data_args = ""
    if data:
        data_args = f" -d '{data}'"
    cmd = f"adb shell curl -s -X {method} '{url}'{hdr_args}{data_args}"
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=15)
    return result.stdout

if __name__ == "__main__":
    print("=== Logging in to EcoFlow API (via adb relay) ===")
    pwd_md5 = hashlib.md5(PASSWORD.encode()).hexdigest()
    payload = json.dumps({"email": EMAIL, "password": pwd_md5})
    resp_text = adb_curl("POST", f"{BASE_URL}/api/v1/login",
                         headers={"Content-Type": "application/json", "lang": "en-us"},
                         data=payload)
    print("Response:", resp_text[:500])
    if resp_text:
        try:
            login_result = json.loads(resp_text)
            data = login_result.get("data", {})
            token = data.get("access_token", "")
            user_id = data.get("user_id", 0)
            print(f"\nuser_id: {user_id}")
            print(f"token: {token[:30]}..." if token else "no token")
            if token and user_id:
                print("\n=== Getting refresh token for device ===")
                sn = "<SN>"
                rt_text = adb_curl("GET", f"{BASE_URL}/iot-service/user/device/refreshToken?sn={sn}",
                                   headers={"Authorization": f"Bearer {token}", "lang": "en-us"})
                print("RefreshToken response:", rt_text[:500])
        except Exception as e:
            print(f"Parse error: {e}")
    if login_result:
        # Extract token and user_id from response
        data = login_result.get("data", {})
        token = data.get("access_token", "")
        user_id = data.get("user_id", 0)
        print(f"\nuser_id: {user_id}")
        print(f"token: {token[:20]}..." if token else "no token")
        
        if token and user_id:
            print("\n=== Getting refresh token for device ===")
            rt = get_refresh_token(user_id, token)
