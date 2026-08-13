"""Legal-consent versioning for Aluta.

A single monotonically-increasing integer, ``CURRENT_POLICY_VERSION``, covers
BOTH the Privacy Policy and the Terms of Use (they are always accepted together).
Every user row stores the highest version they've accepted (see
``User.policy_version``). When this constant is bumped, every user's accepted
version becomes "behind", so the app re-prompts them to read the updated
documents and tick to agree before they can continue.

To publish an update:
  1. Edit ``legal/privacy.html`` and/or ``legal/terms.html``.
  2. Bump ``CURRENT_POLICY_VERSION`` by one and update ``POLICY_EFFECTIVE_DATE``.
  3. Add a short, human "what changed" line to ``POLICY_SUMMARY`` for the new
     version — returning users see it in the re-consent prompt.
  4. Redeploy. Every user is prompted on next launch; new users are prompted at
     first launch. Nothing else to do.
"""

# Bump this (and the date) whenever the policy or terms materially change.
CURRENT_POLICY_VERSION = 1
POLICY_EFFECTIVE_DATE = "13 August 2026"

# The docs are served by the API itself (see main.py), so the client only needs
# the paths; it prefixes them with the API origin. Kept relative so the same
# build works across dev/staging/prod hosts.
PRIVACY_PATH = "/privacy"
TERMS_PATH = "/terms"

# A short, plain-language note shown to a returning user when they must
# re-accept — i.e. "what changed" for the version they're being asked to accept.
# Keyed by the version being accepted. Version 1 is the first formal consent.
POLICY_SUMMARY = {
    1: (
        "Please review and accept Aluta's Privacy Policy and Terms of Use to "
        "continue. They explain what data Aluta handles (note: messages and "
        "media are not end-to-end encrypted in this beta build), the third-party "
        "services it uses, and the rules for using the app."
    ),
}


def summary_for(version: int) -> str:
    """The 'what changed' blurb for a given policy version, falling back to the
    current version's summary if that specific version has no note recorded."""
    return POLICY_SUMMARY.get(version, POLICY_SUMMARY[CURRENT_POLICY_VERSION])
