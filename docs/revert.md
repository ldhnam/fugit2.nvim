# Reverting Commits

Fugit2 provides commit reverting through libgit2's native revert API — no shell subprocess calls. Reverting creates a new commit that applies the inverse of a previous commit's changes, leaving full history intact.

## Opening the Revert Menu

From the status window (`:Fugit2`), press `V` to open the reverting menu.

## Revert Menu Actions

| Key | Action | Description |
|-----|--------|-------------|
| `V` | Revert commit(s) | Revert the commit currently selected in the commit log. |

## Reverting from the Commit Log

Press `V` while the cursor is on a commit in the commit log (right panel) to revert that commit directly, without going through the menu.

A confirmation prompt is shown before the revert is applied:

```
󰕍 Revert commit a1b2c3d4?
```

Press `y` to confirm or `n` / `<Esc>` to cancel.

## What Happens on Revert

1. The inverse of the selected commit's changes is applied to the working directory and index.
2. A new commit is automatically created with the message:

```
Revert "<original commit summary>"

This reverts commit <full 40-character OID>.
```

3. The status view refreshes to reflect the new HEAD.

## Conflicts

If the revert produces conflicts (e.g. the original change has already been partially overwritten), libgit2 returns an error and no commit is created. The status view will show the conflicting files, which must be resolved manually before committing.

---

## Technical Details

This section covers the implementation architecture for contributors and maintainers.

### Files Changed

| File | Role |
|------|------|
| `lua/fugit2/core/libgit2.lua` | FFI C declarations for revert API |
| `lua/fugit2/core/git2.lua` | `Repository:revert` Lua wrapper method |
| `lua/fugit2/view/git_status.lua` | Menu integration, action method, keybindings |

### FFI Layer (`libgit2.lua`)

#### C Declarations

Added inside the `ffi.cdef` block:

```c
typedef struct git_revert_options {
  unsigned int version;
  unsigned int mainline;          /* for merge commits: which parent is "mainline" */
  git_merge_options merge_opts;
  git_checkout_options checkout_opts;
} git_revert_options;

int git_revert(git_repository *repo, git_commit *commit,
               const git_revert_options *given_opts);
```

`git_revert` updates both the working directory and the index with the inverse of `commit`'s changes. It does **not** create a commit — that step is handled by `Repository:revert` in `git2.lua`.

#### Constants

```lua
M.GIT_REVERT_OPTIONS_VERSION = 1

M.GIT_REVERT_OPTIONS_INIT = {
  { M.GIT_REVERT_OPTIONS_VERSION, 0, M.GIT_MERGE_OPTIONS_INIT[1], M.GIT_CHECKOUT_OPTIONS_INIT[1] },
}
```

The init table embeds the standard merge and checkout option defaults. `mainline = 0` means the first parent is used for merge commits (same as `git revert` CLI default).

### Repository Method (`git2.lua`)

#### `revert(oid, signature)`

```lua
function Repository:revert(oid, signature)
```

**Steps:**

1. Looks up the commit via `commit_lookup(oid)`.
2. Captures `commit:summary()` for the revert message subject.
3. Captures `oid:tostring(40)` for the revert message body.
4. Calls `git_revert(repo, commit, opts)` — applies inverse changes to index and workdir.
5. Fetches the updated index via `self:index()`.
6. Calls `self:create_commit(index, signature, message)` to produce the revert commit.
7. Returns `(new_oid, 0)` on success or `(nil, err_code)` on failure.

The revert message format matches the `git revert` CLI:

```
Revert "<summary>"

This reverts commit <40-char-oid>.
```

**Return convention:** Follows the standard `result, err_code` pattern used throughout `git2.lua`. A non-zero error code means the operation failed (e.g. commit not found, merge conflict, index write failure).

### Status View Integration (`git_status.lua`)

#### Menu Wiring

Follows the same 5-step pattern as all other menus:

1. **Enum**: `REVERT = 10` added to `Menu` table.
2. **Data**: `_init_menus` elseif branch with a single action item (`V`).
3. **Wiring**: `_init_revert_menu()` calls `_init_menus(Menu.REVERT)` then registers `on_submit` dispatcher.
4. **Dispatch table**: `MENU_INITS[Menu.REVERT] = GitStatus._init_revert_menu`.
5. **Keybinding**: `file_tree:map("n", "V", ...)` opens the menu; `commit_log:map("n", "V", ...)` reverts directly.

The menu is lazily constructed on first `V` keypress from the file tree and cached in `self._menus[10]`.

#### `revert_commit()`

```lua
function GitStatus:revert_commit()
```

1. Gets the commit at cursor from `commit_log:get_commit()`.
2. Converts `commit.oid` (string) to `GitObjectId` via `git2.ObjectId.from_string`.
3. Reads `self._git.signature` (cached during `init()`).
4. Shows `UI.Confirm` prompt.
5. On confirmation, calls `self.repo:revert(oid, signature)`.
6. On success: `notifier.info`, `self:update_then_render()`.
7. On failure: `notifier.error(message, err_code)`.

#### Keybindings

| Context | Key | Behavior |
|---------|-----|----------|
| File tree | `V` | Opens the Reverting menu |
| Commit log | `V` | Reverts the commit at cursor directly |

Both paths call `GitStatus:revert_commit()`. The menu path provides discoverability for users unfamiliar with the direct binding.

### Data Flow

```
V keypress (file tree)
  -> _menu_handlers(Menu.REVERT)
    -> lazy _init_revert_menu() -> cached
    -> menu:mount()

V selection in menu
  -> on_submit("V", _)
    -> revert_commit()

V keypress (commit log)
  -> revert_commit()

revert_commit():
  commit_log:get_commit()
  ObjectId.from_string(commit.oid)
  UI.Confirm:show()
    -> on_yes:
      repo:revert(oid, signature)
        -> git_commit_lookup(oid)
        -> git_revert(repo, commit, opts)   -- updates index + workdir
        -> repo:index()
        -> repo:create_commit(index, sig, message)
      -> notifier feedback
      -> update_then_render()
```

### Error Handling

Follows the codebase convention:

- FFI calls return integer error codes (0 = success).
- On failure, `notifier.error(message, err_code)` is called and the status view is not refreshed.
- Merge conflicts from `git_revert` produce a non-zero error code; no partial state is committed.

### Testing

Tests live in `spec/fugit2/core/revert_spec.lua`:

| Test | Coverage |
|------|----------|
| `revert` returns a new OID | Operation succeeds and new OID differs from reverted commit |
| File content restored | Working tree reflects pre-revert-commit state after revert |
| Commit message format | New HEAD message matches `Revert "<summary>"` pattern |
| Commit message includes OID | Body contains 40-character hex OID of the reverted commit |
| Invalid OID fails | All-zeros OID returns non-zero error and nil OID |

Run tests with:

```bash
luarocks test --local -- --config-file=nlua.busted spec/fugit2/core/revert_spec.lua
```
