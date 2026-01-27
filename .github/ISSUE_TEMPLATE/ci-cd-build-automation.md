---
name: CI/CD Build Automation
about: Automate build process with GitHub Actions
title: '[CI/CD] Automate build process with GitHub Actions'
labels: enhancement, ci-cd, build
assignees: ''
---

## Goal

Automate the build process using GitHub Actions to:
- Eliminate manual rebuild steps
- Verify builds on every push/PR
- Generate release artifacts automatically
- Ensure build consistency

## Current State

- ✅ Pre-commit hook verifies builds locally
- ✅ Build script (`build.sh`) works correctly
- ⚠️ Manual rebuild required before commits
- ⚠️ No CI/CD verification

## Proposed Solution

### GitHub Actions Workflow

Create `.github/workflows/build.yml`:

```yaml
name: Build and Verify

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main, develop ]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Build clsecure
        run: ./build.sh
      
      - name: Verify build consistency
        run: |
          if git diff --quiet clsecure; then
            echo "✅ Build is consistent"
          else
            echo "❌ Build is out of sync"
            git diff clsecure
            exit 1
          fi
      
      - name: Syntax check
        run: bash -n clsecure
      
      - name: Functional test
        run: ./clsecure --help
```

### Release Workflow

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  release:
    types: [created]

jobs:
  build-release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Build clsecure
        run: ./build.sh
      
      - name: Create release artifact
        run: |
          tar czf clsecure-${GITHUB_REF#refs/tags/}.tar.gz clsecure
          sha256sum clsecure-${GITHUB_REF#refs/tags/}.tar.gz > clsecure-${GITHUB_REF#refs/tags/}.tar.gz.sha256
      
      - name: Upload artifacts
        uses: actions/upload-artifact@v3
        with:
          name: clsecure-release
          path: clsecure-*.tar.gz*
```

## Benefits

1. **Automated Verification**
   - Builds verified on every push
   - PRs checked automatically
   - No manual rebuild needed

2. **Release Automation**
   - Builds created automatically
   - Release artifacts generated
   - Checksums provided

3. **Consistency**
   - Ensures `clsecure` matches source
   - Catches build issues early
   - Reduces manual errors

## Implementation Steps

- [ ] Create `.github/workflows/build.yml`
- [ ] Create `.github/workflows/release.yml`
- [ ] Test workflows on test branch
- [ ] Update documentation
- [ ] Consider removing built file from repo (CI-only builds)

## Alternative: CI-Only Builds

If we move to CI-only builds:
- ✅ Cleaner git history
- ✅ No manual rebuilds
- ⚠️ Users need to download from releases
- ⚠️ No direct file download from repo

## Acceptance Criteria

- [ ] Build workflow runs on push/PR
- [ ] Release workflow creates artifacts
- [ ] Builds are verified automatically
- [ ] Documentation updated
- [ ] Workflows tested and working

## Related Issues

- Build process documentation
- Build script enhancements
- Release process improvements
