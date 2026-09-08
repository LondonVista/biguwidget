#!/usr/bin/env python3
"""
BigUwidget 1.0.9 — Track B (Native Qt / PySide Desktop Meter for Linux)
Ultra-low memory footprint: ~35–45 MB RSS (down from ~530 MB on Electron).
Supports PySide6, PyQt6, and PyQt5.
"""

import sys
import os
import time
import json
import base64
import struct
import subprocess
import webbrowser
import threading
from pathlib import Path
import urllib.request
import urllib.error
import ssl

# Version & Config
APP_VERSION = "1.0.9"
DONATE_URL = "https://ko-fi.com/london_vista"
CONFIG_DIR = Path.home() / ".config" / "biguwidget"
STATE_FILE = CONFIG_DIR / "state.json"
USER_AGENT = "BigUwidget/1.0.9 (Linux; x86_64)"
FEED_URL = "https://github.com/LondonVista/biguwidget/releases/latest/download/latest.json"
RELEASES_URL = "https://github.com/LondonVista/biguwidget/releases/latest"

# Dynamic Qt Import: PySide6 -> PyQt6 -> PyQt5
QT_LIB = None
try:
    from PySide6 import QtCore, QtGui, QtWidgets
    from PySide6.QtCore import Qt, QTimer, Signal, QPoint, QSize
    QT_LIB = "PySide6"
except ImportError:
    try:
        from PyQt6 import QtCore, QtGui, QtWidgets
        from PyQt6.QtCore import Qt, QTimer, pyqtSignal as Signal, QPoint, QSize
        QT_LIB = "PyQt6"
    except ImportError:
        try:
            from PyQt5 import QtCore, QtGui, QtWidgets
            from PyQt5.QtCore import Qt, QTimer, pyqtSignal as Signal, QPoint, QSize
            QT_LIB = "PyQt5"
        except ImportError:
            pass

# Service Card Definitions
SERVICES = [
    {"id": "grok", "title": "Grok", "sub": "grok.com", "login_url": "https://grok.com"},
    {"id": "grokBot", "title": "Grok Bot", "sub": "Cursor", "login_url": "https://cursor.com"},
    {"id": "agy", "title": "AGY (Gemini)", "sub": "Antigravity", "login_url": "https://antigravity.google"},
    {"id": "claudeGPT", "title": "Claude & GPT", "sub": "via AGY", "login_url": "https://antigravity.google"},
    {"id": "chatGPT", "title": "ChatGPT", "sub": "chatgpt.com", "login_url": "https://chatgpt.com"},
]
DEFAULT_ENABLED = ["grok", "grokBot", "agy", "claudeGPT"]

# SSL context for HTTPS
SSL_CTX = ssl.create_default_context()

# ----------------- Helpers -----------------

def cmp_ver(a, b):
    pa = [int(x) if x.isdigit() else 0 for x in str(a or "0").split(".")]
    pb = [int(x) if x.isdigit() else 0 for x in str(b or "0").split(".")]
    for i in range(max(len(pa), len(pb))):
        x = pa[i] if i < len(pa) else 0
        y = pb[i] if i < len(pb) else 0
        if x > y: return 1
        if x < y: return -1
    return 0

def clean_token(raw):
    if not raw or not isinstance(raw, str):
        return None
    s = raw.strip()
    if not s:
        return None
    if s.startswith("go-keyring-base64:"):
        try:
            s = base64.b64decode(s[len("go-keyring-base64:"):].encode("utf-8")).decode("utf-8").strip()
        except Exception:
            pass
    if s.startswith("{"):
        try:
            obj = json.loads(s)
            tok = obj.get("token", {}).get("access_token") or obj.get("access_token")
            if tok and isinstance(tok, str):
                return tok.strip()
        except Exception:
            pass
    return s

def detect_agy_token(saved_token=None):
    if saved_token:
        c = clean_token(saved_token)
        if c:
            return {"source": "saved", "token": c}

    # 1. Linux Secret Service via secret-tool
    try:
        res = subprocess.run(
            ["secret-tool", "lookup", "service", "gemini", "username", "antigravity"],
            capture_output=True, text=True, timeout=2
        )
        if res.returncode == 0 and res.stdout.strip():
            c = clean_token(res.stdout)
            if c:
                return {"source": "Secret Service", "token": c}
    except Exception:
        pass

    # 2. Token files on disk
    candidates = [
        Path.home() / ".gemini" / "antigravity-cli" / "antigravity-oauth-token",
        Path.home() / ".gemini" / "oauth_creds.json",
        Path.home() / ".config" / "antigravity" / "oauth_creds.json",
        Path.home() / ".config" / "antigravity-cli" / "antigravity-oauth-token",
    ]
    for p in candidates:
        if p.is_file():
            try:
                raw = p.read_text("utf-8")
                c = clean_token(raw)
                if c:
                    return {"source": str(p.name), "token": c}
            except Exception:
                pass

    return None

def remaining_str(ts):
    if not ts:
        return ""
    diff_s = int((ts - time.time() * 1000) / 1000)
    if diff_s <= 0:
        return "now"
    days = diff_s // 86400
    hours = (diff_s % 86400) // 3600
    mins = (diff_s % 3600) // 60
    if days > 0:
        return f"{days}d {hours}h"
    if hours > 0:
        return f"{hours}h {mins}m"
    return f"{mins}m"

def ago_str(ts):
    if not ts:
        return "never"
    diff_s = int(time.time() - ts / 1000)
    if diff_s < 10:
        return "just now"
    if diff_s < 60:
        return f"{diff_s}s ago"
    mins = diff_s // 60
    if mins < 60:
        return f"{mins}m ago"
    hours = mins // 60
    return f"{hours}h ago"

def headline_floats(buf: bytes):
    out = []
    for i in range(len(buf) - 4):
        if buf[i] == 0x15:
            try:
                (n,) = struct.unpack("<f", buf[i+1:i+5])
                if 0.0 <= n <= 100.0:
                    out.append(n)
            except Exception:
                pass
    return out

# ----------------- Network Fetchers -----------------

def http_post(url, headers=None, data=b""):
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("User-Agent", USER_AGENT)
    if headers:
        for k, v in headers.items():
            req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, context=SSL_CTX, timeout=10) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception:
        return 0, b""

def http_get(url, headers=None):
    req = urllib.request.Request(url, method="GET")
    req.add_header("User-Agent", USER_AGENT)
    if headers:
        for k, v in headers.items():
            req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, context=SSL_CTX, timeout=10) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception:
        return 0, b""

def fetch_agy(saved_token=None):
    tok_info = detect_agy_token(saved_token)
    if not tok_info or not tok_info.get("token"):
        return {"ok": False, "need_login": True}

    token = tok_info["token"]
    endpoints = [
        "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
    ]
    for url in endpoints:
        status, body = http_post(
            url,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {token}",
            },
            data=b"{}",
        )
        if status == 200:
            try:
                data = json.loads(body.decode("utf-8"))
                groups = data.get("groups", [])
                gemini = {"weekly": 0, "five": None, "reset": None, "five_reset": None}
                claude = {"weekly": 0, "five": None, "reset": None, "five_reset": None}
                for g in groups:
                    name = str(g.get("displayName", "")).lower()
                    for b in g.get("buckets", []):
                        rem = b.get("remainingFraction", 1)
                        used = max(0, min(100, (1 - rem) * 100))
                        reset = None
                        if b.get("resetTime"):
                            try:
                                t = time.strptime(b["resetTime"].split(".")[0].replace("Z", ""), "%Y-%m-%dT%H:%M:%S")
                                reset = int(time.mktime(t) * 1000)
                            except Exception:
                                pass
                        tgt = gemini if "gemini" in name else (claude if ("claude" in name or "gpt" in name) else None)
                        if not tgt:
                            continue
                        win = b.get("window")
                        if win == "weekly":
                            tgt["weekly"] = used
                            tgt["reset"] = reset
                        elif win == "5h":
                            tgt["five"] = used
                            tgt["five_reset"] = reset
                return {"ok": True, "gemini": gemini, "claude": claude, "source": tok_info.get("source", "token")}
            except Exception:
                pass
        elif status in (401, 403):
            return {"ok": False, "need_login": True}

    return {"ok": False, "error": f"Failed ({status})"}

def fetch_grok(cookie_header=None):
    if not cookie_header:
        return {"ok": False, "need_login": True}
    status, body = http_post(
        "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig",
        headers={
            "Content-Type": "application/grpc-web+proto",
            "connect-protocol-version": "1",
            "x-grpc-web": "1",
            "Origin": "https://grok.com",
            "Cookie": cookie_header,
        },
        data=b"\x00\x00\x00\x00\x00",
    )
    if status in (401, 403):
        return {"ok": False, "need_login": True}
    if status != 200:
        return {"ok": False, "error": f"HTTP {status}"}
    floats = headline_floats(body)
    if not floats:
        return {"ok": False, "error": "Parse error"}
    pct = round(floats[0], 1)
    return {"ok": True, "weekly": pct, "reset": None}

def fetch_grok_bot(cookie_header=None):
    if not cookie_header:
        return {"ok": False, "need_login": True}
    status, body = http_post(
        "https://cursor.com/api/dashboard/get-sand-usage-status",
        headers={
            "Content-Type": "application/json",
            "Origin": "https://cursor.com",
            "Referer": "https://cursor.com",
            "Cookie": cookie_header,
        },
        data=b"{}",
    )
    if status in (401, 403):
        return {"ok": False, "need_login": True}
    if status != 200:
        return {"ok": False, "error": f"HTTP {status}"}
    try:
        d = json.loads(body.decode("utf-8"))
        weekly = d.get("usagePercent", 0)
        reset = None
        if d.get("nextResetTimestampUtc"):
            try:
                t = time.strptime(d["nextResetTimestampUtc"].split(".")[0].replace("Z", ""), "%Y-%m-%dT%H:%M:%S")
                reset = int(time.mktime(t) * 1000)
            except Exception:
                pass
        return {"ok": True, "weekly": weekly, "reset": reset}
    except Exception:
        return {"ok": False, "error": "Parse error"}

def fetch_chatgpt(cookie_header=None):
    if not cookie_header:
        return {"ok": False, "need_login": True}
    status, body = http_get(
        "https://chatgpt.com/api/auth/session",
        headers={"Accept": "application/json", "Cookie": cookie_header, "Origin": "https://chatgpt.com"},
    )
    if status in (401, 403) or status != 200:
        return {"ok": False, "need_login": True}
    try:
        s = json.loads(body.decode("utf-8"))
        token = s.get("accessToken")
    except Exception:
        return {"ok": False, "need_login": True}
    if not token:
        return {"ok": False, "need_login": True}

    u_status, u_body = http_get(
        "https://chatgpt.com/backend-api/wham/usage",
        headers={"Accept": "application/json", "Authorization": f"Bearer {token}", "Cookie": cookie_header},
    )
    if u_status != 200:
        return {"ok": False, "need_login": True}
    try:
        u = json.loads(u_body.decode("utf-8"))
        rate = u.get("usage", {}).get("rate_limit", {})
        sec = rate.get("secondary_window", {})
        prim = rate.get("primary_window", {})
        used = sec.get("used_percent") or prim.get("used_percent", 0)
        reset_sec = sec.get("reset_at") or prim.get("reset_at")
        reset_ms = int(reset_sec * 1000) if reset_sec else None
        return {"ok": True, "weekly": used, "reset": reset_ms}
    except Exception:
        return {"ok": False, "error": "Parse error"}

def fetch_latest_update():
    status, body = http_get(FEED_URL)
    if status == 200:
        try:
            return json.loads(body.decode("utf-8"))
        except Exception:
            pass
    return None

# ----------------- UI / Qt Components -----------------

if QT_LIB:
    class ServiceCard(QtWidgets.QFrame):
        def __init__(self, service_id, title, sub, parent_widget):
            super().__init__()
            self.service_id = service_id
            self.title = title
            self.sub = sub
            self.parent_widget = parent_widget
            self.is_collapsed = False
            self.data = {"status": "loading"}
            self.setup_ui()

        def setup_ui(self):
            self.setObjectName("Card")
            self.setStyleSheet("""
                #Card {
                    background-color: rgba(30, 30, 40, 0.65);
                    border: 1px solid rgba(255, 255, 255, 0.08);
                    border-radius: 9px;
                    margin-bottom: 4px;
                }
            """)
            self.layout = QtWidgets.QVBoxLayout(self)
            self.layout.setContentsMargins(8, 7, 8, 7)
            self.layout.setSpacing(3)

            # Header Row
            hdr = QtWidgets.QHBoxLayout()
            hdr.setContentsMargins(0, 0, 0, 0)
            self.lbl_title = QtWidgets.QLabel(self.title)
            self.lbl_title.setStyleSheet("font-size: 11px; font-weight: bold; color: #f3f4f6; background: transparent;")
            hdr.addWidget(self.lbl_title)

            self.lbl_status = QtWidgets.QLabel("")
            self.lbl_status.setStyleSheet("font-size: 10px; color: #f59e0b; margin-left: 4px; background: transparent;")
            hdr.addWidget(self.lbl_status)

            hdr.addStretch()

            self.btn_col = QtWidgets.QPushButton("▴")
            self.btn_col.setFixedSize(16, 16)
            self.btn_col.setStyleSheet("QPushButton { background: transparent; color: #9ca3af; border: none; font-size: 9px; } QPushButton:hover { color: #fff; }")
            self.btn_col.clicked.connect(self.toggle_collapse)
            hdr.addWidget(self.btn_col)

            self.btn_login = QtWidgets.QPushButton("👤")
            self.btn_login.setFixedSize(16, 16)
            self.btn_login.setStyleSheet("QPushButton { background: transparent; color: #9ca3af; border: none; font-size: 10px; } QPushButton:hover { color: #fff; }")
            self.btn_login.clicked.connect(self.open_login)
            hdr.addWidget(self.btn_login)

            self.layout.addLayout(hdr)

            # Details container
            self.details_box = QtWidgets.QWidget()
            self.details_box.setStyleSheet("background: transparent;")
            d_lay = QtWidgets.QVBoxLayout(self.details_box)
            d_lay.setContentsMargins(0, 3, 0, 0)
            d_lay.setSpacing(3)

            self.lbl_pct = QtWidgets.QLabel("0% used")
            self.lbl_pct.setStyleSheet("font-size: 14px; font-weight: bold; color: #ffffff; background: transparent;")
            d_lay.addWidget(self.lbl_pct)

            self.lbl_reset = QtWidgets.QLabel("")
            self.lbl_reset.setStyleSheet("font-size: 9.5px; color: #9ca3af; background: transparent;")
            d_lay.addWidget(self.lbl_reset)

            self.pbar = QtWidgets.QProgressBar()
            self.pbar.setFixedHeight(5)
            self.pbar.setTextVisible(False)
            self.pbar.setStyleSheet("""
                QProgressBar {
                    background-color: rgba(0, 0, 0, 0.35);
                    border: none;
                    border-radius: 2px;
                }
                QProgressBar::chunk {
                    background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #6366f1, stop:1 #a855f7);
                    border-radius: 2px;
                }
            """)
            d_lay.addWidget(self.pbar)

            # Foot row
            foot = QtWidgets.QHBoxLayout()
            foot.setContentsMargins(0, 2, 0, 0)
            self.lbl_left = QtWidgets.QLabel("")
            self.lbl_left.setStyleSheet("font-size: 9.5px; color: #9ca3af; background: transparent;")
            foot.addWidget(self.lbl_left)
            foot.addStretch()

            self.lbl_ago = QtWidgets.QLabel("")
            self.lbl_ago.setStyleSheet("font-size: 9.5px; color: #6b7280; background: transparent;")
            foot.addWidget(self.lbl_ago)
            d_lay.addLayout(foot)

            self.layout.addWidget(self.details_box)

            # Collapsed summary
            self.lbl_mini = QtWidgets.QLabel("")
            self.lbl_mini.setStyleSheet("font-size: 10px; color: #d1d5db; padding-top: 2px; background: transparent;")
            self.lbl_mini.setVisible(False)
            self.layout.addWidget(self.lbl_mini)

        def toggle_collapse(self):
            self.is_collapsed = not self.is_collapsed
            self.btn_col.setText("▾" if self.is_collapsed else "▴")
            self.details_box.setVisible(not self.is_collapsed)
            self.lbl_mini.setVisible(self.is_collapsed)
            self.parent_widget.fit_to_content()

        def update_data(self, snap):
            self.data = snap
            status = snap.get("status")
            if status == "needsLogin":
                self.lbl_status.setText("offline")
                self.lbl_status.setStyleSheet("color: #f59e0b; font-size: 9.5px; background: transparent;")
                self.lbl_pct.setText("Sign in")
                self.lbl_reset.setText("")
                self.pbar.setValue(0)
                self.lbl_left.setText("")
                self.lbl_ago.setText("")
                self.lbl_mini.setText("Offline (Sign in)")
            elif status == "error":
                self.lbl_status.setText("error")
                self.lbl_status.setStyleSheet("color: #ef4444; font-size: 9.5px; background: transparent;")
                self.lbl_pct.setText("Refresh failed")
                self.lbl_reset.setText(snap.get("error", ""))
                self.lbl_mini.setText("Error")
            elif status == "loading":
                self.lbl_status.setText("…")
                self.lbl_pct.setText("Loading…")
                self.lbl_mini.setText("Loading…")
            else:
                self.lbl_status.setText("")
                weekly = snap.get("weekly", 0)
                reset = snap.get("reset")
                fetched_at = snap.get("fetched_at", int(time.time() * 1000))
                left = max(0, 100 - weekly)

                self.lbl_pct.setText(f"{weekly:.1f}% used")
                self.pbar.setValue(min(100, max(0, int(weekly))))

                r_str = remaining_str(reset)
                self.lbl_reset.setText(f"Resets in {r_str}" if r_str else "")

                self.lbl_left.setText(f"weekly {left:.1f}% left" if left > 0.05 else "weekly 0% left")
                self.lbl_ago.setText(ago_str(fetched_at))

                self.lbl_mini.setText(f"{weekly:.1f}% used · {ago_str(fetched_at)}")

        def open_login(self):
            self.parent_widget.show_login_dialog(self.service_id)


    class SettingsCard(QtWidgets.QFrame):
        """In-place translucent Settings view (no extra OS window frame)."""
        def __init__(self, parent_widget):
            super().__init__()
            self.parent_widget = parent_widget
            self.setObjectName("SettingsCard")
            self.setStyleSheet("""
                #SettingsCard {
                    background-color: rgba(28, 28, 38, 0.75);
                    border: 1px solid rgba(255, 255, 255, 0.10);
                    border-radius: 9px;
                    padding: 8px;
                }
            """)
            self.checks = {}
            self.policy_btns = {}
            self.setup_ui()

        def setup_ui(self):
            lay = QtWidgets.QVBoxLayout(self)
            lay.setContentsMargins(6, 6, 6, 6)
            lay.setSpacing(6)

            # Title
            t = QtWidgets.QLabel("Widget Settings")
            t.setStyleSheet("font-size: 11.5px; font-weight: bold; color: #ffffff; background: transparent;")
            lay.addWidget(t)

            sub = QtWidgets.QLabel("Toggle cards:")
            sub.setStyleSheet("font-size: 9.5px; color: #9ca3af; background: transparent;")
            lay.addWidget(sub)

            # Services Checklist
            state = self.parent_widget.state
            enabled = set(state.get("enabled", DEFAULT_ENABLED))
            for s in SERVICES:
                row = QtWidgets.QHBoxLayout()
                row.setContentsMargins(0, 0, 0, 0)
                # Note: replace & with && so Qt doesn't turn it into a mnemonic underscore
                title_clean = s["title"].replace("&", "&&")
                cb = QtWidgets.QCheckBox(title_clean)
                cb.setChecked(s["id"] in enabled)
                cb.setStyleSheet("QCheckBox { color: #d1d5db; font-size: 10.5px; background: transparent; }")
                self.checks[s["id"]] = cb
                row.addWidget(cb)

                row.addStretch()

                btn_log = QtWidgets.QPushButton("👤")
                btn_log.setFixedSize(16, 16)
                btn_log.setStyleSheet("QPushButton { background: transparent; color: #9ca3af; border: none; font-size: 10px; } QPushButton:hover { color: #fff; }")
                btn_log.clicked.connect(lambda _, sid=s["id"]: self.parent_widget.show_login_dialog(sid))
                row.addWidget(btn_log)

                lay.addLayout(row)

            # Updates Section
            up_lbl = QtWidgets.QLabel("Updates (GitHub)")
            up_lbl.setStyleSheet("font-size: 10px; font-weight: bold; color: #e2e8f0; margin-top: 6px; background: transparent;")
            lay.addWidget(up_lbl)

            u_row = QtWidgets.QHBoxLayout()
            u_row.setContentsMargins(0, 0, 0, 0)
            u_row.setSpacing(4)

            current_pol = state.get("updatePolicy", "prompt")
            for pol in ["off", "prompt", "auto"]:
                btn = QtWidgets.QPushButton(pol.capitalize())
                btn.setFixedHeight(22)
                btn.clicked.connect(lambda _, p=pol: self.set_policy(p))
                self.policy_btns[pol] = btn
                u_row.addWidget(btn)

            btn_check = QtWidgets.QPushButton("↻")
            btn_check.setFixedSize(22, 22)
            btn_check.setToolTip("Check for updates now")
            btn_check.setStyleSheet("QPushButton { background: rgba(255,255,255,0.08); color: #e2e8f0; border: 1px solid rgba(255,255,255,0.12); border-radius: 4px; font-size: 11px; } QPushButton:hover { background: rgba(255,255,255,0.16); }")
            btn_check.clicked.connect(self.check_now)
            u_row.addWidget(btn_check)
            lay.addLayout(u_row)
            self.update_policy_ui()

            # Status / Update feedback
            self.lbl_update_status = QtWidgets.QLabel("")
            self.lbl_update_status.setStyleSheet("font-size: 9px; color: #a5b4fc; background: transparent;")
            lay.addWidget(self.lbl_update_status)

            # Donate Button
            btn_donate = QtWidgets.QPushButton("💖 Donate")
            btn_donate.setFixedHeight(24)
            btn_donate.setStyleSheet("""
                QPushButton {
                    background: rgba(255, 255, 255, 0.06);
                    color: #f43f5e;
                    border: 1px solid rgba(244, 63, 94, 0.25);
                    border-radius: 5px;
                    font-size: 10.5px;
                    font-weight: 500;
                }
                QPushButton:hover { background: rgba(244, 63, 94, 0.15); }
            """)
            btn_donate.clicked.connect(lambda: webbrowser.open(DONATE_URL))
            lay.addWidget(btn_donate)

            # Footer
            foot = QtWidgets.QHBoxLayout()
            foot.setContentsMargins(0, 4, 0, 0)
            lbl_ver = QtWidgets.QLabel(f"v{APP_VERSION} (Track B Qt)")
            lbl_ver.setStyleSheet("font-size: 9px; color: #64748b; background: transparent;")
            foot.addWidget(lbl_ver)
            foot.addStretch()

            btn_done = QtWidgets.QPushButton("Done")
            btn_done.setFixedSize(48, 22)
            btn_done.setStyleSheet("""
                QPushButton {
                    background: #6366f1;
                    color: #ffffff;
                    border: none;
                    border-radius: 5px;
                    font-size: 10px;
                    font-weight: bold;
                }
                QPushButton:hover { background: #4f46e5; }
            """)
            btn_done.clicked.connect(self.save_and_close)
            foot.addWidget(btn_done)
            lay.addLayout(foot)

        def set_policy(self, pol):
            self.parent_widget.state["updatePolicy"] = pol
            self.parent_widget.save_state()
            self.update_policy_ui()

        def update_policy_ui(self):
            cur = self.parent_widget.state.get("updatePolicy", "prompt")
            for pol, btn in self.policy_btns.items():
                if pol == cur:
                    btn.setStyleSheet("QPushButton { background: #6366f1; color: #ffffff; border: none; border-radius: 4px; font-size: 10px; font-weight: bold; }")
                else:
                    btn.setStyleSheet("QPushButton { background: rgba(255,255,255,0.06); color: #94a3b8; border: 1px solid rgba(255,255,255,0.08); border-radius: 4px; font-size: 10px; } QPushButton:hover { background: rgba(255,255,255,0.12); color: #fff; }")

        def check_now(self):
            self.lbl_update_status.setText("Checking GitHub...")
            def worker():
                latest = fetch_latest_update()
                if latest and latest.get("version"):
                    ver = latest["version"]
                    if cmp_ver(ver, APP_VERSION) > 0:
                        self.parent_widget.update_signal.emit({"type": "status", "msg": f"Update {ver} available! (Click to open)", "url": latest.get("html_url", RELEASES_URL)})
                    else:
                        self.parent_widget.update_signal.emit({"type": "status", "msg": f"Up to date (v{APP_VERSION})", "url": None})
                else:
                    self.parent_widget.update_signal.emit({"type": "status", "msg": "Could not check updates", "url": None})
            threading.Thread(target=worker, daemon=True).start()

        def save_and_close(self):
            enabled = [sid for sid, cb in self.checks.items() if cb.isChecked()]
            self.parent_widget.state["enabled"] = enabled
            self.parent_widget.save_state()
            self.parent_widget.toggle_settings()

    class LoginDialog(QtWidgets.QDialog):
        def __init__(self, service_id, parent=None):
            super().__init__(parent)
            self.service_id = service_id
            self.svc = next((s for s in SERVICES if s["id"] == service_id), None)
            self.setWindowTitle(f"Sign in — {self.svc['title'] if self.svc else ''}")
            self.setFixedSize(270, 220)
            self.setWindowFlags(Qt.Dialog | Qt.FramelessWindowHint)
            self.setAttribute(Qt.WA_TranslucentBackground)
            self.setStyleSheet("""
                QDialog {
                    background-color: rgba(18, 18, 24, 0.95);
                    border: 1px solid rgba(255, 255, 255, 0.15);
                    border-radius: 12px;
                    color: #ffffff;
                }
                QLabel { color: #f3f4f6; font-size: 11px; background: transparent; }
                QLineEdit {
                    background-color: rgba(255, 255, 255, 0.08);
                    color: #ffffff;
                    border: 1px solid rgba(255, 255, 255, 0.15);
                    border-radius: 6px;
                    padding: 6px;
                    font-size: 10px;
                }
                QPushButton {
                    background-color: rgba(255, 255, 255, 0.08);
                    color: #ffffff;
                    border: 1px solid rgba(255, 255, 255, 0.12);
                    border-radius: 6px;
                    padding: 5px 8px;
                    font-size: 11px;
                }
                QPushButton:hover { background-color: rgba(255, 255, 255, 0.15); }
            """)
            self.init_ui()

        def init_ui(self):
            lay = QtWidgets.QVBoxLayout(self)
            lay.setContentsMargins(14, 14, 14, 14)
            lay.setSpacing(8)

            hdr = QtWidgets.QHBoxLayout()
            t = QtWidgets.QLabel(f"Sign in — {self.svc['title'] if self.svc else ''}")
            t.setStyleSheet("font-size: 12px; font-weight: bold;")
            hdr.addWidget(t)
            hdr.addStretch()

            btn_x = QtWidgets.QPushButton("✕")
            btn_x.setFixedSize(18, 18)
            btn_x.setStyleSheet("QPushButton { border: none; background: transparent; color: #9ca3af; font-size: 11px; } QPushButton:hover { color: #ef4444; }")
            btn_x.clicked.connect(self.reject)
            hdr.addWidget(btn_x)
            lay.addLayout(hdr)

            desc = QtWidgets.QLabel("1. Log in via your system browser:\n2. Paste session cookie or token below:")
            desc.setStyleSheet("color: #9ca3af; font-size: 10px;")
            lay.addWidget(desc)

            btn_open = QtWidgets.QPushButton("🌐 Open in System Browser")
            if self.svc:
                btn_open.clicked.connect(lambda: webbrowser.open(self.svc["login_url"]))
            lay.addWidget(btn_open)

            self.inp = QtWidgets.QLineEdit()
            self.inp.setPlaceholderText("Paste token / cookie header here...")
            lay.addWidget(self.inp)

            lay.addStretch()

            btn_save = QtWidgets.QPushButton("Save && Refresh")
            btn_save.setStyleSheet("background-color: #6366f1; font-weight: bold; border: none;")
            btn_save.clicked.connect(self.accept)
            lay.addWidget(btn_save)


    class BigUwidgetWindow(QtWidgets.QWidget):
        data_signal = Signal(dict)
        update_signal = Signal(dict)

        def __init__(self):
            super().__init__()
            self.drag_position = QPoint()
            self.cards = {}
            self.show_settings = False
            self.state = self.load_state()

            self.init_window_flags()
            self.init_ui()
            self.data_signal.connect(self.on_data_received)
            self.update_signal.connect(self.on_update_event)

            # Center window on first run if no bounds saved
            self.position_window()

            # Refresh ticker
            self.timer = QTimer(self)
            self.timer.timeout.connect(self.fetch_all_async)
            self.timer.start(60000) # 60s poll

            # Relative time ticker
            self.time_timer = QTimer(self)
            self.time_timer.timeout.connect(self.update_relative_times)
            self.time_timer.start(30000)

            # Initial fetch & update check
            QTimer.singleShot(100, self.fetch_all_async)
            QTimer.singleShot(3000, self.check_updates_startup)

        def init_window_flags(self):
            self.setWindowFlags(
                Qt.FramelessWindowHint
                | Qt.WindowStaysOnTopHint
                | Qt.Tool
            )
            self.setAttribute(Qt.WA_TranslucentBackground)
            self.setFixedWidth(236)

        def init_ui(self):
            self.main_layout = QtWidgets.QVBoxLayout(self)
            self.main_layout.setContentsMargins(6, 6, 6, 6)
            self.main_layout.setSpacing(0)

            # Translucent glass root frame
            self.root_frame = QtWidgets.QFrame()
            self.root_frame.setObjectName("RootFrame")
            self.root_frame.setStyleSheet("""
                #RootFrame {
                    background-color: rgba(16, 16, 22, 0.72);
                    border: 1px solid rgba(255, 255, 255, 0.12);
                    border-radius: 12px;
                }
            """)
            self.card_layout = QtWidgets.QVBoxLayout(self.root_frame)
            self.card_layout.setContentsMargins(6, 6, 6, 6)
            self.card_layout.setSpacing(2)

            # Header Control Bar
            hdr = QtWidgets.QHBoxLayout()
            hdr.setContentsMargins(4, 2, 4, 4)
            lbl_logo = QtWidgets.QLabel("BigUwidget")
            lbl_logo.setStyleSheet("font-size: 11px; font-weight: bold; color: #a5b4fc; background: transparent;")
            hdr.addWidget(lbl_logo)
            hdr.addStretch()

            btn_refresh = QtWidgets.QPushButton("↻")
            btn_refresh.setFixedSize(16, 16)
            btn_refresh.setStyleSheet("QPushButton { background: transparent; color: #9ca3af; border: none; font-size: 11px; } QPushButton:hover { color: #fff; }")
            btn_refresh.clicked.connect(self.fetch_all_async)
            hdr.addWidget(btn_refresh)

            btn_settings = QtWidgets.QPushButton("⚙")
            btn_settings.setFixedSize(16, 16)
            btn_settings.setStyleSheet("QPushButton { background: transparent; color: #9ca3af; border: none; font-size: 10px; } QPushButton:hover { color: #fff; }")
            btn_settings.clicked.connect(self.toggle_settings)
            hdr.addWidget(btn_settings)

            btn_quit = QtWidgets.QPushButton("✕")
            btn_quit.setFixedSize(16, 16)
            btn_quit.setStyleSheet("QPushButton { background: transparent; color: #9ca3af; border: none; font-size: 9px; } QPushButton:hover { color: #ef4444; }")
            btn_quit.clicked.connect(QtWidgets.QApplication.instance().quit)
            hdr.addWidget(btn_quit)

            self.card_layout.addLayout(hdr)

            # Optional Update Banner Card (hidden by default)
            self.update_card = QtWidgets.QFrame()
            self.update_card.setObjectName("UpdateCard")
            self.update_card.setStyleSheet("""
                #UpdateCard {
                    background-color: rgba(99, 102, 241, 0.25);
                    border: 1px solid rgba(99, 102, 241, 0.45);
                    border-radius: 8px;
                    margin-bottom: 4px;
                    padding: 4px 6px;
                }
            """)
            u_lay = QtWidgets.QHBoxLayout(self.update_card)
            u_lay.setContentsMargins(4, 2, 4, 2)
            self.lbl_update_banner = QtWidgets.QLabel("Update available")
            self.lbl_update_banner.setStyleSheet("font-size: 9.5px; color: #ffffff; background: transparent;")
            u_lay.addWidget(self.lbl_update_banner)
            u_lay.addStretch()
            self.btn_update_link = QtWidgets.QPushButton("Download ↗")
            self.btn_update_link.setStyleSheet("QPushButton { background: #6366f1; color: #fff; border: none; border-radius: 4px; font-size: 9px; padding: 2px 6px; font-weight: bold; } QPushButton:hover { background: #4f46e5; }")
            u_lay.addWidget(self.btn_update_link)
            self.update_card.setVisible(False)
            self.card_layout.addWidget(self.update_card)

            # In-place Settings Card (hidden by default)
            self.settings_card = SettingsCard(self)
            self.settings_card.setVisible(False)
            self.card_layout.addWidget(self.settings_card)

            # Add Service Cards
            enabled = set(self.state.get("enabled", DEFAULT_ENABLED))
            for s in SERVICES:
                card = ServiceCard(s["id"], s["title"], s["sub"], self)
                card.setVisible(s["id"] in enabled)
                self.cards[s["id"]] = card
                self.card_layout.addWidget(card)

            self.main_layout.addWidget(self.root_frame)
            self.fit_to_content()

        def position_window(self):
            bounds = self.state.get("bounds")
            screen = QtGui.QGuiApplication.primaryScreen()
            if not screen:
                return
            geom = screen.availableGeometry()

            w = 236
            h = self.sizeHint().height()

            if bounds and "x" in bounds and "y" in bounds:
                x = bounds["x"]
                y = bounds["y"]
                if 0 <= x < geom.width() - 50 and 0 <= y < geom.height() - 50:
                    self.move(x, y)
                    return

            # Center position
            x = geom.x() + (geom.width() - w) // 2
            y = geom.y() + (geom.height() - h) // 2
            self.move(x, y)

        def fit_to_content(self):
            self.adjustSize()
            self.setFixedHeight(self.sizeHint().height())

        def mousePressEvent(self, event):
            if event.button() == Qt.LeftButton:
                self.drag_position = event.globalPosition().toPoint() - self.frameGeometry().topLeft()
                event.accept()

        def mouseMoveEvent(self, event):
            if event.buttons() == Qt.LeftButton and not self.drag_position.isNull():
                self.move(event.globalPosition().toPoint() - self.drag_position)
                event.accept()

        def mouseReleaseEvent(self, event):
            self.drag_position = QPoint()
            # Save position
            b = {"x": self.x(), "y": self.y()}
            self.state["bounds"] = b
            self.save_state()

        def load_state(self):
            CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            if STATE_FILE.is_file():
                try:
                    return json.loads(STATE_FILE.read_text("utf-8"))
                except Exception:
                    pass
            return {"enabled": DEFAULT_ENABLED, "bounds": None, "tokens": {}, "updatePolicy": "prompt"}

        def save_state(self):
            try:
                STATE_FILE.write_text(json.dumps(self.state, indent=2), "utf-8")
            except Exception:
                pass

        def toggle_settings(self):
            self.show_settings = not self.show_settings
            self.settings_card.setVisible(self.show_settings)
            enabled = set(self.state.get("enabled", DEFAULT_ENABLED))
            for sid, card in self.cards.items():
                card.setVisible(not self.show_settings and sid in enabled)
            self.fit_to_content()
            if not self.show_settings:
                self.fetch_all_async()

        def show_login_dialog(self, service_id):
            dlg = LoginDialog(service_id, self)
            if dlg.exec():
                val = dlg.inp.text().strip()
                if val:
                    if "tokens" not in self.state:
                        self.state["tokens"] = {}
                    self.state["tokens"][service_id] = val
                    self.save_state()
                    self.fetch_all_async()

        def check_updates_startup(self):
            pol = self.state.get("updatePolicy", "prompt")
            if pol == "off":
                return
            def worker():
                latest = fetch_latest_update()
                if latest and latest.get("version"):
                    if cmp_ver(latest["version"], APP_VERSION) > 0:
                        self.update_signal.emit({
                            "type": "banner",
                            "version": latest["version"],
                            "url": latest.get("html_url", RELEASES_URL),
                        })
            threading.Thread(target=worker, daemon=True).start()

        def on_update_event(self, data):
            if data.get("type") == "status":
                msg = data.get("msg", "")
                url = data.get("url")
                self.settings_card.lbl_update_status.setText(msg)
                if url:
                    try:
                        self.settings_card.lbl_update_status.mousePressEvent = lambda _: webbrowser.open(url)
                        self.settings_card.lbl_update_status.setStyleSheet("font-size: 9px; color: #818cf8; text-decoration: underline; cursor: pointer; background: transparent;")
                    except Exception:
                        pass
            elif data.get("type") == "banner":
                ver = data.get("version")
                url = data.get("url", RELEASES_URL)
                self.lbl_update_banner.setText(f"Update v{ver} available!")
                try:
                    self.btn_update_link.clicked.disconnect()
                except Exception:
                    pass
                self.btn_update_link.clicked.connect(lambda: webbrowser.open(url))
                self.update_card.setVisible(True)
                self.fit_to_content()

        def fetch_all_async(self):
            tokens = self.state.get("tokens", {})
            enabled = set(self.state.get("enabled", DEFAULT_ENABLED))

            def worker():
                results = {}
                # AGY & Claude/GPT
                if "agy" in enabled or "claudeGPT" in enabled:
                    saved = tokens.get("agy")
                    res = fetch_agy(saved)
                    if res.get("ok"):
                        now = int(time.time() * 1000)
                        if "agy" in enabled:
                            results["agy"] = {
                                "status": "ready",
                                "weekly": res["gemini"]["weekly"],
                                "reset": res["gemini"]["reset"],
                                "fetched_at": now,
                            }
                        if "claudeGPT" in enabled:
                            results["claudeGPT"] = {
                                "status": "ready",
                                "weekly": res["claude"]["weekly"],
                                "reset": res["claude"]["reset"],
                                "fetched_at": now,
                            }
                    elif res.get("need_login"):
                        if "agy" in enabled: results["agy"] = {"status": "needsLogin"}
                        if "claudeGPT" in enabled: results["claudeGPT"] = {"status": "needsLogin"}
                    else:
                        err = res.get("error", "Error")
                        if "agy" in enabled: results["agy"] = {"status": "error", "error": err}
                        if "claudeGPT" in enabled: results["claudeGPT"] = {"status": "error", "error": err}

                # Grok
                if "grok" in enabled:
                    res = fetch_grok(tokens.get("grok"))
                    if res.get("ok"):
                        results["grok"] = {
                            "status": "ready",
                            "weekly": res["weekly"],
                            "reset": res.get("reset"),
                            "fetched_at": int(time.time() * 1000),
                        }
                    elif res.get("need_login"):
                        results["grok"] = {"status": "needsLogin"}
                    else:
                        results["grok"] = {"status": "error", "error": res.get("error", "Error")}

                # Grok Bot (Cursor)
                if "grokBot" in enabled:
                    res = fetch_grok_bot(tokens.get("grokBot"))
                    if res.get("ok"):
                        results["grokBot"] = {
                            "status": "ready",
                            "weekly": res["weekly"],
                            "reset": res.get("reset"),
                            "fetched_at": int(time.time() * 1000),
                        }
                    elif res.get("need_login"):
                        results["grokBot"] = {"status": "needsLogin"}
                    else:
                        results["grokBot"] = {"status": "error", "error": res.get("error", "Error")}

                # ChatGPT
                if "chatGPT" in enabled:
                    res = fetch_chatgpt(tokens.get("chatGPT"))
                    if res.get("ok"):
                        results["chatGPT"] = {
                            "status": "ready",
                            "weekly": res["weekly"],
                            "reset": res.get("reset"),
                            "fetched_at": int(time.time() * 1000),
                        }
                    elif res.get("need_login"):
                        results["chatGPT"] = {"status": "needsLogin"}
                    else:
                        results["chatGPT"] = {"status": "error", "error": res.get("error", "Error")}

                self.data_signal.emit(results)

            threading.Thread(target=worker, daemon=True).start()

        def on_data_received(self, results):
            for sid, snap in results.items():
                if sid in self.cards:
                    self.cards[sid].update_data(snap)
            self.fit_to_content()

        def update_relative_times(self):
            for card in self.cards.values():
                if card.isVisible() and card.data.get("status") == "ready":
                    ts = card.data.get("fetched_at")
                    if ts:
                        card.lbl_ago.setText(ago_str(ts))

# ----------------- Main Entrypoint -----------------

def main():
    if not QT_LIB:
        print("[-] PySide6, PyQt6, or PyQt5 is required for Track B native meter.")
        print("[+] Install with: pip install PySide6")
        print("[+] Or on Debian/Ubuntu: sudo apt install python3-pyside6")
        sys.exit(1)

    app = QtWidgets.QApplication(sys.argv)
    app.setApplicationName("BigUwidget")
    app.setApplicationVersion(APP_VERSION)

    # Clean dark font style
    font = QtGui.QFont("Inter", 10)
    font.setStyleHint(QtGui.QFont.SansSerif)
    app.setFont(font)

    win = BigUwidgetWindow()
    win.show()
    sys.exit(app.exec())

if __name__ == "__main__":
    main()
