# Contributing to clsecure

First off, thank you for considering contributing to clsecure! It's people like you that make this tool better for everyone.

## Where to Start

- **Bugs & Issues:** If you find a bug, please check the existing issues to see if it has already been reported. If not, open a new issue using the provided templates.
- **Feature Requests:** Have an idea to make clsecure better? Open an issue to discuss it before writing code.
- **Pull Requests:** Ready to contribute code? Great! See the workflow below.

## Development Workflow

clsecure uses a modular architecture for maintainability:
- `clsecure-src` is the main script (for development)
- `lib/` contains modules
- `build.sh` assembles the final `clsecure` script
- `tests/` contains BATS tests

1. **Fork & Clone:** Fork the repository and clone it locally.
2. **Branch:** Create a new branch for your feature or bugfix (`git checkout -b feature/my-new-feature`).
3. **Edit Modules:** Modify `clsecure-src` and files in `lib/`. Keep modules focused and under 300 lines.
4. **Follow Guidelines:**
   - Follow bash best practices (`set -euo pipefail`).
   - Use the logging functions (`log_info`, `log_warn`, etc.).
5. **Rebuild:** Run `./build.sh` to regenerate the single-file `clsecure` script.
6. **Test:** Run `./run_tests.sh` to execute unit tests. Please add tests for new functionality.
7. **Commit:** Commit your changes with a clear commit message.
8. **Push & PR:** Push to your fork and submit a Pull Request.

## Code of Conduct

Please note that this project is released with a [Contributor Code of Conduct](CODE_OF_CONDUCT.md). By participating in this project you agree to abide by its terms.