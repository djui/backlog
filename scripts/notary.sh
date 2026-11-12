# Sourced by the release scripts: sets notary_args for `xcrun notarytool submit`.
# Uses the keychain profile in NOTARY_PROFILE when it works, else the App Store Connect API key in
# ~/.appstoreconnect (private_keys/AuthKey_<id>.p8 and issuer_id) — no keychain item needed.
notary_args=()
if [[ -n "${NOTARY_PROFILE:-}" ]] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  notary_args=(--keychain-profile "$NOTARY_PROFILE")
else
  key="$(ls ~/.appstoreconnect/private_keys/AuthKey_*.p8 2>/dev/null | head -1)"
  issuer="$(cat ~/.appstoreconnect/issuer_id 2>/dev/null || true)"
  if [[ -n "$key" && -n "$issuer" ]]; then
    key_id="$(basename "$key" .p8)"; key_id="${key_id#AuthKey_}"
    notary_args=(--key "$key" --key-id "$key_id" --issuer "$issuer")
  fi
fi
