# Example: Python CLI Project

This example shows how to configure KitchenLoop for a Python command-line tool.

## Project: docgen

A documentation generator that reads source code and produces formatted output.
It has 5 subcommands, 4 output formats, 4 input sources, and 5 error conditions.

## Spec Surface

The spec surface has 4 dimensions:

- **subcommands**: generate, serve, validate, init, config
- **output_formats**: html, markdown, pdf, json
- **input_sources**: single_file, directory, git_repo, stdin
- **error_conditions**: valid_input, missing_input, permission_denied, corrupt_input, empty_input

Total combinations: 400, minus blocked: ~300 testable.

## Blocked Combinations

Several combinations are blocked because they are not supported:
- `serve` does not produce PDF or JSON
- `validate` only outputs plain text
- `init` and `config` do not take input sources
- `stdin` is not supported for `serve`

## Usage

```bash
# Copy this config to your project
cp kitchenloop.yaml /path/to/your-cli-project/

# Edit to match your project
$EDITOR /path/to/your-cli-project/kitchenloop.yaml

# Run
kitchenloop.sh --once
```

## What to Customize

1. **subcommands**: Replace with your CLI's actual subcommands
2. **output_formats**: Replace with your output types (or remove if not applicable)
3. **input_sources**: Replace with your input types
4. **error_conditions**: Keep these or add project-specific error modes
5. **test_command**: Point to your actual test runner
6. **lint_command**: Point to your actual linter
