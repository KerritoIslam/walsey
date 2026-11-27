# ESI-SBA Moodle: Automation Feasibility Report for Walsey

**Report date:** 2026-11-19 | **Target:** https://elearn.esi-sba.dz | **Status: PHASE 1 of 2**

## 0. Read this first: what was and was not tested

I could not run live tests. The sandbox this report was produced in cannot resolve `elearn.esi-sba.dz`, and a manual login (your credentials, your visible browser) cannot be done by me anyway. What exists:

| Item | State |
|---|---|
| Public (logged-out) front page and login page | **Fetched and recorded** (`evidence/public_fetch/`). Text conversion only, so no DOM selectors. |
| Everything behind login (courses, resources, assignments, grades, sessions, web services) | **Not tested.** Every row below says so. |
| `moodle_test.py` test suite | **Written, compiles, parsers and sanitiser unit-tested on synthetic HTML.** Never run against the real site. Expect to fix selector mismatches on the first run; the script records which selectors matched so a failure shows up as evidence, not a silent wrong answer. |

Nothing in sections 3 to 9 is a finding. "Hypothesis" marks general Moodle knowledge that the suite is designed to confirm or refute. Phase 2 is you running the commands in section 2 and sending back `capabilities.json` plus the `evidence/` folder (minus `private/`).

## 1. Verified facts (public pages, 2026-11-19)

1. **Platform is Moodle.** Footer says "Powered by Moodle"; URLs follow `/login/index.php`, `/course/index.php?categoryid=N`, `/pluginfile.php/...`.
2. **Theme is `moove`** (asset paths `pluginfile.php/1/theme_moove/...`; footer credits Conecti.me). A third-party theme, so DOM selectors may differ from stock Boost/Classic. This matters for scraping.
3. **Moodle version: unknown.** Not shown on public pages.
4. **Login page** shows Username, Password, Log in, "Lost password?", and a **guest login button**. `meta robots` is `noindex`. No CAPTCHA, 2FA prompt, SSO button or signup link in the rendered text (weak evidence; the `public` command checks the real DOM).
5. **UI languages:** English and French via `?lang=`.
6. **Public category tree** is browsable without login (`/course/index.php?categoryid=N`), organised by year/stream (preparatory, second cycle, ISI/SIW/IASD/Cybersecurity, Master, Doctorat). Front page advertises 112 courses and 2432 active users.

## 2. How to run the suite (Windows, PowerShell)

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
playwright install chromium

python moodle_test.py public                 # no login; DOM of login form, version/plugin hints, WS probes
python moodle_test.py login                  # visible browser; YOU log in; script never sees credentials
python moodle_test.py session --method both  # new process: does the saved state / profile still work?
python moodle_test.py courses --scan-categories
python moodle_test.py inspect --course-id <ID>        # ID from evidence/courses_discovered.json
python moodle_test.py assignments --course-id <ID>
python moodle_test.py grades --course-id <ID>
python moodle_test.py webservices
python moodle_test.py download --cmid <CMID>          # ONE harmless PDF you pick; cmids are in evidence/private/resource_probes_<ID>.json
```

Optional, opt-in only:

```powershell
python moodle_test.py upload-form --cmid <ASSIGN_CMID> --i-understand-get-may-create-empty-draft
```

Re-run `inspect` for the same course later (days apart) to verify new-material detection (an inventory diff is produced on the second run).
Repeat `session` at intervals (Task Scheduler, e.g. every 2 h for a day) to build `evidence/session_log.jsonl`, the only honest way to learn real session lifetime.

Safety properties of the suite:
- Navigation is read-only GET. A deny-list blocks `logout.php`, `action=submit/remove/savesubmission/...`, `modedit.php`, `sesskey=` URLs, token pages.
- The only POST is to Moodle's AJAX endpoint for four whitelisted read-only functions (`READ_ONLY_AJAX`); the sesskey stays inside the page and is never logged.
- No credentials are read, prompted for or stored. Auth state is saved to `.walsey_auth/` (cookie values; git-ignored; treat like a password).
- Caveat: **Moodle logs every page view and some courses mark "view" completion.** Read-only here means "no data written by you", not "invisible to the teacher". The suite caps visits (`--max-*` flags).
- `upload-form` is opt-in because I could not confirm whether loading `action=editsubmission` creates an empty draft submission record on this Moodle version. Prefer a teacher-designated test assignment.

## 3. Status matrix (all unverified until you run the suite)

Feasibility column = **Not tested** for every row. The "Hypothesis" and "Command" columns say what I expect and which command settles it.

| Operation | Feasibility | Hypothesis (general Moodle knowledge, not verified here) | Command |
|---|---|---|---|
| Login | Not tested | Standard `username`/`password` form at `/login/index.php`, plus hidden `logintoken` | `public`, `login` |
| Session persistence | Not tested | **Risk:** `MoodleSession` is normally a session cookie (no expiry). Chromium persistent profiles often drop session cookies on close, so the suite saves Playwright `storage_state` as the primary mechanism and tests both | `session --method both` |
| Course discovery | Not tested | `/my/courses.php` DOM (JS-rendered) and `/lib/ajax/service.php` function `core_course_get_enrolled_courses_by_timeline_classification` | `courses` |
| Course navigation | Not tested | `/course/view.php?id=N` | `inspect` |
| Section discovery | Not tested | `li.section` / `[data-for=section]`; moove may differ | `inspect` |
| PDF downloads | Not tested | `/mod/resource/view.php?id=CMID&redirect=1` redirects to `/pluginfile.php/<ctx>/mod_resource/content/<rev>/<name>`; works with session cookie via plain HTTP | `inspect`, `download` |
| ZIP downloads | Not tested | Same as PDF; folder "download all" form is `download_folder.php` (field list captured by `inspect`) | `inspect`, `download` |
| New material detection | Not tested | DOM inventory diff (cmid + name + details) between runs; conditional GET (ETag/Last-Modified) for changed files | `inspect` x2, `download` |
| Assignment discovery | Not tested | `/mod/assign/index.php?id=<courseid>` table, cmid in link | `assignments` |
| Deadline extraction | Not tested | Due date in index table and on `view.php`; calendar AJAX `core_calendar_get_action_events_by_timesort` | `assignments`, `courses` |
| Submission status | Not tested | "Submission status" / "Grading status" rows on `/mod/assign/view.php?id=CMID` | `assignments` |
| File upload | Not tested | Needs filemanager draft area + upload endpoint; see section 6 | `upload-form` (inspection only) |
| Final submission | Not tested, **deliberately never run** | May need a second "Submit assignment" confirmation depending on the teacher's setting | none |
| Grade retrieval | Not tested | `/grade/report/user/index.php?id=<courseid>` (structure only is recorded; no values stored) | `grades` |

## 4. Authentication and session (to be filled from `public`, `login`, `session`)

Open questions the suite answers, with where the answer lands:
- Form fields, action, method, hidden CSRF field name, CAPTCHA/IdP buttons: `evidence/public_probe.json` -> `login_form`
- Cookie names and security attributes (HttpOnly, Secure, SameSite, session vs persistent): `capabilities.json` -> `session.cookie_attributes_*`
- Landing path after login: `authentication.manual_login.landing_path_after_login`
- Configured idle timeout exposed to JS (`M.cfg.sessiontimeout`): `session.server_side_session_timeout_seconds`
- Survives browser restart: `session.survives_browser_restart_via_state|profile`
- Real expiry: only from `session_log.jsonl` over time (not inferable from config)
- Logout: **not scripted** (it would kill your saved session). Test by hand if needed.
- 2FA / extra verification: you must note it during `login`; the script cannot detect one it never sees.

## 5. Architecture and plugins

`public` records: theme/body-class hints, `M.cfg` non-secret values, plugin hints from every requested URL (heuristic: core vs third-party not distinguished), `/lib/upgrade.txt` top heading (indicative version only), and `tool_mobile_get_public_config` via `service-nologin.php` (returns the release number if the mobile web service is exposed). Version will be marked `verified` only if the release string comes back; otherwise `partial` or `unknown`.

## 6. Assignment submission: what automating it would need (hypothesis)

Core Moodle submits files in two steps, which is why this is the riskiest feature:
1. Load the edit form; read `sesskey`, the filemanager draft `itemid` (field `files_filemanager`), and upload-repository parameters.
2. Upload bytes to Moodle's repository upload endpoint into that draft area, then POST the form with `action=savesubmission`.
3. If the teacher requires explicit confirmation, a **separate** "Submit assignment" step (plus possibly a submission statement checkbox) is needed before it counts as final.

`upload-form` records the real field names, file manager restrictions (max size, max files, accepted types) and button labels, so an implementer does not guess. A Playwright route that drives the real UI (set file input, click Save) is slower but tolerant of field-name drift.

## 7. Web services (to be filled from `public`, `webservices`)

Keep the five questions separate when reading results:
1. Endpoint exists: `rest_endpoint_reachable` (HTTP response from `/webservice/rest/server.php`)
2. Endpoint accessible: depends on response body (token error vs "protocol not enabled")
3. Authentication works: needs a token; not testable by script
4. Functions enabled: unknown without a token
5. Permitted for students: unknown without a token

The `/admin/webservice/documentation.php` probe is expected to be denied for students; that does not mean web services are off.

**One manual check I deliberately did not script**, because it needs your password: `/login/token.php` (`service=moodle_mobile_app`). If you decide to test it, run it yourself from a terminal you trust, never paste the response here, and treat any returned token like a password. A refusal message tells you whether the mobile service is enabled; I have not observed this site's wording.

Independent of that: the logged-in browser session can call Moodle's own AJAX endpoint (`/lib/ajax/service.php` with the page sesskey). Only functions flagged AJAX-enabled work, and the suite tests three candidates. This is not an official student API and can change on upgrade.

## 8. Risks I already see, regardless of test results

- **Third-party theme (moove)** means selectors can differ from documentation. Anchor on `cmid` URLs (`/mod/<type>/view.php?id=`) rather than CSS classes where possible.
- **Course page is JS-heavy** (dashboard cards, drawers). Expect `networkidle` plus explicit waits.
- **View logging / completion side effects** (section 2).
- **Session cookie persistence** may differ between profile reuse and `storage_state` (section 3). Cookie values in `.walsey_auth/` are credentials-equivalent.
- **Server-side session timeout and possible IP binding** are unknown until measured.
- **Screenshots can show course content.** Names/avatars are masked; review before sharing.

## 9. Provisional architecture for Walsey (revise after Phase 2)

This is a design recommendation from general Moodle knowledge, not a result of tests. I'd re-evaluate it once `capabilities.json` is populated.

| Approach | Reliability | Maintenance | Auth complexity | Windows | Android | Download speed | Submission safety |
|---|---|---|---|---|---|---|---|
| Playwright only | Medium (tolerates UI quirks, slow, breaks on layout changes) | High | Low (manual login once) | Good (Python/Node sidecar) | Not viable on-device | Slow | Best control (can pause before the final click) |
| Direct HTTP with session cookie | High for stable URLs (`pluginfile`, `view.php`) | Medium (HTML parsing) | Medium (need the session from a browser login) | Good (Dart `http` + cookie jar) | Possible but cookie hand-off needed | Fast | Fragile for uploads |
| Web Services API | Highest, if enabled | Lowest | Token needed (unknown if students can get one) | Good | Good | Fast | Cleanest, if `mod_assign_save_submission` is permitted |
| **Hybrid (recommended starting point)** | | | | | | | |

Recommended hybrid, pending Phase 2:
1. **Playwright, headed, manual login only** to obtain the session (`storage_state`). Re-login prompt when the session expires.
2. **Direct HTTP + the session** for the bulk work: listing, downloads (with sha256 manifest and conditional GET), status polling, and the AJAX calls that verified OK.
3. **Playwright UI driving for submission**, with a mandatory preview-and-confirm step in Walsey ("Submit file X to assignment Y, accepted types Z, due D: confirm?"), pre-flight checks against the recorded restrictions, and never combining upload and final submit in one unconfirmed action.
4. **Switch step 2 to Web Services** if Phase 2 shows a student token is obtainable and the needed functions are permitted.
5. **Architecture split:** the Windows app is the automation host (sidecar process with a narrow local API: `list_courses`, `download_latest`, `due_this_week`, `submission_status`, `prepare_submission`, `submit` with confirmation token). Android sends commands to the host and never holds cookies.

Map to your example commands: "list my courses", "download the latest TD", "assignments due this week" and "is it submitted?" depend only on read operations (low risk once verified). "Prepare this PDF" is local. "Submit this assignment" is the only write; gate it behind explicit confirmation and ship it last.

## 10. Evidence index

- `evidence/public_fetch/frontpage_fetch.md`, `login_page_fetch.md`: the only evidence collected so far
- `evidence/README.md`: what the suite will generate
- `capabilities.json`: baseline; only the public-page facts are non-`not_tested`
