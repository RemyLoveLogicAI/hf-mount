```markdown
# hf-mount Development Patterns

> Auto-generated skill from repository analysis

## Overview
This skill provides guidance for contributing to the `hf-mount` Rust codebase. It covers coding conventions, commit patterns, documentation workflows, and testing practices observed in the repository. By following these patterns, contributors can ensure consistency and maintainability across the project.

## Coding Conventions

### File Naming
- Use **PascalCase** for file names.
  - **Example:** `MyModule.rs`, `FileSystem.rs`

### Imports
- Use **relative imports** within modules.
  - **Example:**
    ```rust
    mod utils;
    use crate::utils::FileHelper;
    ```

### Exports
- Use **named exports** for module items.
  - **Example:**
    ```rust
    pub struct MountOptions { /* ... */ }
    pub fn mount() { /* ... */ }
    ```

### Commit Messages
- Follow **conventional commit** style.
- Use prefixes like `fix`, `test`.
  - **Example:**  
    ```
    fix: resolve panic when mounting empty directory
    test: add unit tests for MountOptions parser
    ```

## Workflows

### update-readme-and-related-docs
**Trigger:** When someone updates features, fixes bugs, or adds new functionality that requires documentation changes.  
**Command:** `/update-docs`

1. Edit implementation or test files as needed to reflect code changes.
2. Update `README.md` to document the latest changes.
3. Update related documentation files in `_docs/`:
    - `_docs/README.md`
    - `_docs/DEPENDENCIES.md`
    - `_docs/src/README.md`
    - `_docs/src/setup.rs.md`
4. Fix references and ensure all documentation is consistent and up to date.

**Example Workflow:**
```sh
# After implementing a new feature
git add src/NewFeature.rs
git commit -m "feat: add NewFeature module"

# Update documentation
vim README.md
vim _docs/README.md

# Commit documentation updates
git add README.md _docs/README.md
git commit -m "docs: update documentation for NewFeature"

# Optionally, use the suggested command in PR comments
/update-docs
```

## Testing Patterns

- **Test Framework:** Unknown (no specific framework detected)
- **Test File Pattern:** Files named with `*.test.*`
  - **Example:** `MountOptions.test.rs`
- Tests are likely written in Rust's built-in test format:
    ```rust
    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn test_mount_options() {
            // test implementation
        }
    }
    ```

## Commands

| Command        | Purpose                                                        |
|----------------|----------------------------------------------------------------|
| /update-docs   | Run the workflow to update README and related documentation    |

```