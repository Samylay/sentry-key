# Contributing to SentryKey

These rules come from the project brief. They are part of the grade, so follow them on every change.

## Workflow

1. Never push directly to `main`. Work on a branch named `feature/...`, `fix/...` or `docs/...`.
2. Open a pull request and fill in the checklist from the template.
3. **A human teammate other than the author reviews and approves every merge.**
4. Security-related code (crypto, pairing, policy, key storage) needs tests before it is merged.

## Using AI

**Allowed:** generating code, tests and docs; refactoring and explaining code; exploring unfamiliar APIs; drafting the threat model.

**Mandatory:**
- Log every prompt in [`docs/PROMPT_JOURNAL.md`](docs/PROMPT_JOURNAL.md), including ones whose output you threw away.
- Read and understand every line before committing it. Everyone must be able to explain the whole codebase at the oral.
- Test all security code.

**Forbidden:**
- Pasting secrets, private keys or real personal data into a prompt.
- Merging crypto code that has not been reviewed line by line.
- Adding a dependency that has not been vetted. AI tools sometimes invent package names, and attackers register them.
- Submitting work you cannot explain.

## Common pitfalls in AI-generated code

Check every AI-generated change for these:

- Hard-coded secrets or keys
- Outdated crypto: MD5, ECB mode, fixed IVs, non-cryptographic randomness
- Invented or unvetted dependencies
- Network input used without validating its format and size
- Logs that print tokens, keys, host names or locations
- "It compiles" is not "it's secure"

## Commits

- Use short, imperative messages: `Add QR pairing screen`, `Fix nonce reuse in channel`.
- If AI generated a significant part of a commit, reference the prompt journal entry in the message, for example `(prompt P-012)`.
