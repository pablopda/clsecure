# GitHub Issues - Next Tasks

This document tracks planned improvements and tasks for the clsecure project.

## Build Process Improvements

### 🔨 Build Process Documentation
**Issue**: Document the build/compilation workflow for contributors

**Status**: Ready to create
**Priority**: Medium
**Template**: `.github/ISSUE_TEMPLATE/build-process-documentation.md`

**Tasks**:
- [ ] Add build process to `CONTRIBUTING.md`
- [ ] Document pre-commit hook behavior
- [ ] Add troubleshooting section
- [ ] Create `BUILD-TROUBLESHOOTING.md`

### 🤖 CI/CD Build Automation
**Issue**: Automate build process with GitHub Actions

**Status**: Ready to create
**Priority**: High
**Template**: `.github/ISSUE_TEMPLATE/ci-cd-build-automation.md`

**Tasks**:
- [ ] Create `.github/workflows/build.yml`
- [ ] Create `.github/workflows/release.yml`
- [ ] Test workflows
- [ ] Update documentation

### ⚙️ Build Script Enhancements
**Issue**: Improve build.sh with better UX and features

**Status**: Ready to create
**Priority**: Low
**Template**: `.github/ISSUE_TEMPLATE/build-process-improvements.md`

**Tasks**:
- [ ] Add `--dry-run` flag
- [ ] Add `--verify` flag
- [ ] Add version/commit hash to built file
- [ ] Improve error messages

## How to Create Issues

### Using GitHub Web Interface

1. Go to the repository
2. Click "Issues" → "New Issue"
3. Select a template:
   - `build-process-documentation.md` - For documenting build process
   - `ci-cd-build-automation.md` - For CI/CD automation
   - `build-process-improvements.md` - For build script enhancements
   - `bug_report.md` - For bug reports
   - `feature_request.md` - For feature requests

### Using GitHub CLI

```bash
# Create issue from template
gh issue create \
  --title "[DOCS] Document build process workflow" \
  --body-file .github/ISSUE_TEMPLATE/build-process-documentation.md \
  --label documentation,build

# Create CI/CD issue
gh issue create \
  --title "[CI/CD] Automate build process with GitHub Actions" \
  --body-file .github/ISSUE_TEMPLATE/ci-cd-build-automation.md \
  --label enhancement,ci-cd,build
```

## Current Build Process Status

✅ **Working:**
- Build script (`build.sh`) functional
- Pre-commit hook installed
- Build workflow documented (`BUILD-WORKFLOW.md`)

⚠️ **Needs Improvement:**
- Manual rebuild step required
- No CI/CD automation
- Build process not in `CONTRIBUTING.md`

## Next Steps

1. **Create GitHub Issues** using the templates
2. **Prioritize** based on project needs
3. **Implement** CI/CD automation (highest priority)
4. **Document** build process for contributors

## Related Documentation

- `BUILD-WORKFLOW.md` - Current build workflow
- `CLAUDE.md` - Development guidelines
- `.github/workflows/test.yml` - Existing CI/CD workflow
