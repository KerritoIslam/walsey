#!/usr/bin/env python3
"""
moodle_test.py - read-only feasibility test suite for a Moodle site (default: ESI-SBA).

Nothing here submits, uploads, deletes or edits anything. Moodle still LOGS page views
(and may mark view-based activity completion), so visits are kept minimal and capped.

Commands (run in this order):
  public       no login: login-form structure, Moodle/theme/plugin hints, web-service probes
  login        VISIBLE browser: you log in manually; saves auth state locally (never printed)
  session      re-open the saved auth state / profile and check you are still logged in
  courses      discover enrolled courses (DOM + Moodle AJAX), optional category scan
  inspect      sections + activities of one course, resource URLs (no file bodies downloaded)
  assignments  assignment list + status pages of one course (read-only GETs)
  grades       structure of grade tables only (no grade values are stored)
  webservices  authenticated probes of web-service endpoints and read-only AJAX functions
  download     download ONE resource you name with --cmid (size-capped), verify sha256/metadata
  upload-form  OPT-IN: GET the "edit submission" page of ONE assignment, read form structure only
  all          public-less convenience: session + courses + inspect/assignments for N courses

Never stored/printed: passwords, cookie values, sesskey, tokens, auth headers.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from bs4 import BeautifulSoup
from playwright.sync_api import sync_playwright

# --------------------------------------------------------------------------- config
BASE = "https://elearn.esi-sba.dz"
OUT = Path("evidence")
AUTH_DIR = Path(".walsey_auth")          # holds secrets (cookies) -> git-ignored automatically
AUTH_STATE = AUTH_DIR / "storage_state.json"
PROFILE_DIR = AUTH_DIR / "chromium_profile"
CAP_FILE = Path("capabilities.json")
ARGS: argparse.Namespace

# Only these AJAX functions may ever be called through /lib/ajax/service.php (all read-only).
READ_ONLY_AJAX = {
    "core_course_get_enrolled_courses_by_timeline_classification",
    "core_course_get_recent_courses",
    "core_calendar_get_action_events_by_timesort",
    "tool_mobile_get_public_config",
}
# URLs the script refuses to open, whatever the command (defence in depth).
FORBIDDEN_URL = re.compile(
    r"(logout\.php|action=(submit|remove|savesubmission|lock|unlock|editsubmission)\b|"
    r"[?&]delete=|modedit\.php|course/edit\.php|enrol/.*(enrolme|unenrol)|"
    r"user/(edit|preferences)\.php|managetoken\.php|sesskey=)",
    re.I,
)
MASK_SEL = ".usermenu, .userpicture, .logininfo, input[type=password]"


# --------------------------------------------------------------------------- utilities
def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def log(event: str, **kw) -> None:
    rec = {"ts": now(), "event": event, **kw}
    OUT.mkdir(parents=True, exist_ok=True)
    with open(OUT / "test_log.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False, default=str) + "\n")
    flat = " ".join(f"{k}={v}" for k, v in kw.items() if not isinstance(v, (dict, list)))
    print(f"[{rec['ts'][11:19]}] {event} {flat}")


def scrub_url(u: str) -> str:
    return re.sub(r"(sesskey|token|wstoken|logintoken)=[^&#]+", r"\1=[REDACTED]", u or "")


def save_json(name: str, data, private: bool = False) -> Path:
    d = OUT / ("private" if private else "")
    d.mkdir(parents=True, exist_ok=True)
    p = d / name
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False, default=str), encoding="utf-8")
    return p


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def safe_name(s: str) -> str:
    return re.sub(r"[^\w.\- ]", "_", s)[:120] or "file"


# ---- capability registry: statuses = verified | partial | failed | not_tested | unknown | impossible
def load_caps() -> dict:
    if CAP_FILE.exists():
        return json.loads(CAP_FILE.read_text(encoding="utf-8"))
    return {}


CAPS: dict = {}


def cap(section: str, key: str, status: str, /, **notes) -> None:
    CAPS.setdefault(section, {})
    entry = {"status": status, "tested_at": now()}
    # a note called "status" (e.g. an HTTP status) must not overwrite the capability status
    entry.update({("http_status" if k == "status" else k): v for k, v in notes.items()})
    CAPS[section][key] = entry
    log("capability", section=section, key=key, status=status)


def flush_caps() -> None:
    CAPS.setdefault("platform", "Moodle")
    CAPS["last_run"] = now()
    CAP_FILE.write_text(json.dumps(CAPS, indent=2, ensure_ascii=False), encoding="utf-8")


# --------------------------------------------------------------------------- sanitising
EMAIL_RE = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")


def sanitize_html(html: str, names: list[str] | tuple = ()) -> str:
    soup = BeautifulSoup(html, "html.parser")
    for t in soup(["script", "noscript", "style"]):
        t.decompose()
    for sel in (".usermenu", ".logininfo", ".userpicture", "img.userpicture",
                "#intro", ".activity-description", "[data-region='activity-description']",
                ".fileuploadsubmission", ".submissioncomment", ".feedback", ".gradingform"):
        for el in soup.select(sel):
            n = len(el.get_text(strip=True))
            el.clear()
            el.string = f"[REDACTED {n} chars]"
    for inp in soup.find_all("input"):
        if inp.has_attr("value"):
            inp["value"] = "[REDACTED]"
    for img in soup.find_all("img"):
        if "/user/" in (img.get("src") or ""):
            img["src"] = "[REDACTED]"
    out = str(soup)
    out = re.sub(r"(sesskey|token)=[A-Za-z0-9]+", r"\1=[REDACTED]", out)
    out = re.sub(r"/user/(profile|view)\.php\?id=\d+", r"/user/\1.php?id=[REDACTED]", out)
    out = EMAIL_RE.sub("[EMAIL]", out)
    for n in sorted({x for x in names if x and len(x) >= 3}, key=len, reverse=True):
        out = re.sub(re.escape(n), "[NAME]", out, flags=re.I)
    return out


def page_user_names(page) -> list[str]:
    try:
        raw = page.evaluate(
            "() => [...document.querySelectorAll('.usermenu .usertext, .usermenu')]"
            ".map(e => e.innerText.trim()).filter(Boolean)")
    except Exception:
        return []
    names: list[str] = []
    for r in raw:
        names.append(r)
        names.extend(re.split(r"\s+", r))
    return names


def snapshot(page, name: str) -> None:
    """Sanitised HTML + masked screenshot. Screenshots can still show course content: review before sharing."""
    (OUT / "html").mkdir(parents=True, exist_ok=True)
    (OUT / "screenshots").mkdir(parents=True, exist_ok=True)
    try:
        html = sanitize_html(page.content(), page_user_names(page))
        (OUT / "html" / f"{name}.html").write_text(html, encoding="utf-8")
    except Exception as e:
        log("snapshot_html_failed", name=name, err=str(e)[:120])
    try:
        page.screenshot(path=str(OUT / "screenshots" / f"{name}.png"), full_page=True,
                        mask=[page.locator(MASK_SEL)])
    except Exception as e:
        log("snapshot_png_failed", name=name, err=str(e)[:120])


def goto(page, path_or_url: str, wait: str = "networkidle"):
    url = path_or_url if path_or_url.startswith("http") else BASE + path_or_url
    if FORBIDDEN_URL.search(url):
        raise RuntimeError(f"refusing forbidden URL: {scrub_url(url)}")
    resp = page.goto(url, wait_until=wait, timeout=60000)
    return resp


# --------------------------------------------------------------------------- browser/session
def is_logged_in(page) -> bool:
    return bool(page.evaluate(
        "() => !document.body.classList.contains('notloggedin') && "
        "!!document.querySelector('.usermenu, #user-menu-toggle, a[href*=\"logout.php\"]')"))


def moodle_cfg(page) -> dict:
    """Non-secret M.cfg values only (sesskey deliberately excluded)."""
    return page.evaluate(
        "() => (window.M && M.cfg) ? {wwwroot:M.cfg.wwwroot, theme:M.cfg.theme, language:M.cfg.language,"
        "sessiontimeout:M.cfg.sessiontimeout, slasharguments:M.cfg.slasharguments, themerev:M.cfg.themerev,"
        "jsrev:M.cfg.jsrev, hasSesskey: !!M.cfg.sesskey} : null") or {}


def cookie_report(ctx) -> list[dict]:
    rows = []
    for c in ctx.cookies():
        if "esi-sba.dz" not in c["domain"]:
            continue
        exp = c.get("expires", -1)
        rows.append({
            "name": c["name"], "domain": c["domain"], "path": c["path"],
            "httpOnly": c["httpOnly"], "secure": c["secure"], "sameSite": c.get("sameSite"),
            "session_cookie": exp in (-1, None),
            "expires_in_hours": None if exp in (-1, None) else round((exp - time.time()) / 3600, 1),
        })
    return rows


def write_auth_gitignore() -> None:
    AUTH_DIR.mkdir(exist_ok=True)
    (AUTH_DIR / ".gitignore").write_text("*\n", encoding="utf-8")


@contextlib.contextmanager
def authed(p, method: str = "state"):
    """Yield (ctx, page) logged in via saved storage_state ('state') or persistent profile ('profile')."""
    headless = not ARGS.headed
    if method == "state":
        if not AUTH_STATE.exists():
            sys.exit("No saved auth state. Run:  python moodle_test.py login")
        browser = p.chromium.launch(headless=headless)
        ctx = browser.new_context(storage_state=str(AUTH_STATE), locale="en-US", accept_downloads=True)
        closer = browser.close
    else:
        ctx = p.chromium.launch_persistent_context(str(PROFILE_DIR), headless=headless,
                                                   locale="en-US", accept_downloads=True)
        closer = ctx.close
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    try:
        goto(page, "/my/")
        if not is_logged_in(page):
            sys.exit("Session is not logged in (expired or not persisted). Run:  python moodle_test.py login")
        yield ctx, page
    finally:
        closer()


def ajax_read(page, method: str, args: dict) -> dict:
    """Call a whitelisted read-only Moodle AJAX function from inside the page (sesskey never leaves the page)."""
    if method not in READ_ONLY_AJAX:
        raise RuntimeError(f"AJAX method not whitelisted: {method}")
    js = """async ([method, args]) => {
      const sk = (window.M && M.cfg && M.cfg.sesskey) || null;
      if (!sk) return {noSesskey: true};
      const url = `${M.cfg.wwwroot}/lib/ajax/service.php?sesskey=${sk}&info=${method}`;
      const r = await fetch(url, {method:'POST', credentials:'same-origin',
        headers:{'Content-Type':'application/json'},
        body: JSON.stringify([{index:0, methodname: method, args}])});
      const text = await r.text(); let j = null;
      try { j = JSON.parse(text); } catch(e) {}
      return {status: r.status, json: j, snippet: j ? null : text.slice(0, 200)};
    }"""
    return page.evaluate(js, [method, args])


def ajax_summary(res: dict) -> dict:
    """Describe an AJAX result without leaking data."""
    if res.get("noSesskey"):
        return {"ok": False, "reason": "no sesskey on page"}
    j = res.get("json")
    if isinstance(j, list) and j and isinstance(j[0], dict):
        if j[0].get("error"):
            exc = j[0].get("exception") or {}
            return {"ok": False, "http": res.get("status"), "errorcode": exc.get("errorcode"),
                    "message": (exc.get("message") or "")[:160]}
        return {"ok": True, "http": res.get("status")}
    return {"ok": False, "http": res.get("status"), "snippet": (res.get("snippet") or "")[:160]}


# --------------------------------------------------------------------------- command: public
PLUGIN_RE = re.compile(
    r"/(theme|local|blocks?|mod|filter|auth|enrol|report|tool|repository|format|availability|qtype|editor)/([A-Za-z0-9_]+)/")
PLUGINFILE_RE = re.compile(r"pluginfile\.php/\d+/(theme|local|block|mod|filter|auth|enrol|tool|format)_([A-Za-z0-9]+)/")


def cmd_public(p):
    browser = p.chromium.launch(headless=not ARGS.headed)
    ctx = browser.new_context(locale="en-US")
    page = ctx.new_page()
    seen: list[str] = []
    page.on("request", lambda r: seen.append(r.url))
    result: dict = {}

    # front page
    goto(page, "/")
    snapshot(page, "public_frontpage")
    result["frontpage"] = {
        "title": page.title(), "cfg": moodle_cfg(page),
        "body_classes": page.evaluate("() => document.body.className"),
        "category_links": page.evaluate(
            "() => [...document.querySelectorAll('a[href*=\"course/index.php?categoryid=\"]')].length"),
    }

    # login page
    goto(page, "/login/index.php")
    snapshot(page, "public_login")
    form = page.evaluate("""() => {
      const f = document.querySelector('form#login, form[action*="login/index.php"]');
      const fields = f ? [...f.querySelectorAll('input,button,select')].map(e => ({
        tag: e.tagName.toLowerCase(), type: e.type || null, name: e.name || null, id: e.id || null,
        autocomplete: e.getAttribute('autocomplete')})) : [];
      return {
        formFound: !!f, action: f ? f.getAttribute('action') : null, method: f ? f.method : null,
        formId: f ? f.id : null, fields,
        captcha: !!document.querySelector('.g-recaptcha, [data-sitekey], .h-captcha, iframe[src*="recaptcha"], iframe[src*="hcaptcha"]'),
        guestLogin: !!document.querySelector('input[name="username"][value="guest"]'),
        idpButtons: [...document.querySelectorAll('.potentialidplist a, .potentialidp a')].map(a => a.textContent.trim()),
        signupLink: !!document.querySelector('a[href*="login/signup.php"]'),
        forgotLink: !!document.querySelector('a[href*="forgot_password.php"]'),
        cfg: (window.M && M.cfg) ? {theme: M.cfg.theme, sessiontimeout: M.cfg.sessiontimeout} : null
      };}""")
    result["login_form"] = form
    names = {f.get("name") for f in form.get("fields", [])}
    cap("authentication", "login_form_standard",
        "verified" if form["formFound"] and {"username", "password"} <= names else "failed",
        field_names=sorted(n for n in names if n), form_action=form.get("action"), form_method=form.get("method"))
    cap("authentication", "csrf_login_token_field", "verified" if "logintoken" in names else "not_found",
        note="hidden input named logintoken (Moodle >= 3.2 login CSRF token); value not recorded")
    cap("authentication", "captcha_on_login_page", "verified_absent" if not form["captcha"] else "present")
    cap("authentication", "guest_login_button", "verified" if form["guestLogin"] else "not_found")
    cap("authentication", "alternative_auth_buttons", "verified", buttons=form["idpButtons"])
    cap("authentication", "two_factor", "not_tested",
        note="2FA can only be observed after a real login; see 'login' command")

    # cookies set before login
    result["cookies_prelogin"] = cookie_report(ctx)
    cap("session", "cookie_attributes_prelogin", "verified", cookies=result["cookies_prelogin"])

    # plugin / theme hints from every URL the browser requested
    plugins = set()
    for u in seen:
        for m in PLUGIN_RE.finditer(u):
            plugins.add((m.group(1), m.group(2)))
        for m in PLUGINFILE_RE.finditer(u):
            plugins.add((m.group(1), m.group(2)))
    result["plugin_hints"] = sorted(f"{t}/{n}" for t, n in plugins)
    cap("architecture", "plugin_hints", "partial", hints=result["plugin_hints"],
        note="Heuristic from requested URLs; core vs third-party is not distinguished")

    # unauthenticated probes
    api = p.request.new_context(base_url=BASE)
    probes = {}
    for label, path in {
        "upgrade_txt": "/lib/upgrade.txt",
        "ws_rest_server": "/webservice/rest/server.php",
        "ws_site_info_no_token": "/webservice/rest/server.php?wsfunction=core_webservice_get_site_info&moodlewsrestformat=json",
        "login_token_no_credentials": "/login/token.php?service=moodle_mobile_app",
        "ws_documentation_anonymous": "/admin/webservice/documentation.php",
        "robots": "/robots.txt",
    }.items():
        try:
            r = api.get(path, max_redirects=0)
            body = r.text()[:4000]
            probes[label] = {"status": r.status, "content_type": r.headers.get("content-type"),
                             "location": scrub_url(r.headers.get("location", "")),
                             "snippet": EMAIL_RE.sub("[EMAIL]", re.sub(r"\s+", " ", body)[:240])}
            if label == "upgrade_txt" and r.status == 200:
                m = re.search(r"^===\s*([0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*===", body, re.M)
                probes[label]["top_heading_version"] = m.group(1) if m else None
        except Exception as e:
            probes[label] = {"error": str(e)[:160]}
    # public mobile config (no login, read-only) - reveals release + whether mobile WS is on
    try:
        r = api.post("/lib/ajax/service-nologin.php",
                     data=json.dumps([{"index": 0, "methodname": "tool_mobile_get_public_config", "args": {}}]),
                     headers={"Content-Type": "application/json"}, max_redirects=0)
        j = None
        with contextlib.suppress(Exception):
            j = r.json()
        d = (j[0].get("data") if isinstance(j, list) and j and isinstance(j[0], dict) else None) or {}
        probes["public_mobile_config"] = {
            "status": r.status, "error": bool(isinstance(j, list) and j and j[0].get("error")),
            "release": d.get("release"), "version": d.get("version"),
            "typeoflogin": d.get("typeoflogin"), "mobile_ws_hint": "data returned" if d else "no data"}
    except Exception as e:
        probes["public_mobile_config"] = {"error": str(e)[:160]}
    result["probes"] = probes
    rel = probes.get("public_mobile_config", {}).get("release")
    cap("architecture", "moodle_version",
        "verified" if rel else ("partial" if probes.get("upgrade_txt", {}).get("top_heading_version") else "unknown"),
        release=rel, upgrade_txt_top_heading=probes.get("upgrade_txt", {}).get("top_heading_version"))
    cap("web_services", "rest_endpoint_reachable", "partial", probe=probes.get("ws_rest_server"),
        note="Reachable != enabled for students; see 'webservices' command")
    save_json("public_probe.json", result)
    api.dispose()
    browser.close()


# --------------------------------------------------------------------------- command: login/session
def cmd_login(p):
    write_auth_gitignore()
    ctx = p.chromium.launch_persistent_context(str(PROFILE_DIR), headless=False, locale="en-US",
                                               accept_downloads=True)
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    goto(page, "/login/index.php")
    if not is_logged_in(page):
        print("\n>>> Log in MANUALLY in the browser window. Waiting up to "
              f"{ARGS.login_timeout}s. Credentials are never read by this script.\n")
        deadline = time.time() + ARGS.login_timeout
        while time.time() < deadline:
            try:
                if is_logged_in(page):
                    break
            except Exception:
                pass
            page.wait_for_timeout(1500)
        else:
            ctx.close()
            cap("authentication", "manual_login", "failed", note="timeout waiting for manual login")
            flush_caps()
            sys.exit("Timed out.")
    page.wait_for_load_state("networkidle")
    landing = urlparse(page.url).path
    cfg = moodle_cfg(page)
    cap("authentication", "manual_login", "verified", landing_path_after_login=landing)
    cap("authentication", "post_login_two_factor_or_extra_step", "partial",
        note="No extra step was needed during THIS manual login if you did not see one; confirm yourself")
    cap("session", "server_side_session_timeout_seconds", "partial", value=cfg.get("sessiontimeout"),
        note="M.cfg.sessiontimeout is the configured idle timeout exposed to JS; real expiry still needs the 'session' log")
    cookies = cookie_report(ctx)
    cap("session", "cookie_attributes_postlogin", "verified", cookies=cookies)
    snapshot(page, "post_login_landing")
    ctx.storage_state(path=str(AUTH_STATE))
    (OUT).mkdir(exist_ok=True)
    save_json("state.json", {"last_login_ts": now(), "landing_path": landing})
    ctx.close()
    log("login_done", landing=landing, state_saved=True)


def cmd_session(p):
    st = json.loads((OUT / "state.json").read_text()) if (OUT / "state.json").exists() else {}
    for method in (["state", "profile"] if ARGS.method == "both" else [ARGS.method]):
        try:
            with authed(p, method) as (ctx, page):
                cfg = moodle_cfg(page)
                rec = {"ts": now(), "method": method, "logged_in": True,
                       "since_login_ts": st.get("last_login_ts"), "cookies": cookie_report(ctx)}
                ok = True
        except SystemExit as e:
            rec = {"ts": now(), "method": method, "logged_in": False, "detail": str(e)[:100]}
            ok = False
        with open(OUT / "session_log.jsonl", "a", encoding="utf-8") as f:
            f.write(json.dumps(rec) + "\n")
        cap("session", f"survives_browser_restart_via_{method}", "verified" if ok else "failed",
            note="Each run is a new browser process; verified only for the elapsed time in session_log.jsonl")
    log("session_checked")


# --------------------------------------------------------------------------- command: courses
def collect_course_links(page) -> list[dict]:
    rows = page.evaluate("""() => [...document.querySelectorAll('a[href*="/course/view.php?id="]')]
        .map(a => ({href: a.href, text: a.textContent.trim().slice(0, 120)}))""")
    seen, out = set(), []
    for r in rows:
        cid = parse_qs(urlparse(r["href"]).query).get("id", [None])[0]
        if cid and cid not in seen:
            seen.add(cid)
            out.append({"id": int(cid), "text": r["text"]})
    return out


def cmd_courses(p):
    with authed(p) as (ctx, page):
        goto(page, "/my/courses.php")
        page.wait_for_timeout(2500)
        snapshot(page, "my_courses")
        dom = collect_course_links(page)
        res = ajax_read(page, "core_course_get_enrolled_courses_by_timeline_classification",
                        {"offset": 0, "limit": 0, "classification": "all", "sort": "fullname",
                         "customfieldname": "", "customfieldvalue": ""})
        summ = ajax_summary(res)
        ajax_courses = []
        if summ["ok"]:
            for c in res["json"][0]["data"].get("courses", []):
                ajax_courses.append({"id": c.get("id"), "shortname": c.get("shortname"),
                                     "fullname": c.get("fullname"), "category": c.get("coursecategory"),
                                     "visible": c.get("visible"), "enddate": c.get("enddate"),
                                     "viewurl": c.get("viewurl")})
        cap("courses", "discovery_dom_my_courses", "verified" if dom else "failed", count=len(dom))
        cap("courses", "discovery_ajax_enrolled_all", "verified" if ajax_courses else "failed", detail=summ,
            count=len(ajax_courses))
        # anonymised public view + private raw view
        anon = [{"id": c["id"], "label": f"COURSE_{i:03d}", "category": c["category"],
                 "visible": c["visible"]} for i, c in enumerate(ajax_courses or dom, 1)]
        save_json("courses_discovered.json", anon)
        save_json("courses_raw.json", ajax_courses or dom, private=True)
        log("courses_found", dom=len(dom), ajax=len(ajax_courses))

        # deadlines via calendar AJAX (read-only)
        ts = int(time.time())
        cal = ajax_read(page, "core_calendar_get_action_events_by_timesort",
                        {"timesortfrom": ts, "timesortto": ts + 30 * 86400, "limitnum": 50,
                         "limittononsuspendedevents": True})
        csum = ajax_summary(cal)
        n = None
        if csum["ok"]:
            n = len(cal["json"][0]["data"].get("events", []))
        cap("assignments", "deadlines_via_calendar_ajax", "verified" if csum["ok"] else "failed",
            detail=csum, events_next_30_days=n)

        if ARGS.scan_categories:
            scan_categories(ctx, page, {c["id"] for c in (ajax_courses or dom)})
    flush_caps()


def scan_categories(ctx, page, enrolled_ids: set):
    goto(page, "/")
    cats = page.evaluate("""() => [...new Set([...document.querySelectorAll('a[href*="categoryid="]')]
        .map(a => new URL(a.href).searchParams.get('categoryid')))]""")
    found: dict[int, int] = {}
    for cid in cats[: ARGS.max_categories]:
        goto(page, f"/course/index.php?categoryid={cid}&perpage=all")
        for c in collect_course_links(page):
            found[c["id"]] = int(cid)
    others = [i for i in found if i not in enrolled_ids][: ARGS.max_probe]
    access = {}
    for i in others:
        r = ctx.request.get(f"{BASE}/course/view.php?id={i}", max_redirects=0)
        access[i] = {"status": r.status, "location_path": urlparse(r.headers.get("location", "")).path}
    save_json("category_scan.json", {"categories_scanned": len(cats[:ARGS.max_categories]),
                                      "listed_courses": len(found), "enrolled": len(enrolled_ids & set(found)),
                                      "non_enrolled_probe": access})
    cap("courses", "enrolled_vs_public_distinction", "partial",
        listed=len(found), probed_non_enrolled=len(access), see="evidence/category_scan.json")


# --------------------------------------------------------------------------- command: inspect
def parse_course(html: str) -> dict:
    soup = BeautifulSoup(html, "html.parser")
    body_classes = soup.body.get("class", []) if soup.body else []
    matched = {
        "li.section": len(soup.select("li.section")),
        "[data-for=section]": len(soup.select("[data-for='section']")),
        "li.activity": len(soup.select("li.activity")),
        "[data-for=cmitem]": len(soup.select("[data-for='cmitem']")),
    }
    sec_nodes = soup.select("li.section, [data-for='section']")
    sections, seen_sec = [], set()
    for s in sec_nodes:
        sid = s.get("id") or s.get("data-id") or s.get("data-sectionid")
        if sid in seen_sec:
            continue
        seen_sec.add(sid)
        title_el = s.select_one(".sectionname, [data-for='section_title']")
        acts, seen_act = [], set()
        for a in s.select("li.activity, [data-for='cmitem']"):
            aid = a.get("id") or a.get("data-id")
            m = re.search(r"(\d+)$", str(aid or ""))
            cmid = int(m.group(1)) if m else None
            if cmid in seen_act:
                continue
            seen_act.add(cmid)
            cls = a.get("class", [])
            modtype = next((c[8:] for c in cls if c.startswith("modtype_")), None)
            name_el = a.select_one(".instancename, .activityname")
            if name_el:
                for hid in name_el.select(".accesshide, .sr-only"):
                    hid.decompose()
            link = a.select_one("a.aalink, .activityname a, a[href*='/mod/']")
            det = a.select_one(".resourcelinkdetails")
            icon = a.select_one("img.activityicon, img.icon")
            acts.append({
                "cmid": cmid, "modtype": modtype,
                "name": name_el.get_text(" ", strip=True) if name_el else None,
                "href_path": urlparse(link["href"]).path + ("?" + urlparse(link["href"]).query if urlparse(link["href"]).query else "") if link and link.get("href") else None,
                "details": det.get_text(" ", strip=True) if det else None,
                "icon_src_tail": (icon.get("src") or "").rsplit("/", 2)[-2:] if icon else None,
                "restricted": bool(a.select_one(".availabilityinfo")),
                "dimmed": any(c in cls for c in ("dimmed", "dimmed_text", "stealth")),
            })
        sections.append({"id": sid, "title": title_el.get_text(" ", strip=True) if title_el else None,
                         "activities": acts})
    return {"selectors_matched": matched,
            "body_class_hints": [c for c in body_classes if c.startswith(("format-", "theme", "uses-", "path-", "pagelayout-"))],
            "sections": sections}


def course_inventory(page, course_id: int) -> dict | None:
    resp = goto(page, f"/course/view.php?id={course_id}")
    page.wait_for_timeout(1500)
    if "/course/view.php" not in page.url:
        log("course_not_accessible", course_id=course_id, landed=urlparse(page.url).path)
        return None
    snapshot(page, f"course_{course_id}")
    inv = parse_course(page.content())
    inv["course_id"] = course_id
    inv["fetched_at"] = now()
    return inv


def diff_inventory(old: dict, new: dict) -> dict:
    flat = lambda inv: {a["cmid"]: (a["name"], a["modtype"], a["details"]) for s in inv["sections"] for a in s["activities"]}
    o, n = flat(old), flat(new)
    return {"added": sorted(set(n) - set(o)), "removed": sorted(set(o) - set(n)),
            "changed": sorted(k for k in set(o) & set(n) if o[k] != n[k])}


def resource_probe(ctx, cmid: int) -> dict:
    """Resolve where a resource activity points WITHOUT downloading its body."""
    r = ctx.request.get(f"{BASE}/mod/resource/view.php?id={cmid}&redirect=1", max_redirects=0)
    info = {"cmid": cmid, "view_status": r.status}
    loc = r.headers.get("location")
    if loc:
        u = urlparse(loc)
        info["redirect_path_pattern"] = re.sub(r"/\d+/", "/<n>/", u.path)
        info["filename"] = Path(u.path).name
        info["extension"] = Path(u.path).suffix.lower()
        h = ctx.request.fetch(loc, method="HEAD", max_redirects=0)
        info["head_status"] = h.status
        for k in ("content-type", "content-length", "last-modified", "etag", "content-disposition", "cache-control"):
            if k in h.headers:
                info[k] = h.headers[k]
    return info


def cmd_inspect(p):
    with authed(p) as (ctx, page):
        inv = course_inventory(page, ARGS.course_id)
        if not inv:
            cap("courses", "course_navigation", "failed", course_id=ARGS.course_id)
            flush_caps()
            return
        acts = [a for s in inv["sections"] for a in s["activities"]]
        types: dict[str, int] = {}
        for a in acts:
            types[a["modtype"] or "?"] = types.get(a["modtype"] or "?", 0) + 1
        cap("courses", "course_navigation", "verified", activity_counts=types)
        cap("courses", "section_discovery", "verified" if inv["sections"] else "failed",
            sections=len(inv["sections"]), selectors=inv["selectors_matched"], body_hints=inv["body_class_hints"])

        # change detection across runs
        inv_path = OUT / "private" / f"inventory_{ARGS.course_id}.json"
        if inv_path.exists():
            d = diff_inventory(json.loads(inv_path.read_text(encoding="utf-8")), inv)
            save_json(f"inventory_diff_{ARGS.course_id}.json", d)
            cap("materials", "new_material_detection", "verified", last_diff=d,
                note="DOM inventory diff between two runs; no timestamps from Moodle itself")
        else:
            cap("materials", "new_material_detection", "partial", note="baseline saved; run again later to verify a diff")
        save_json(f"inventory_{ARGS.course_id}.json", inv, private=True)

        # resources (cap)
        probes = []
        for a in [x for x in acts if x["modtype"] == "resource"][: ARGS.max_resources]:
            try:
                probes.append(resource_probe(ctx, a["cmid"]))
            except Exception as e:
                probes.append({"cmid": a["cmid"], "error": str(e)[:120]})
        save_json(f"resource_probes_{ARGS.course_id}.json", probes, private=True)
        by_ext: dict[str, dict] = {}
        for pr in probes:
            ext = pr.get("extension") or "(none/inline)"
            e = by_ext.setdefault(ext, {"count": 0, "head_ok": 0})
            e["count"] += 1
            e["head_ok"] += int(pr.get("head_status") == 200)
        cap("downloads", "resource_url_resolution_without_body", "verified" if probes else "not_tested",
            by_extension=by_ext)

        # folders + urls
        for a in [x for x in acts if x["modtype"] == "folder"][: ARGS.max_folders]:
            goto(page, f"/mod/folder/view.php?id={a['cmid']}")
            snapshot(page, f"folder_{a['cmid']}")
            files = page.evaluate("""() => [...document.querySelectorAll('a[href*="pluginfile.php"]')]
                .map(a => new URL(a.href).pathname.split('/').pop())""")
            dl_form = page.evaluate("""() => { const f = document.querySelector('form[action*="download_folder.php"]');
                return f ? {action: f.getAttribute('action'), method: f.method,
                            fields: [...f.querySelectorAll('input')].map(i => i.name)} : null; }""")
            cap("downloads", "folder_listing", "verified" if files else "partial", cmid=a["cmid"],
                file_count=len(files), extensions=sorted({Path(x).suffix.lower() for x in files}),
                download_all_form=dl_form)
        urls = [x for x in acts if x["modtype"] == "url"][:3]
        for a in urls:
            r = ctx.request.get(f"{BASE}/mod/url/view.php?id={a['cmid']}&redirect=1", max_redirects=0)
            cap("downloads", "external_url_activity", "verified", cmid=a["cmid"], status=r.status,
                redirects_to_host=urlparse(r.headers.get("location", "")).netloc or None)
    flush_caps()


# --------------------------------------------------------------------------- command: assignments
ACTION_RE = re.compile(r"[?&]action=(\w+)")


def cmd_assignments(p):
    with authed(p) as (ctx, page):
        goto(page, f"/mod/assign/index.php?id={ARGS.course_id}")
        snapshot(page, f"assign_index_{ARGS.course_id}")
        table = page.evaluate("""() => {
          const t = document.querySelector('table.generaltable');
          if (!t) return null;
          const heads = [...t.querySelectorAll('thead th, tr:first-child th')].map(h => h.textContent.trim());
          const rows = [...t.querySelectorAll('tbody tr')].map(tr => {
            const cells = [...tr.querySelectorAll('td')].map(td => td.textContent.trim().slice(0, 60));
            const a = tr.querySelector('a[href*="/mod/assign/view.php?id="]');
            return {cmid: a ? new URL(a.href).searchParams.get('id') : null, cells};
          });
          return {heads, rows};}""")
        if not table or not table["rows"]:
            cap("assignments", "discovery", "partial", note="no assignment table (course may have none)")
            flush_caps()
            return
        cap("assignments", "discovery", "verified", columns=table["heads"], count=len(table["rows"]),
            ids_available=all(r["cmid"] for r in table["rows"]))
        details = []
        for row in table["rows"][: ARGS.max_assign]:
            if not row["cmid"]:
                continue
            goto(page, f"/mod/assign/view.php?id={row['cmid']}")
            snapshot(page, f"assign_{row['cmid']}")
            d = page.evaluate("""() => {
              const kv = {}; document.querySelectorAll('.submissionstatustable tr, table.generaltable tr').forEach(tr => {
                const th = tr.querySelector('th'), td = tr.querySelector('td');
                if (th && td) kv[th.textContent.trim()] = td.textContent.trim().slice(0, 80);});
              const acts = [...document.querySelectorAll('a[href*="/mod/assign/view.php"], form[action*="/mod/assign/view.php"]')]
                .map(e => (e.href || e.action || ''));
              return {kv, acts};}""")
            safe_keys = {k: (v if re.search(r"status|remaining|due|opened|graded|modified", k, re.I) and
                             not re.search(r"file|comment|feedback", k, re.I) else "[redacted]")
                         for k, v in d["kv"].items()}
            actions = sorted({m.group(1) for u in d["acts"] for m in [ACTION_RE.search(u)] if m})
            details.append({"cmid": int(row["cmid"]), "fields": safe_keys, "actions_offered_to_student": actions})
        save_json(f"assignments_{ARGS.course_id}.json", details)
        cap("assignments", "deadline_extraction", "verified" if any("Due date" in k or "due" in k.lower() for d in details for k in d["fields"]) else "partial")
        cap("assignments", "submission_status", "verified" if any(re.search("submission status", k, re.I) for d in details for k in d["fields"]) else "partial")
        cap("assignments", "grading_status_visible", "verified" if any(re.search("grading status", k, re.I) for d in details for k in d["fields"]) else "partial")
        cap("assignments", "actions_available_links", "verified", note="query 'action=' values seen on view pages; NOT clicked")
    flush_caps()


def cmd_upload_form(p):
    """OPT-IN. GET on action=editsubmission is not guaranteed side-effect free on every Moodle version
    (it may create an empty 'draft'/'new' submission record). Nothing is clicked, typed or saved."""
    if not ARGS.i_understand_get_may_create_empty_draft:
        sys.exit("Refusing: pass --i-understand-get-may-create-empty-draft to run this opt-in test on ONE assignment "
                 "(preferably a teacher-designated test activity).")
    with authed(p) as (ctx, page):
        page.goto(f"{BASE}/mod/assign/view.php?id={ARGS.cmid}&action=editsubmission", wait_until="networkidle")
        snapshot(page, f"assign_{ARGS.cmid}_editform")
        info = page.evaluate("""() => {
          const form = document.querySelector('form.mform');
          const restr = [...document.querySelectorAll('.fp-restrictions, .fp-maxsize, .fp-maxfiles, .fp-accepted-types')]
              .map(e => e.textContent.trim().replace(/\\s+/g,' ').slice(0,200));
          return {
            formFound: !!form, action: form ? form.getAttribute('action') : null, method: form ? form.method : null,
            inputNames: form ? [...form.querySelectorAll('input,textarea,select,button')].map(e => e.name).filter(Boolean) : [],
            hasFileManager: !!document.querySelector('.filemanager, .fp-wrap, [id^="fitem_id_files_"]'),
            hasOnlineText: !!document.querySelector('[name^="onlinetext_editor"], #fitem_id_onlinetext_editor'),
            hasSubmissionStatement: !!document.querySelector('[name="submissionstatement"]'),
            restrictions: restr,
            buttons: [...document.querySelectorAll('form.mform input[type=submit], form.mform button[type=submit]')].map(b => (b.value || b.textContent).trim())
          };}""")
        save_json(f"upload_form_{ARGS.cmid}.json", info)
        cap("assignments", "upload_inspection", "verified" if info["formFound"] else "failed",
            file_manager=info["hasFileManager"], online_text=info["hasOnlineText"],
            restrictions=info["restrictions"], buttons=info["buttons"])
        cap("assignments", "actual_submission", "not_tested", note="intentionally never performed by this script")
    flush_caps()


# --------------------------------------------------------------------------- command: grades
def cmd_grades(p):
    with authed(p) as (ctx, page):
        goto(page, f"/grade/report/user/index.php?id={ARGS.course_id}")
        shape = page.evaluate("""() => {
          const t = document.querySelector('table.user-grade, table.generaltable');
          if (!t) return null;
          const heads = [...t.querySelectorAll('thead th, tr:first-child th')].map(h => h.textContent.trim().slice(0, 40));
          const rows = [...t.querySelectorAll('tbody tr')];
          const withNumber = rows.filter(r => /\\d/.test(r.querySelector('td.column-grade, td:nth-child(2)')?.textContent || '')).length;
          return {heads, rows: rows.length, rows_with_numeric_grade_cell: withNumber};}""")
        cap("grades", "retrieval", "verified" if shape else "failed",
            table_shape=shape, note="structure only; no grade values stored")
    flush_caps()


# --------------------------------------------------------------------------- command: webservices
def cmd_webservices(p):
    with authed(p) as (ctx, page):
        res = {}
        for label, path in {"admin_ws_documentation": "/admin/webservice/documentation.php",
                            "admin_ws_settings": "/admin/settings.php?section=webservicesoverview"}.items():
            goto(page, path)
            res[label] = {"final_path": urlparse(page.url).path, "title": page.title()[:80],
                          "http_ok_but_denied_text": bool(page.evaluate(
                              "() => /permission|not allowed|exception|accès|autoris/i.test(document.body.innerText)"))}
        rest = ctx.request.get(f"{BASE}/webservice/rest/server.php?wsfunction=core_webservice_get_site_info&moodlewsrestformat=json", max_redirects=0)
        res["rest_without_token_while_logged_in"] = {"status": rest.status, "snippet": rest.text()[:160]}
        for fn, args in {
            "core_course_get_recent_courses": {"limit": 5},
            "tool_mobile_get_public_config": {},
        }.items():
            res[f"ajax_{fn}"] = ajax_summary(ajax_read(page, fn, args))
        save_json("webservices_authed.json", res)
        cap("web_services", "admin_documentation_for_student", "verified",
            final_path=res["admin_ws_documentation"]["final_path"], note="expected to be denied for students")
        cap("web_services", "session_ajax_service_php", "verified" if res.get("ajax_core_course_get_recent_courses", {}).get("ok") else "partial",
            note="/lib/ajax/service.php with page sesskey = what the Moodle web UI itself uses; only AJAX-enabled functions work")
        cap("web_services", "token_for_student", "not_tested",
            note="Needs your own credentials against /login/token.php - do this manually (see report); never scripted here")
    flush_caps()


# --------------------------------------------------------------------------- command: download
def cmd_download(p):
    if not ARGS.cmid:
        sys.exit("--cmid is required (take it from: inspect, then private/resource_probes_<course>.json)")
    dest = OUT / "downloads_test"
    dest.mkdir(parents=True, exist_ok=True)
    with authed(p) as (ctx, page):
        r = ctx.request.get(f"{BASE}/mod/resource/view.php?id={ARGS.cmid}&redirect=1", max_redirects=0)
        loc = r.headers.get("location")
        if not loc:
            cap("downloads", "direct_http_download", "failed", view_status=r.status,
                note="resource does not redirect to a file (display mode embed/page?)")
            flush_caps()
            return
        head = ctx.request.fetch(loc, method="HEAD", max_redirects=0)
        size = int(head.headers.get("content-length", "0") or 0)
        if size and size > ARGS.max_mb * 1024 * 1024:
            sys.exit(f"Refusing: file is {size/1e6:.1f} MB > --max-mb {ARGS.max_mb}")
        # (a) direct HTTP with the authenticated session
        g = ctx.request.get(loc, max_redirects=0)
        body = g.body()
        fname = safe_name(Path(urlparse(loc).path).name)
        (dest / f"http_{fname}").write_bytes(body)
        h_http = sha256_bytes(body)
        meta = {"filename": fname, "status": g.status, "bytes": len(body), "sha256": h_http,
                "content_type": g.headers.get("content-type"), "last_modified": g.headers.get("last-modified"),
                "etag": g.headers.get("etag"), "content_disposition_present": "content-disposition" in g.headers}
        cap("downloads", "direct_http_download", "verified" if g.status == 200 and body else "failed", **{k: v for k, v in meta.items() if k != "filename"})
        # unauthenticated access to the same URL
        anon = p.request.new_context()
        a = anon.get(loc, max_redirects=0)
        cap("downloads", "download_requires_authentication", "verified", anonymous_status=a.status,
            anonymous_redirect_path=urlparse(a.headers.get("location", "")).path or None)
        anon.dispose()
        # conditional GET => cheap new-version detection
        cond = {}
        if meta["etag"]:
            cond["If-None-Match"] = meta["etag"]
        if meta["last_modified"]:
            cond["If-Modified-Since"] = meta["last_modified"]
        if cond:
            c = ctx.request.get(loc, headers=cond, max_redirects=0)
            cap("downloads", "conditional_get_304_supported", "verified", status=c.status)
        # (b) real browser download event
        try:
            with page.expect_download(timeout=60000) as dl:
                page.evaluate("u => { location.href = u; }", loc)
            d = dl.value
            bpath = dest / f"browser_{safe_name(d.suggested_filename)}"
            d.save_as(str(bpath))
            h_br = sha256_bytes(bpath.read_bytes())
            cap("downloads", "playwright_download_event", "verified", suggested_filename_present=bool(d.suggested_filename),
                same_sha256_as_http=(h_br == h_http))
        except Exception as e:
            cap("downloads", "playwright_download_event", "failed", err=str(e)[:120])
        # duplicate detection via manifest
        mf = dest / "manifest.json"
        manifest = json.loads(mf.read_text()) if mf.exists() else {}
        dup_of = next((k for k, v in manifest.items() if v["sha256"] == h_http and k != str(ARGS.cmid)), None)
        manifest[str(ARGS.cmid)] = {"sha256": h_http, "bytes": len(body), "ts": now(), "filename": fname}
        mf.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        cap("downloads", "duplicate_detection_by_sha256", "verified", duplicate_of_cmid=dup_of,
            note="manifest keyed by cmid; compare hash before re-downloading")
        save_json("download_test.json", meta)
    flush_caps()


# --------------------------------------------------------------------------- command: all
def cmd_all(p):
    cmd_session(p)
    cmd_courses(p)
    raw = json.loads((OUT / "private" / "courses_raw.json").read_text(encoding="utf-8"))
    for c in raw[: ARGS.max_courses]:
        ARGS.course_id = c["id"]
        cmd_inspect(p)
        cmd_assignments(p)
        cmd_grades(p)
    cmd_webservices(p)


# --------------------------------------------------------------------------- main
def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["public", "login", "session", "courses", "inspect", "assignments",
                                        "grades", "webservices", "download", "upload-form", "all"])
    ap.add_argument("--base-url", default=BASE)
    ap.add_argument("--out", default="evidence")
    ap.add_argument("--headed", action="store_true", help="show browser for non-login commands too")
    ap.add_argument("--login-timeout", type=int, default=300)
    ap.add_argument("--method", choices=["state", "profile", "both"], default="state")
    ap.add_argument("--course-id", type=int)
    ap.add_argument("--cmid", type=int)
    ap.add_argument("--max-courses", type=int, default=3)
    ap.add_argument("--max-resources", type=int, default=15)
    ap.add_argument("--max-folders", type=int, default=2)
    ap.add_argument("--max-assign", type=int, default=5)
    ap.add_argument("--max-mb", type=int, default=25)
    ap.add_argument("--scan-categories", action="store_true")
    ap.add_argument("--max-categories", type=int, default=8)
    ap.add_argument("--max-probe", type=int, default=5)
    ap.add_argument("--i-understand-get-may-create-empty-draft", action="store_true")
    return ap


def main() -> None:
    global ARGS, BASE, OUT, CAPS
    ARGS = build_parser().parse_args()
    BASE, OUT = ARGS.base_url.rstrip("/"), Path(ARGS.out)
    OUT.mkdir(parents=True, exist_ok=True)
    CAPS = load_caps()
    needs_course = {"inspect", "assignments", "grades"}
    if ARGS.command in needs_course and not ARGS.course_id:
        sys.exit("--course-id is required for this command")
    if ARGS.command == "upload-form" and not ARGS.cmid:
        sys.exit("--cmid (assignment course-module id) is required")
    fn = {"public": cmd_public, "login": cmd_login, "session": cmd_session, "courses": cmd_courses,
          "inspect": cmd_inspect, "assignments": cmd_assignments, "grades": cmd_grades,
          "webservices": cmd_webservices, "download": cmd_download, "upload-form": cmd_upload_form,
          "all": cmd_all}[ARGS.command]
    with sync_playwright() as p:
        try:
            fn(p)
        finally:
            flush_caps()
    log("done", command=ARGS.command)


if __name__ == "__main__":
    main()
