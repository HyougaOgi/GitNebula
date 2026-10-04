# Contributing to GitNebula

## Getting started

Use the platform guide linked from the README. Keep native implementations in `Mac/`, `Linux/`, and `Windows/`; share behavioral specifications in `shared/` rather than introducing a common GUI runtime.

Before submitting a pull request:

1. Describe the user-visible problem and the behavior after the change.
2. Add an integration test for Git state transitions, using temporary repositories and local remotes.
3. Run the relevant native build and test commands. State any platforms you could not test.
4. Preserve unrelated staged changes, local files, and existing Git configuration.
5. Update platform documentation when installation or behavior changes.

Keep destructive actions explicit and confirmed in the GUI. Pass Git arguments as argument arrays, never interpolated shell commands. Do not disable certificate verification, run force pushes, or change global Git settings in application workflows.

## Reporting issues

Include the application revision, operating system, Git version, reproduction steps, and expected result. Remove credentials, private repository URLs, and private file contents from logs and screenshots. For security-sensitive issues, see SECURITY.md.

## Release maintenance

Package scripts live in each platform folder. Signing identities remain in the OS keychain, certificate store, or GPG keyring. Release artifacts, local environment files, and private keys are ignored by Git. Publish source code and license information alongside distributed binaries as required by the GPL.
