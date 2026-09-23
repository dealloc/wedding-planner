defmodule WeddingPlannerWeb.Live.PasskeyCeremony do
  @moduledoc """
  The browser half of both WebAuthn ceremonies (`AUTH-02`) — task 13. This module owns
  only the client boundary: a colocated JS hook that speaks `navigator.credentials` and
  the base64url encoding WebAuthn requires, plus the function component that renders it.

  It has no server-side ceremony logic of its own. Tasks 14 (setup) and 15 (login) are the
  callers: they hold the `%Wax.Challenge{}` in a LiveView assign (never a cookie, per
  `WeddingPlanner.Accounts.WebAuthn`'s moduledoc), call `WeddingPlanner.Accounts.WebAuthn`'s
  `begin_*`/`finish_*` functions, and wire the events documented below. This module never
  calls `WeddingPlanner.Accounts.WebAuthn` itself — it only carries bytes across the wire in
  the exact shapes that module's docs specify.

  ## Rendering it

  Render `ceremony/1` once per LiveView that needs passkey ceremonies, with a unique DOM id:

      <PasskeyCeremony.ceremony id="passkey-ceremony" />

  The element itself is invisible (`hidden`) — it exists only to host `phx-hook`.

  ## The event contract

  ### Server → client (`push_event/3`)

  The host LiveView starts a ceremony by calling the matching `begin_*` function from
  `WeddingPlanner.Accounts.WebAuthn` and pushing its `options` map verbatim — no
  transformation needed, since `begin_registration/1` and `begin_authentication/0` already
  return base64url-encoded, JS-ready maps:

    * `"passkey:create"` — payload is the `options` map from `WebAuthn.begin_registration/1`
      (`challenge`, `rp`, `user`, `pubKeyCredParams`, `authenticatorSelection`, `attestation`,
      `timeout`, `excludeCredentials`). Triggers `navigator.credentials.create()`.
    * `"passkey:get"` — payload is the `options` map from `WebAuthn.begin_authentication/0`
      (`challenge`, `rpId`, `userVerification`, `timeout`, and deliberately **no**
      `allowCredentials` key — the hook only decodes it if present, so the usernameless flow
      needs nothing special). Triggers `navigator.credentials.get()`.

  Remember to rebind/return the socket after `push_event/3`, per `AGENTS.md`.

  ### Client → server (`this.pushEvent`)

  On success, the hook re-encodes the browser's response as base64url and pushes it back in
  **exactly** the shape `WebAuthn.finish_registration/4` / `WebAuthn.finish_authentication/3`
  expect as `params` — the host can hand the event payload straight to those functions with
  no reshaping:

    * `"passkey:registration-success"`:

          %{"rawId" => "...", "response" => %{
            "attestationObject" => "...",
            "clientDataJSON" => "...",
            "transports" => ["internal", "hybrid", ...]
          }}

    * `"passkey:authentication-success"`:

          %{"rawId" => "...", "response" => %{
            "authenticatorData" => "...",
            "clientDataJSON" => "...",
            "signature" => "...",
            "userHandle" => "..." | nil
          }}

  Failure is split into three events so the host can give each a different tone, per
  `.claude/design/ui-decisions.md` §3 ("calm, non-alarming" cancellation vs. a real error):

    * `"passkey:cancelled"` — payload `%{}`. Sent when the browser reports
      `NotAllowedError`, which covers both the user dismissing the prompt and the ceremony
      timing out. **Not** a failure worth alarming the user over — the host should reset its
      UI quietly (no flash) rather than show an error.
    * `"passkey:unsupported"` — payload `%{}`. Sent once, on mount, when
      `window.PublicKeyCredential` does not exist (no WebAuthn support at all), and again
      defensively if a ceremony is somehow triggered afterwards. The host **should** show a
      user-facing flash here — this is not a transient blip, the browser cannot do passkeys.
    * `"passkey:error"` — payload `%{"message" => "..."}`, a short, human-readable string
      (not a raw `DOMException` name). Sent for every other failure (no authenticator
      attached, origin mismatch, the device can't verify the user, etc). The host should show
      this as a flash, using the message directly.

  ## Safari

  Out of scope per `.claude/tasks/13-webauthn-client-hook.md` and the DR-4 spike's findings:
  neither user has an iPhone or uses Safari, so no user-gesture workaround is implemented.
  """

  use Phoenix.Component

  @doc """
  Renders the invisible element that hosts the passkey colocated hook.

  Give it a unique DOM id, as required for `phx-hook`. Render it at most once per
  LiveView — one hook instance handles both ceremonies, one at a time.
  """
  attr :id, :string, default: "passkey-ceremony"

  def ceremony(assigns) do
    ~H"""
    <div id={@id} phx-hook=".PasskeyCeremony" hidden></div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PasskeyCeremony">
      // base64url (the `-`/`_` alphabet, no padding) <-> ArrayBuffer. Every WebAuthn
      // binary field (challenge, user.id, credential ids, attestationObject,
      // clientDataJSON, authenticatorData, signature, userHandle) crosses the wire as one
      // of these strings, never standard base64.
      const b64urlToBuffer = (value) => {
        const padded = value.replace(/-/g, "+").replace(/_/g, "/")
        const raw = atob(padded + "=".repeat((4 - padded.length % 4) % 4))
        const bytes = new Uint8Array(raw.length)
        for (let i = 0; i < raw.length; i++) { bytes[i] = raw.charCodeAt(i) }
        return bytes.buffer
      }

      const bufferToB64url = (buffer) => {
        const bytes = new Uint8Array(buffer)
        let raw = ""
        for (let i = 0; i < bytes.length; i++) { raw += String.fromCharCode(bytes[i]) }
        return btoa(raw).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
      }

      // DOMException.name is the only reliable discriminator across browsers; .message is
      // browser-specific and sometimes deliberately vague for privacy.
      const describe = (error) => {
        switch (error.name) {
          case "InvalidStateError":
            return "This device already has a passkey for this account."
          case "NotSupportedError":
            return "This device cannot create the kind of passkey we need."
          case "SecurityError":
            return "The page origin does not match the passkey domain."
          case "AbortError":
            return "The request was aborted."
          case "ConstraintError":
            return "This device cannot verify you (no PIN, fingerprint or face set up)."
          default:
            return `${error.name}: ${error.message}`
        }
      }

      export default {
        mounted() {
          this.abort = null
          this.supported = !!window.PublicKeyCredential

          if (!this.supported) {
            this.pushEvent("passkey:unsupported", {})
          }

          this.handleEvent("passkey:create", async (options) => {
            if (!this.supported) {
              this.pushEvent("passkey:unsupported", {})
              return
            }

            try {
              const publicKey = {
                ...options,
                challenge: b64urlToBuffer(options.challenge),
                user: {...options.user, id: b64urlToBuffer(options.user.id)},
              }

              if (Array.isArray(options.excludeCredentials)) {
                publicKey.excludeCredentials = options.excludeCredentials.map((c) => (
                  {...c, id: b64urlToBuffer(c.id)}
                ))
              }

              this.abort = new AbortController()
              const credential = await navigator.credentials.create({
                publicKey,
                signal: this.abort.signal,
              })

              this.pushEvent("passkey:registration-success", {
                rawId: bufferToB64url(credential.rawId),
                response: {
                  attestationObject: bufferToB64url(credential.response.attestationObject),
                  clientDataJSON: bufferToB64url(credential.response.clientDataJSON),
                  transports: credential.response.getTransports
                    ? credential.response.getTransports()
                    : [],
                },
              })
            } catch (error) {
              if (error.name === "NotAllowedError") {
                this.pushEvent("passkey:cancelled", {})
              } else {
                this.pushEvent("passkey:error", {message: describe(error)})
              }
            }
          })

          this.handleEvent("passkey:get", async (options) => {
            if (!this.supported) {
              this.pushEvent("passkey:unsupported", {})
              return
            }

            try {
              const publicKey = {
                ...options,
                challenge: b64urlToBuffer(options.challenge),
              }

              // Deliberately omitted unless the server sends one: a usernameless login
              // (WebAuthn.begin_authentication/0) sends no allowCredentials at all, and
              // an empty/absent list both mean "let the authenticator offer whatever
              // discoverable credentials it has."
              if (Array.isArray(options.allowCredentials)) {
                publicKey.allowCredentials = options.allowCredentials.map((c) => (
                  {...c, id: b64urlToBuffer(c.id)}
                ))
              }

              this.abort = new AbortController()
              const assertion = await navigator.credentials.get({
                publicKey,
                signal: this.abort.signal,
              })

              this.pushEvent("passkey:authentication-success", {
                rawId: bufferToB64url(assertion.rawId),
                response: {
                  authenticatorData: bufferToB64url(assertion.response.authenticatorData),
                  clientDataJSON: bufferToB64url(assertion.response.clientDataJSON),
                  signature: bufferToB64url(assertion.response.signature),
                  userHandle: assertion.response.userHandle
                    ? bufferToB64url(assertion.response.userHandle)
                    : null,
                },
              })
            } catch (error) {
              if (error.name === "NotAllowedError") {
                this.pushEvent("passkey:cancelled", {})
              } else {
                this.pushEvent("passkey:error", {message: describe(error)})
              }
            }
          })
        },

        destroyed() {
          // A pending ceremony outliving the LiveView (e.g. navigating away mid-prompt)
          // would otherwise leave a dangling platform modal on screen.
          if (this.abort) { this.abort.abort() }
        },
      }
    </script>
    """
  end
end
