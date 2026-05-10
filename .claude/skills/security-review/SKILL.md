---
name: security-review
description: Security-focused code review of pending changes on current branch
allowed-tools:
  - Bash(git diff:*)
  - Bash(git status:*)
  - Bash(git log:*)
  - Bash(git show:*)
  - Read
  - Glob
  - Grep
when_to_use: "Use when the user asks for a security review, security audit of code changes, or before merging sensitive changes. Examples: '/security-review', 'review security', 'audit this PR for vulns'."
context: fork
---

# Security Review

Security-focused code review of pending changes on the current branch.
Derived from Anthropic's security-review-slash-command, adapted for LCARS.

---

## Goal

Identify HIGH-CONFIDENCE security vulnerabilities in the diff. Not a general code review — security only. Minimize false positives.

---

## Steps

### 1. Collect context

```bash
git status
git diff --name-only origin/HEAD...
git log --no-decorate origin/HEAD...
git diff origin/HEAD...
```

**Success criteria**: diff content available for analysis.

### 2. Analyze for security vulnerabilities

Categories to examine:

**Input validation** : SQL injection, command injection, XXE, template injection, path traversal
**Auth/authz** : authentication bypass, privilege escalation, session flaws, JWT issues
**Data exposure** : sensitive data in logs/responses/errors, PII leaks, credential exposure
**Crypto** : weak algorithms, hardcoded secrets, insecure random, improper TLS
**Infrastructure** : SSRF, insecure deserialization, unsafe file ops, race conditions
**Shell-specific (LCARS)** : unquoted variables in commands, eval on user input, world-writable files, missing input validation on IPC messages, sudo escalation paths

Only flag issues with >80% confidence of actual exploitability.

**Exclusions** :
- Denial of Service (handled by infrastructure)
- Secrets on disk (handled by check-secrets hook)
- Rate limiting / resource exhaustion
- Style or quality concerns

**Success criteria**: each finding has file:line, category, impact, and fix.

### 3. Report

Format:

```
## Security Review — <branch>

**Files reviewed**: N
**Findings**: N (CRITICAL: N, HIGH: N, MEDIUM: N)

### [SR-001] CRITICAL — <title>
File: `path/to/file.sh:42`
Category: command injection
Impact: <what an attacker can do>
Fix: <specific remediation>
Evidence: <code snippet>

### No findings
If clean: "No high-confidence security vulnerabilities found in this diff."
```

**Success criteria**: structured report, actionable findings only.
