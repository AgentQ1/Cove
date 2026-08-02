#!/usr/bin/env python3
"""Generates the Inditalk public site (legal + support pages) into site/public.

The pages exist because the App Store requires a reachable Privacy Policy and support
contact, and because a user-generated-content app needs published community guidelines
and a documented way to report abuse and delete an account.

Content is written to match what the app ACTUALLY does — see the notes in
Services/Crypto/MessageCrypto.swift and Services/Firebase/FirestoreService.swift.
Do not add claims here that the code does not support.

    python3 site/build.py && firebase deploy --only hosting:inditalk --project cove-7f31f
"""
import os, re, datetime

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "public")
UPDATED = "27 July 2026"
SUPPORT = "moomolab@gmail.com"
COMPANY = "MOOMOLAB LLC"
ADDRESS = "3361 South Wabash Avenue, Chicago, IL 60616, United States"

CSS = """
*{box-sizing:border-box}
:root{
  --bg:#F5F2EC; --surface:#FBF9F5; --ink:#1C3A4B; --text:#20262B; --muted:#5F6B72;
  --line:#E2DCD1; --accent:#2F6E63;
}
@media (prefers-color-scheme:dark){
  :root{--bg:#14171A; --surface:#1C2024; --ink:#CFE3ED; --text:#E8EAEC; --muted:#9AA4AB;
        --line:#2C3238; --accent:#6FB3A6;}
}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);
  font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
.wrap{max-width:760px;margin:0 auto;padding:32px 20px 72px}
header.site{display:flex;align-items:center;gap:12px;padding:20px 0;border-bottom:1px solid var(--line);
  margin-bottom:36px;flex-wrap:wrap}
.logo{width:38px;height:38px;border-radius:11px;background:var(--ink);color:var(--bg);
  display:grid;place-items:center;font-weight:700;font-size:19px;flex:none}
.brand{font-weight:700;font-size:19px;color:var(--text);text-decoration:none}
nav{margin-left:auto;display:flex;gap:18px;flex-wrap:wrap}
nav a{color:var(--muted);text-decoration:none;font-size:14px}
nav a:hover{color:var(--accent)}
h1{font-size:32px;line-height:1.2;margin:0 0 6px}
h2{font-size:20px;margin:34px 0 10px;color:var(--ink)}
h3{font-size:16px;margin:22px 0 6px}
.updated{color:var(--muted);font-size:14px;margin:0 0 28px}
p,li{color:var(--text)}
a{color:var(--accent)}
ul{padding-left:22px}
li{margin:6px 0}
table{width:100%;border-collapse:collapse;margin:14px 0;font-size:15px;display:block;overflow-x:auto}
th,td{border:1px solid var(--line);padding:9px 11px;text-align:left;vertical-align:top}
th{background:var(--surface);font-weight:600}
.card{background:var(--surface);border:1px solid var(--line);border-radius:14px;padding:18px 20px;margin:18px 0}
.lead{font-size:18px;color:var(--muted)}
footer{border-top:1px solid var(--line);margin-top:56px;padding-top:22px;color:var(--muted);font-size:14px}
footer a{color:var(--muted)}
code{background:var(--surface);border:1px solid var(--line);border-radius:5px;padding:1px 5px;font-size:14px}
"""

NAV = [("Privacy", "/privacy"), ("Terms", "/terms"),
       ("Guidelines", "/guidelines"), ("Help", "/help")]


def page(title, description, body, path):
    nav = "".join(f'<a href="{href}">{label}</a>' for label, href in NAV)
    html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title} · Inditalk</title>
<meta name="description" content="{description}">
<style>{CSS}</style>
</head>
<body>
<div class="wrap">
<header class="site">
  <div class="logo">I</div>
  <a class="brand" href="/">Inditalk</a>
  <nav>{nav}</nav>
</header>
{body}
<footer>
  <p>Inditalk is operated by {COMPANY}, {ADDRESS}.<br>
     Support: <a href="mailto:{SUPPORT}">{SUPPORT}</a></p>
  <p><a href="/privacy">Privacy Policy</a> · <a href="/terms">Terms of Service</a> ·
     <a href="/guidelines">Community Guidelines</a> · <a href="/help">Help &amp; Support</a> ·
     <a href="/delete-account">Delete your account</a></p>
</footer>
</div>
</body>
</html>"""
    full = os.path.join(OUT, path.strip("/"))
    os.makedirs(full, exist_ok=True) if path != "/" else os.makedirs(OUT, exist_ok=True)
    dest = os.path.join(OUT, "index.html") if path == "/" else os.path.join(full, "index.html")
    with open(dest, "w") as f:
        f.write(html)
    return dest


HOME = f"""
<h1>Inditalk</h1>
<p class="lead">A private messenger for texting, voice and video calls with the people you
actually talk to.</p>
<div class="card">
  <p><strong>Inditalk</strong> lets you send messages, photos, videos, voice notes,
  documents and your location, place one-to-one voice and video calls, create groups, and
  post updates that disappear after 24 hours. You sign in with your phone number — no
  email address and no password.</p>
</div>
<h2>Your controls</h2>
<ul>
  <li>Choose who can see your last seen, profile photo, About text and read receipts.</li>
  <li>Block or report any contact directly from their profile.</li>
  <li>Turn on disappearing messages for any chat.</li>
  <li>Delete your account and its data at any time from Settings.</li>
</ul>
<h2>Legal &amp; support</h2>
<ul>
  <li><a href="/privacy">Privacy Policy</a> — what we collect and why</li>
  <li><a href="/terms">Terms of Service</a></li>
  <li><a href="/guidelines">Community Guidelines</a> — what is not allowed, and how to report it</li>
  <li><a href="/help">Help &amp; Support</a></li>
  <li><a href="/delete-account">How to delete your account</a></li>
</ul>
"""

PRIVACY = f"""
<h1>Privacy Policy</h1>
<p class="updated">Last updated {UPDATED}</p>

<p>Inditalk is operated by <strong>{COMPANY}</strong>, {ADDRESS}, which is the controller
responsible for the personal data described here. This policy explains what Inditalk
(“we”, “the app”) collects when you use the Inditalk iOS app, why we collect it, and the
choices you have. Questions: <a href="mailto:{SUPPORT}">{SUPPORT}</a>.</p>

<h2>1. What we collect</h2>
<table>
<tr><th>Data</th><th>Why</th></tr>
<tr><td>Phone number</td><td>It is your account identifier. Sign-in is by SMS one-time code; we do not use passwords.</td></tr>
<tr><td>Account ID</td><td>An identifier assigned to your account, used to route messages and calls.</td></tr>
<tr><td>Profile: display name, About text, profile photo</td><td>Shown to people you chat with. All optional except the display name.</td></tr>
<tr><td>Contacts</td><td>Only if you grant contacts access. Phone numbers are hashed on your device before being sent, so we can tell you which of your contacts already use Inditalk without receiving your address book in readable form.</td></tr>
<tr><td>Messages and attachments</td><td>Stored so they can be delivered to the people you send them to. See “Encryption” below.</td></tr>
<tr><td>Status updates</td><td>Text, photos and videos you post as updates. These expire after 24 hours.</td></tr>
<tr><td>Call records</td><td>Who called whom, when, for how long, and whether it was voice or video. We do not record call audio or video.</td></tr>
<tr><td>Push notification token</td><td>So your device can be told a message or call has arrived.</td></tr>
<tr><td>Location</td><td>Only the location you explicitly choose to send in a chat. We do not track your location in the background.</td></tr>
</table>

<h2>2. What we do not do</h2>
<ul>
  <li>We do not show advertising.</li>
  <li>We do not use advertising identifiers (IDFA) and do not ask for tracking permission.</li>
  <li>We do not include analytics or advertising SDKs.</li>
  <li>We do not sell or rent your personal data.</li>
  <li>We do not use your messages to build advertising or marketing profiles.</li>
</ul>

<h2>3. Encryption — what is and is not protected</h2>
<p>We want to be precise here rather than make a broad claim.</p>
<ul>
  <li><strong>One-to-one message bodies and attachments are encrypted on your device</strong>
      before they are stored, so our servers hold ciphertext rather than readable text.</li>
  <li><strong>This is not an audited end-to-end encryption system.</strong> Key management
      is still being hardened and has not been independently reviewed. Please do not rely
      on Inditalk for information whose disclosure would put you at serious risk.</li>
  <li><strong>Status updates are not encrypted this way.</strong> They are broadcast to your
      contacts, and their media is stored unencrypted.</li>
  <li><strong>Group chat bodies are not covered by the one-to-one encryption described above.</strong></li>
  <li><strong>Metadata is visible to the service</strong> — who is messaging or calling whom,
      and when — even where message bodies are encrypted.</li>
  <li>Calls use WebRTC and are encrypted in transit (SRTP/DTLS). When a direct connection
      cannot be made, media is relayed through a TURN server.</li>
</ul>

<h2>4. Service providers</h2>
<p>Inditalk runs on <strong>Google Firebase</strong> (Google LLC). Firebase provides phone
authentication, the database, file storage, push delivery and server functions, and
processes the data above on our behalf. See
<a href="https://firebase.google.com/support/privacy">Firebase&nbsp;privacy</a>. We also
operate a TURN relay server that carries call media when a direct peer-to-peer connection
is not possible; it relays encrypted media and does not store it.</p>

<h2>5. Retention</h2>
<ul>
  <li>Messages and attachments are retained until deleted by you, or until they expire if
      you turned on disappearing messages.</li>
  <li>Status updates are deleted automatically 24 hours after posting.</li>
  <li>Your profile and account data are retained while your account exists.</li>
  <li>Deleting your account removes your profile, keys, chat membership and stored files —
      see below.</li>
</ul>

<h2>6. Deleting your account and data</h2>
<p>You can delete your account from inside the app at any time:
<strong>Settings → Account → Delete Account</strong>. This deletes your account, removes
your profile, encryption keys, chat membership and uploaded files from our servers, and
wipes all Inditalk data stored on your device. It cannot be undone. Full steps are on the
<a href="/delete-account">account deletion page</a>. If you cannot access the app, email
<a href="mailto:{SUPPORT}">{SUPPORT}</a> from the phone number on the account.</p>
<p>Note that messages you already sent to other people remain on their devices, in the same
way that a sent SMS does.</p>

<h2>7. Your rights</h2>
<p>You can access and correct your profile in the app, delete your account and data as
described above, withdraw contacts, camera, microphone, photos, location or notification
permissions at any time in iOS Settings, and contact us at
<a href="mailto:{SUPPORT}">{SUPPORT}</a> to ask what we hold about you. Depending on where
you live, you may have additional rights under laws such as the GDPR or India's DPDP Act;
write to us and we will honour them.</p>

<h2>8. Children</h2>
<p>Inditalk is not intended for children under 13, and you must be old enough to consent to
this policy where you live. We do not knowingly collect data from children under 13. If you
believe a child has created an account, contact <a href="mailto:{SUPPORT}">{SUPPORT}</a> and
we will remove it.</p>

<h2>9. International transfers</h2>
<p>Our service providers operate globally, so your data may be processed in countries other
than your own, including the United States.</p>

<h2>10. Changes</h2>
<p>If we change this policy we will update the date at the top of this page, and we will
tell you in the app if the change is significant.</p>

<h2>11. Contact</h2>
<p>Privacy questions, data requests and complaints: <a href="mailto:{SUPPORT}">{SUPPORT}</a>.</p>
"""

TERMS = f"""
<h1>Terms of Service</h1>
<p class="updated">Last updated {UPDATED}</p>

<p>These terms are an agreement between you and <strong>{COMPANY}</strong>, {ADDRESS}
(“we”, “us”), which operates Inditalk. They govern your use of the Inditalk app. By
creating an account you agree to them. If you do not agree, do not use Inditalk.</p>

<h2>1. Who can use Inditalk</h2>
<p>You must be at least 13 years old, and old enough to form a binding contract where you
live. You need a working phone number to register.</p>

<h2>2. Your account</h2>
<p>You are responsible for the phone number and device used to access your account, and for
activity that happens through it. Tell us at <a href="mailto:{SUPPORT}">{SUPPORT}</a> if you
believe someone else has taken over your account.</p>

<h2>3. Your content</h2>
<p>You keep ownership of what you send. You grant us only the limited permission needed to
store and transmit your content so we can deliver it to the people you send it to. You are
responsible for what you send and for having the right to send it.</p>

<h2>4. Acceptable use</h2>
<p>You agree not to use Inditalk to do anything unlawful or harmful. This includes the
conduct listed in our <a href="/guidelines">Community Guidelines</a>, which forms part of
these terms. In particular, do not use Inditalk to harass or threaten people, to share
sexual content involving minors, to incite violence, to send spam or bulk unsolicited
messages, to impersonate others, to infringe copyright, or to attack or reverse-engineer
the service.</p>

<h2>5. Reporting and enforcement</h2>
<p>Anyone can report a contact or a group from inside the app, and can block any contact.
We review reports and may remove content, or suspend or terminate accounts that break these
terms or the Community Guidelines. Serious violations may be terminated without notice.</p>

<h2>6. Service availability</h2>
<p>Inditalk is provided as-is. We do not guarantee that it will always be available, that
messages or calls will always be delivered, or that it will be free of faults. Do not rely
on Inditalk for emergency communication — contact your local emergency services directly.</p>

<h2>7. Security</h2>
<p>We describe honestly in our <a href="/privacy">Privacy Policy</a> what Inditalk does and
does not encrypt. Inditalk has not undergone an independent security audit. Please read that
section before relying on the app for sensitive communication.</p>

<h2>8. Termination</h2>
<p>You can stop using Inditalk and delete your account at any time from
<strong>Settings → Account → Delete Account</strong>. We may suspend or end your access if
you break these terms.</p>

<h2>9. Disclaimers and liability</h2>
<p>To the maximum extent permitted by law, Inditalk is provided without warranties of any
kind, and we are not liable for indirect, incidental or consequential losses arising from
your use of the service. Nothing in these terms limits liability that cannot be limited by
law.</p>

<h2>10. Changes</h2>
<p>We may update these terms. We will change the date at the top of this page, and tell you
in the app if the change is significant. Continuing to use Inditalk after a change means you
accept the updated terms.</p>

<h2>11. Governing law</h2>
<p>These terms are governed by the laws of the State of Illinois and the United States,
without regard to conflict-of-law rules. Nothing here removes any protection you have
under the mandatory consumer law of the country you live in.</p>

<h2>12. Contact</h2>
<p>{COMPANY}, {ADDRESS}<br>
<a href="mailto:{SUPPORT}">{SUPPORT}</a></p>
"""

GUIDELINES = f"""
<h1>Community Guidelines</h1>
<p class="updated">Last updated {UPDATED}</p>

<p>Inditalk is for talking to people you know. These rules apply to everything you send:
messages, photos, videos, voice notes, group names and status updates.</p>

<h2>Not allowed</h2>
<ul>
  <li><strong>Content that sexualises minors.</strong> Zero tolerance. Accounts are removed
      immediately and reported to the appropriate authorities.</li>
  <li><strong>Harassment, bullying, threats or stalking</strong>, including coordinating
      others to target someone.</li>
  <li><strong>Hate speech</strong> — attacking people based on religion, caste, ethnicity,
      national origin, sex, gender identity, sexual orientation, disability or age.</li>
  <li><strong>Violent extremism or incitement to violence.</strong></li>
  <li><strong>Non-consensual intimate images</strong>, or sharing someone's private
      information without their permission.</li>
  <li><strong>Spam</strong> — bulk or automated unsolicited messaging, scams, phishing,
      or fraudulent financial schemes.</li>
  <li><strong>Impersonation</strong> of another person or organisation.</li>
  <li><strong>Illegal goods and services</strong>, including the sale of drugs, weapons or
      stolen data.</li>
  <li><strong>Content you do not have the right to share</strong>, including copyrighted
      material.</li>
</ul>

<h2>How to report</h2>
<p>Open the contact's profile, or a group's info screen, and tap <strong>Report</strong>.
Reports are sent to our safety team and include enough context to act on. You can also
email <a href="mailto:{SUPPORT}">{SUPPORT}</a>.</p>

<h2>How to block</h2>
<p>Open the contact's profile and tap <strong>Block</strong>. A blocked contact cannot send
you messages or call you, and is not told that you blocked them. You can unblock at any time
from <strong>Settings → Privacy → Blocked Contacts</strong>.</p>

<h2>What we do about reports</h2>
<div class="card">
  <p>We aim to review every report within <strong>24 hours</strong>. Depending on what we
  find we may remove content, warn the account, suspend it, or remove it permanently.
  Content that sexualises minors is actioned immediately and referred to the appropriate
  authorities.</p>
</div>
<p>If you believe we got a decision wrong, reply to us at
<a href="mailto:{SUPPORT}">{SUPPORT}</a> and we will look again.</p>

<h2>Emergencies</h2>
<p>If someone is in immediate danger, contact your local emergency services. We cannot
respond to emergencies.</p>
"""

HELP = f"""
<h1>Help &amp; Support</h1>
<p class="updated">Last updated {UPDATED}</p>

<div class="card">
  <p><strong>Contact us:</strong> <a href="mailto:{SUPPORT}">{SUPPORT}</a><br>
  We aim to reply within two working days, and to review safety reports within 24 hours.</p>
</div>

<h2>Getting started</h2>
<h3>Signing in</h3>
<p>Enter your phone number and tap <strong>Get started</strong>. We send a 6-digit code by
SMS; type it in to finish. There is no password.</p>

<h3>Finding people</h3>
<p>Allow contacts access and Inditalk will show which of your contacts already use the app.
You can also add someone by number, or scan their contact QR code from
<strong>Settings → your profile → the QR icon</strong>.</p>

<h2>Messaging</h2>
<ul>
  <li>Send photos, videos, voice notes, documents and your location from the <strong>+</strong>
      button in a chat.</li>
  <li>Swipe a message to reply to it; long-press for forward, star, copy and delete.</li>
  <li>Turn on <strong>disappearing messages</strong> from the chat's info screen.</li>
  <li>Search inside a conversation from the chat's info screen.</li>
</ul>

<h2>Calls</h2>
<p>Open a one-to-one chat or contact and tap the phone or video icon. Calls ring through iOS
itself, so they behave like ordinary calls. You can switch from voice to video during a
call. Group calling is not available yet.</p>

<h2>Notifications</h2>
<p>If you are not receiving notifications, check
<strong>iOS Settings → Inditalk → Notifications</strong>, and
<strong>Inditalk → Settings → Notifications</strong>.</p>

<h2>Privacy controls</h2>
<p><strong>Settings → Privacy</strong> lets you choose who can see your last seen, profile
photo, About text and read receipts, and shows your blocked contacts.</p>

<h2>Safety</h2>
<p>To report or block someone, open their profile and tap <strong>Report</strong> or
<strong>Block</strong>. See our <a href="/guidelines">Community Guidelines</a>.</p>

<h2>Deleting your account</h2>
<p>See <a href="/delete-account">how to delete your account</a>.</p>
"""

DELETE = f"""
<h1>Delete your Inditalk account</h1>
<p class="updated">Last updated {UPDATED}</p>

<p>You can delete your Inditalk account and its data from inside the app. You do not need to
contact us first.</p>

<h2>Steps</h2>
<ol>
  <li>Open <strong>Inditalk</strong>.</li>
  <li>Go to the <strong>You</strong> tab.</li>
  <li>Tap <strong>Account</strong>.</li>
  <li>Tap <strong>Delete Account</strong>.</li>
  <li>Type the confirmation shown on screen and confirm.</li>
</ol>

<h2>What gets deleted</h2>
<ul>
  <li>Your account and phone-number registration.</li>
  <li>Your profile — display name, About text and profile photo.</li>
  <li>Your encryption keys and chat membership.</li>
  <li>Files you uploaded, including attachments, status media and your profile photo.</li>
  <li>All Inditalk data stored on your device.</li>
</ul>

<h2>What does not get deleted</h2>
<p>Messages you already sent to other people remain on their devices, in the same way a sent
SMS does. We cannot remove those.</p>

<div class="card">
  <p>Deletion is permanent and cannot be undone. If your account is deleted, registering the
  same phone number again creates a new, empty account.</p>
</div>

<h2>If you cannot open the app</h2>
<p>Email <a href="mailto:{SUPPORT}">{SUPPORT}</a> from the phone number registered to the
account, and we will delete it for you.</p>
"""

NOT_FOUND = """
<h1>Page not found</h1>
<p class="lead">That page does not exist.</p>
<p><a href="/">Go to the Inditalk home page</a></p>
"""


def main():
    pages = [
        ("Inditalk — private messaging and calls", "Inditalk is a private messenger for texting, voice and video calls.", HOME, "/"),
        ("Privacy Policy", "What Inditalk collects, why, and how to delete your data.", PRIVACY, "/privacy"),
        ("Terms of Service", "The terms that govern your use of Inditalk.", TERMS, "/terms"),
        ("Community Guidelines", "What is not allowed on Inditalk, and how to report it.", GUIDELINES, "/guidelines"),
        ("Help & Support", "How to use Inditalk and how to contact support.", HELP, "/help"),
        ("Delete your account", "How to delete your Inditalk account and data.", DELETE, "/delete-account"),
    ]
    for title, desc, body, path in pages:
        print("wrote", page(title, desc, body, path))

    # Aliases people (and reviewers) commonly try.
    for alias, target in [("/support", "/help"), ("/community-guidelines", "/guidelines")]:
        os.makedirs(os.path.join(OUT, alias.strip("/")), exist_ok=True)
        with open(os.path.join(OUT, alias.strip("/"), "index.html"), "w") as f:
            f.write(f'<!doctype html><meta charset="utf-8">'
                    f'<meta http-equiv="refresh" content="0;url={target}">'
                    f'<link rel="canonical" href="{target}">'
                    f'<title>Redirecting…</title>'
                    f'<p>Redirecting to <a href="{target}">{target}</a>.</p>')
        print("wrote alias", alias, "->", target)

    with open(os.path.join(OUT, "404.html"), "w") as f:
        nav = "".join(f'<a href="{h}">{l}</a>' for l, h in NAV)
        f.write(f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Not found · Inditalk</title>
<style>{CSS}</style></head><body><div class="wrap">
<header class="site"><div class="logo">I</div><a class="brand" href="/">Inditalk</a><nav>{nav}</nav></header>
{NOT_FOUND}</div></body></html>""")
    print("wrote", os.path.join(OUT, "404.html"))


if __name__ == "__main__":
    main()
