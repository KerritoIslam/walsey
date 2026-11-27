# evidence/
Populated by `moodle_test.py`:
- html/            sanitised HTML snapshots (scripts removed, hidden-input values, emails, user names, sesskeys redacted)
- screenshots/     full-page PNGs, user menu/avatar/password fields masked (REVIEW before sharing: course content may be visible)
- test_log.jsonl   structured log (no secrets)
- session_log.jsonl one line per `session` run (timestamp, logged_in, cookie ATTRIBUTES only)
- public_probe.json, courses_discovered.json (anonymised COURSE_nnn labels), assignments_<id>.json, upload_form_<cmid>.json,
  webservices_authed.json, category_scan.json, download_test.json
- private/         real course names, inventories, resource probes (git-ignored, keep local)
- downloads_test/  the single test download(s) + manifest.json (git-ignored)
- public_fetch/    the only evidence collected so far, from the assistant's public web fetch (no login)
