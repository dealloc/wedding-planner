# Module: Authentication

## Purpose
Shield the app from the internet with minimal friction for two users on multiple devices. Passkeys only; no passwords, no email, no third-party identity provider.

## Rules

- **AUTH-01** Every page and endpoint MUST require an authenticated session, except the passkey login page, the enrollment page reached via a valid link, and the one-time setup page (AUTH-03).
- **AUTH-02** Authentication MUST use WebAuthn passkeys. There are no passwords.
- **AUTH-03 Bootstrap.** When no user exists, the app accepts a one-time **setup token** supplied through application configuration (environment variable). It is **not** generated or printed by the app: an operator-supplied value means the token survives a restart and never lands in the logs of a public-facing machine. If the variable is unset and no user exists, the app starts and serves only a page saying so. The token MUST be at least 32 characters; it has no expiry of its own, because it stops working the moment the first user exists. Using it creates the first user and registers their first passkey. Once any user exists, the setup flow MUST be permanently disabled.
- **AUTH-04 Device enrollment link.** An authenticated user can generate an enrollment link for **their own account**. Opening it on another device lets that device register an additional passkey for the same user.
- **AUTH-05 User invitation link.** An authenticated user can generate an enrollment link that **creates a new user** (with a display name chosen at creation) and registers that user's first passkey.
- **AUTH-06** Enrollment links MUST be single-use, MUST expire (default 15 minutes), and MUST be shown both as a copyable URL and as a QR code.
- **AUTH-07** Unused links can be revoked by any user before expiry.
- **AUTH-08 Device management.** Each user sees their registered passkeys with a user-editable name ("Wannes' phone"), registration date and last-used date, and can revoke any of them. A user MUST NOT be able to revoke their last remaining passkey from the UI.
- **AUTH-09 Recovery.** An operator command run on the server (e.g. a release command) MUST be able to generate an enrollment link for an existing user, for the case where all their devices are lost.
- **AUTH-10** Sessions last 30 days and are extended on use (sliding expiry).
- **AUTH-11** Enrollment link creation, passkey registration and revocation MUST be recorded in the activity log.

## Acceptance criteria

- Given no users exist, when the app starts, then only the setup flow is reachable and it requires the setup token.
- Given a user is logged in on a laptop, when they generate a device link and scan the QR code with a phone, then the phone registers a passkey and can log in as the same user.
- Given an enrollment link was used once, when it is opened again, then it is rejected.
- Given an enrollment link is older than its expiry, when opened, then it is rejected.
