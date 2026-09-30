"""
VulnShop — a deliberately vulnerable Flask web app for learning
OWASP Top 10:2025.

*** DO NOT DEPLOY THIS ANYWHERE PUBLIC. LOCAL / ISOLATED LAB USE ONLY. ***

Every vulnerability below is tagged with a comment like:
    # [A05:2025-Injection] SQL Injection
so you can grep the file for a category, e.g.:
    grep -n "A05:2025" app.py

See README.md for the full exploitation + remediation walkthrough
for each tagged vulnerability.
"""

import os
import sqlite3
import hashlib
import pickle
import base64
import subprocess
import secrets

from flask import (
    Flask, request, render_template, redirect, url_for,
    session, g, make_response
)

# ----------------------------------------------------------------------
# [A02:2025-Security Misconfiguration] Debug mode enabled, hardcoded
# secret key committed to source control, verbose errors left on.
# ----------------------------------------------------------------------
app = Flask(__name__)
app.config["DEBUG"] = True                      # Werkzeug debugger reachable + RCE via console
app.secret_key = "dev-secret-key-12345"          # hardcoded, guessable, reused everywhere

DB_PATH = os.path.join(os.path.dirname(__file__), "vulnshop.db")
UPLOAD_DIR = os.path.join(os.path.dirname(__file__), "uploads")


# ----------------------------------------------------------------------
# DB helpers
# ----------------------------------------------------------------------
def get_db():
    if "db" not in g:
        g.db = sqlite3.connect(DB_PATH)
        g.db.row_factory = sqlite3.Row
    return g.db


@app.teardown_appcontext
def close_db(exc):
    db = g.pop("db", None)
    if db is not None:
        db.close()


def init_db():
    db = sqlite3.connect(DB_PATH)
    db.executescript(
        """
        DROP TABLE IF EXISTS users;
        DROP TABLE IF EXISTS notes;
        DROP TABLE IF EXISTS logins;

        CREATE TABLE users (
            id INTEGER PRIMARY KEY,
            username TEXT UNIQUE,
            password TEXT,          -- [A04:2025-Cryptographic Failures] MD5, no salt
            is_admin INTEGER DEFAULT 0,
            reset_token TEXT
        );

        CREATE TABLE notes (
            id INTEGER PRIMARY KEY,
            user_id INTEGER,
            content TEXT            -- stores raw HTML -> stored XSS sink
        );

        -- [A09:2025-Security Logging & Alerting Failures]
        -- table exists but the app never writes failed-login attempts to it,
        -- and nothing ever alerts on its contents.
        CREATE TABLE logins (
            id INTEGER PRIMARY KEY,
            username TEXT,
            success INTEGER,
            ts TEXT
        );
        """
    )

    # [A04:2025-Cryptographic Failures] MD5 password hashing, no salt/pepper
    def md5(p):
        return hashlib.md5(p.encode()).hexdigest()

    db.execute(
        "INSERT INTO users (username, password, is_admin, reset_token) VALUES (?,?,?,?)",
        ("admin", md5("admin123"), 1, "tok-00001"),
    )
    db.execute(
        "INSERT INTO users (username, password, is_admin, reset_token) VALUES (?,?,?,?)",
        ("alice", md5("alicepw"), 0, "tok-00002"),
    )
    db.execute(
        "INSERT INTO users (username, password, is_admin, reset_token) VALUES (?,?,?,?)",
        ("bob", md5("bobpw"), 0, "tok-00003"),
    )
    db.execute("INSERT INTO notes (user_id, content) VALUES (2, 'Welcome to my notes, Alice!')")
    db.commit()
    db.close()


# ----------------------------------------------------------------------
# Home / login
# ----------------------------------------------------------------------
@app.route("/")
def index():
    return render_template("index.html", user=session.get("username"))


@app.route("/login", methods=["GET", "POST"])
def login():
    error = None
    if request.method == "POST":
        username = request.form.get("username", "")
        password = request.form.get("password", "")

        # ------------------------------------------------------------
        # [A05:2025-Injection] Classic SQL Injection: raw string
        # concatenation into a query instead of parameter binding.
        # Try:  username = admin' -- 
        # ------------------------------------------------------------
        query = "SELECT * FROM users WHERE username = '%s' AND password = '%s'" % (
            username,
            hashlib.md5(password.encode()).hexdigest(),
        )
        db = get_db()
        cur = db.execute(query)
        row = cur.fetchone()

        # [A09:2025] failed/successful logins are never recorded anywhere.
        # [A06:2025-Insecure Design] no rate limiting / lockout on this
        # endpoint -> unlimited password guessing is possible.

        if row:
            session["username"] = row["username"]
            session["user_id"] = row["id"]
            session["is_admin"] = bool(row["is_admin"])
            return redirect(url_for("index"))
        else:
            error = "Invalid credentials"
    return render_template("login.html", error=error)


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("index"))


# ----------------------------------------------------------------------
# [A01:2025-Broken Access Control] IDOR — any logged-in user can view
# any other user's profile by changing ?id=, no ownership check.
# ----------------------------------------------------------------------
@app.route("/profile")
def profile():
    user_id = request.args.get("id", session.get("user_id"))
    db = get_db()
    row = db.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
    if row is None:
        return "No such user", 404
    return render_template("profile.html", profile=row)


# ----------------------------------------------------------------------
# [A01:2025-Broken Access Control] Missing function-level access control.
# /admin only *hides* the link for non-admins in the UI — the route
# itself never checks session["is_admin"], so any authenticated (or
# even unauthenticated, since session is never actually enforced here)
# user can reach it directly.
# ----------------------------------------------------------------------
@app.route("/admin")
def admin():
    db = get_db()
    users = db.execute("SELECT id, username, is_admin FROM users").fetchall()
    return render_template("admin.html", users=users)


# ----------------------------------------------------------------------
# [A01:2025-Broken Access Control] SSRF (now folded into Broken Access
# Control in the 2025 list). The server fetches an arbitrary
# user-supplied URL server-side with no allow-list, so it can be used
# to reach internal-only services (e.g. cloud metadata endpoints).
# ----------------------------------------------------------------------
@app.route("/fetch-avatar", methods=["GET", "POST"])
def fetch_avatar():
    result = None
    if request.method == "POST":
        import urllib.request
        url = request.form.get("url", "")
        try:
            with urllib.request.urlopen(url, timeout=3) as resp:
                result = resp.read(500).decode(errors="replace")
        except Exception as e:
            result = f"Error: {e}"
    return render_template("fetch_avatar.html", result=result)


# ----------------------------------------------------------------------
# [A05:2025-Injection] Reflected XSS — user input echoed back with
# |safe, so <script> executes in the victim's browser.
# ----------------------------------------------------------------------
@app.route("/search")
def search():
    q = request.args.get("q", "")
    return render_template("search.html", q=q)


# ----------------------------------------------------------------------
# [A05:2025-Injection] Stored XSS — note content is saved and rendered
# with |safe on every visitor's page, no sanitization/encoding.
# ----------------------------------------------------------------------
@app.route("/notes", methods=["GET", "POST"])
def notes():
    db = get_db()
    if request.method == "POST":
        content = request.form.get("content", "")
        uid = session.get("user_id", 2)
        db.execute("INSERT INTO notes (user_id, content) VALUES (?, ?)", (uid, content))
        db.commit()
    rows = db.execute("SELECT * FROM notes").fetchall()
    return render_template("notes.html", notes=rows)


# ----------------------------------------------------------------------
# [A05:2025-Injection] OS Command Injection via unsanitized input
# passed to a shell.
# ----------------------------------------------------------------------
@app.route("/ping", methods=["GET", "POST"])
def ping():
    output = None
    if request.method == "POST":
        host = request.form.get("host", "")
        cmd = f"ping -c 1 {host}"          # shell=True + string concat = command injection
        try:
            output = subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT, timeout=5).decode()
        except Exception as e:
            output = str(e)
    return render_template("ping.html", output=output)


# ----------------------------------------------------------------------
# [A08:2025-Software or Data Integrity Failures] Insecure deserialization.
# A base64-encoded pickle from a cookie is unpickled with no integrity
# check (no HMAC/signature) -> arbitrary code execution on unpickle.
# ----------------------------------------------------------------------
@app.route("/set-theme", methods=["GET", "POST"])
def set_theme():
    if request.method == "POST":
        theme = request.form.get("theme", "light")
        blob = base64.b64encode(pickle.dumps({"theme": theme})).decode()
        resp = make_response(redirect(url_for("set_theme")))
        resp.set_cookie("theme_prefs", blob)
        return resp

    prefs = {"theme": "light"}
    raw = request.cookies.get("theme_prefs")
    if raw:
        try:
            prefs = pickle.loads(base64.b64decode(raw))   # <-- unsafe deserialization
        except Exception:
            pass
    return render_template("theme.html", prefs=prefs)


# ----------------------------------------------------------------------
# [A08:2025 / A02:2025] Unrestricted file upload — no type/size/content
# validation, files served back directly, path traversal not blocked.
# ----------------------------------------------------------------------
@app.route("/upload", methods=["GET", "POST"])
def upload():
    msg = None
    if request.method == "POST":
        f = request.files.get("file")
        if f and f.filename:
            # no extension allow-list, no filename sanitization
            dest = os.path.join(UPLOAD_DIR, f.filename)
            f.save(dest)
            msg = f"Uploaded to {dest}"
    return render_template("upload.html", msg=msg)


# ----------------------------------------------------------------------
# [A06:2025-Insecure Design] Predictable password-reset token
# (sequential, guessable — see init_db: tok-00001, tok-00002, ...)
# and the token is accepted from the URL with no expiry and no
# verification that the requester owns that account.
# ----------------------------------------------------------------------
@app.route("/reset", methods=["GET", "POST"])
def reset():
    msg = None
    if request.method == "POST":
        token = request.form.get("token", "")
        newpw = request.form.get("password", "")
        db = get_db()
        row = db.execute("SELECT * FROM users WHERE reset_token = ?", (token,)).fetchone()
        if row:
            db.execute(
                "UPDATE users SET password = ? WHERE id = ?",
                (hashlib.md5(newpw.encode()).hexdigest(), row["id"]),
            )
            db.commit()
            msg = f"Password for {row['username']} updated."
        else:
            msg = "Invalid token"
    return render_template("reset.html", msg=msg)


# ----------------------------------------------------------------------
# [A10:2025-Mishandling of Exceptional Conditions] Divide-by-zero /
# malformed input crashes into a raw traceback (Werkzeug debug
# console), leaking source code, local variables, and offering a
# remote Python shell because DEBUG=True.
# ----------------------------------------------------------------------
@app.route("/calc")
def calc():
    a = request.args.get("a", "10")
    b = request.args.get("b", "0")
    result = int(a) / int(b)   # no validation, no try/except -> unhandled exception
    return f"Result: {result}"


# ----------------------------------------------------------------------
# [A03:2025-Software Supply Chain Failures] see requirements.txt —
# dependencies are pinned to old versions with known CVEs on purpose.
# Nothing to exploit in this route; the point is demonstrated with
# `pip-audit` / `safety` / `npm audit`-style SCA tooling instead.
# ----------------------------------------------------------------------
@app.route("/about")
def about():
    return render_template("about.html")


if __name__ == "__main__":
    if not os.path.exists(DB_PATH):
        init_db()
    os.makedirs(UPLOAD_DIR, exist_ok=True)
    # [A02:2025] binds on 0.0.0.0 with debug=True by default in dev
    # runs — fine for an isolated lab VM, catastrophic on the open
    # internet.
    app.run(host="0.0.0.0", port=5000, debug=True)
