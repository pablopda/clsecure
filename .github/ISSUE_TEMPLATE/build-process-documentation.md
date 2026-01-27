---
name: Build Process Documentation
about: Document the build/compilation process for contributors
title: '[DOCS] Document build process workflow'
labels: documentation, build
assignees: ''
---

## Overview

Document the build process for **clsecure** to help contributors understand:
- Why we have a build step
- How the build process works
- When to rebuild
- How to troubleshoot build issues

## Documentation Needed

### 1. Contributor Guide
- [ ] Add build process to `CONTRIBUTING.md`
- [ ] Explain why we build (modular → single-file)
- [ ] Document pre-commit hook behavior
- [ ] Add troubleshooting section

### 2. Developer Documentation
- [ ] Update `CLAUDE.md` with build details
- [ ] Document build script internals
- [ ] Explain module dependency order
- [ ] Document export handling

### 3. User Documentation
- [ ] Update `README.md` with build info (if needed)
- [ ] Explain that `clsecure` is generated
- [ ] Document how to build from source (optional)

### 4. Build Script Documentation
- [ ] Add inline comments to `build.sh`
- [ ] Document awk script logic
- [ ] Explain heredoc handling
- [ ] Document export filtering

## Current Documentation

- ✅ `BUILD-WORKFLOW.md` - Comprehensive workflow guide
- ✅ `CLAUDE.md` - Development guidelines (includes build process)
- ⚠️ `CONTRIBUTING.md` - Missing build process details
- ⚠️ `README.md` - Could mention build process

## Proposed Structure

```
docs/
├── BUILD-WORKFLOW.md          # Detailed workflow (exists)
├── BUILD-TROUBLESHOOTING.md    # Common issues and fixes
└── BUILD-INTERNALS.md          # Technical details of build.sh
```

## Key Points to Document

1. **Why Build?**
   - Modular development vs single-file distribution
   - Backwards compatibility
   - User convenience

2. **How to Build**
   - Manual: `./build.sh`
   - Automatic: Pre-commit hook
   - CI/CD: GitHub Actions

3. **When to Build**
   - After editing `clsecure-src`
   - After editing `lib/*.sh`
   - Before committing

4. **Troubleshooting**
   - Build fails: Check syntax
   - Pre-commit fails: Rebuild manually
   - Exports missing: Check build.sh filters

## Acceptance Criteria

- [ ] All build-related docs are complete
- [ ] Contributors can understand the process
- [ ] Troubleshooting guide exists
- [ ] Examples are provided
- [ ] Links between docs are clear
