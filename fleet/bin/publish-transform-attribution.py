# SOURCE: bin/publish-transform-attribution.py
# ruff: noqa: F821  # `commit` est libre ICI : filter-repo l'injecte (cf. l'encadre ci-dessous).
# AUTHOR: DrDree
# STARDATE: 2026-07-07
# STATUS: PROTO-V1 — the --commit-callback body of publish-transform.sh
#
# ⚠ NOT A SCRIPT, AND IT WILL NOT RUN ON ITS OWN. git-filter-repo reads this file
# (`--commit-callback FILE`), indents every line by two spaces and execs it as the body of
# `def callback(commit, ...)`. So: no shebang, no `if __name__`, top level only — and `commit`
# is free here, supplied by filter-repo.
#
# The 4 values cross through the ENVIRONMENT and not through the caller's string: an author name is
# UNCONTROLLED data (git log %cn), and interpolating one that holds an apostrophe used to produce
# invalid Python and an opaque filter-repo SyntaxError. `os.environb` also yields the exact bytes,
# so non-UTF-8 names survive.
import re
import os

VENDOR_NAME = os.environb[b"LCARS_PUB_VENDOR_NAME"]
VENDOR_EMAIL = os.environb[b"LCARS_PUB_VENDOR_EMAIL"]
HUMAN_NAME = os.environb[b"LCARS_PUB_HUMAN_NAME"]
HUMAN_EMAIL = os.environb[b"LCARS_PUB_HUMAN_EMAIL"]


# INTERNAL IS THE DOMAIN, not one address, and CASE-FOLDED: this must ask the SAME question the
# certification asks. A narrower test here sends survivors straight into the refusal — blocked,
# never leaked, but with a clone the script itself is unable to clean.
def internal(email):
    return email.lower().endswith(b"@lcars.local")


# ⚠ BOTH SIDES ARE READ BEFORE EITHER IS WRITTEN. Testing the LIVE `commit.author_email` below would
# read a side the first block may already have rewritten, and take the branch meaning "external
# author" on a commit where that is false.
author_was_internal = internal(commit.author_email)
committer_was_internal = internal(commit.committer_email)

if author_was_internal:
    if not committer_was_internal:
        commit.author_name = commit.committer_name
        commit.author_email = commit.committer_email
    else:
        commit.author_name = HUMAN_NAME
        commit.author_email = HUMAN_EMAIL

if committer_was_internal:
    if not author_was_internal:
        # Falling back to the repo-wide human here would attribute the commit to somebody else.
        commit.committer_name = commit.author_name
        commit.committer_email = commit.author_email
    else:
        commit.committer_name = HUMAN_NAME
        commit.committer_email = HUMAN_EMAIL

# THE DOMAIN HERE TOO: the address inside the angle brackets is the fact, the name is not. Anchoring
# on a `LCARS-` prefix would bet on the commit gate always shaping the trailer that way.
commit.message = re.sub(
    rb"Co-authored-by:\s*[^<\n]*<[^>]+@lcars\.local>",
    b"Co-Authored-By: " + VENDOR_NAME + b" <" + VENDOR_EMAIL + b">",
    commit.message,
    flags=re.IGNORECASE,
)
