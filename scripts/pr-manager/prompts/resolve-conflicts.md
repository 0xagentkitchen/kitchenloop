# Resolve Merge Conflicts

You are resolving merge conflicts on a PR branch.

## Steps

1. **Identify conflicts**:
   ```bash
   git diff --name-only --diff-filter=U
   ```

2. **For each conflicted file**:
   - Read both versions
   - Resolve by preferring the PR branch's intent (the feature being added)
   - Keep base branch structural changes (renames, formatting) where they don't conflict with the feature
   - When in doubt, keep the PR branch version and note the resolution

3. **After resolving all conflicts**:
   ```bash
   git add .
   git commit -m "chore: resolve merge conflicts"
   ```

4. **Verify**:
   - Run lint to ensure no syntax errors
   - Run quick tests to ensure nothing is broken
   - If lint/tests fail, fix and commit again

5. **Push**:
   ```bash
   git push
   ```

## Output

- `RESOLVED` — All conflicts resolved, lint passes, pushed
- `STUCK` — Could not resolve conflicts automatically (explain which files and why)

## Rules

- NEVER drop changes from either side silently — always explain your resolution logic
- If a conflict involves generated files (lock files, etc.), regenerate them rather than manually merging
- If a conflict is in test expectations, prefer the PR branch values and re-run tests to verify
