# Evidence: public login page (fetched 2026-11-19, NOT logged in)
Source: https://elearn.esi-sba.dz/login/index.php  |  Method: web_fetch (markdown conversion; no DOM/selectors)
meta-robots: noindex
Visible elements, in order: "Username" field, "Password" field, "Log in" button,
"Lost password?" link (/login/forgot_password.php), "Log in as a guest" button,
language switcher (en/fr), "Cookies notice".
NOT visible in the rendered text: any CAPTCHA label, 2FA prompt, SSO/identity-provider buttons, signup link.
(Absence in a text conversion is weak evidence; the `public` command checks the real DOM.)
